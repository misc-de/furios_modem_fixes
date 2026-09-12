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

sudo mkdir -p "$SHARE/patches" "$SHARE/patched-files"
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

sudo systemctl daemon-reload
# enable, not start: applying happens below, with output you can read.
sudo systemctl enable furios-modem-fixes.service >/dev/null

sudo "$BIN/modemctl" apply

echo
echo "Installed. Check any time with:  modemctl status"
echo "What the radio really gets:      modemctl signal"
