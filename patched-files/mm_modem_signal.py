import asyncio

from copy import deepcopy

from dbus_fast.service import ServiceInterface, method, dbus_property
from dbus_fast.constants import PropertyAccess
from dbus_fast import Variant, DBusError

from ofono2mm.logging import ofono2mm_print

# How often the serving cell measurements are refreshed on our own initiative.
#
# oFono only publishes cell info on demand: GetServingCellInformation makes the
# cellinfo netmon plugin switch RIL cell reporting on at a 500 ms interval,
# waits for the first update and switches it off again. So one poll costs about
# half a second of cell reporting, not a permanently enabled radio report.
SIGNAL_POLL_INTERVAL = 30

# The interface is exported long before the SIM is readable and the modem is
# registered, so the first few reads come back empty. Retry quickly until one
# lands instead of leaving the signal bar blank for a full interval after every
# start, but give up on the hurry so an unregistered modem is not polled hard
# forever.
SIGNAL_POLL_STARTUP_INTERVAL = 3
SIGNAL_POLL_STARTUP_TRIES = 20

# Plausible ranges, used to throw away the "unknown" placeholders the HAL likes
# to send (0, 99, 0x7fffffff, ...) instead of feeding them to ModemManager.
RSRP_RANGE = (-140.0, -43.0)   # dBm, 36.133
RSRQ_RANGE = (-25.0, -3.0)     # dB, 36.133
RSCP_RANGE = (-125.0, -25.0)   # dBm

# 3GPP 05.08 RXQUAL classes 0-7 expressed as a representative bit error rate in
# percent. oFono hands out the class index, ModemManager documents a percentage.
BER_CLASS_PERCENT = (0.14, 0.28, 0.57, 1.13, 2.26, 4.53, 9.05, 18.10)

# Signal bar anchor points, (measurement in dBm, quality in percent). The RSRP
# anchors follow the level thresholds AOSP's CellSignalStrengthLte uses
# (-128 / -118 / -108 / -98), so the bar count matches what the same radio
# would show on Android.
RSRP_QUALITY_POINTS = (
    (-140.0, 0.0), (-128.0, 10.0), (-118.0, 30.0),
    (-108.0, 50.0), (-98.0, 70.0), (-88.0, 90.0), (-75.0, 100.0),
)
RSSI_QUALITY_POINTS = (
    (-113.0, 0.0), (-107.0, 10.0), (-98.0, 30.0),
    (-89.0, 50.0), (-80.0, 70.0), (-70.0, 90.0), (-60.0, 100.0),
)

def _signed_level(variant, valid_range):
    """
    Turn one of oFono's reference signal bytes into a real dBm/dB reading.

    The binder HAL reports RSRP, RSRQ and RSCP as positive magnitudes, the sign
    simply dropped, while the ModemManager API is defined in actual dBm and dB.
    Handing the raw byte through is what made mmcli print impossibilities like
    rsrp=18 dBm and rsrq=100 dB. Returns None when the value is not usable.
    """
    if variant is None:
        return None

    try:
        value = float(variant.value)
    except (AttributeError, TypeError, ValueError):
        return None

    if value == 0:
        return None

    value = -abs(value)
    low, high = valid_range
    return value if low <= value <= high else None

def _asu_to_rssi(variant):
    """
    oFono's "Strength" is <rssi> as defined in 27.007 section 8.5: an ASU index
    from 0 to 31, with 99 meaning unknown. It is not a percentage, even though
    NetworkRegistration.Strength on other drivers is one.
    """
    if variant is None:
        return None

    try:
        asu = int(variant.value)
    except (AttributeError, TypeError, ValueError):
        return None

    if asu < 0 or asu > 31:
        return None

    return -113.0 + 2.0 * asu

def _ber_percent(variant):
    if variant is None:
        return None

    try:
        rxqual = int(variant.value)
    except (AttributeError, TypeError, ValueError):
        return None

    if rxqual < 0 or rxqual >= len(BER_CLASS_PERCENT):
        return None

    return BER_CLASS_PERCENT[rxqual]

def _quality_percent(value, points):
    """Piecewise linear interpolation of a dBm reading onto a 0-100 bar."""
    if value is None:
        return None

    if value <= points[0][0]:
        return int(points[0][1])
    if value >= points[-1][0]:
        return int(points[-1][1])

    for (x0, y0), (x1, y1) in zip(points, points[1:]):
        if x0 <= value <= x1:
            return int(round(y0 + (y1 - y0) * (value - x0) / (x1 - x0)))

    return None

class MMModemSignalInterface(ServiceInterface):
    def __init__(self, modem_name, ofono_interfaces, ofono_interface_props, verbose=False, mm_modem=None):
        super().__init__('org.freedesktop.ModemManager1.Modem.Signal')
        self.modem_name = modem_name
        ofono2mm_print("Initializing Signal interface", verbose)
        self.ofono_interfaces = ofono_interfaces
        self.ofono_interface_props = ofono_interface_props
        self.mm_modem = mm_modem
        self.is_busy = False
        self.have_measurement = False
        self.verbose = verbose
        self.props = {
            'Rate': Variant('u', 0),
            'RssiThreshold': Variant('u', 0),
            'ErrorRateThreshold': Variant('b', False),
            'Gsm': Variant('a{sv}', {
                'rssi': Variant('d', 0),
                'error-rate': Variant('d', 0)
            }),
            'Umts': Variant('a{sv}', {
                'rssi': Variant('d', 0),
                'rscp': Variant('d', 0),
                'ecio': Variant('d', 0),
                'error-rate': Variant('d', 0)
            }),
            'Lte': Variant('a{sv}', {
                'rssi': Variant('d', 0),
                'rsrq': Variant('d', 0),
                'rsrp': Variant('d', 0),
                'snr': Variant('d', 0),
                'error-rate': Variant('d', 0)
            }),
            'Nr5g': Variant('a{sv}', {
                'rsrq': Variant('d', 0),
                'rsrp': Variant('d', 0),
                'snr': Variant('d', 0),
                'error-rate': Variant('d', 0)
            })
        }

    def _set(self, group, key, value):
        """Write one measurement, or clear it when we have nothing to say."""
        self.props[group].value[key] = Variant('d', float(value) if value is not None else 0)

    def _clear_groups(self, keep):
        """
        Zero the access technologies we are not camped on. Without this the LTE
        numbers from before a fallback keep being served while the modem is on
        GSM, and mmcli happily prints both.
        """
        for group in ('Gsm', 'Umts', 'Lte', 'Nr5g'):
            if group == keep:
                continue
            for key in self.props[group].value:
                self._set(group, key, None)

    async def set_props(self):
        ofono2mm_print("Setting properties", self.verbose)

        if self.is_busy:
            return

        if 'org.ofono.SimManager' in self.ofono_interface_props and 'Present' in self.ofono_interface_props['org.ofono.SimManager'].props:
            sim_props = self.ofono_interface_props['org.ofono.SimManager']
            if not sim_props['Present'].value:
                ofono2mm_print("SIM is not present. no need to set signal props", self.verbose)
                return
        else:
            ofono2mm_print("SIM manager is not up yet. cannot set signal props", self.verbose)
            return

        pin_required = sim_props['PinRequired'].value if 'PinRequired' in sim_props.props else None
        if pin_required is not None and pin_required != 'none':
            ofono2mm_print("SIM is still locked and/or not ready. cannot set signal props", self.verbose)
            return

        if 'org.ofono.NetworkMonitor' in self.ofono_interfaces:
            self.is_busy = True
            old_props = deepcopy(self.props)

            cellinfo = {}
            try:
                cellinfo = await self.ofono_interfaces['org.ofono.NetworkMonitor'].call_get_serving_cell_information()
            except Exception as e:
                ofono2mm_print(f"Failed to get cell info from NetworkMonitor: {e}", self.verbose)
            finally:
                self.is_busy = False

            tech = cellinfo.get('Technology', Variant('s', '')).value
            if not tech:
                # A failed or empty read says nothing about the radio. Keep the
                # last known measurements rather than blanking the signal bar.
                return

            rssi = _asu_to_rssi(cellinfo.get('Strength'))
            quality = None

            if tech in ('lte', 'nr'):
                # oFono's cellinfo netmon plugin swaps these two. In
                # plugins/cellinfo-netmon.c the HAL's lte->rsrp is published as
                # OFONO_NETMON_INFO_RSRQ ("ReferenceSignalReceivedQuality") and
                # lte->rsrq as OFONO_NETMON_INFO_RSRP
                # ("ReferenceSignalReceivedPower"). Read them back crosswise.
                rsrp = _signed_level(cellinfo.get('ReferenceSignalReceivedQuality'), RSRP_RANGE)
                rsrq = _signed_level(cellinfo.get('ReferenceSignalReceivedPower'), RSRQ_RANGE)

                group = 'Nr5g' if tech == 'nr' else 'Lte'
                self._set(group, 'rsrp', rsrp)
                self._set(group, 'rsrq', rsrq)
                if group == 'Lte':
                    # Not ChannelQualityIndicator: CQI is a modulation hint on a
                    # 0-15 scale, not a received power in dBm.
                    self._set(group, 'rssi', rssi)
                self._clear_groups(group)

                quality = _quality_percent(rsrp, RSRP_QUALITY_POINTS)
                if quality is None:
                    quality = _quality_percent(rssi, RSSI_QUALITY_POINTS)
            elif tech == 'umts':
                # The plugin's wcdma path only ever emits Strength and the bit
                # error rate, so rscp is normally absent here.
                self._set('Umts', 'rscp', _signed_level(cellinfo.get('ReceivedSignalCodePower'), RSCP_RANGE))
                self._set('Umts', 'rssi', rssi)
                self._set('Umts', 'error-rate', _ber_percent(cellinfo.get('BitErrorRate')))
                self._clear_groups('Umts')

                quality = _quality_percent(rssi, RSSI_QUALITY_POINTS)
            elif tech == 'gsm':
                self._set('Gsm', 'rssi', rssi)
                self._set('Gsm', 'error-rate', _ber_percent(cellinfo.get('BitErrorRate')))
                self._clear_groups('Gsm')

                quality = _quality_percent(rssi, RSSI_QUALITY_POINTS)

            # This modem's HAL never feeds oFono's NetworkRegistration.Strength,
            # so the modem interface has nothing of its own to build
            # SignalQuality from and the shell would draw an empty bar forever.
            if quality is not None:
                self.have_measurement = True
                if self.mm_modem is not None:
                    self.mm_modem.update_signal_quality(quality)

            changed_props = {}
            for prop in self.props:
                if self.props[prop].value != old_props[prop].value:
                    changed_props.update({ prop: self.props[prop].value })

            if changed_props:
                self.emit_properties_changed(changed_props)

    async def poll_signal(self):
        """
        Keep the measurements fresh. oFono pushes no signal strength at all on
        this modem, so nothing else would ever move the bar between cell
        changes.
        """
        tries = 0

        while True:
            if self.have_measurement or tries >= SIGNAL_POLL_STARTUP_TRIES:
                await asyncio.sleep(SIGNAL_POLL_INTERVAL)
            else:
                tries += 1
                await asyncio.sleep(SIGNAL_POLL_STARTUP_INTERVAL)

            try:
                await self.set_props()
            except asyncio.CancelledError:
                raise
            except Exception as e:
                ofono2mm_print(f"Failed to poll signal: {e}", self.verbose)

    @method()
    def Setup(self, rate: 'u'):
        ofono2mm_print(f"Setup with rate {rate}", self.verbose)
        self.props['Rate'] = Variant('u', rate)
        self.emit_properties_changed({'Rate': self.props['Rate'].value})

    @method()
    def SetupThresholds(self, settings: 'a{sv}'):
        raise DBusError('org.freedesktop.ModemManager1.Error.Core.Unsupported', 'Cannot setup thresholds: operation not supported')

    @dbus_property(access=PropertyAccess.READ)
    def Rate(self) -> 'u':
        return self.props['Rate'].value

    @dbus_property(access=PropertyAccess.READ)
    def RssiThreshold(self) -> 'u':
        return self.props['RssiThreshold'].value

    @dbus_property(access=PropertyAccess.READ)
    def ErrorRateThreshold(self) -> 'b':
        return self.props['ErrorRateThreshold'].value

    @dbus_property(access=PropertyAccess.READ)
    def Gsm(self) -> 'a{sv}':
        return self.props['Gsm'].value

    @dbus_property(access=PropertyAccess.READ)
    def Umts(self) -> 'a{sv}':
        return self.props['Umts'].value

    @dbus_property(access=PropertyAccess.READ)
    def Lte(self) -> 'a{sv}':
        return self.props['Lte'].value

    @dbus_property(access=PropertyAccess.READ)
    def Nr5g(self) -> 'a{sv}':
        return self.props['Nr5g'].value

    def ofono_changed(self, _name, _varval):
        asyncio.create_task(self.set_props())

    def ofono_interface_changed(self, _iface):
        def ch(_name, _varval):
            asyncio.create_task(self.set_props())
        return ch
