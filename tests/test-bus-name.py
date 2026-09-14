#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
"""
Taking the bus name: the one step that decides whether the phone has a
ModemManager at all.

Measured 14.9. on the device: after a cold boot ofono2mm was running, healthy
and busy - and nobody owned org.freedesktop.ModemManager1. Two minutes in,
mmcli still said "couldn't find the ModemManager process in the bus". No
mobile data, no signal icon, and in the journal one line: "Started
ModemManager.service". Nothing else, ever.

Three things made that possible, and each one is checked here:

  * The failure was reported through ofono2mm_print, which prints nothing at
    all without -v. The service does not run with -v.
  * request_name's return value was dropped. Two of its four answers mean the
    name is ours; IN_QUEUE and EXISTS mean it is not, and looked like success.
  * Failure returned from main(), which does not end the process: asyncio.run
    then waits on the background tasks that outlive main(), so systemd sees a
    service that is up while nothing answers for ModemManager. Restart= cannot
    catch a failure that never exits.

As in test-object-manager.py, the function is lifted out of the shipped
main.py with ast rather than imported, because main.py pulls in ofono2mm and a
real bus.
"""
import ast
import asyncio
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


class Reply:
    """dbus_fast's RequestNameReply, by name and by number.

    Copied rather than imported so this runs anywhere; kept honest at the
    bottom of the file, where it is compared against the real one whenever
    dbus_fast is installed.
    """

    def __init__(self, name, value):
        self.name = name
        self.value = value

    def __repr__(self):
        return f"RequestNameReply.{self.name}"


PRIMARY_OWNER = Reply("PRIMARY_OWNER", 1)
IN_QUEUE = Reply("IN_QUEUE", 2)
EXISTS = Reply("EXISTS", 3)
ALREADY_OWNER = Reply("ALREADY_OWNER", 4)


class FakeRequestNameReply:
    PRIMARY_OWNER = PRIMARY_OWNER
    IN_QUEUE = IN_QUEUE
    EXISTS = EXISTS
    ALREADY_OWNER = ALREADY_OWNER


class FakeBus:
    """A bus that answers request_name from a script of outcomes.

    An entry is either a reply to return or an exception to raise, and the
    last one repeats for ever so a test that never succeeds does not run off
    the end of the list - it runs into the attempt cap instead.
    """

    def __init__(self, answers):
        self.answers = list(answers)
        self.asked = []

    async def request_name(self, name):
        self.asked.append(name)
        answer = self.answers[min(len(self.asked) - 1, len(self.answers) - 1)]
        if isinstance(answer, BaseException):
            raise answer
        return answer


class FakeAsyncio:
    """asyncio, with the waiting taken out and written down instead."""

    TimeoutError = asyncio.TimeoutError

    def __init__(self):
        self.slept = []
        self.waited_for = []

    async def sleep(self, delay):
        self.slept.append(delay)
        # Written down, not waited out - but the event loop still has to get a
        # turn, or a function that retries for ever never lets its driver
        # look at it again.
        await asyncio.sleep(0)

    async def wait_for(self, coro, timeout):
        self.waited_for.append(timeout)
        return await coro


def load_take_bus_name():
    """Pull take_bus_name and the bus name constant out of the shipped file."""
    tree = ast.parse(open(SOURCE).read(), SOURCE)
    keep = [
        node
        for node in tree.body
        if (isinstance(node, ast.AsyncFunctionDef) and node.name == "take_bus_name")
        or (
            isinstance(node, ast.Assign)
            and any(isinstance(t, ast.Name) and t.id == "MM_BUS_NAME" for t in node.targets)
        )
    ]
    if len(keep) != 2:
        print(
            f"  \033[31mFAIL\033[0m {SOURCE} has no take_bus_name with a "
            f"MM_BUS_NAME to default to (found {len(keep)} of 2) - is main.py "
            f"patched?"
        )
        sys.exit(1)
    # The constant has to come first: it is the function's default argument,
    # evaluated when the def is executed.
    keep.sort(key=lambda n: isinstance(n, ast.AsyncFunctionDef))
    return keep


def run_take(answers, cap=8):
    """Run take_bus_name against a scripted bus. Returns what it did.

    cap stops a function that never gives up from never returning, which is
    the whole point of it - so "hit the cap" is an outcome the tests assert
    on, not a failure of the harness.
    """
    fake_asyncio = FakeAsyncio()
    printed = []
    bus = FakeBus(answers)

    ns = {
        "asyncio": fake_asyncio,
        "RequestNameReply": FakeRequestNameReply,
        "print": lambda *a, **k: printed.append(" ".join(str(x) for x in a)),
    }
    exec(compile(ast.Module(body=load_take_bus_name(), type_ignores=[]), SOURCE, "exec"), ns)

    async def drive():
        task = asyncio.ensure_future(ns["take_bus_name"](bus))
        # Nothing here really waits, so the coroutine only ever stops at the
        # cap; a few loop turns are enough to get there.
        for _ in range(cap * 4):
            if task.done():
                break
            if len(bus.asked) >= cap:
                task.cancel()
                break
            await asyncio.sleep(0)
        try:
            await task
            return "returned"
        except asyncio.CancelledError:
            return "still trying"

    outcome = asyncio.new_event_loop().run_until_complete(drive())
    return {
        "outcome": outcome,
        "asked": bus.asked,
        "printed": printed,
        "slept": fake_asyncio.slept,
        "waited_for": fake_asyncio.waited_for,
        "name": ns["MM_BUS_NAME"],
    }


print("\n  the two answers that mean the name is ours")

r = run_take([PRIMARY_OWNER])
check("PRIMARY_OWNER is success", "returned", r["outcome"])
check("and it only asks once", 1, len(r["asked"]))
check("it asks for ModemManager1", "org.freedesktop.ModemManager1", r["name"])
check("under that name", ["org.freedesktop.ModemManager1"], r["asked"])
check("and says so", True, any("is ours" in line for line in r["printed"]))

r = run_take([ALREADY_OWNER])
check("ALREADY_OWNER is success too", "returned", r["outcome"])
check("said out loud as well", True, any("is ours" in line for line in r["printed"]))

print("\n  the two that do not, and used to look like they did")

r = run_take([IN_QUEUE])
check("IN_QUEUE is not success", "still trying", r["outcome"])
check("it keeps asking", True, len(r["asked"]) >= 8)
check("and names the answer it got", True, any("IN_QUEUE" in l for l in r["printed"]))
check("saying somebody else owns it", True,
      any("somebody else owns it" in l for l in r["printed"]))

r = run_take([EXISTS])
check("EXISTS is not success either", "still trying", r["outcome"])
check("and it is named too", True, any("EXISTS" in l for l in r["printed"]))

print("\n  a bus that refuses, or does not answer at all")

r = run_take([PermissionError("Connection is not allowed to own the service")])
check("an error does not end the attempt", "still trying", r["outcome"])
check("the error text is printed", True,
      any("not allowed to own" in l for l in r["printed"]))
check("with the kind of error it was", True,
      any("PermissionError" in l for l in r["printed"]))

r = run_take([asyncio.TimeoutError()])
check("no answer does not end it either", "still trying", r["outcome"])
check("and says the bus went quiet", True,
      any("did not answer" in l for l in r["printed"]))
check("the ask itself is given ten seconds", [10] * len(r["asked"]), r["waited_for"])

print("\n  it gets there in the end")

r = run_take([IN_QUEUE, IN_QUEUE, PRIMARY_OWNER])
check("a name that frees up is taken", "returned", r["outcome"])
check("after exactly three asks", 3, len(r["asked"]))
check("having waited twice", 2, len(r["slept"]))

print("\n  waiting, without spinning and without giving up")

r = run_take([IN_QUEUE], cap=8)
check("the wait doubles", [1, 2, 4, 8, 16, 30, 30], r["slept"][:7])
check("and stops doubling at half a minute", True, max(r["slept"]) == 30)
check("every failed attempt says something", True, len(r["printed"]) >= len(r["asked"]) - 1)

print("\n  and the daemon uses it")

shipped = open(SOURCE).read()
check("main() takes the name through it", True, "await take_bus_name(bus)" in shipped)
check(
    "no quiet ofono2mm_print is left on that path",
    False,
    "Failed to request org.freedesktop.ModemManager1 bus name" in shipped,
)
check(
    "and no bare request_name that ignores the answer",
    False,
    "await bus.request_name('org.freedesktop.ModemManager1')" in shipped,
)
check(
    "and no wait for a modem is left before it (defect 23)",
    False,
    "something_to_show" in shipped or "no modem after ten seconds" in shipped,
)
check("RequestNameReply is imported from dbus_fast", True,
      "from dbus_fast.constants import PropertyAccess, RequestNameReply" in shipped)

print("\n  oFono leaving does not take the bus name with it (defect 18)")


class FakeModem:
    def __init__(self):
        self.unexported = False

    def unexport_mm_interface_objects(self):
        self.unexported = True


class FakeNameBus:
    """A bus that writes down every attempt to give the name away."""

    def __init__(self):
        # Deliberately no something_to_show: defect 23 took the wait out, and
        # a method that reaches for it again should raise here rather than
        # quietly pass.
        self.released = []

    async def release_name(self, name):
        self.released.append(name)


class FakeLoop:
    def __init__(self):
        self.tasks = []

    def create_task(self, coro):
        # Run it here and now: a release queued and never run is still a
        # release, and on the phone it ran a moment after the name was taken.
        self.tasks.append(coro)
        asyncio.new_event_loop().run_until_complete(coro)
        return coro


class FakeSelf:
    def __init__(self):
        self.verbose = False
        self.ofono_manager_interface = object()
        self.modems = {"/ril_0": FakeModem()}
        self.bus = FakeNameBus()
        self.loop = FakeLoop()


def load_method(name):
    """Lift one method out of the shipped file, class and all left behind."""
    tree = ast.parse(open(SOURCE).read(), SOURCE)
    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name == name:
            return node
    print(f"  \033[31mFAIL\033[0m {SOURCE} has no {name} - is main.py patched?")
    sys.exit(1)


def run_ofono_removed():
    ns = {"ofono2mm_print": lambda *a, **k: None}
    exec(compile(ast.Module(body=[load_method("ofono_removed")], type_ignores=[]),
                 SOURCE, "exec"), ns)
    me = FakeSelf()
    modem = me.modems["/ril_0"]
    ns["ofono_removed"](me)
    return me, modem


me, modem = run_ofono_removed()
check("the modem is unexported", True, modem.unexported)
check("and forgotten", 0, len(me.modems))
check("the oFono manager interface is dropped", None, me.ofono_manager_interface)
check("the bus name is not released", [], me.bus.released)
check("nothing is queued that could release it later", 0, len(me.loop.tasks))

shipped = open(SOURCE).read()
check(
    "no release of the ModemManager name is left anywhere",
    False,
    "release_name('org.freedesktop.ModemManager1')" in shipped
    or "release_name(MM_BUS_NAME)" in shipped,
)

print("\n  the name goes up before anything is waited for (defect 23)")


def load_function(name):
    tree = ast.parse(open(SOURCE).read(), SOURCE)
    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name == name:
            return node
    print(f"  \033[31mFAIL\033[0m {SOURCE} has no {name}")
    sys.exit(1)


def called_names(stmt):
    """Every call in this statement, as a dotted name where there is one."""
    out = []
    for node in ast.walk(stmt):
        if not isinstance(node, ast.Call):
            continue
        f = node.func
        if isinstance(f, ast.Name):
            out.append(f.id)
        elif isinstance(f, ast.Attribute):
            base = f.value.id if isinstance(f.value, ast.Name) else ""
            out.append(f"{base}.{f.attr}" if base else f.attr)
    return out


main_fn = load_function("main")
take_at = export_at = None
for i, stmt in enumerate(main_fn.body):
    names = called_names(stmt)
    if take_at is None and "take_bus_name" in names:
        take_at = i
    if export_at is None and any(n.endswith("export") for n in names):
        export_at = i

check("main() takes the bus name", True, take_at is not None)
check("the manager interface is exported first", True,
      export_at is not None and take_at is not None and export_at < take_at)

# On the old main.py this list came back with asyncio.wait_for and .wait in
# it: the name waited ten seconds for a modem, and on the boot of 14.9. 14:50
# phosh asked in the gap and got nobody.
waited = []
for stmt in main_fn.body[:take_at or 0]:
    for n in called_names(stmt):
        if n in ("asyncio.wait_for", "asyncio.sleep") or n.endswith(".wait"):
            waited.append(n)
check("and nothing at all is waited for before it", [], waited)


print("\n  the copy of RequestNameReply above is still the real one")
try:
    from dbus_fast.constants import RequestNameReply as Real
except ImportError:
    print("  \033[33mskipped\033[0m - dbus_fast not installed here")
else:
    for mine in (PRIMARY_OWNER, IN_QUEUE, EXISTS, ALREADY_OWNER):
        real = getattr(Real, mine.name, None)
        check(f"{mine.name} is still {mine.value}",
              mine.value, None if real is None else real.value)
    check("and there are still four of them", 4, len(list(Real)))

print(f"\n  {RUN} checks, {FAILED} failed")
sys.exit(1 if FAILED else 0)
