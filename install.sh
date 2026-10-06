#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
# Installs modemctl, the patches, the boot unit and the apt hook, then applies
# everything. Safe to re-run.
set -e
cd "$(dirname "$0")"

# /usr/local, not /usr: that is where a hand installation belongs, and it
# keeps this out of the way of the .deb. Installing both used to leave an
# "apt remove" behind with a unit in /etc pointing at a binary that was gone.
BIN=/usr/local/bin
SHARE=/usr/local/share/furios-modem

sudo install -Dm755 modemctl                  "$BIN/modemctl"
sudo install -Dm755 tools/furios-modem-signal "$BIN/furios-modem-signal"
sudo install -Dm755 tools/furios-modem-signal "$SHARE/tools/furios-modem-signal"
sudo install -Dm755 tools/furios-mobile-route "$BIN/furios-mobile-route"
sudo install -Dm755 tools/furios-mobile-route "$SHARE/tools/furios-mobile-route"
sudo install -Dm755 tools/furios-mobile-context "$BIN/furios-mobile-context"
sudo install -Dm755 tools/furios-mobile-context "$SHARE/tools/furios-mobile-context"

# Before anything in $SHARE is overwritten: take out the previous version of
# our OWN patches. Changing one of them is the ordinary case when developing
# here, and it used to end in a dead end that costs half an hour to recognise
# - the file on the phone is our previous patched version, so the new patch
# does not fit ("main.py: patch does not fit (upstream moved)") and revert
# does not recognise it either ("main.py is not ours to revert"): by both
# patches' reckoning, nothing on the phone is ours. The old ready-made copies
# and the old patches are still here at this point, which is exactly what is
# needed to undo them. The .deb has this covered in prerm; this is the hand
# path. Measured 14.9.
TARGET=/usr/lib/ofono2mm/ofono2mm
for f in utils mm_bearer mm_modem mm_modem_simple mm_modem_signal main; do
    [ "$f" = main ] && on_disk="$TARGET/../main.py" || on_disk="$TARGET/$f.py"
    old_copy="$SHARE/patched-files/$f.py"
    [ -f "$old_copy" ] && [ -f "$on_disk" ] || continue
    # Diverted (6.10.2026 on): the shipped file is the .distrib, and apply
    # makes our copy again from it whenever the patch changed. Nothing to
    # take out by hand - and a reverse patch here would only edit our copy.
    [ "$(dpkg-divert --truename "$on_disk" 2>/dev/null)" = "$on_disk.distrib" ] && continue
    # Only a file that is byte for byte what we installed last time, and is
    # not already what we are about to install.
    cmp -s "$old_copy" "$on_disk" || continue
    cmp -s "patched-files/$f.py" "$on_disk" && continue
    if sudo patch -R -s -f -p1 -d "$TARGET/.." < "$SHARE/patches/ofono2mm-$f.patch"; then
        echo "  ok    $f.py: previous version of our own patch taken back out"
    else
        echo "  warn  $f.py: could not take the previous patch out - the new"
        echo "  warn       patch will not fit; $SHARE/patched-files/$f.py is the way in"
    fi
done

sudo mkdir -p "$SHARE/patches" "$SHARE/patched-files" "$SHARE/networkmanager" \
             "$SHARE/dbus" "$SHARE/systemd" "$SHARE/mtk"
sudo install -m644 networkmanager/*.conf "$SHARE/networkmanager/"
sudo install -m644 dbus/*.conf            "$SHARE/dbus/"
sudo install -m644 systemd/*.conf "$SHARE/systemd/"
sudo install -m644 patches/*.patch    "$SHARE/patches/"
sudo install -m755 mtk/build.sh       "$SHARE/mtk/build.sh"
# The ready-made files are the rescue path for the day a patch stops fitting.
# -type f: a stray __pycache__ from a test run must not take the install down.
find patched-files -maxdepth 1 -type f -exec sudo install -m644 {} "$SHARE/patched-files/" \;

# The unit ships with the package's path in it; point it at this one.
sed "s|^ExecStart=/usr/bin/modemctl|ExecStart=$BIN/modemctl|" \
    systemd/furios-modem-fixes.service | sudo tee \
    /etc/systemd/system/furios-modem-fixes.service >/dev/null
sudo chmod 644 /etc/systemd/system/furios-modem-fixes.service
sed "s|/usr/bin/modemctl|$BIN/modemctl|g" apt/99furios-modem-fixes | sudo tee \
    /etc/apt/apt.conf.d/99furios-modem-fixes >/dev/null
sudo chmod 644 /etc/apt/apt.conf.d/99furios-modem-fixes

sed "s|^ExecStart=/usr/bin/modemctl|ExecStart=$BIN/modemctl|" \
    systemd/furios-modem-sim-check.service | sudo tee \
    /etc/systemd/system/furios-modem-sim-check.service >/dev/null
sudo chmod 644 /etc/systemd/system/furios-modem-sim-check.service

# 5G: the probe is compiled here (needs gcc and libgbinder-dev), the unit
# points at this modemctl.
tools/5g/build.sh >/dev/null
sudo install -Dm755 tools/5g/nrprobe /usr/local/lib/furios-modem/nrprobe
sed "s|^ExecStart=/usr/bin/modemctl|ExecStart=$BIN/modemctl|" \
    systemd/furios-modem-nr.service | sudo tee \
    /etc/systemd/system/furios-modem-nr.service >/dev/null
sudo chmod 644 /etc/systemd/system/furios-modem-nr.service

sed "s|^ExecStart=/usr/bin/furios-mobile-route|ExecStart=$BIN/furios-mobile-route|" \
    systemd/furios-mobile-route.service | sudo tee \
    /etc/systemd/system/furios-mobile-route.service >/dev/null
sudo chmod 644 /etc/systemd/system/furios-mobile-route.service
sed "s|^ExecStart=/usr/bin/furios-mobile-context|ExecStart=$BIN/furios-mobile-context|" \
    systemd/furios-mobile-context.service | sudo tee \
    /etc/systemd/system/furios-mobile-context.service >/dev/null
sudo chmod 644 /etc/systemd/system/furios-mobile-context.service

# The polkit action names the binary it is allowed to run, so it has to name
# THIS one. A policy pointing at /usr/bin while the app starts /usr/local/bin
# does not fail loudly - pkexec just refuses, and the switch looks broken.
sed "s|>/usr/bin/modemctl<|>$BIN/modemctl<|" polkit/de.misc-de.modemctl.policy \
    | sudo tee /usr/share/polkit-1/actions/de.misc-de.modemctl.policy >/dev/null
sudo chmod 644 /usr/share/polkit-1/actions/de.misc-de.modemctl.policy

sudo systemctl daemon-reload
# enable, not start: applying happens below, with output you can read.
sudo systemctl enable furios-modem-fixes.service >/dev/null
sudo systemctl enable furios-modem-sim-check.service >/dev/null
sudo systemctl enable furios-modem-nr.service >/dev/null
# The watchers are enabled on every phone, whatever is recorded: whether they
# run is the profile's business, through the mark "modemctl boot" writes below
# (ConditionPathExists in both units). Enabling them only on a "fixed" phone
# tied two states together that could drift apart, and did - an update left a
# "fixed" phone without its data-call supervisor (4.10.2026).
sudo "$BIN/modemctl" adopt
RECORDED=$("$BIN/modemctl" profile 2>/dev/null | sed -n 's/^recorded: *//p')
sudo systemctl enable furios-mobile-route.service furios-mobile-context.service >/dev/null

# boot, not apply - the same verb the package's postinst, the boot unit and the
# apt hook run. With apply, re-running this on a phone recorded as "shipped"
# put every repair back, said "Installed", and the boot unit took them all out
# again at the next start: a phone that changed state across a reboot for no
# reason anybody could see. With nothing recorded, boot leaves everything off.
# The MTK plugin fix is C and has to be built on the phone first (defect 25).
# Only for a phone that has the repairs on; boot below puts the build in. A
# failed build - no network, a -dev package missing - leaves the shipped
# plugin and says what to do.
# The first build of 4.10. went to /var/lib/furios-modem-fixes/mtk, which
# only root can read; it lives in /var/lib/furios-modem-mtk now.
sudo rm -rf /var/lib/furios-modem-fixes/mtk
if [ "$RECORDED" = fixed ]; then
    sudo "$BIN/modemctl" mtk-build || echo "  warn  MTK plugin not built - the shipped one stays (sudo modemctl mtk-build)"
fi
sudo "$BIN/modemctl" boot
# After boot, which wrote the mark: restart hands a running watcher the new
# code, starts a stopped one on a "fixed" phone, and on any other phone the
# condition keeps it - or stops it - off.
sudo systemctl restart furios-mobile-route.service furios-mobile-context.service
[ "$RECORDED" = fixed ] || echo "The repairs are off - switch them on with: sudo modemctl set fixed"

echo
echo "Installed. Check any time with:  modemctl status"
echo "What the radio really gets:      modemctl signal"
