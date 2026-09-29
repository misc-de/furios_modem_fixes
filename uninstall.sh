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
sudo systemctl daemon-reload

echo "Shipped state restored. Takes effect after: sudo systemctl restart ModemManager"
echo "A SIM slot other than 1 goes back to slot 1 at the next reboot."
echo
echo "Note: the data connection flaps again on the shipped radioInterface 1.4."
echo "That is the state the phone came in, not a working one."
