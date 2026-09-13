#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
"""
The modem's port list, and the one rule it has to keep: what is in it is what
the bearers actually have.

Three places in ofono2mm used to append an interface name here and not one of
them ever removed one, so an interface that carried an earlier data call stayed
in the list for the life of the process. ModemManager then offered
NetworkManager two net ports for one modem; NetworkManager picked the stale
one and handed dnsmasq the carrier's resolvers bound to an interface that was
DOWN. dnsmasq answered REFUSED without forwarding anything - every lookup
failed while packets still flowed over the live interface.

That failure is invisible from inside the code: no exception, no error return,
just a list that grows. So it gets pinned down here.

mm_modem.py imports half of ofono2mm, which a test has no business dragging in.
The method is lifted out of the shipped source with ast and run on its own -
the real text of what is installed, without the package.
"""
import ast
import os
import sys

sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SOURCE = os.path.join(ROOT, "patched-files", "mm_modem.py")

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


class Variant:
    """Enough of dbus_fast.Variant for a list of ports."""

    def __init__(self, signature, value):
        self.signature, self.value = signature, value

    def __eq__(self, other):
        return (isinstance(other, Variant)
                and self.signature == other.signature and self.value == other.value)

    def __repr__(self):
        return f"Variant({self.signature!r}, {self.value!r})"


def load_method(name):
    """Pull one method out of the shipped file and compile it on its own."""
    tree = ast.parse(open(SOURCE, encoding="utf-8").read(), SOURCE)
    for node in ast.walk(tree):
        if isinstance(node, ast.FunctionDef) and node.name == name:
            node.decorator_list = []
            module = ast.Module(body=[node], type_ignores=[])
            ast.fix_missing_locations(module)
            ns = {"Variant": Variant}
            exec(compile(module, SOURCE, "exec"), ns)  # noqa: S102
            return ns[name]
    raise SystemExit(f"{name} not found in {SOURCE} - did the patch move?")


sync_net_ports = load_method("sync_net_ports")


class Bearer:
    def __init__(self, iface=None):
        self.props = {} if iface is None else {"Interface": Variant("s", iface)}


class Modem:
    def __init__(self, ports, bearers):
        self.modem_name = "/ril_0"
        self.props = {"Ports": Variant("a(su)", ports)}
        self.bearers = {str(i): b for i, b in enumerate(bearers)}
        self.emitted = []

    def emit_properties_changed(self, changed):
        self.emitted.append(changed)


MODEM = ["/ril_0", 0]
NET = 2

print("\n\033[1m== the stale interface goes\033[0m")

# The case from the phone: two net ports, one of them a corpse from the first
# data call, one bearer that names the live one.
m = Modem([MODEM, ["ccmni0", NET], ["ccmni2", NET]], [Bearer("ccmni0")])
sync_net_ports(m)
check("the dead interface is dropped", [MODEM, ["ccmni0", NET]], m.props["Ports"].value)
check("and the change is announced", 1, len(m.emitted))

print("\n\033[1m== but only when something really changed\033[0m")

m = Modem([MODEM, ["ccmni0", NET]], [Bearer("ccmni0")])
sync_net_ports(m)
check("a correct list is left alone", [MODEM, ["ccmni0", NET]], m.props["Ports"].value)
check("and nothing is announced", 0, len(m.emitted))

print("\n\033[1m== what counts as a port\033[0m")

# A bearer that is not connected has no interface, and must not put an empty
# name in the list - NetworkManager would take it for a device.
m = Modem([MODEM], [Bearer("ccmni0"), Bearer(""), Bearer(None)])
sync_net_ports(m)
check("an empty interface is not a port", [MODEM, ["ccmni0", NET]], m.props["Ports"].value)

# The IMS context gets its own ccmni and is a real port. Dropping it would be
# the opposite mistake to the one being fixed.
m = Modem([MODEM], [Bearer("ccmni0"), Bearer("ccmni1")])
sync_net_ports(m)
check("a second live interface is kept",
      [MODEM, ["ccmni0", NET], ["ccmni1", NET]], m.props["Ports"].value)

m = Modem([MODEM], [Bearer("ccmni0"), Bearer("ccmni0")])
sync_net_ports(m)
check("the same interface twice is one port", [MODEM, ["ccmni0", NET]], m.props["Ports"].value)

print("\n\033[1m== the modem's own port\033[0m")

# The control port is not a net port and is not derived from any bearer: it has
# to survive a sync with no bearers at all, or ModemManager loses the modem.
m = Modem([MODEM, ["ccmni0", NET]], [])
sync_net_ports(m)
check("survives with no bearers left", [MODEM], m.props["Ports"].value)
check("and stays first", MODEM, m.props["Ports"].value[0])

print(f"\n  {RUN} checks, {FAILED} failed")
sys.exit(1 if FAILED else 0)
