#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
"""
What the ObjectManager at /org/freedesktop/ModemManager1 is allowed to
announce: modems, and nothing else.

ModemManager exports SIMs and bearers on the bus too, but it does not put them
in the ObjectManager. dbus_fast has no such notion - it answers
GetManagedObjects from every exported sub-path - so ofono2mm announced the SIM
and every bearer alongside the modem. libmm-glib wraps each entry in an
MMObject; phosh takes the first one of the list, on the documented assumption
that "Modem interface is always present", remembers it and never looks at
another object. Land a bearer in first place and the phone shows no signal at
all. First place is hash order, which is why it came and went across reboots.

The filter is four lines and every one of them fails silently: announce too
much and the bug is back, announce too little and mmcli stops seeing the
modem, and forget to put _path_exports back and the daemon answers every later
call from a truncated table.

main.py imports ofono2mm, which a test has no business dragging in, and the
class cannot be instantiated without a bus. So the class is lifted out of the
shipped source with ast and given a stand-in base that reproduces dbus_fast's
node selection - the real text of what we install, without the connection.
"""
import ast
import os
import sys

sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SOURCE = os.path.join(ROOT, "patched-files", "main.py")

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


class FakeBus:
    """dbus_fast's MessageBus, reduced to the three things we override.

    _default_get_managed_objects_handler picks its nodes exactly the way the
    real one does, so the test measures our filter and not a copy of it.
    """

    __slots__ = ("_path_exports", "added", "removed", "walked", "raise_on_call",
                 "sent", "_disconnected", "_ready_modems")

    def __init__(self, paths, interfaces=None):
        # What dbus_fast keeps: path -> {interface name: interface}.
        names = interfaces if interfaces is not None else [FakeServiceInterface.name]
        self._path_exports = {
            p: {n: FakeServiceInterface(n) for n in names} for p in paths
        }
        self._ready_modems = set()
        self.added = []
        self.removed = []
        self.walked = None
        self.raise_on_call = False
        self.sent = []
        self._disconnected = False

    def _default_get_managed_objects_handler(self, msg, send_reply):
        if self.raise_on_call:
            raise RuntimeError("property read blew up")
        self.walked = sorted(
            node
            for node in self._path_exports
            if msg.path == "/" or node.startswith(msg.path + "/")
        )
        send_reply(self.walked)

    def _emit_interface_added(self, path, interface):
        self.added.append(path)

    def _emit_interface_removed(self, path, removed_interfaces):
        self.removed.append(path)

    def send(self, msg):
        self.sent.append(msg)


class Msg:
    def __init__(self, path):
        self.path = path


class FakeLoop:
    """Records what was scheduled instead of waiting ten seconds for it."""

    def __init__(self):
        self.later = []

    def call_later(self, delay, fn, *args):
        self.later.append((delay, fn, args))


class FakeEvent:
    def __init__(self):
        self.is_set_ = False

    def set(self):
        self.is_set_ = True


class FakeAsyncio:
    loop = None
    Event = FakeEvent

    @staticmethod
    def get_running_loop():
        if FakeAsyncio.loop is None:
            raise RuntimeError("no running event loop")
        return FakeAsyncio.loop


class FakeMessage:
    """Only what the two announcements put in: where it is sent from, and what
    it says was added or removed."""

    def __init__(self, path=None, interface=None, member=None, signature=None, body=None):
        self.path = path
        self.interface = interface
        self.member = member
        self.signature = signature
        self.body = body or []

    @staticmethod
    def new_signal(**kwargs):
        return FakeMessage(**kwargs)


class FakeServiceInterface:
    """dbus_fast reads an interface's properties before it announces it and
    hands them to a callback. Here it is one fixed value, because what is being
    tested is the envelope and not the contents."""

    name = "org.freedesktop.ModemManager1.Modem"

    def __init__(self, name=None):
        if name is not None:
            self.name = name

    @staticmethod
    def _get_all_property_values(interface, callback):
        callback(interface, {"Sim": "/org/freedesktop/ModemManager1/SIM/0"}, None, None)


def load_class():
    """Pull ModemManagerBus and its two constants out of the shipped main.py."""
    tree = ast.parse(open(SOURCE).read(), SOURCE)
    wanted = ("MM_ROOT", "MM_MODEM_PREFIX", "MM_MODEM_IFACE")
    keep = []
    for node in tree.body:
        if isinstance(node, ast.ClassDef) and node.name == "ModemManagerBus":
            keep.append(node)
        elif isinstance(node, ast.Assign) and any(
            isinstance(t, ast.Name) and t.id in wanted for t in node.targets
        ):
            keep.append(node)

    if len(keep) != 4:
        print(
            f"  \033[31mFAIL\033[0m {SOURCE} has no ModemManagerBus with all "
            f"three constants (found {len(keep)} of 4) - is main.py patched?"
        )
        sys.exit(1)

    ns = {
        "MessageBus": FakeBus,
        "Message": FakeMessage,
        "ServiceInterface": FakeServiceInterface,
        "ofono2mm_print": lambda *a, **k: None,
        "asyncio": FakeAsyncio,
    }
    exec(compile(ast.Module(body=keep, type_ignores=[]), SOURCE, "exec"), ns)
    return ns["ModemManagerBus"], ns["MM_ROOT"]


Bus, MM_ROOT = load_class()


def make_bus(paths, interfaces=None, ready=True, named=True):
    """A bus holding these paths, with the modems among them ready by default.

    Ready is the normal case: a modem is handed out and announced once it has
    reported itself built, and almost every check below is about what happens
    after that. The class fills _ready_modems in its own __init__, so it is
    filled in here afterwards and not in the stand-in base.

    Named is the normal case for the same reason: nothing is announced before
    the daemon owns org.freedesktop.ModemManager1, so a test about the shape
    of an announcement has to be past that point. The block that is about the
    holding back itself passes named=False.
    """
    bus = Bus(paths, interfaces)
    if ready:
        bus._ready_modems.update(paths)
    if named:
        bus._name_is_ours = True
    return bus

MODEM = f"{MM_ROOT}/Modem/0"
MODEM2 = f"{MM_ROOT}/Modem/1"
SIM = f"{MM_ROOT}/SIM/0"
BEARER = f"{MM_ROOT}/Bearer/0"
BEARER2 = f"{MM_ROOT}/Bearer/1"
CALL = f"{MM_ROOT}/Call/2"
SMS = f"{MM_ROOT}/SMS/3"

EVERYTHING = [BEARER2, MODEM, SIM, BEARER, CALL, SMS, MM_ROOT]


def managed(bus, path):
    got = []
    bus._default_get_managed_objects_handler(Msg(path), got.append)
    return got[0] if got else None


print("\n  which paths may be announced")
for path, want in [
    (MM_ROOT, True),
    (MODEM, True),
    (MODEM2, True),
    (SIM, False),
    (BEARER, False),
    (CALL, False),
    (SMS, False),
    ("/org/freedesktop/NetworkManager", True),
    # Not a child of ours: the prefix has to end at a path separator, or a
    # future /org/freedesktop/ModemManager1Extra would be filtered too.
    ("/org/freedesktop/ModemManager1Extra/Thing", True),
]:
    check(path, want, Bus._is_announced(path))

print("\n  GetManagedObjects")
bus = make_bus(EVERYTHING)
check("the manager hands out modems only", [MODEM], managed(bus, MM_ROOT))

bus = make_bus([BEARER2, MODEM, SIM, BEARER, MODEM2])
check("both modems, neither SIM nor bearer", [MODEM, MODEM2], managed(bus, MM_ROOT))

bus = make_bus([SIM, BEARER])
check("no modem yet means an empty answer, not a bearer", [], managed(bus, MM_ROOT))

# Half a modem is worse than no modem: NetworkManager drops an object without
# the Modem interface and never looks at it again. ofono2mm exports the
# interfaces one at a time while the bus name is already there, so this window
# is real - measured on the phone, twenty milliseconds wide.
bus = make_bus([MODEM], interfaces=["org.freedesktop.ModemManager1.Modem.Voice"],
          ready=False)
check("a modem that has not reported itself ready is not handed out", [],
      managed(bus, MM_ROOT))
check("and the export table survives being filtered twice", [MODEM],
      sorted(bus._path_exports))
bus.announce_modem(MODEM)
check("once it is ready it is handed out", [MODEM], managed(bus, MM_ROOT))
# main() holds the bus name back until this is set: a client that enumerates
# the moment the name appears - and phosh is one that then never looks again -
# has to find a whole modem there.
check("and the daemon is told there is something worth showing", True,
      bus.something_to_show.is_set_)

bus = make_bus(EVERYTHING)
managed(bus, MM_ROOT)
check("the export table is put back afterwards", sorted(EVERYTHING),
      sorted(bus._path_exports))

bus = make_bus(EVERYTHING)
bus.raise_on_call = True
try:
    managed(bus, MM_ROOT)
except RuntimeError:
    pass
check("put back even when the call below throws", sorted(EVERYTHING),
      sorted(bus._path_exports))

# Any other path is somebody else's ObjectManager; we have no business
# narrowing it.
bus = make_bus(EVERYTHING)
check("another path is passed through untouched", [MODEM],
      managed(bus, f"{MM_ROOT}/Modem"))

print("\n  InterfacesAdded / InterfacesRemoved")
# Exported, because an announcement is made from what the bus is holding: the
# modem path has to carry its Modem interface before anything goes out.
bus = make_bus([MODEM, SIM, BEARER, MODEM2, CALL])
for p in [MODEM, SIM, BEARER, MODEM2, CALL]:
    bus._emit_interface_added(p, FakeServiceInterface())
    bus._emit_interface_removed(p, ["iface"])

added = [m for m in bus.sent if m.member == "InterfacesAdded"]
removed = [m for m in bus.sent if m.member == "InterfacesRemoved"]
check("added is announced for modems only", [MODEM, MODEM2],
      [m.body[0] for m in added])
check("removed is announced for modems only", [MODEM, MODEM2],
      [m.body[0] for m in removed])

# The reason any of this is ours to send. dbus_fast puts these signals on the
# path of the object that changed; the specification puts them on the object
# manager's path, with the object path as the first argument, and that is the
# only place a client is listening. Sent from the object's own path they reach
# nobody - which is what upstream's release-and-request of the bus name was
# covering up, at the price of the signal icon.
check("added is sent from the object manager, not from the object",
      [MM_ROOT, MM_ROOT], [m.path for m in added])
check("removed is sent from the object manager too",
      [MM_ROOT, MM_ROOT], [m.path for m in removed])
check("and the base class is not asked to send a second one", [], bus.added)
check("nor for removals", [], bus.removed)
check("added carries the interface and its properties",
      [{"org.freedesktop.ModemManager1.Modem":
        {"Sim": "/org/freedesktop/ModemManager1/SIM/0"}}],
      [added[0].body[1]])
check("added has the signature clients expect", ["oa{sa{sv}}"],
      [added[0].signature])
check("removed carries the interface names", [["iface"]], [removed[0].body[1]])
check("removed has the signature clients expect", ["oas"],
      [removed[0].signature])

# A bus on its way out must not try to send anything.
bus = make_bus([MODEM])
bus._disconnected = True
bus._emit_interface_added(MODEM, FakeServiceInterface())
bus._emit_interface_removed(MODEM, ["iface"])
check("a disconnected bus announces nothing", [], bus.sent)

# One announcement per modem, carrying everything it has. libmm-glib builds its
# object from the first announcement that names the path, and NetworkManager
# drops that object for good when the Modem interface is not in it - measured
# on the phone, where it cost the modem its NetworkManager device on every
# restart until this was right.
VOICE = "org.freedesktop.ModemManager1.Modem.Voice"
SIMPLE = "org.freedesktop.ModemManager1.Modem.Simple"

bus = make_bus([MODEM], interfaces=[VOICE, SIMPLE], ready=False)
bus._emit_interface_added(MODEM, FakeServiceInterface(VOICE))
check("nothing is announced while the modem is still being built", [], bus.sent)

bus = make_bus([MODEM], interfaces=[VOICE, SIMPLE, FakeServiceInterface.name],
               ready=False)
bus.announce_modem(MODEM)
check("reporting ready announces the modem once", 1, len(bus.sent))
check("and every interface it has is in that one message",
      sorted([VOICE, SIMPLE, FakeServiceInterface.name]),
      sorted(bus.sent[0].body[1]))

# Not "on its own": the Modem interface is exported before the bus name is
# requested, so its own announcement reaches nobody, and whatever is announced
# next is the first thing a client hears. If that one leaves the Modem
# interface out, the client builds an object without it and gives up on the
# modem - which is exactly what NetworkManager did, every restart.
bus = make_bus([MODEM], interfaces=[FakeServiceInterface.name, VOICE])
bus._emit_interface_added(MODEM, FakeServiceInterface(VOICE))
check("an interface added later brings the whole modem with it again",
      sorted([FakeServiceInterface.name, VOICE]), sorted(bus.sent[0].body[1]))

# A modem that never says it is ready would be invisible for ever, which is a
# worse failure than the one this fixes. Exporting the Modem interface arms a
# net for that.
FakeAsyncio.loop = FakeLoop()
bus = make_bus([MODEM], ready=False)
bus._emit_interface_added(MODEM, FakeServiceInterface())
check("a modem that is not ready yet announces nothing", [], bus.sent)
check("but a late announcement is scheduled", 1, len(FakeAsyncio.loop.later))
check("and it is the announcement, not something else", MODEM,
      FakeAsyncio.loop.later[0][2][0])
delay, fn, args = FakeAsyncio.loop.later[0]
fn(*args)
check("which announces the modem when it fires", [MODEM],
      [m.body[0] for m in bus.sent])

# No event loop yet is not a reason to fall over - the modem is exported before
# anything is running.
FakeAsyncio.loop = None
bus = make_bus([MODEM], ready=False)
bus._emit_interface_added(MODEM, FakeServiceInterface())
check("with no loop running it simply says nothing", [], bus.sent)

# Paths that are not modems keep the plain behaviour: one interface, one
# announcement, no waiting for something that will never be exported there.
bus = make_bus([MM_ROOT], interfaces=[VOICE])
bus._emit_interface_added(MM_ROOT, FakeServiceInterface(VOICE))
check("the manager object itself is announced without that rule", [VOICE],
      list(bus.sent[0].body[1]))

print("\n  nothing is announced before the bus name is ours")
# An announcement made while org.freedesktop.ModemManager1 belongs to nobody
# is worse than none at all. NetworkManager watches the bus rather than the
# name, so it hears it and builds its modem straight away - and every method
# it then calls on that name is answered UnknownMethod by the bus itself:
#
#   failed to enable modem: Method "Enable" with signature "b" on interface
#   "org.freedesktop.ModemManager1.Modem" doesn't exist
#
# It keeps the modem it built ("already exists, ignoring") and the phone has
# no mobile data for the rest of the boot, with oFono registered on LTE the
# whole time. Measured 14.9. 13:41:04: announced at .8245, the name became
# ours at .8261, NetworkManager was inside those one and a half milliseconds.
bus = make_bus([MODEM], interfaces=[FakeServiceInterface.name], ready=False,
               named=False)
bus.announce_modem(MODEM)
check("an unnamed bus announces nothing", [], bus.sent)
# But it must still say there is something to show, or main() waits for that
# event for ten seconds before it even asks for the name - holding the
# announcement back would then hold the whole daemon back.
check("it does say there is something worth showing", True,
      bus.something_to_show.is_set_)
check("and the modem is handed out to whoever enumerates", [MODEM],
      managed(bus, MM_ROOT))

# The interfaces that were still being exported while the name was unowned are
# the whole point: Simple was one of them, which is why NetworkManager had a
# modem it could not call Connect on.
bus._path_exports[MODEM][SIMPLE] = FakeServiceInterface(SIMPLE)
bus.name_acquired()
check("taking the name announces what was held back", [MODEM],
      [m.body[0] for m in bus.sent])
check("and it carries the interfaces exported since, not the ones it had then",
      sorted([FakeServiceInterface.name, SIMPLE]), sorted(bus.sent[0].body[1]))

# Held back twice - announce_modem and an interface exported after it - is
# still one modem and must not become two announcements.
bus = make_bus([MODEM], interfaces=[FakeServiceInterface.name], ready=False,
               named=False)
bus.announce_modem(MODEM)
bus._emit_interface_added(MODEM, FakeServiceInterface())
bus.name_acquired()
check("a path held back twice is announced once", 1, len(bus.sent))

# After the name is ours the holding back is over; anything else would be a
# modem nobody hears about.
bus = make_bus([MODEM], interfaces=[FakeServiceInterface.name], ready=False,
               named=False)
bus.name_acquired()
bus.announce_modem(MODEM)
check("once the name is ours announcements go out as they happen", [MODEM],
      [m.body[0] for m in bus.sent])

# Nothing was waiting: taking the name must not invent an announcement.
bus = make_bus([SIM], interfaces=[FakeServiceInterface.name], named=False)
bus.name_acquired()
check("with nothing held back it announces nothing", [], bus.sent)

print("\n  the daemon actually uses it")
shipped = open(SOURCE).read()
check(
    "the daemon says the name is ours once it has it",
    True,
    "bus.name_acquired()" in shipped,
)
# Order is the fix. Calling it before take_bus_name returns would announce
# into the same empty room this is here to close.
check(
    "and it says so after taking the name, not before",
    True,
    shipped.index("await take_bus_name(bus)") < shipped.index("bus.name_acquired()"),
)
check(
    "the system bus is a ModemManagerBus",
    True,
    "ModemManagerBus(bus_type=BusType.SYSTEM)" in shipped,
)
check(
    "no plain MessageBus is left connecting",
    False,
    "MessageBus(bus_type=BusType.SYSTEM).connect()" in shipped,
)

print(f"\n  {RUN} checks, {FAILED} failed")
sys.exit(1 if FAILED else 0)
