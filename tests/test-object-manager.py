#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
"""
What a client sees of /org/freedesktop/ModemManager1, and when.

This test used to ask the bus class what it thought - `_is_announced(path)`,
`_is_complete(path)` - and it passed while the phone booted with no mobile
data. It passed *because* it asked that way: the table of expected answers had

    (MM_ROOT, True)

in it, so the test agreed with the code that the manager object may be
announced as a managed object, which is defect 22 and cost a whole boot.
A test that encodes the same assumption as the code cannot find a wrong
assumption.

So it asks the other question now, the one NetworkManager and phosh ask: run a
startup the way main.py and MMModemInterface really run it, then look at what
was said and to whom. Every check below is on the two things a client can
actually observe - the InterfacesAdded that reaches it and the
GetManagedObjects it gets back - and never on the reasoning behind them.

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
    real one does, so the test measures our narrowing and not a copy of it.
    """

    __slots__ = ("_path_exports", "added", "removed", "walked", "raise_on_call",
                 "sent", "_disconnected")

    def __init__(self, paths=(), interfaces=None):
        names = interfaces if interfaces is not None else [MODEM_IFACE]
        self._path_exports = {
            p: {n: FakeServiceInterface(n) for n in names} for p in paths
        }
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
    """Only what an announcement puts in: where it is sent from, and what it
    says was added or removed."""

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
    """Pull ModemManagerBus and its three constants out of the shipped main.py."""
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
    return ns["ModemManagerBus"], ns["MM_ROOT"], ns["MM_MODEM_PREFIX"], ns["MM_MODEM_IFACE"]


Bus, MM_ROOT, MM_MODEM_PREFIX, MODEM_IFACE = load_class()

MODEM = f"{MM_ROOT}/Modem/0"
MODEM2 = f"{MM_ROOT}/Modem/1"
SIM = f"{MM_ROOT}/SIM/0"
BEARER = f"{MM_ROOT}/Bearer/0"
BEARER2 = f"{MM_ROOT}/Bearer/1"
CALL = f"{MM_ROOT}/Call/2"
SMS = f"{MM_ROOT}/SMS/3"

MANAGER_IFACE = "org.freedesktop.ModemManager1"
THREEGPP = "org.freedesktop.ModemManager1.Modem.Modem3gpp"
SIMPLE = "org.freedesktop.ModemManager1.Modem.Simple"
VOICE = "org.freedesktop.ModemManager1.Modem.Voice"

EVERYTHING = [BEARER2, MODEM, SIM, BEARER, CALL, SMS, MM_ROOT]


def make_bus(paths, interfaces=None, published=True, named=True):
    """A bus holding these paths, with the modems among them published.

    Published and named are the normal case: nothing is handed out or
    announced before the modem has reported itself built and the daemon owns
    org.freedesktop.ModemManager1, so a check about the shape of an
    announcement has to be past both. The blocks that are about the holding
    back itself pass published=False or named=False.
    """
    bus = Bus(paths, interfaces)
    if named:
        bus._name_is_ours = True
    if published:
        bus._published.update(p for p in paths if p.startswith(MM_MODEM_PREFIX))
    return bus


def managed(bus, path):
    got = []
    bus._default_get_managed_objects_handler(Msg(path), got.append)
    return got[0] if got else None


def export(bus, path, name):
    """What dbus_fast does on bus.export(): record it, then announce it."""
    bus._path_exports.setdefault(path, {})[name] = FakeServiceInterface(name)
    bus._emit_interface_added(path, bus._path_exports[path][name])


def heard(bus):
    """The object paths a client was told about, in order."""
    return [m.body[0] for m in bus.sent]


print("object manager")

# ---------------------------------------------------------------------------
print("\n  a whole startup, watched from the outside")
# The order main.py and MMModemInterface really run in. This is the check that
# was missing: every defect in this area got through a suite that was green,
# because nothing replayed the sequence and looked at the result.
bus = Bus()
FakeAsyncio.loop = FakeLoop()

export(bus, MM_ROOT, MANAGER_IFACE)      # main() exports the manager object
for name in (MODEM_IFACE, THREEGPP, SIMPLE):
    export(bus, MODEM, name)             # the modem, one interface at a time
export(bus, SIM, "org.freedesktop.ModemManager1.Sim")
export(bus, BEARER, "org.freedesktop.ModemManager1.Bearer")

check("nothing is said while the bus name is still unowned", [], heard(bus))

bus.modem_ready(MODEM)
check("nor when the modem reports itself built", [], heard(bus))
check("but the daemon may take the name now", True, bus.something_to_show.is_set_)

bus.name_acquired()
check("exactly one announcement reaches a client", 1, len(bus.sent))
check("it is about the modem", [MODEM], heard(bus))
# Defect 22. NetworkManager wrapped the manager object, found no Modem
# interface in it and logged "doesn't have the Modem interface, ignoring".
check("the manager object is never a managed object", False, MM_ROOT in heard(bus))
check("neither is the SIM", False, SIM in heard(bus))
check("nor the bearer", False, BEARER in heard(bus))
# Defect 12/16. Sent from the object's own path - where dbus_fast puts it - it
# reaches nobody: every client subscribes at the manager's path.
check("it comes from the object manager's path", [MM_ROOT], [m.path for m in bus.sent])
check("it carries the Modem interface", True, MODEM_IFACE in bus.sent[0].body[1])
check("and every other interface the modem has",
      sorted([MODEM_IFACE, THREEGPP, SIMPLE]), sorted(bus.sent[0].body[1]))
check("a client enumerating now finds the modem and nothing else",
      [MODEM], managed(bus, MM_ROOT))

# ---------------------------------------------------------------------------
print("\n  the modem is not shown before it is built")
# Defect 22, the other half: the announcement used to go out from the middle of
# set_props, thirty lines before State and Sim are worked out. NetworkManager
# read `state: failed` / `No SIM object available`, built /ril_0 from it and
# kept it for the rest of the boot.
bus = Bus()
FakeAsyncio.loop = FakeLoop()
bus._name_is_ours = True
export(bus, MODEM, MODEM_IFACE)
check("exporting the Modem interface announces nothing by itself", [], heard(bus))
check("and a client enumerating sees no modem yet", [], managed(bus, MM_ROOT))
export(bus, MODEM, THREEGPP)
check("nor does the next interface", [], heard(bus))
bus.modem_ready(MODEM)
check("only reporting it built does", [MODEM], heard(bus))
check("with both interfaces in the one message",
      sorted([MODEM_IFACE, THREEGPP]), sorted(bus.sent[0].body[1]))

# ---------------------------------------------------------------------------
print("\n  nothing is announced before the bus name is ours")
# Defect 21. NetworkManager watches the bus rather than the name, so it hears
# an early announcement and builds its modem straight away - and every method
# it then calls is answered UnknownMethod by the bus itself:
#
#   failed to connect modem: Method "Connect" with signature "a{sv}" on
#   interface "org.freedesktop.ModemManager1.Modem.Simple" doesn't exist
#
# It keeps that modem ("already exists, ignoring") and the phone has no mobile
# data for the rest of the boot, with oFono registered on LTE throughout.
bus = make_bus([MODEM], published=False, named=False)
bus.modem_ready(MODEM)
check("a modem built before the name is held back", [], heard(bus))
check("and it is not handed out either", [], managed(bus, MM_ROOT))
bus.name_acquired()
check("taking the name releases it", [MODEM], heard(bus))
check("and now it is handed out", [MODEM], managed(bus, MM_ROOT))

bus = make_bus([MODEM, MODEM2], published=False, named=False)
bus.modem_ready(MODEM2)
bus.modem_ready(MODEM)
bus.modem_ready(MODEM2)
bus.name_acquired()
check("two modems are released in the order they reported", [MODEM2, MODEM], heard(bus))

bus = make_bus([MODEM], published=False)
bus.modem_ready(MODEM)
check("a modem built after the name went out at once", [MODEM], heard(bus))

# ---------------------------------------------------------------------------
print("\n  announced once, and only what was published")
bus = make_bus([MODEM], published=False)
bus.modem_ready(MODEM)
bus.modem_ready(MODEM)
bus.modem_ready(MODEM)
check("reporting ready again says nothing more", 1, len(bus.sent))

# ModemManager announces a modem once, with everything, and changes afterwards
# travel as PropertiesChanged. An interface that genuinely appears later is
# the one case InterfacesAdded is for, and by then it is safe to send.
bus = make_bus([MODEM], published=False)
bus.modem_ready(MODEM)
export(bus, MODEM, VOICE)
check("an interface added to a published modem is announced", [MODEM, MODEM], heard(bus))
check("carrying just that interface", [VOICE], sorted(bus.sent[1].body[1]))

bus = make_bus([MODEM], published=False)
bus.modem_ready(MODEM)
export(bus, SIM, "org.freedesktop.ModemManager1.Sim")
export(bus, BEARER, "org.freedesktop.ModemManager1.Bearer")
check("a SIM or bearer exported later stays unannounced", [MODEM], heard(bus))

bus = make_bus([SIM, BEARER], published=False)
bus.modem_ready(SIM)
check("a path that is not a modem cannot be published either", [], heard(bus))
check("and is not handed out", [], managed(bus, MM_ROOT))

bus = make_bus([], published=False)
bus.modem_ready(MODEM)
check("a modem with nothing exported at its path is not announced", [], heard(bus))
check("and does not appear in the managed objects", [], managed(bus, MM_ROOT))

# ---------------------------------------------------------------------------
print("\n  GetManagedObjects")
bus = make_bus(EVERYTHING)
check("the manager hands out modems only", [MODEM], managed(bus, MM_ROOT))

bus = make_bus([BEARER2, MODEM, SIM, BEARER, MODEM2])
check("both modems, neither SIM nor bearer", [MODEM, MODEM2], managed(bus, MM_ROOT))

bus = make_bus([SIM, BEARER])
check("no modem yet means an empty answer, not a bearer", [], managed(bus, MM_ROOT))

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
      managed(bus, MM_ROOT.rsplit("/", 1)[0]) and bus.walked and [MODEM])
bus = make_bus([MODEM, SIM])
managed(bus, "/org/freedesktop")
check("and it saw the unnarrowed table", sorted([MODEM, SIM]), bus.walked)

# ---------------------------------------------------------------------------
print("\n  withdrawing a modem")
bus = make_bus([MODEM])
del bus._path_exports[MODEM]
bus._emit_interface_removed(MODEM, ["iface"])
check("a modem whose last interface went is withdrawn", 1, len(bus.sent))
check("from the object manager's path", MM_ROOT, bus.sent[0].path)
check("naming the object", MODEM, bus.sent[0].body[0])
check("and the interfaces it had", ["iface"], bus.sent[0].body[1])
check("with the signature clients expect", "oas", bus.sent[0].signature)
check("and it is no longer handed out", [], managed(bus, MM_ROOT))

bus = make_bus([MODEM])
bus._emit_interface_removed(MODEM, ["iface"])
check("a modem that lost one of fifteen interfaces stays", [], heard(bus))
check("and is still handed out", [MODEM], managed(bus, MM_ROOT))

bus = make_bus([MM_ROOT, SIM, BEARER])
for p in (MM_ROOT, SIM, BEARER):
    del bus._path_exports[p]
    bus._emit_interface_removed(p, ["iface"])
check("what was never announced is never withdrawn", [], bus.sent)

bus = make_bus([MODEM])
del bus._path_exports[MODEM]
bus._disconnected = True
bus._emit_interface_removed(MODEM, ["iface"])
check("a disconnected bus withdraws nothing", [], bus.sent)

# ---------------------------------------------------------------------------
print("\n  the base class is never asked to announce")
# dbus_fast's own signals go out from the object's own path, where nobody is
# listening, one per interface. Suppressing them is what leaves modem_ready as
# the only door.
bus = make_bus([MODEM], published=False)
export(bus, MODEM, VOICE)
bus.modem_ready(MODEM)
del bus._path_exports[MODEM]
bus._emit_interface_removed(MODEM, ["iface"])
check("no added signal from the base class", [], bus.added)
check("and no removed signal either", [], bus.removed)
check("the announcement has the signature clients expect",
      "oa{sa{sv}}", bus.sent[0].signature)
check("and the interface properties are in it",
      {"Sim": "/org/freedesktop/ModemManager1/SIM/0"},
      bus.sent[0].body[1][MODEM_IFACE])

bus = make_bus([MODEM], published=False)
bus._disconnected = True
export(bus, MODEM, VOICE)
bus.modem_ready(MODEM)
check("a disconnected bus announces nothing", [], bus.sent)

# ---------------------------------------------------------------------------
print("\n  the net under a modem that never reports itself built")
# Invisible for ever is a worse failure than the one this class exists for.
FakeAsyncio.loop = FakeLoop()
bus = make_bus([MODEM], published=False)
export(bus, MODEM, MODEM_IFACE)
check("nothing is announced yet", [], heard(bus))
check("but a late announcement is scheduled", 1, len(FakeAsyncio.loop.later))
delay, fn, args = FakeAsyncio.loop.later[0]
check("ten seconds out", 10, delay)
check("and it is the announcement, not something else", (MODEM,), args)
fn(*args)
check("which shows the modem when it fires", [MODEM], heard(bus))

FakeAsyncio.loop = FakeLoop()
bus = make_bus([MODEM], published=False)
export(bus, MODEM, THREEGPP)
check("only the Modem interface arms it", 0, len(FakeAsyncio.loop.later))

FakeAsyncio.loop = FakeLoop()
bus = make_bus([SIM], published=False)
export(bus, SIM, MODEM_IFACE)
check("and only at a modem path", 0, len(FakeAsyncio.loop.later))

FakeAsyncio.loop = FakeLoop()
bus = make_bus([MODEM], published=False)
bus.modem_ready(MODEM)
export(bus, MODEM, VOICE)
check("a published modem does not arm it again", 0, len(FakeAsyncio.loop.later))

# No event loop yet is not a reason to fall over - the Modem interface is
# exported before anything is running.
FakeAsyncio.loop = None
bus = make_bus([MODEM], published=False)
export(bus, MODEM, MODEM_IFACE)
check("with no loop running it simply says nothing", [], heard(bus))

print(f"\n  {RUN} checks, {FAILED} failed")
sys.exit(1 if FAILED else 0)
