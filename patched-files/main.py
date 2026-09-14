#! /usr/bin/python3

import asyncio
import sys
from os import environ
from argparse import ArgumentParser

from dbus_fast.aio import MessageBus
from dbus_fast.service import (ServiceInterface,
                               method, dbus_property)
from dbus_fast.constants import PropertyAccess
from dbus_fast import DBusError, BusType, Message, Variant

from ofono2mm import MMModemInterface, Ofono, DBus
from ofono2mm.logging import ofono2mm_print
from typing import Dict

def get_version():
    return "1.24.0"

MM_ROOT = '/org/freedesktop/ModemManager1'
MM_MODEM_PREFIX = MM_ROOT + '/Modem/'
MM_MODEM_IFACE = 'org.freedesktop.ModemManager1.Modem'

class ModemManagerBus(MessageBus):
    """A bus whose ObjectManager announces modems and nothing else.

    ModemManager puts its SIM and bearer objects on the bus under
    /org/freedesktop/ModemManager1/SIM/n and /Bearer/n, but it does not
    hand them out through the ObjectManager at /org/freedesktop/ModemManager1
    -- that one carries modems only. dbus_fast has no such distinction: it
    answers GetManagedObjects from every exported sub-path, so ours announces
    the SIM and every bearer as well.

    libmm-glib wraps each entry in an MMObject, and a client that takes one
    and asks for its Modem interface gets NULL. phosh takes the first entry
    of the list ("Modem interface is always present"), remembers it, and
    never looks at another object -- so when a bearer happens to come first,
    the phone shows no signal at all until something restarts. Which entry
    comes first is hash order, which is why it looked intermittent.

    So keep the non-modem paths off the ObjectManager. They stay exported and
    reachable at their own paths; they are simply not announced, exactly as
    ModemManager does it.
    """

    __slots__ = ('_ready_modems', 'something_to_show')

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        # Modems that have finished coming up. Until a modem is in here it is
        # not handed out and not announced - see _is_complete.
        self._ready_modems = set()
        # Set once there is either a modem worth showing or nothing to wait
        # for. main() holds the bus name back until then.
        self.something_to_show = asyncio.Event()

    def announce_modem(self, path):
        """Say that the modem at this path is ready to be looked at.

        This is what upstream's release-and-request of the bus name was for:
        the modem is built, the interfaces are exported, now tell everyone.
        Losing the bus name made every client enumerate again, which is one way
        to be noticed and a very expensive one - see FINDINGS.md, defect 16.
        An InterfacesAdded says the same thing to the same clients, and costs
        nobody their signal icon.
        """
        self._ready_modems.add(path)
        self.something_to_show.set()
        interfaces = list(self._path_exports.get(path, {}).values())
        if interfaces:
            self._announce(path, interfaces)

    def _announce_modem_eventually(self, path, delay=10):
        # A modem that never reports itself ready would otherwise stay
        # invisible for ever - a worse failure than the one this fixes. Every
        # path into MMModemInterface ends in announce_modem, so this net should
        # never catch anything; it is here because "should" is not a guarantee
        # and a phone without a modem is not an acceptable way to find out.
        try:
            loop = asyncio.get_running_loop()
        except RuntimeError:
            return
        loop.call_later(delay, self.announce_modem, path)

    @staticmethod
    def _is_announced(path):
        if not path.startswith(MM_ROOT + '/'):
            return True
        return path.startswith(MM_MODEM_PREFIX)

    def _is_complete(self, path):
        """Whether a modem path is worth showing to anybody yet.

        ofono2mm builds a modem in pieces: the Modem interface is exported
        before the bus name is even requested, the other fourteen follow one at
        a time, and the SIM, the bands and the capabilities are filled in after
        that. A client that looks in the middle of it gets something that
        cannot be used and does not get a second chance:

            mm_object_peek_modem: runtime check failed: (MM_IS_MODEM (modem))
            modem with path .../Modem/0 doesn't have the Modem interface, ignoring

            modem-broadband[/ril_0]: failed to retrieve SIM object: No SIM
            object available

        Both measured on 14.9., twenty milliseconds after the bus name
        appeared. ModemManager itself never shows a half-built modem: it
        exports the object when it is finished. So this one waits for the
        modem to say it is ready, which is the moment upstream chose too - it
        just said so by throwing its bus name away.
        """
        if not path.startswith(MM_MODEM_PREFIX):
            return True
        return path in self._ready_modems

    def _default_get_managed_objects_handler(self, msg, send_reply):
        if msg.path != MM_ROOT:
            return super()._default_get_managed_objects_handler(msg, send_reply)

        # The handler reads _path_exports synchronously to pick its nodes and
        # their interfaces; the property callbacks that finish the reply later
        # never touch it. Narrowing it for the length of the call is therefore
        # enough, and it reuses dbus_fast's logic rather than copying it.
        every = self._path_exports
        self._path_exports = {
            path: interfaces
            for path, interfaces in every.items()
            if self._is_announced(path) and self._is_complete(path)
        }
        try:
            return super()._default_get_managed_objects_handler(msg, send_reply)
        finally:
            self._path_exports = every

    # Both announcements go out from the object manager's own path, and not
    # from the path of the object that changed, which is where dbus_fast sends
    # them. The specification is explicit: InterfacesAdded and
    # InterfacesRemoved belong on the manager's path, with the object path as
    # the first argument - and that is where every client is listening,
    # because that is where it subscribed. Sent from the object's own path
    # they reach nobody at all: NetworkManager, phosh and chatty all watch
    # /org/freedesktop/ModemManager1 and never hear that a modem appeared.
    #
    # This is what release_request_modemmanager in mm_modem.py was working
    # around - with a TODO beside it asking why it should be necessary. With
    # no announcement that arrives, the only way a client learns about the
    # modem is to enumerate all over again, and taking the bus name away
    # forces it to. That trick also costs the phone its signal icon, because
    # in the moment nobody owns the name a client's GetManagedObjects is
    # refused and GLib never asks again. See FINDINGS.md, defect 16.
    # And a modem is announced once, with everything it has, the way
    # ModemManager itself does it. libmm-glib builds its MMObject from the
    # first announcement that names the object, and NetworkManager throws that
    # object away for good when the Modem interface is not in it:
    #
    #   mm_object_peek_modem: runtime check failed: (MM_IS_MODEM (modem))
    #   modem with path .../Modem/0 doesn't have the Modem interface, ignoring
    #
    # dbus_fast announces one interface per export call and ofono2mm exports
    # fifteen of them in a row, so which one happened to go first decided
    # whether the phone had mobile data at all. Measured 14.9.: with the
    # announcements corrected but still one at a time, NetworkManager dropped
    # the modem on every restart.
    def _emit_interface_added(self, path, interface):
        if self._disconnected or not self._is_announced(path):
            return

        exported = self._path_exports.get(path, {})
        if path.startswith(MM_MODEM_PREFIX):
            if not self._is_complete(path):
                # Too early to say anything: a half-built modem is one a client
                # is entitled to believe in. Everything exported so far goes
                # out together when the modem reports itself ready.
                if interface.name == MM_MODEM_IFACE:
                    self._announce_modem_eventually(path)
                return
            # Every announcement carries the whole modem, not just the
            # interface that was added. The Modem interface is exported before
            # the bus name is even requested, so its own announcement is made
            # to an empty room; the first one a client actually hears is
            # whichever interface happened to be exported next. Measured 14.9.:
            # that was Modem3gpp, NetworkManager built an object with no Modem
            # interface in it and ignored the modem for the rest of the boot.
            # Repeating the interfaces a client already has costs nothing - it
            # updates them - while leaving one out costs the phone its
            # connection.
            self._announce(path, list(exported.values()))
            return
        self._announce(path, [interface])

    def _announce(self, path, interfaces):
        body = {iface.name: None for iface in interfaces}

        def collected(iface, values, _user_data, error):
            if error is not None:
                # dbus_fast sends the signal anyway in this case, with whatever
                # it did read. A modem announced with some properties missing
                # is still better than a modem nobody hears about; the client
                # asks for what it needs afterwards.
                ofono2mm_print(f"Some properties of {iface.name} are missing "
                               f"from the announcement of {path}: {error}", True)
                values = {}
            body[iface.name] = values
            if any(value is None for value in body.values()):
                return
            self.send(Message.new_signal(
                path=MM_ROOT,
                interface='org.freedesktop.DBus.ObjectManager',
                member='InterfacesAdded',
                signature='oa{sa{sv}}',
                body=[path, body],
            ))

        for iface in interfaces:
            ServiceInterface._get_all_property_values(iface, collected)

    def _emit_interface_removed(self, path, removed_interfaces):
        if path not in self._path_exports:
            # The modem is gone; the next one at this path has to earn its
            # announcement again.
            self._ready_modems.discard(path)
        if self._disconnected or not self._is_announced(path):
            return
        self.send(Message.new_signal(
            path=MM_ROOT,
            interface='org.freedesktop.DBus.ObjectManager',
            member='InterfacesRemoved',
            signature='oas',
            body=[path, removed_interfaces],
        ))

class MMInterface(ServiceInterface):
    def __init__(self, loop, bus, verbose=False):
        super().__init__('org.freedesktop.ModemManager1')
        ofono2mm_print("Initializing Manager interface", verbose)
        self.loop = loop
        self.bus = bus
        self.verbose = verbose
        self.ofono_client: Ofono = Ofono(bus)
        self.dbus_client: DBus = DBus(bus)
        self.modems: Dict[str, MMModemInterface] = {}
        self.loop.create_task(self.check_ofono_presence())

    @dbus_property(access=PropertyAccess.READ)
    def Version(self) -> 's':
        return get_version()

    @method()
    async def ScanDevices(self):
        ofono2mm_print("Scanning devices", self.verbose)

        try:
            await self.find_ofono_modems()
        except Exception as e:
            ofono2mm_print(f"Failed to scan for devices: {e}", self.verbose)
            raise DBusError("org.freedesktop.ModemManager1.Error.Core.Failed", "Failed to scan for devices")

    async def check_ofono_presence(self):
        ofono2mm_print("Checking ofono presence", self.verbose)

        dbus_iface = self.dbus_client["dbus"]["/org/freedesktop/DBus"]["org.freedesktop.DBus"]
        dbus_iface.on_name_owner_changed(self.dbus_name_owner_changed)
        has_ofono = await dbus_iface.call_name_has_owner("org.ofono")
        if has_ofono:
            self.ofono_added()
        else:
            self.ofono_removed()

    def ofono_added(self):
        ofono2mm_print("oFono added", self.verbose)

        self.ofono_manager_interface = self.ofono_client["ofono"]["/"]["org.ofono.Manager"]
        self.ofono_manager_interface.on_modem_added(self.ofono_modem_added)
        self.ofono_manager_interface.on_modem_removed(self.ofono_modem_removed)
        self.loop.create_task(self.find_ofono_modems())

    def ofono_removed(self):
        ofono2mm_print("oFono removed", self.verbose)
        self.ofono_manager_interface = None

        for _path, modem in self.modems.items():
            modem.unexport_mm_interface_objects()
        self.modems.clear()
        self.bus.something_to_show.set()

        self.loop.create_task(self.bus.release_name('org.freedesktop.ModemManager1'))

    async def find_ofono_modems(self, retry_counter=5):
        ofono2mm_print("Finding oFono modems", self.verbose)

        if not self.ofono_manager_interface:
            ofono2mm_print("oFono manager interface is empty, skipping", self.verbose)
            return

        try:
            modems = await self.ofono_manager_interface.call_get_modems()
        except DBusError as e:
            ofono2mm_print(f"Failed to get modems from oFono: {e}", self.verbose)
            return

        ril_modems = [modem for modem in modems if modem[0].startswith("/ril_")]

        if not ril_modems:
            ofono2mm_print("No ril modems found", self.verbose)
            # This can happen if we try to connect too early. Give it a couple seconds and give it some more shots
            # Seriously though, that's fucking stupid.
            if retry_counter <= 0:
                ofono2mm_print("No ril modems found after retries, giving up", self.verbose)
                # Nothing will be exported, so nothing is gained by making
                # anyone wait for it.
                self.bus.something_to_show.set()
                return

            ofono2mm_print("No ril modems found, retrying", self.verbose)
            await asyncio.sleep(2)
            await self.find_ofono_modems(retry_counter - 1)

        modems_to_export = []

        for path, props in ril_modems:
            ofono2mm_print(f"Found modem: {path}, {props}", self.verbose)

            if not props['Powered'].value:
                try:
                    await self.ofono_client["ofono_modem"][path]['org.ofono.Modem'].call_set_property('Powered', Variant('b', True))
                except DBusError as e:
                    ofono2mm_print(f"Failed to power up modem {path}: {e}", self.verbose)

            if not props['Online'].value:
                try:
                    await self.ofono_client["ofono_modem"][path]['org.ofono.Modem'].call_set_property('Online', Variant('b', True))
                except DBusError as e:
                    # Can happen if airplane mode is on. Don't worry about it.
                    ofono2mm_print(f"Failed to set modem {path} to online: {e}", self.verbose)

                props.update(await self.ofono_client["ofono_modem"][path]['org.ofono.Modem'].call_get_properties())

            try:
                sim_manager = self.ofono_client["ofono_modem"][path]['org.ofono.SimManager']
                sim_props = await sim_manager.call_get_properties()
                sim_present = sim_props['Present'].value
            except DBusError as e:
                # Can also happen if airplane mode is on.
                ofono2mm_print(f"Failed to get SIM properties for modem {path}: {e}", self.verbose)
                sim_present = False

            # If the SIM card is present, prepend it to the list of modems to export so it gets exported first
            if sim_present:
                modems_to_export.insert(0, (path, props))
            else:
                modems_to_export.append((path, props))

        for path, props in modems_to_export:
            await self.export_new_modem(path, props)

    def dbus_name_owner_changed(self, name, old_owner, new_owner):
        if name == "org.ofono":
            ofono2mm_print(f"oFono name owner changed, name: {name}, old owner: {old_owner}, new owner: {new_owner}", self.verbose)
            if new_owner == "":
                self.ofono_removed()
            else:
                self.ofono_added()

    def ofono_modem_added(self, path, mprops):
        ofono2mm_print(f"oFono modem added at path {path} and properties {mprops}", self.verbose)

        try:
            self.loop.create_task(self.export_new_modem(path, mprops))
        except Exception as e:
            ofono2mm_print(f"Failed to create task for modem {path}: {e}", self.verbose)

    async def export_new_modem(self, path, mprops):
        if not '/ril_' in path:
            # This can happen when, for example, a phone is paired over Bluetooth -- even if the phone isn't connected!
            # TODO: there is no substantial reason to not support non-RIL modems, but we are just focusing on whatever
            # provides the best user experience for now. This could be revisited in the future.
            ofono2mm_print(f"Modem {path} is not a RIL modem, skipping", self.verbose)
            return

        ofono2mm_print(f"Processing modem {path} with properties {mprops}", self.verbose)

        if path in self.modems:
            ofono2mm_print(f"Modem {path} already exists. Not sure why we're here.", self.verbose)
            return

        index = int(path.split('_')[-1])

        mm_modem_interface = MMModemInterface(self.loop, index, self.bus, self.ofono_client, path, self.verbose)
        promises = [mm_modem_interface.init_mm_sim_interface(),
                    mm_modem_interface.init_mm_3gpp_interface(),
                    mm_modem_interface.init_mm_3gpp_ussd_interface(),
                    mm_modem_interface.init_mm_3gpp_profile_manager_interface(),
                    mm_modem_interface.init_mm_messaging_interface(),
                    mm_modem_interface.init_mm_simple_interface(),
                    mm_modem_interface.init_mm_firmware_interface(),
                    mm_modem_interface.init_mm_time_interface(),
                    mm_modem_interface.init_mm_cdma_interface(),
                    mm_modem_interface.init_mm_sar_interface(),
                    mm_modem_interface.init_mm_oma_interface(),
                    mm_modem_interface.init_mm_signal_interface(),
                    mm_modem_interface.init_mm_location_interface(),
                    mm_modem_interface.init_mm_voice_interface(),
                    mm_modem_interface.init_mm_cell_broadcast_interface()]

        await asyncio.gather(*promises)


        self.modems[path] = mm_modem_interface

        mm_modem_simple = mm_modem_interface.get_mm_modem_simple_interface()
        self.loop.create_task(self.simple_set_apn(mm_modem_simple))

    async def simple_set_apn(self, mm_modem_simple):
        ofono2mm_print("Setting APN in Network Manager", self.verbose)

        while True:
            ret = await mm_modem_simple.network_manager_set_apn()
            if ret:
                return

            await asyncio.sleep(2)

    def ofono_modem_removed(self, path):
        ofono2mm_print(f"oFono modem removed at path {path}", self.verbose)

        if path in self.modems:
            self.modems[path].unexport_mm_interface_objects()
            self.modems.pop(path)

    @method()
    def SetLogging(self, level: 's'):
        ofono2mm_print(f"Set logging with level {level}", self.verbose)

    @method()
    def ReportKernelEvent(self, properties: 'a{sv}'):
        ofono2mm_print(f"Report kernel events with properties {properties}", self.verbose)

    @method()
    def InhibitDevice(self, uid: 's', inhibit: 'b'):
        ofono2mm_print(f"Inhibit device with uid {uid} set to {inhibit}", self.verbose)

def print_version():
    version = get_version()
    print(f"oFono2MM version {version}")

def custom_help(parser):
    parser.print_help()
    print("\nDBus system service to control mobile broadband modems through oFono.")

async def main():
    # Disable buffering for stdout and stderr so that logs are written immediately
    sys.stdout.reconfigure(line_buffering=True)
    sys.stderr.reconfigure(line_buffering=True)

    parser = ArgumentParser(description="Run the ModemManager interface.", add_help=False)
    parser.add_argument('-v', '--verbose', action='store_true', help='Enable verbose output.')
    parser.add_argument('-V', '--version', action='store_true', help='Print version.')
    parser.add_argument('-h', '--help', action='store_true', help='Show help.')

    args = parser.parse_args()

    if args.version:
        print_version()
        return

    if args.help:
        custom_help(parser)
        return

    if environ.get('MODEM_DEBUG', 'false').lower() == 'true':
        verbose = True
    else:
        verbose = args.verbose

    bus = await ModemManagerBus(bus_type=BusType.SYSTEM).connect()
    loop = asyncio.get_running_loop()

    mm_manager_interface = MMInterface(loop, bus, verbose=verbose)

    bus.export('/org/freedesktop/ModemManager1', mm_manager_interface)

    # The bus name is the announcement. Everything that watches ModemManager
    # enumerates the moment the name appears, and some of those clients look
    # exactly once - phosh draws the signal icon from the objects it finds
    # then, and nothing later changes its mind. Taking the name before the
    # modem exists therefore means an icon-less phone until something restarts
    # the shell, which is what upstream's release-and-request of the name was
    # really for: a second chance at the enumeration, bought by making the
    # name disappear - and at the price of every client that asks during that
    # gap being refused for good (FINDINGS.md, defect 16).
    #
    # So: wait until there is a modem to show, or until it is clear there
    # will not be one. Measured 14.9.: the modem is ready about 150 ms after
    # start. The timeout is what keeps a phone with no modem - no SIM, oFono
    # still coming up - from having no ModemManager on the bus either.
    try:
        await asyncio.wait_for(bus.something_to_show.wait(), timeout=10)
    except asyncio.TimeoutError:
        ofono2mm_print("No modem after ten seconds - taking the bus name anyway", verbose)

    try:
        await bus.request_name('org.freedesktop.ModemManager1')
    except Exception as e:
        ofono2mm_print(f"Failed to request org.freedesktop.ModemManager1 bus name: {e}", verbose)
        return

    try:
        await bus.wait_for_disconnect()
    except Exception as e:
        print(f"System bus disconnected, exiting: {e}")

if __name__ == "__main__":
    asyncio.run(main())
