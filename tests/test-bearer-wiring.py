#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
"""
Every bearer has to listen to its oFono context. All three places that build
one, not two of them.

ofono2mm builds an MMBearerInterface in three places: when it enumerates the
contexts at startup, when oFono announces a new one, and inside doCreateBearer,
which is what Simple.Connect calls. The first two subscribed to the context's
PropertyChanged; doCreateBearer never did. A bearer made there stayed deaf for
the life of the process - no Connected, no Interface, no entry in the modem's
port list - and NetworkManager refused every activation with

    modem-broadband[/ril_0]: failed to connect modem: missing data port

Nothing repaired it later, because check_ofono_contexts skips any context that
already belongs to a bearer: the deaf one owned the context and kept it.

Which of the three runs first is a race between oFono publishing the internet
context and NetworkManager's autoconnect. Win it and the phone has data; lose
it and mobile data is gone until the next reboot - with oFono, the radio and
every mmcli field looking perfectly healthy, which is what made it expensive to
find.

So the invariant is checked here rather than left to that race: build a bearer,
subscribe to its context. The check is on the text of the file we ship, with
ast, because mm_modem.py imports half of ofono2mm and a test has no business
dragging that in.
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


def calls(node, name):
    """Every call of a method called <name>, anywhere below this node."""
    return [n for n in ast.walk(node)
            if isinstance(n, ast.Call)
            and isinstance(n.func, ast.Attribute) and n.func.attr == name]


def builds_bearer(node):
    return any(isinstance(n, ast.Call) and isinstance(n.func, ast.Name)
               and n.func.id == "MMBearerInterface" for n in ast.walk(node))


def subscriptions(node):
    """Calls of on_property_changed that hand over ofono_context_changed."""
    out = []
    for call in calls(node, "on_property_changed"):
        for arg in call.args:
            if isinstance(arg, ast.Attribute) and arg.attr == "ofono_context_changed":
                out.append(call)
    return out


def assignments_to(node, name):
    return [n for n in ast.walk(node)
            if isinstance(n, ast.Assign)
            and any(isinstance(t, ast.Name) and t.id == name for t in n.targets)]


tree = ast.parse(open(SOURCE, encoding="utf-8").read())
funcs = {n.name: n for n in ast.walk(tree)
         if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))}

builders = sorted(name for name, n in funcs.items() if builds_bearer(n))

print("\n\033[1m== who builds a bearer\033[0m")

# If ofono2mm grows a fourth place, this is the line that says so, and the
# check below then has something new to hold to the rule.
check("the places that build one are known",
      ["check_ofono_contexts", "doCreateBearer", "ofono_context_added"], builders)

print("\n\033[1m== and every one of them listens\033[0m")

for name in builders:
    check(f"{name} subscribes to the context", True, len(subscriptions(funcs[name])) > 0)

print("\n\033[1m== every context it takes hold of, not just the first\033[0m")

# doCreateBearer reaches a context two ways: the one oFono already provisioned,
# and one it adds itself when MBPI provisioned nothing. Both end up as the
# bearer's context, so both have to be subscribed to - a fix that covers only
# the common branch leaves the same silence behind on a phone whose carrier is
# not in the database.
create = funcs["doCreateBearer"]
check("both branches reach a context", 2, len(assignments_to(create, "ofono_ctx_interface")))
check("and both subscribe", 2, len(subscriptions(create)))

print("\n\033[1m== a context that is already up sends nothing\033[0m")

# Subscribing is not enough on its own. Simple.Connect can arrive when the
# context is already active - there is then no property change left to hear,
# and a bearer that waits for one waits forever. So the state gets read once.
check("doCreateBearer reads the context state", True, len(calls(create, "call_get_properties")) > 0)

# Order matters in that read. Connected arriving before Interface is exactly
# the state NetworkManager rejects as "missing data port", and it would be a
# self-inflicted version of the bug this test exists for.
seeded = []
for n in ast.walk(create):
    if isinstance(n, ast.Tuple):
        names = [e.value for e in n.elts
                 if isinstance(e, ast.Constant) and isinstance(e.value, str)]
        if "Active" in names:
            seeded = names
check("Settings is seeded before Active", True,
      "Settings" in seeded and seeded.index("Settings") < seeded.index("Active"))
check("IPv6 settings are seeded too", True, "IPv6.Settings" in seeded)

print(f"\n  {RUN} checks, {FAILED} failed")
sys.exit(1 if FAILED else 0)
