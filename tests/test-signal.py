#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
"""
The conversions, and the whole path through them.

This is where the actual repair lives: two fields arrive swapped, both without
their sign, and a third is an ASU index pretending to be nothing in
particular. Every one of those is a silent failure - wrong numbers, never an
exception - so the only way to keep them honest is to pin them down here.

The module under test is patched-files/mm_modem_signal.py, not the installed
copy, so this runs on a desk as well as on the phone.
"""
import asyncio
import importlib.util
import os
import sys
import types

# No .pyc next to the module under test: patched-files/ is installed verbatim,
# and a __pycache__ directory appearing in it breaks the installer's glob.
sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

RUN = 0
FAILED = 0


def check(desc, want, got):
    global RUN, FAILED
    RUN += 1
    if want == got:
        print(f"  \033[32mok\033[0m   {desc}")
    else:
        FAILED += 1
        print(f"  \033[31mFAIL\033[0m {desc}\n       expected [{want}], got [{got}]")


# --- load the module --------------------------------------------------------
#
# dbus_fast is on the phone but not necessarily anywhere else. Use the real one
# when it is there, so the test exercises real Variants, and fall back to a
# stub small enough to read.
try:
    import dbus_fast  # noqa: F401
except ImportError:
    fast = types.ModuleType("dbus_fast")

    class Variant:
        def __init__(self, signature, value):
            self.signature, self.value = signature, value

        def __eq__(self, other):
            return (isinstance(other, Variant)
                    and self.signature == other.signature and self.value == other.value)

        def __repr__(self):
            return f"Variant({self.signature!r}, {self.value!r})"

    class DBusError(Exception):
        pass

    fast.Variant, fast.DBusError = Variant, DBusError
    service = types.ModuleType("dbus_fast.service")

    class ServiceInterface:
        def __init__(self, name):
            self.name = name

        def emit_properties_changed(self, changed):
            pass

    service.ServiceInterface = ServiceInterface
    service.method = lambda *a, **k: (lambda f: f)
    service.dbus_property = lambda *a, **k: (lambda f: f)
    constants = types.ModuleType("dbus_fast.constants")
    constants.PropertyAccess = types.SimpleNamespace(READ="read")
    fast.service, fast.constants = service, constants
    sys.modules["dbus_fast"] = fast
    sys.modules["dbus_fast.service"] = service
    sys.modules["dbus_fast.constants"] = constants

# ofono2mm.logging is a one-function module; a stub keeps the test from needing
# the package installed at all.
pkg = types.ModuleType("ofono2mm")
pkg.__path__ = []
logging_mod = types.ModuleType("ofono2mm.logging")
logging_mod.ofono2mm_print = lambda *a, **k: None
sys.modules.setdefault("ofono2mm", pkg)
sys.modules["ofono2mm.logging"] = logging_mod

spec = importlib.util.spec_from_file_location(
    "mm_modem_signal", os.path.join(ROOT, "patched-files", "mm_modem_signal.py"))
sig = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sig)

from dbus_fast import Variant  # noqa: E402


# --- the individual conversions --------------------------------------------
print("\n\033[1m== magnitudes become real dBm\033[0m")
# The HAL drops the sign. 121 is -121 dBm, and -121 dBm is a plausible RSRP.
check("RSRP magnitude 121 -> -121 dBm", -121.0,
      sig._signed_level(Variant("y", 121), sig.RSRP_RANGE))
check("RSRQ magnitude 12 -> -12 dB", -12.0,
      sig._signed_level(Variant("y", 12), sig.RSRQ_RANGE))
# Out of range is the HAL saying "I do not know". Forwarding it would put
# rsrq=-121 dB into ModemManager, which is what the bug looked like.
check("an RSRP value in the RSRQ range is rejected", None,
      sig._signed_level(Variant("y", 121), sig.RSRQ_RANGE))
check("0 is not a measurement", None, sig._signed_level(Variant("y", 0), sig.RSRP_RANGE))
check("255 is out of range", None, sig._signed_level(Variant("y", 255), sig.RSRP_RANGE))
check("a missing field is not a measurement", None,
      sig._signed_level(None, sig.RSRP_RANGE))

print("\n\033[1m== Strength is an ASU index, not a percentage\033[0m")
check("ASU 0 -> -113 dBm", -113.0, sig._asu_to_rssi(Variant("y", 0)))
check("ASU 21 -> -71 dBm", -71.0, sig._asu_to_rssi(Variant("y", 21)))
check("ASU 31 -> -51 dBm", -51.0, sig._asu_to_rssi(Variant("y", 31)))
check("ASU 99 means unknown", None, sig._asu_to_rssi(Variant("y", 99)))

print("\n\033[1m== the bar\033[0m")
check("nothing measured, nothing to draw", None,
      sig._quality_percent(None, sig.RSRP_QUALITY_POINTS))
check("below the floor is 0 %", 0, sig._quality_percent(-150.0, sig.RSRP_QUALITY_POINTS))
check("above the ceiling is 100 %", 100, sig._quality_percent(-40.0, sig.RSRP_QUALITY_POINTS))
# The anchors are AOSP's LTE level thresholds; if someone moves them, the bar
# stops matching what the same radio shows on Android.
check("AOSP threshold -98 dBm", 70, sig._quality_percent(-98.0, sig.RSRP_QUALITY_POINTS))
check("AOSP threshold -108 dBm", 50, sig._quality_percent(-108.0, sig.RSRP_QUALITY_POINTS))
check("AOSP threshold -118 dBm", 30, sig._quality_percent(-118.0, sig.RSRP_QUALITY_POINTS))
check("AOSP threshold -128 dBm", 10, sig._quality_percent(-128.0, sig.RSRP_QUALITY_POINTS))

monotonic = True
previous = -1
for dbm in range(-150, -39):
    value = sig._quality_percent(float(dbm), sig.RSRP_QUALITY_POINTS)
    if value < previous or not 0 <= value <= 100:
        monotonic = False
        break
    previous = value
check("more signal never means fewer bars, and it stays within 0-100",
      True, monotonic)

print("\n\033[1m== bit error rate\033[0m")
check("RXQUAL 0 is the best class", 0.14, sig._ber_percent(Variant("y", 0)))
check("RXQUAL 7 is the worst class", 18.10, sig._ber_percent(Variant("y", 7)))
check("RXQUAL 8 does not exist", None, sig._ber_percent(Variant("y", 8)))


# --- the whole path ---------------------------------------------------------
#
# Two real readings taken off this phone. The first is the weak cell that
# started all of this; the second is the strong one measured earlier the same
# day. Before the fix the first came out as rsrp=+12 dBm, rsrq=+121 dB.
class FakeProps:
    def __init__(self, props):
        self.props = props

    def __getitem__(self, key):
        return self.props[key]

    def __contains__(self, key):
        return key in self.props


class FakeInterfaceProps:
    def __init__(self, mapping):
        self.mapping = mapping

    def __getitem__(self, key):
        return self.mapping[key]

    def __contains__(self, key):
        return key in self.mapping


class FakeNetworkMonitor:
    def __init__(self, cellinfo):
        self.cellinfo = cellinfo

    async def call_get_serving_cell_information(self):
        return self.cellinfo


class FakeModem:
    def __init__(self):
        self.quality = None

    def update_signal_quality(self, quality):
        self.quality = quality


def run_once(cellinfo):
    props = FakeInterfaceProps({
        "org.ofono.SimManager": FakeProps({
            "Present": Variant("b", True),
            "PinRequired": Variant("s", "none"),
        }),
    })
    modem = FakeModem()
    iface = sig.MMModemSignalInterface(
        "/ril_0", {"org.ofono.NetworkMonitor": FakeNetworkMonitor(cellinfo)},
        props, False, modem)
    asyncio.run(iface.set_props())
    return iface, modem


print("\n\033[1m== the whole path, on readings taken off the phone\033[0m")
weak, modem = run_once({
    "Technology": Variant("s", "lte"),
    "Strength": Variant("y", 2),
    "ReferenceSignalReceivedQuality": Variant("y", 121),   # really RSRP
    "ReferenceSignalReceivedPower": Variant("y", 12),      # really RSRQ
    "EARFCN": Variant("q", 350),
})
check("weak cell: rsrp", -121.0, weak.props["Lte"].value["rsrp"].value)
check("weak cell: rsrq", -12.0, weak.props["Lte"].value["rsrq"].value)
check("weak cell: rssi from ASU 2", -109.0, weak.props["Lte"].value["rssi"].value)
check("weak cell: one bar", 24, modem.quality)

strong, modem = run_once({
    "Technology": Variant("s", "lte"),
    "Strength": Variant("y", 21),
    "ReferenceSignalReceivedQuality": Variant("y", 78),
    "ReferenceSignalReceivedPower": Variant("y", 8),
})
check("strong cell: rsrp", -78.0, strong.props["Lte"].value["rsrp"].value)
check("strong cell: rsrq", -8.0, strong.props["Lte"].value["rsrq"].value)
check("strong cell: full bar", 98, modem.quality)

# CQI used to be written into rssi. It is a modulation index 0-15; as a
# received power it would read as -15 dBm, better than any real cell.
cqi, _ = run_once({
    "Technology": Variant("s", "lte"),
    "Strength": Variant("y", 21),
    "ReferenceSignalReceivedQuality": Variant("y", 78),
    "ReferenceSignalReceivedPower": Variant("y", 8),
    "ChannelQualityIndicator": Variant("y", 11),
})
check("CQI never reaches rssi", -71.0, cqi.props["Lte"].value["rssi"].value)

# A fallback to GSM used to leave the old LTE numbers on display.
gsm, modem = run_once({
    "Technology": Variant("s", "gsm"),
    "Strength": Variant("y", 15),
    "BitErrorRate": Variant("y", 2),
})
check("on GSM, rssi comes from ASU 15", -83.0, gsm.props["Gsm"].value["rssi"].value)
check("on GSM, the bit error class becomes a percentage", 0.57,
      gsm.props["Gsm"].value["error-rate"].value)
check("on GSM, the stale LTE reading is cleared", 0.0,
      gsm.props["Lte"].value["rsrp"].value)

# An empty or failed read says nothing about the radio; blanking the bar on it
# would make every hiccup look like lost service.
kept, modem = run_once({})
check("an empty answer keeps the last reading", 0.0,
      kept.props["Lte"].value["rsrp"].value)
check("an empty answer reports no quality", None, modem.quality)

print(f"\n  {RUN} checks, {FAILED} failed")
sys.exit(1 if FAILED else 0)
