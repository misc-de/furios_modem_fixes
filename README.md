# furios_modem_fixes

Fourteen defects in the FuriOS modem stack, and a way to keep them fixed.

Out of the box on this phone the data connection often only came up after a
reboot, the signal icon sat at the emptiest bar regardless of reception, and
mobile data never carried a single packet of anybody's traffic. None of it was
a radio problem. Seven of the causes are in `ofono2mm`, one is in oFono's binder
configuration, one is in oFono itself, one is in how FuriOS wires up DNS, one
is in ModemManager's own bus policy, and one is in the database the alert
channel list comes from.

Three are different in kind from the rest: nothing gets patched. Number
7 is about what oFono *says* about the data call, and the fix is to install the
route that claim prevents. Number 8 is a resolver that is filled correctly and
asked by nobody. Together they are why switching Wi-Fi off left this phone with
no network at all. Number 14 is one line in a database belonging to a third
package, and the only one here that is wrong upstream as well. Number 13 is a
permission that was never written down:
ModemManager grew a Cell Broadcast interface and a polkit action to guard it,
but no rule in its bus policy, so the bus turns the call away before polkit is
ever asked - and the channels a phone must listen on to receive a public
emergency alert stay at whatever the modem happened to default to.

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

## The fourteen defects

| # | What | Where | Symptom |
|---|---|---|---|
| 1 | The stored radio preference asks for NR, which this modem rejects outright | oFono state | RIL error 44 once a second, no clean cell reselection |
| 2 | MMS context with a placeholder APN | oFono state | ~1,700 failed activations an hour |
| 3 | Netmask never copied into `Ip4Config` | `utils.py`, `mm_bearer.py`, `mm_modem.py` | address configured as a `/0` |
| 4 | NM profile asks for IPv6 on an IPv4-only context | `mm_modem_simple.py`, `mm_bearer.py` | `modem IP method unsupported` on every activation |
| 5 | `active_connect` never cleared on the failure path | `mm_modem_simple.py`, `mm_bearer.py` | NetworkManager waits in `prepare` until you reboot |
| 6 | No signal strength, and RSRP/RSRQ swapped and unsigned | `mm_modem_signal.py`, `mm_modem.py`, `mm_modem_simple.py` | bar stuck at 0%, `rsrp=+10 dBm` |
| 7 | Data call's `Gateway` reported as the interface's own address | oFono | either no default route at all, or one that silently drops every packet |
| 8 | `resolvconf` is a symlink to `resolvectl` and fails on every network change | FuriOS NM config | `/etc/resolv.conf` points at a resolver that only ever learns Wi-Fi's servers |
| 9 | Nothing brings the data context back after a failed data call | the system as shipped | mobile data stays down until the next reboot |
| 10 | Interfaces are appended to the modem's port list and never removed | `mm_modem.py`, `mm_bearer.py` | NM binds the resolver to a dead interface; every lookup REFUSED with Wi-Fi off |
| 11 | An oFono interface asked for before oFono has it is never asked again | `mm_modem.py` | `CurrentCapabilities` pinned to LTE alone and `SupportedModes` **empty**, for the whole uptime |
| 12 | SIM and bearer objects announced through the ObjectManager, which ModemManager reserves for modems | `main.py` | phosh grabs a bearer, finds no modem on it and shows **no signal icon at all** |
| 13 | ModemManager's bus policy has no rule for the CellBroadcast interface it gained in 1.24 | `/etc/dbus-1/system.d` | the system bus rejects `SetChannels`, so **emergency alert channels never reach the modem** |
| 14 | The alert channel database lists EU-Alert level 2 for `de` and `nl` without channel 4372, while listing its local-language counterpart | `serviceproviders.xml` | **"extreme, immediate, likely" warnings sent on 4372 go unheard** |

Numbers behind each of these, and why they are what they are, in
[FINDINGS.md](FINDINGS.md).

Number 1 carries a correction worth reading before trusting anything else
here. For a day this repository "fixed" it with `radioInterface = 1.6`, and
the error loop did stop. But `1.6` is not a value `ofono-binder-plugin`
accepts - its table ends at `1.5` - and an unrecognised value falls back to
`1.2` silently. The loop stopped because at 1.2 the plugin drops NR from the
technology list, so nothing asked for it any more. The phone ran two interface
versions below the one it shipped with, lost 5G from the settings, and the
config file said 1.6 the whole time. See [FINDINGS.md](FINDINGS.md#1-runaway-loop-the-modem-rejects-the-preferred-mode).

Numbers 7, 8, 10 and 11 are the ones nobody notices, because everything reports itself
healthy: the modem is registered, the bearer is connected, the interface has an
address, `mmcli` is happy, names resolve, and `ip route` can even show a
default route - one measured at 100% packet loss. There is simply no way out of the
phone, and no resolver that will answer once Wi-Fi is gone. All three only show
the moment Wi-Fi goes away. `furios-mobile-route` installs the route and keeps it
installed, `modemctl apply` fixes the DNS wiring, `furios-mobile-context` puts
the data call back when it dies, and `modemctl status` calls out any of them
when it is missing.

Number 12 is the same kind of trap seen from the other side. There the stack
lied and the phone worked; here the stack is right about everything - modem
registered, bearer up, packets flowing - and the phone still shows no signal,
because the one client that draws the icon was handed a bearer where it
expected a modem. Nothing in `mmcli`, `ip`, or `ping` can see it. Only
`journalctl | grep phosh` can:

    phosh: mm_object_get_modem: runtime check failed: (MM_IS_MODEM (modem))
    phosh: modem_init_modem: assertion 'self->modem' failed

## When a patch stops fitting

An ofono2mm update can move the code a patch anchors on. `modemctl` then says
so and **changes nothing** - a patch that lands in the wrong place is worse
than no patch:

    FAIL  mm_modem_signal.py: patch does not fit (upstream moved)
          ready-made file in /usr/share/furios-modem/patched-files/... - check by hand

Three of the fourteen are already fixed or half-fixed upstream, so this is expected to
happen eventually.

The same message used to appear for a much less interesting reason: **a patch
of ours that changed**. The installed file was then neither what ofono2mm
ships nor what the new patch produces, so it applied in neither direction -
and the new fix could not be installed at all onto a phone that already had
this package. The package now reverts itself on upgrade, from the old version,
while its patches still describe the files on disk:

    modemctl revert --patches-only     # files back, configuration untouched

which is what `prerm upgrade` calls. Configuration is left alone on purpose: a
full revert would put `radioInterface` back to 1.4, and an upgrade that stops
between the two halves would leave the phone on the value that brings back the
Error-44 loop.

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
write; that half a DNS fix is never reported as a whole one; and - most of it -
that the context supervisor refuses to act, on mobile data somebody switched
off, on a radio that is not registered, and during a call.

What cannot: whether the bar on the screen moves. That is `modemctl check`, on
the device, with a SIM in it.

## Layout

    modemctl             the tool
    tools/               the signal readout, the route watcher, the context supervisor
    patches/             the fixes, as unified diffs
    patched-files/       the finished files - the rescue path when a patch stops fitting
    original-files/      untouched originals from the package, for the tests
    networkmanager/      the DNS drop-in that takes resolvconf out of the path
    dbus/                the bus policy that lets emergency alert channels be set
    systemd/, apt/       the two things that survive a package update
    upstream/            bug reports, ready to file
    tests/               what can be checked without a radio
    packaging/           build-deb.sh

## Licence

Our own code is MIT. The patches are diffs against ofono2mm's files and carry
ofono2mm's licences - BSD-3-Clause for four of them, **GPL-2.0** for
`mm_modem_signal.py`, which makes the package as a whole GPL-2.0. See
[NOTICE](NOTICE).
