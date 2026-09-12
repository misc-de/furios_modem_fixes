#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
# Removes everything this project installed and puts the shipped code back.
set -e
cd "$(dirname "$0")"

# Revert first - afterwards modemctl and the patches are gone and the ofono2mm
# files would stay patched with nothing left to undo them.
sudo /usr/local/bin/modemctl revert || true

sudo systemctl disable --now furios-modem-fixes.service 2>/dev/null || true
sudo rm -f /etc/systemd/system/furios-modem-fixes.service \
           /etc/apt/apt.conf.d/99furios-modem-fixes \
           /usr/local/bin/modemctl \
           /usr/local/bin/furios-modem-signal
sudo rm -rf /usr/local/share/furios-modem
sudo systemctl daemon-reload

echo "Shipped state restored. Takes effect after: sudo systemctl restart ModemManager"
echo
echo "Note: the data connection flaps again on the shipped radioInterface 1.4."
echo "That is the state the phone came in, not a working one."
