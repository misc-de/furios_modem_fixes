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

    __slots__ = ("_path_exports", "added", "removed", "walked", "raise_on_call")

    def __init__(self, paths):
        self._path_exports = {p: {"iface": object()} for p in paths}
        self.added = []
        self.removed = []
        self.walked = None
        self.raise_on_call = False

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


class Msg:
    def __init__(self, path):
        self.path = path


def load_class():
    """Pull ModemManagerBus and its two constants out of the shipped main.py."""
    tree = ast.parse(open(SOURCE).read(), SOURCE)
    wanted = ("MM_ROOT", "MM_MODEM_PREFIX")
    keep = []
    for node in tree.body:
        if isinstance(node, ast.ClassDef) and node.name == "ModemManagerBus":
            keep.append(node)
        elif isinstance(node, ast.Assign) and any(
            isinstance(t, ast.Name) and t.id in wanted for t in node.targets
        ):
            keep.append(node)

    if len(keep) != 3:
        print(
            f"  \033[31mFAIL\033[0m {SOURCE} has no ModemManagerBus with both "
            f"constants (found {len(keep)} of 3) - is main.py patched?"
        )
        sys.exit(1)

    ns = {"MessageBus": FakeBus}
    exec(compile(ast.Module(body=keep, type_ignores=[]), SOURCE, "exec"), ns)
    return ns["ModemManagerBus"], ns["MM_ROOT"]


Bus, MM_ROOT = load_class()

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
bus = Bus(EVERYTHING)
check("the manager hands out modems only", [MODEM], managed(bus, MM_ROOT))

bus = Bus([BEARER2, MODEM, SIM, BEARER, MODEM2])
check("both modems, neither SIM nor bearer", [MODEM, MODEM2], managed(bus, MM_ROOT))

bus = Bus([SIM, BEARER])
check("no modem yet means an empty answer, not a bearer", [], managed(bus, MM_ROOT))

bus = Bus(EVERYTHING)
managed(bus, MM_ROOT)
check("the export table is put back afterwards", sorted(EVERYTHING),
      sorted(bus._path_exports))

bus = Bus(EVERYTHING)
bus.raise_on_call = True
try:
    managed(bus, MM_ROOT)
except RuntimeError:
    pass
check("put back even when the call below throws", sorted(EVERYTHING),
      sorted(bus._path_exports))

# Any other path is somebody else's ObjectManager; we have no business
# narrowing it.
bus = Bus(EVERYTHING)
check("another path is passed through untouched", [MODEM],
      managed(bus, f"{MM_ROOT}/Modem"))

print("\n  InterfacesAdded / InterfacesRemoved")
bus = Bus([])
for p in [MODEM, SIM, BEARER, MODEM2, CALL]:
    bus._emit_interface_added(p, object())
    bus._emit_interface_removed(p, ["iface"])
check("added is announced for modems only", [MODEM, MODEM2], bus.added)
check("removed is announced for modems only", [MODEM, MODEM2], bus.removed)

print("\n  the daemon actually uses it")
shipped = open(SOURCE).read()
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
