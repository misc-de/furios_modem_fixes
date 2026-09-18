# furios_modem_fixes

Fixes twenty-four defects in the FuriOS modem stack on the FuriPhone FLX1, and
keeps them fixed across package updates.

As it comes, the phone shows symptoms that look like bad reception but are not:
mobile data that only comes up after a reboot, mobile data that reports itself
connected over an interface that no longer exists, a signal bar stuck at its
lowest regardless of actual strength, no working route for mobile traffic at
all, and emergency alert channels the modem never listens on. Most of the causes sit in
`ofono2mm`, the rest in oFono's configuration, in NetworkManager's defaults and
in one database belonging to a third package.

Ten of the fixes are patches to files owned by the `ofono2mm` package, so
**every update of that package removes them**. That is why this is more than a
patch file: a boot unit and an apt hook put them back, and `modemctl` tells you
whether they are in place and whether they are working.

## Install

    git clone https://github.com/misc-de/furios_modem_fixes
    cd furios_modem_fixes && ./install.sh

or as a package:

    ./packaging/build-deb.sh --install

Both apply everything immediately and enable three units: one that restores the
patches after a package update, one that keeps a default route on mobile data,
and one that brings the data context back when it drops. Undo with
`./uninstall.sh` or `apt remove furios-modem-fixes`.

## Usage

    modemctl status     what is in place, and what the stack says
    modemctl apply      apply whatever is missing (idempotent, needs root)
    modemctl revert     back to the shipped state
    modemctl check      status plus runtime checks
    modemctl signal     what the radio really receives, cross-checked
    modemctl settle     after restarting ModemManager by hand: puts
                        NetworkManager back in order (needs root)

`modemctl signal` is the one worth knowing. Neither the icon nor
`mmcli --signal-get` could be trusted before these fixes, so it reads oFono
directly and checks the answer against `AT+CESQ`, an independent path through
the modem:

    technology     lte
    RSRP           -120 dBm
    RSRQ           -10 dB
    bar            26 %

    AT+CESQ        RSRP -119 dBm, RSRQ -10 dB
                   agrees within 1 dB

One thing before pasting its output into a bug report: `cell` and `EARFCN`
identify the tower you are on, which places you within a kilometre or so. The
signal levels do not.

## Tests

    ./tests/run-tests.sh        # never with sudo

Everything that can be decided without a SIM in the phone: the conversions, the
patches, and modemctl's judgement about when to leave a file alone. Whether the
bar on the screen moves needs a radio and a look at the device — that is
`modemctl check`.

## Licence

Our own code is MIT (see [LICENSE](LICENSE)). The patches modify ofono2mm's
files and carry ofono2mm's licences, one of which is GPL-2.0 — **so the built
package as a whole is GPL-2.0**. The details are in [NOTICE](NOTICE).

Every defect, the measurements behind it and the traps that cost hours are in
[FINDINGS.md](FINDINGS.md).
