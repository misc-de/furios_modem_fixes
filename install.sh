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
             "$SHARE/dbus" "$SHARE/systemd"
sudo install -m644 networkmanager/*.conf "$SHARE/networkmanager/"
sudo install -m644 dbus/*.conf            "$SHARE/dbus/"
sudo install -m644 systemd/*.conf "$SHARE/systemd/"
sudo install -m644 patches/*.patch    "$SHARE/patches/"
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
# This one is enable --now: it is a watcher, not a one-shot, and a watcher that
# is running but was never enabled is a fix that disappears at the next boot
# without telling anybody.
sudo systemctl enable --now furios-mobile-route.service >/dev/null
sudo systemctl enable --now furios-mobile-context.service >/dev/null
# Re-running install.sh over a running watcher has to hand it the new code;
# "enable --now" alone leaves the old process running.
sudo systemctl try-restart furios-mobile-route.service furios-mobile-context.service

sudo "$BIN/modemctl" apply

echo
echo "Installed. Check any time with:  modemctl status"
echo "What the radio really gets:      modemctl signal"
