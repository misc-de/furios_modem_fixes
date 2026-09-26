#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
"""
The band getters, and the one rule they have to keep: the modem is asked once,
not on every read.

SupportedBands and CurrentBands each sent an AT command to the modem whenever
anybody read them, and every GetManagedObjects reads them. One mmcli call was
two AT round trips; the route watcher alone makes three mmcli calls per burst.
Measured on the phone: over 2000 AT+EPBSEH in under an hour, and a modem that
woke the phone out of suspend within a quarter of a second, every time.

The other half matters just as much: a cache that is never dropped would keep
reporting bands the modem no longer has. It is dropped whenever they can have
changed, and a failed read is never remembered as "no bands".

Same approach as test-ports.py: the methods are lifted out of the shipped
source with ast and run on their own.
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


TREE = ast.parse(open(SOURCE, encoding="utf-8").read(), SOURCE)
FUNCS = {n.name: n for n in ast.walk(TREE)
         if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))}


# _BANDS lives in ofono2mm/types.py, which only the phone has - and a suite
# that only passes where ofono2mm is installed is no suite. Every bit of every
# byte as its own "band" is enough for a cache test.
_BANDS = [(byte * 8 + bit + 1, byte, bit) for byte in range(32) for bit in range(8)]


def load(*names):
    """Compile the named methods on their own."""
    body = []
    for name in names:
        if name not in FUNCS:
            raise SystemExit(f"{name} not found in {SOURCE} - did the patch move?")
        node = FUNCS[name]
        node.decorator_list = []
        body.append(node)
    module = ast.Module(body=body, type_ignores=[])
    ast.fix_missing_locations(module)
    ns = {"ofono2mm_print": lambda *a, **k: None, "_BANDS": _BANDS}
    exec(compile(module, SOURCE, "exec"), ns)  # noqa: S102
    return ns


NS = load("_read_bands", "_parse_epbseh", "SupportedBands", "CurrentBands")

# A real answer from the phone (FINDINGS.md).
ANSWER = '+EPBSEH: "0000009a","00000081","080808DF000000A000000002","080800D5000001A000003000"\nOK'


class Prop:
    def __init__(self, value):
        self.value = value


class Modem:
    _read_bands = NS["_read_bands"]
    _parse_epbseh = NS["_parse_epbseh"]
    SupportedBands = NS["SupportedBands"]
    CurrentBands = NS["CurrentBands"]

    def __init__(self, answers):
        self.verbose = False
        self._band_cache = {}
        self.props = {"SupportedBands": Prop(["dummy"]), "CurrentBands": Prop(["dummy"])}
        self.answers = answers
        self.sent = []

    async def _send_at_command(self, cmd):
        self.sent.append(cmd)
        return self.answers.pop(0) if self.answers else ''


def run(coro):
    return asyncio.run(coro)


print("\n\033[1m== the modem is asked once\033[0m")

m = Modem([ANSWER])
first = run(m.CurrentBands())
second = run(m.CurrentBands())
check("the first read asks the modem", "AT+EPBSEH?", m.sent[0])
check("the second read does not", 1, len(m.sent))
check("and both reads agree", first, second)
check("and the answer is a real band list", True, len(first) > 0)

m = Modem([ANSWER, ANSWER])
run(m.SupportedBands())
run(m.CurrentBands())
run(m.SupportedBands())
run(m.CurrentBands())
check("supported and current are two separate questions", ["AT+EPBSEH=?", "AT+EPBSEH?"], m.sent)

m = Modem([ANSWER])
got = run(m.CurrentBands())
got.append(9999)
check("a caller changing its list does not change the cache",
      False, 9999 in run(m.CurrentBands()))

print("\n\033[1m== a failed read is not remembered\033[0m")

m = Modem(['', ANSWER])
check("an empty answer falls back to the stored property", ["dummy"], run(m.CurrentBands()))
check("and the next read asks again", True, len(run(m.CurrentBands())) > 0)
check("two questions in all", 2, len(m.sent))

print("\n\033[1m== the cache is dropped whenever the bands can have changed\033[0m")

m = Modem([ANSWER, ANSWER])
run(m.CurrentBands())
m._band_cache.clear()
run(m.CurrentBands())
check("after a clear the modem is asked again", 2, len(m.sent))


def clears_cache(func):
    for node in ast.walk(FUNCS[func]):
        if (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
                and node.func.attr == "clear"
                and isinstance(node.func.value, ast.Attribute)
                and node.func.value.attr == "_band_cache"):
            return True
    return False


# Setting bands, restoring the saved ones at start, and the AT interface coming
# (back) up after an oFono or modem restart are three ways they change. The
# fourth is the one this list first forgot, because it shared the cache's own
# idea of who writes bands: the Command method hands any AT string straight to
# the modem, and "mmcli --command='AT+EPBSEH=...'" left CurrentBands reporting
# the old list until ModemManager was restarted.
for func in ("SetCurrentBands", "_restore_saved_bands", "add_ofono_interface", "Command"):
    check(f"{func} drops the cache", True, clears_cache(func))

# And by behaviour, not only by the presence of a call: a band change sent as
# a raw command is seen by the next read.
NS_CMD = load("Command")


class AtIface:
    def __init__(self, fail=False):
        self.fail = fail

    async def call_send_command(self, _cmd):
        if self.fail:
            raise RuntimeError("modem gone")
        return "OK"


for fail in (False, True):
    m = Modem([ANSWER, ANSWER])
    m.ofono_interfaces = {"org.ofono.FuriLabs.AT": AtIface(fail)}
    run(m.CurrentBands())
    run(NS_CMD["Command"](m, 'AT+EPBSEH="00","00","00","00"', 0))
    run(m.CurrentBands())
    check("a raw command " + ("that fails " if fail else "")
          + "makes the next read ask the modem", 2, len(m.sent))

print(f"\n  {RUN} checks, {FAILED} failed")
sys.exit(1 if FAILED else 0)
