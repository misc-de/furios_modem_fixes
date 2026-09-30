#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
# Removes everything this project installed and puts the shipped code back.
set -e
cd "$(dirname "$0")"

# Revert first - afterwards modemctl and the patches are gone and the ofono2mm
# files would stay patched with nothing left to undo them.
sudo /usr/local/bin/modemctl revert || true
# oFono back on slot 1, from the next boot on: restarting oFono by hand
# leaves the modem offline.
sudo /usr/local/bin/modemctl sim 1 --no-restart || true
# 5G back to what oFono asks for, while nrprobe is still here to do it.
[ -f /etc/furios-modem-fixes.nr ] && sudo /usr/local/bin/modemctl nr off || true

# The older way in was a .deb (packaging/build-deb.sh), with everything under
# /usr instead of /usr/local and the apt hook as a conffile. Purged, not
# removed: its prerm reverts with the package's own modemctl, and only purge
# takes the conffile and the records in /etc and /var/lib with it. Also when
# only its configuration is left ("rc" in dpkg -l).
if dpkg-query -W -f='${Status}' furios-modem-fixes 2>/dev/null | grep -qv 'not-installed'; then
    sudo dpkg --purge furios-modem-fixes || true
fi

sudo systemctl disable --now furios-modem-fixes.service 2>/dev/null || true
sudo systemctl disable furios-modem-sim-check.service 2>/dev/null || true
sudo systemctl disable furios-modem-nr.service 2>/dev/null || true
sudo systemctl disable --now furios-mobile-route.service 2>/dev/null || true
sudo systemctl disable --now furios-mobile-context.service 2>/dev/null || true
# The watcher's route goes with it. Leaving a default route behind that nothing
# maintains any more is exactly the half-state this project exists to avoid.
#
# The metric is asked of the watcher rather than written here a second time -
# while it is still installed, which is why this runs before the removals
# below. If it is already gone, fall back to the default it ships with.
METRIC=$(/usr/local/bin/furios-mobile-route --metric 2>/dev/null || echo 1050)
sudo ip route del default dev "$(ip -4 route show default metric "$METRIC" \
    | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)" \
    metric "$METRIC" 2>/dev/null || true
# The recorded profile goes too. Left behind, a "shipped" from an old
# "modemctl set" is what the next installation finds and obeys: it installs,
# applies nothing, and keeps the watchers off - a choice made about a package
# that has since been removed.
sudo rm -f /etc/systemd/system/furios-modem-fixes.service \
           /etc/systemd/system/furios-modem-sim-check.service \
           /etc/systemd/system/furios-modem-nr.service \
           /etc/ofono/binder.d/zz-furios-sim.conf \
           /etc/systemd/system/furios-mobile-route.service \
           /etc/systemd/system/furios-mobile-context.service \
           /etc/apt/apt.conf.d/99furios-modem-fixes \
           /usr/local/bin/modemctl \
           /usr/local/bin/furios-modem-signal \
           /usr/local/bin/furios-mobile-route \
           /usr/local/bin/furios-mobile-context \
           /usr/share/polkit-1/actions/de.misc-de.modemctl.policy \
           /etc/furios-modem-fixes.profile \
           /etc/furios-modem-fixes.sim \
           /etc/furios-modem-fixes.nr
sudo rm -rf /usr/local/share/furios-modem /usr/local/lib/furios-modem /var/lib/furios-modem-fixes
# The SIM switch's lock lives in /run and would go at the next boot anyway.
sudo rm -f /run/furios-modem-fixes.sim.lock
# revert takes the start-order drop-in out and the directory with it - but
# only when today's drop-in was there; one that held just the legacy
# 50-furios-after-ofono.conf stayed behind empty. rmdir: never anything else's.
sudo rmdir /etc/systemd/system/ModemManager.service.d 2>/dev/null || true
# "disable" cannot find a unit whose file is already gone - a half-finished
# earlier uninstall - and leaves its symlink in *.wants dangling. Ours only,
# by name, and only links.
sudo find /etc/systemd/system -path '*.wants/*' -type l \
    \( -name 'furios-modem-*.service' -o -name 'furios-mobile-*.service' \) \
    -delete 2>/dev/null || true
sudo systemctl daemon-reload

# The backups apply took before it changed a file FuriOS ships. Each set goes
# only once that file is what its package shipped again - dpkg's own checksum
# says so, not ours - because until then a backup may be the only way back.
# Only our own names (.bak.YYYYMMDD-HHMMSS); anything else next to them is
# somebody else's. radio-interface-binder.conf included: revert leaves it at
# the shipped 1.4, and its backups hold the 1.6 an earlier version wrongly
# set - nothing anybody should ever put back.
shipped_again() {
    local pkg
    pkg=$(dpkg-query -S "$1" 2>/dev/null | head -1 | cut -d: -f1)
    [ -n "$pkg" ] && [ -e "$1" ] || return 1
    ! dpkg --verify "$pkg" 2>/dev/null | grep -q " $1\$"
}
for f in /usr/lib/ofono2mm/main.py /usr/lib/ofono2mm/ofono2mm/utils.py \
         /usr/lib/ofono2mm/ofono2mm/mm_bearer.py /usr/lib/ofono2mm/ofono2mm/mm_modem.py \
         /usr/lib/ofono2mm/ofono2mm/mm_modem_simple.py \
         /usr/lib/ofono2mm/ofono2mm/mm_modem_signal.py \
         /etc/ofono/binder.d/radio-interface-binder.conf; do
    ls "$f".bak.[0-9]*-[0-9]* >/dev/null 2>&1 || continue
    if shipped_again "$f"; then
        sudo rm -f "$f".bak.[0-9]*-[0-9]*
    else
        echo "$f is not what its package shipped - its backups stay:" >&2
        ls -1 "$f".bak.[0-9]*-[0-9]* >&2
    fi
done
# resolv.conf belongs to no package; FuriOS ships it as a link to the
# systemd-resolved stub. Its backups go once revert has put that - or
# anything that is not our link to NetworkManager - back.
if ls /etc/resolv.conf.bak.[0-9]*-[0-9]* >/dev/null 2>&1; then
    if [ "$(readlink -f /etc/resolv.conf)" != /run/NetworkManager/resolv.conf ]; then
        sudo rm -f /etc/resolv.conf.bak.[0-9]*-[0-9]*
    else
        echo "/etc/resolv.conf still points at NetworkManager - its backups stay." >&2
    fi
fi

echo "Shipped state restored. Takes effect after: sudo systemctl restart ModemManager"
echo "A SIM slot other than 1 goes back to slot 1 at the next reboot."
echo
echo "Note: the data connection flaps again on the shipped radioInterface 1.4."
echo "That is the state the phone came in, not a working one."
