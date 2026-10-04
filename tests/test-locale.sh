#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
# Does every script that reads nmcli, mmcli or pactl read them in one language?
#
# nmcli translates its values even with -t ("verbunden" for "connected"), and
# so does pactl ("Servername:"). FuriOS ships NetworkManager without its German
# catalogue today, so nothing here broke yet - pactl's catalogue is there, and
# furios_audio's status said "Pulse server not reachable" on a German FLX1
# with the server running (4.10.2026). This makes the next script that parses
# one of them, and the next distribution that ships the catalogue, safe too.
#
# Nothing here needs root, a phone or a build tree: it reads the scripts.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
# shellcheck source=lib.sh
. "$HERE/lib.sh"
cd "$ROOT"

n=0
for f in modemctl tools/* tools/*/*; do
    [ -f "$f" ] || continue
    head -1 "$f" | grep -q 'sh' || continue
    grep -qE '^[^#]*\b(nmcli|mmcli|pactl)\b' "$f" || continue
    n=$((n + 1))
    check "$f reads its tools in C" yes \
        "$(grep -qx 'export LC_ALL=C.UTF-8' "$f" && echo yes || echo no)"
done
check "there was something to look at" yes "$([ "$n" -gt 0 ] && echo yes || echo no)"

summary
