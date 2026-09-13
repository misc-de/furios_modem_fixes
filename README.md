# furios_modem_fixes

Eight defects in the FuriOS modem stack, and a way to keep them fixed.

Out of the box on this phone the data connection often only came up after a
reboot, the signal icon sat at the emptiest bar regardless of reception, and
mobile data never carried a single packet of anybody's traffic. None of it was
a radio problem. Five of the causes are in `ofono2mm`, one is in oFono's binder
configuration, one is in oFono itself, and one is in how FuriOS wires up DNS.

The last two are different in kind from the rest: nothing gets patched. Number
7 is about what oFono *says* about the data call, and the fix is to install the
route that claim prevents. Number 8 is a resolver that is filled correctly and
asked by nobody. Together they are why switching Wi-Fi off left this phone with
no network at all.

The fixes live in files owned by the `ofono2mm` package, so **every update of
that package removes them**. That is the entire reason this repository is more
than a patch file: a boot unit and an apt hook put them back, and `modemctl`
tells you whether they are in place and whether they are working.

**Two files:** this one says what it does and how to run it.
**[FINDINGS.md](FINDINGS.md)** says why - every measurement, and the traps that
cost hours.

## Install

    git clone https://github.com/misc-de/furios_modem_fixes
    cd furios_modem_fixes && ./install.sh

or build a package:

    ./packaging/build-deb.sh --install

Both apply everything immediately and enable the two units - the one that puts
the patches back after a package update, and the one that keeps a default route
on mobile data. Reversible with `./uninstall.sh` or
`apt remove furios-modem-fixes`.

## modemctl

    modemctl status     what is in place, and what the stack says
    modemctl apply      apply whatever is missing (idempotent, needs root)
    modemctl revert     back to the shipped state
    modemctl check      status plus runtime checks (polling, loops)
    modemctl signal     what the radio really receives, cross-checked

`modemctl signal` is the one worth knowing. Neither the icon nor
`mmcli --signal-get` could be trusted before the fix, so it reads oFono
directly and checks the answer against `AT+CESQ`, an independent path through
the modem:

    technology     lte
    EARFCN         350
    RSRP           -120 dBm
    RSRQ           -10 dB
    RSSI           -111 dBm   (ASU 1)
    bar            26 %

    AT+CESQ        RSRP -119 dBm, RSRQ -10 dB
                   agrees within 1 dB

It imports its conversions from the patched `mm_modem_signal.py` rather than
keeping a copy, so it measures the code that is actually running - and says so
plainly when the fix is not installed.

One thing to know before pasting its output anywhere: `cell` and `EARFCN`
identify the tower you are on, which places you within a kilometre or so. The
signal levels do not. Nothing is stored or sent - it prints and exits - but a
bug report is a public place.

## The eight defects

| # | What | Where | Symptom |
|---|---|---|---|
| 1 | `radioInterface` pinned to 1.4, so NR goes through a call this modem rejects | oFono config | RIL error 44 twice a second, no clean cell reselection |
| 2 | MMS context with a placeholder APN | oFono state | ~1,700 failed activations an hour |
| 3 | Netmask never copied into `Ip4Config` | `utils.py`, `mm_bearer.py`, `mm_modem.py` | address configured as a `/0` |
| 4 | NM profile asks for IPv6 on an IPv4-only context | `mm_modem_simple.py`, `mm_bearer.py` | `modem IP method unsupported` on every activation |
| 5 | `active_connect` never cleared on the failure path | `mm_modem_simple.py`, `mm_bearer.py` | NetworkManager waits in `prepare` until you reboot |
| 6 | No signal strength, and RSRP/RSRQ swapped and unsigned | `mm_modem_signal.py`, `mm_modem.py`, `mm_modem_simple.py` | bar stuck at 0%, `rsrp=+10 dBm` |
| 7 | Data call's `Gateway` reported as the interface's own address | oFono | no default route on mobile data - Wi-Fi off means offline |
| 8 | `resolvconf` is a symlink to `resolvectl` and fails on every network change | FuriOS NM config | `/etc/resolv.conf` points at a resolver that only ever learns Wi-Fi's servers |

Numbers behind each of these, and why they are what they are, in
[FINDINGS.md](FINDINGS.md).

Numbers 7 and 8 are the ones nobody notices, because everything reports itself
healthy: the modem is registered, the bearer is connected, the interface has an
address, `mmcli` is happy, and names resolve. There is simply no way out of the
phone, and no resolver that will answer once Wi-Fi is gone. Both only show the
moment Wi-Fi goes away. `furios-mobile-route` installs the route and keeps it
installed, `modemctl apply` fixes the DNS wiring, and `modemctl status` calls
out either one when it is missing.

## When a patch stops fitting

An ofono2mm update can move the code a patch anchors on. `modemctl` then says
so and **changes nothing** - a patch that lands in the wrong place is worse
than no patch:

    FAIL  mm_modem_signal.py: patch does not fit (upstream moved)
          ready-made file in /usr/share/furios-modem/patched-files/... - check by hand

Two of the eight are already fixed or half-fixed upstream, so this is expected to
happen eventually.

## Root, cost, and what is checked

`apply` and `revert` write under `/usr/lib` and need root. `status`, `signal`
and most of `check` do not, and do not ask. What `apply` tests is whether it
can write the files, not `id -u` - a better message when it cannot, and the
reason the tests can exercise it without root.

Measured on the phone: the 30-second poll costs 0.005% of a core in ofono2mm
and at most 0.068% in oFono; `apply` as a no-op, which is what the boot unit
and the apt hook run, takes 41 ms. Numbers and method in
[FINDINGS.md](FINDINGS.md).

## Tests

    ./tests/run-tests.sh

What can be decided at a desk: that every patch reproduces the file we ship,
byte for byte, and reverts cleanly; that the signal conversions turn real
readings taken off this phone into the right numbers; that `modemctl`
recognises a file it must not touch; that the route watcher picks the default
bearer rather than the IMS one, and writes nothing when there is nothing to
write; and that half a DNS fix is never reported as a whole one.

What cannot: whether the bar on the screen moves. That is `modemctl check`, on
the device, with a SIM in it.

## Layout

    modemctl             the tool
    tools/               the honest signal readout, and the mobile route watcher
    patches/             the fixes, as unified diffs
    patched-files/       the finished files - the rescue path when a patch stops fitting
    original-files/      untouched originals from the package, for the tests
    networkmanager/      the DNS drop-in that takes resolvconf out of the path
    systemd/, apt/       the two things that survive a package update
    upstream/            bug reports, ready to file
    tests/               what can be checked without a radio
    packaging/           build-deb.sh

## Licence

Our own code is MIT. The patches are diffs against ofono2mm's files and carry
ofono2mm's licences - BSD-3-Clause for four of them, **GPL-2.0** for
`mm_modem_signal.py`, which makes the package as a whole GPL-2.0. See
[NOTICE](NOTICE).
