# furios_modem_fixes

Fixes twenty-five defects in the FuriOS modem stack on the FuriPhone FLX1, and
keeps them fixed across package updates.

As it comes, the phone shows symptoms that look like bad reception but are not:
mobile data that only comes up after a reboot, mobile data that reports itself
connected over an interface that no longer exists, a signal bar stuck at its
lowest regardless of actual strength, no working route for mobile traffic at
all, and emergency alert channels the modem never listens on. Most of the causes sit in
`ofono2mm`, the rest in oFono's configuration, in NetworkManager's defaults and
in one database belonging to a third package.

Ten of the fixes are patches to files owned by the `ofono2mm` package, so
**every update of that package outdates them** (they sit behind dpkg
diversions, and the update lands beside them). That is why this is more than a
patch file: a boot unit and an apt hook put them back, and `modemctl` tells you
whether they are in place and whether they are working.

## Install

    git clone https://github.com/misc-de/furios_modem_fixes
    cd furios_modem_fixes && ./install.sh

or as a package:

    ./packaging/build-deb.sh --install

Both install and change nothing: after an installation the repairs are off.
Switch them on with

    sudo modemctl set fixed

which applies the patches, records the choice, and starts the two watchers
(a default route on mobile data, and bringing the data context back when it
drops). From then on a boot unit and an apt hook keep the recorded profile in
place across package updates. A phone that an earlier version had already
switched on keeps its repairs - the installers record that as "fixed". Undo
with `./uninstall.sh` or `apt remove furios-modem-fixes`.

## What is changed, and how it goes back

Everything this changes goes back on `./uninstall.sh` and `apt remove` (the
repairs also on `modemctl set shipped`, 5G on `modemctl nr off`, the SIM slot
on `modemctl sim 1`) - to what was there before, not to what a default is
assumed to be. Before the first change, whatever is not ours by name is
written down in `/var/lib/furios-modem-fixes/original/` (root only, 0700); a
second apply or a reinstall never overwrites that record, and the way back
uses it and drops it. A value somebody changed after us is left alone and
reported. Where there is no record - a phone an older version set up - the old
behaviour stays, and says that it is guessing.

| change | where | how it goes back |
|---|---|---|
| ofono2mm patches | `/usr/lib/ofono2mm/…`, shipped files diverted to `.distrib` (`dpkg -V ofono2mm` stays clean) | ours removed, `dpkg-divert --rename --remove` puts the shipped file back; an update lands on the `.distrib` and the apt hook makes ours again from it, or - when the patch no longer fits - puts the shipped one back and the boot unit fails (exit 5) instead of hiding it. Phones patched in place by older versions are moved over at the next apply; their `.bak.<time>` copies of the shipped file go then |
| DNS drop-in | `/etc/NetworkManager/conf.d/99-furios-modem-resolvconf.conf` | ours by name, removed |
| resolv.conf link | `/etc/resolv.conf` | from the record `resolv.conf.path` / `.absent`; only while it still points at NetworkManager |
| start order drop-in | `/etc/systemd/system/ModemManager.service.d/` | ours by name; the directory only when the record `mm-service-d` says apply made it |
| cell broadcast bus policy | `/etc/dbus-1/system.d/furios-modem-cellbroadcast.conf` | ours by name, removed |
| alert channel 4372 | `serviceproviders.xml` | the one marked line, mode and owner kept |
| warning channel list | oFono, per SIM | from the record `cbs-topics-<IMSI>`, set through oFono, only while it is one of our lists |
| oFono's TechnologyPreference | oFono (`modemctl nr on`) | from the record `ofono-technology-preference` on `nr off`, only while it is still `nr` |
| 5G bitmap | radio HAL | none needed: the RIL writes its own at every oFono start |
| SIM slot | `/etc/ofono/binder.d/zz-furios-sim.conf` | ours by name (and header), removed |
| MTK plugin (defect 25) | `/usr/lib/<arch>/ofono/plugins/mtkbinderpluginext.so`, shipped one diverted to `.distrib`; build in `/var/lib/furios-modem-mtk` | ours removed, `dpkg-divert --rename --remove` puts the shipped file back; takes effect at the next oFono start. Built on the phone by `modemctl mtk-build` (network, `git make gcc pkg-config libofonobinderpluginext-dev libgbinder-radio-dev ofono-dev libandroid-properties-dev`) |
| units, apt hook, polkit action, tools | `/etc/systemd/system`, `/etc/apt/apt.conf.d`, `/usr/share/polkit-1/actions`, `/usr/local` | ours by name, removed |

Not reversible: the modem's `nr_ps` (see [tools/5g/README.md](tools/5g/README.md)).

## Usage

    modemctl status     what is in place, and what the stack says
    modemctl apply      apply whatever is missing (idempotent, needs root)
    modemctl revert     back to the shipped state
    modemctl check      status plus runtime checks
    modemctl signal     what the radio really receives, cross-checked
    modemctl settle     after restarting ModemManager by hand: puts
                        NetworkManager back in order (needs root)
    modemctl sim        SIM slots: how many, which is used, where a card is
    modemctl sim <n>    use the SIM in slot n and remember it (needs root)

The FLX1 has two SIM slots but one radio (dual SIM dual standby), and FuriOS
only ever uses the first. `modemctl sim 2` points oFono at the second slot
instead - one at a time, never both: during a call on one SIM the other would
be unreachable anyway, and a second modem is something the shell, the apps and
the repairs here do not know how to handle. The modem keeps its path `/ril_0`,
so nothing above oFono notices the change. Switching restarts the modem stack
(about half a minute without mobile network) and is refused during a call.
The app shows the choice as a list once two cards are in.

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
patches, and modemctl's judgement about when to leave a file alone. Every
modemctl run in them is sandboxed: `tests/lib.sh` points every `MODEMCTL_*`
override into a temporary tree, and a run with one missing stops the test
before modemctl starts. Whether the
bar on the screen moves needs a radio and a look at the device — that is
`modemctl check`.

## Licence

Our own code is MIT (see [LICENSE](LICENSE)). The patches modify ofono2mm's
files and carry ofono2mm's licences, one of which is GPL-2.0 — **so the built
package as a whole is GPL-2.0**. The details are in [NOTICE](NOTICE).

Every defect, the measurements behind it and the traps that cost hours are in
[FINDINGS.md](FINDINGS.md).

Wi-Fi calling does not work yet; what was measured and the plan to get it
are in [VOWIFI-PLAN.md](VOWIFI-PLAN.md).
