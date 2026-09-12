#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
# Installs modemctl, the patches, the boot unit and the apt hook, then applies
# everything. Safe to re-run.
set -e
cd "$(dirname "$0")"

sudo install -Dm755 modemctl                  /usr/bin/modemctl
sudo install -Dm755 tools/furios-modem-signal /usr/bin/furios-modem-signal

sudo mkdir -p /usr/share/furios-modem/patches /usr/share/furios-modem/patched-files
sudo install -m644 patches/*.patch        /usr/share/furios-modem/patches/
# The ready-made files are the rescue path for the day a patch stops fitting.
sudo install -m644 patched-files/*.py     /usr/share/furios-modem/patched-files/
sudo install -m644 patched-files/radio-interface-binder.conf \
                                          /usr/share/furios-modem/patched-files/
# modemctl looks for tools/ next to its share directory.
sudo install -Dm755 tools/furios-modem-signal /usr/share/furios-modem/tools/furios-modem-signal

sudo install -Dm644 systemd/furios-modem-fixes.service \
    /etc/systemd/system/furios-modem-fixes.service
sudo install -Dm644 apt/99furios-modem-fixes \
    /etc/apt/apt.conf.d/99furios-modem-fixes

sudo systemctl daemon-reload
# enable, not start: applying happens below, with output you can read.
sudo systemctl enable furios-modem-fixes.service >/dev/null

sudo modemctl apply

echo
echo "Installed. Check any time with:  modemctl status"
echo "What the radio really gets:      modemctl signal"
