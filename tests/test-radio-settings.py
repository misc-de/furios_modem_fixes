#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
"""
Fault 11: the modem's own properties, and the one interface that cannot repair
them by itself.

ofono2mm recomputes everything a newly arrived oFono interface feeds - the 3GPP
interface, the SIM, the signal interface - and recomputes the modem's own
properties whenever any watched property CHANGES. Between those two rules there
is a hole exactly the size of org.ofono.RadioSettings: its properties are
static. AvailableTechnologies does not change while the modem runs, so no
PropertyChanged is ever emitted for it, so nothing ever re-runs set_props().

If that interface turns up after the modem's properties were last computed,
caps stays 0 and the fallback pins CurrentCapabilities to LTE alone; modes
stays 0, which matches none of the four totals the mode table is written for,
so SupportedModes comes out EMPTY. The shell is then offered no technology and
no mode at all while oFono has gsm, umts and lte - and the data path keeps
working perfectly throughout, so nothing complains.

Measured on the 2026-09-13 boot, which lost that race: CurrentCapabilities 8
and SupportedModes (0,0), then 12 and 2g/3g/4g after a plain restart of
ModemManager.

mm_modem.py imports half of ofono2mm, which a test has no business dragging in.
The method is lifted out of the shipped source with ast and run on its own -
the real text of what is installed, without the package.
"""
import ast
import asyncio
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


def load_method(name):
    """Pull one method out of the shipped file and compile it on its own."""
    tree = ast.parse(open(SOURCE, encoding="utf-8").read(), SOURCE)
    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name == name:
            node.decorator_list = []
            module = ast.Module(body=[node], type_ignores=[])
            ast.fix_missing_locations(module)
            ns = {"asyncio": asyncio, "ofono2mm_print": lambda *a, **k: None}
            exec(compile(module, SOURCE, "exec"), ns)  # noqa: S102
            return ns[name]
    raise SystemExit(f"{name} not found in {SOURCE} - did the patch move?")


add_ofono_interface = load_method("add_ofono_interface")


class Interface:
    """One oFono interface, as far as this method can tell.

    init() deliberately does NOT raise, because the real one does not: it
    catches its own failures and leaves the properties empty. That is the whole
    reason an interface that never answered cannot be told apart from one that
    answered with nothing.
    """

    def __init__(self, answers=True):
        self.answers, self.inits, self.watchers = answers, [], []
        self.props = {}

    async def init(self, skip_props=False):
        self.inits.append(skip_props)
        if self.answers and not skip_props:
            self.props["AvailableTechnologies"] = ["gsm", "umts", "lte"]

    def on(self, prop, callback):
        self.watchers.append(prop)


class Modem:
    """Enough of MMModemInterface for add_ofono_interface to run."""

    def __init__(self, failing=()):
        self.verbose = False
        self.used_interfaces = {
            "org.ofono.Modem", "org.ofono.NetworkRegistration",
            "org.ofono.RadioSettings", "org.ofono.SimManager",
            "org.ofono.NetworkMonitor", "org.ofono.FuriLabs.AT",
            "org.ofono.CallSettings",
        }
        self.interfaces_without_props = {
            "org.ofono.NetworkMonitor", "org.ofono.FuriLabs.AT",
        }
        self.interfaces = {}
        self.silent = set(failing)
        self.ofono_interfaces = {}
        self.ofono_proxy = Proxy()
        self.ofono_interface_props = Props(self)
        self.mm_modem3gpp_interface = None
        self.mm_sim_interface = None
        self.mm_modem_voice_interface = None
        self.mm_modem_simple_interface = None
        self.mm_modem_signal_interface = None
        self.loop = Loop()
        self.set_props_calls = 0

    async def set_props(self):
        self.set_props_calls += 1

    def ofono_interface_changed(self, iface):
        return lambda *a: None

    async def _restore_saved_bands(self):
        pass


class Props:
    def __init__(self, modem):
        self.modem = modem

    def __getitem__(self, iface):
        if iface not in self.modem.interfaces:
            self.modem.interfaces[iface] = Interface(iface not in self.modem.silent)
        return self.modem.interfaces[iface]


class Proxy:
    def __getitem__(self, iface):
        return object()


class Loop:
    def __init__(self):
        self.tasks = []

    def create_task(self, coro):
        coro.close()
        self.tasks.append(coro)


def arrives(iface, **kwargs):
    m = Modem(**kwargs)
    asyncio.run(add_ofono_interface(m, iface))
    return m


print("\n\033[1m== the interface that cannot repair itself\033[0m")

m = arrives("org.ofono.RadioSettings")
# Without this the phone boots with CurrentCapabilities pinned to LTE and no
# modes at all, for the whole uptime, and nothing anywhere says so.
check("RadioSettings arriving recomputes the modem's properties", 1, m.set_props_calls)
check("and it is still initialised with its properties read", False,
      m.interfaces["org.ofono.RadioSettings"].inits[0])
check("and it is watched for later changes", ["*"],
      m.interfaces["org.ofono.RadioSettings"].watchers)

print("\n\033[1m== and only that one\033[0m")

# The fix is deliberately narrow. Every other interface either has properties
# that change - which re-runs set_props() through the watcher - or feeds one of
# the sub-interfaces that is already recomputed above. Recomputing for all of
# them would also move the modem's power-on, which happens inside set_props(),
# earlier into the startup gather.
m = arrives("org.ofono.CallSettings")
check("an ordinary interface does not recompute them", 0, m.set_props_calls)

m = arrives("org.ofono.NetworkMonitor")
check("nor does the one the signal interface feeds", 0, m.set_props_calls)

m = arrives("org.ofono.Telephony")
check("an unused interface is skipped entirely", 0, m.set_props_calls)
check("and is never even created", [], list(m.interfaces))

print("\n\033[1m== when the one read came back with nothing\033[0m")

# The second way into the same symptom, and the one the first version of this
# fix missed: init() does not fail loudly, it just leaves the properties empty.
# Recomputing then finds nothing to compute from and pins LTE all over again.
# Asking once more is the only thing that can ever fill them, because
# AvailableTechnologies never changes and so never announces itself.
m = arrives("org.ofono.RadioSettings", failing=["org.ofono.RadioSettings"])
check("an empty read is asked again", 2,
      len(m.interfaces["org.ofono.RadioSettings"].inits))
check("and the modem recomputes afterwards", 1, m.set_props_calls)

# And the opposite mistake: a read that worked must not be repeated. oFono is
# on the other side of a bus, at boot, while everything else is starting.
m = arrives("org.ofono.RadioSettings")
check("a read that worked is not repeated", 1,
      len(m.interfaces["org.ofono.RadioSettings"].inits))

print("\n\033[1m== the reason this matters is still in the file\033[0m")

# If either of these ever changes upstream, the narrow fix above needs
# re-reading: it is narrow precisely because of them.
source = open(SOURCE, encoding="utf-8").read()
check("set_props still falls back to LTE alone when caps is 0", True,
      "if caps == 0:" in source)
check("and the mode table still keys on four exact totals", True,
      all(f"if modes == {n}:" in source for n in (30, 14, 6, 2)))

print(f"\n{RUN} checks, {FAILED} failed")
sys.exit(1 if FAILED else 0)
