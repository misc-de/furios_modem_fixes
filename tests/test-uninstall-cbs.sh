#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
# uninstall-cbs.sh puts back our channel lists, and only ours.
#
# The stand-in answers like oFono: a modem list, a Topics property, and a log
# of every SetProperty it was asked for.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
. "$HERE/lib.sh"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
cat > "$T/dbus-send" <<'STUB'
#!/bin/bash
[ -n "${STUB_DOWN:-}" ] && exit 1
case "$*" in
  *Manager.GetModems*)
    printf 'method return\n   array [\n      struct {\n         object path "/ril_0"\n' ;;
  *CellBroadcast.GetProperties*)
    printf '   array [\n      dict entry(\n         string "Topics"\n         variant             string "%s"\n      )\n' "$STUB_TOPICS" ;;
  *CellBroadcast.SetProperty*)
    echo "$*" >> "$STUB_LOG" ;;
esac
STUB
chmod +x "$T/dbus-send"
export DBUS_SEND="$T/dbus-send" STUB_LOG="$T/log"
SHIPPED='4370,4372,4378,4383,4385,4391,4396-4397'

run() { : > "$STUB_LOG"; STUB_TOPICS=$1 "$ROOT/uninstall-cbs.sh" >/dev/null 2>&1; }

for ours in '919,4370-4392,4396-4397' '919,4370-4371,4373-4392,4396-4397'; do
    run "$ours"
    check "our list $ours goes back to the shipped one" \
        "/ril_0 org.ofono.CellBroadcast.SetProperty string:Topics variant:string:$SHIPPED" \
        "$(sed 's/^--system --print-reply --dest=org.ofono //' "$STUB_LOG")"
done

for other in "$SHIPPED" '' '919,4370-4392' '4370'; do
    run "$other"
    check "a list that is not ours ('$other') is left alone" "" "$(cat "$STUB_LOG")"
done

STUB_DOWN=1
export STUB_DOWN
check_status "oFono not answering is no failure" 0 "$ROOT/uninstall-cbs.sh"
unset STUB_DOWN

check "uninstall.sh runs it" 1 "$(grep -c '^sudo ./uninstall-cbs.sh' "$ROOT/uninstall.sh")"

summary
