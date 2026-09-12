#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
#
# modemctl decides what to touch on someone else's package. The interesting
# question is not "does it patch" but "does it know when NOT to": a file the
# patch no longer fits is the case where doing something is worse than doing
# nothing.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
. "$HERE/lib.sh"

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
STUBDIR="$WORK/bin"; mkdir -p "$STUBDIR"
FILES="utils mm_bearer mm_modem mm_modem_simple mm_modem_signal"

# A healthy stack, so the runtime part of "status" does not drown out the part
# this test is about.
cat > "$STUBDIR/mmcli" <<'STUB'
#!/bin/sh
echo "           |         signal quality: 26% (recent)"
STUB
cat > "$STUBDIR/dbus-send" <<'STUB'
#!/bin/sh
echo '      dict entry('
echo '         string "AccessPointName"'
echo '         variant             string "web.vodafone.de"'
STUB
cat > "$STUBDIR/nmcli" <<'STUB'
#!/bin/sh
case "$*" in
  *"-f NAME,TYPE"*) echo "Willkommen:gsm"; echo "Home WLAN:802-11-wireless" ;;
  *)                echo "ipv6.method:disabled" ;;
esac
STUB
chmod +x "$STUBDIR"/*
PATH="$STUBDIR:$PATH"; export PATH

RADIO="$WORK/radio-interface-binder.conf"
TREE="$WORK/usr/lib/ofono2mm/ofono2mm"

reset_tree() {
    # $1: shipped | patched
    rm -rf "$WORK/usr"; mkdir -p "$TREE"
    for f in $FILES; do cp "$ROOT/$1-files/$f.py" "$TREE/$f.py"; done
    printf 'radioInterface = %s\n' "$2" > "$RADIO"
}

run_status() {
    MODEMCTL_TARGET="$TREE" MODEMCTL_RADIO_CONF="$RADIO" \
        bash "$ROOT/modemctl" status 2>&1
}

# --- nothing applied --------------------------------------------------------
reset_tree original 1.4
out=$(run_status)
check_status "shipped tree: status fails" 1 \
    env MODEMCTL_TARGET="$TREE" MODEMCTL_RADIO_CONF="$RADIO" bash "$ROOT/modemctl" status
TESTS_RUN=$((TESTS_RUN + 1))
if echo "$out" | grep -q "mm_modem_signal.py NOT patched"; then
    ok "shipped tree: names the unpatched file"
else
    TESTS_FAILED=$((TESTS_FAILED + 1)); fail "shipped tree: did not name the unpatched file" "$out"
fi
TESTS_RUN=$((TESTS_RUN + 1))
if echo "$out" | grep -q "radioInterface not 1.6"; then
    ok "shipped tree: notices radioInterface 1.4"
else
    TESTS_FAILED=$((TESTS_FAILED + 1)); fail "shipped tree: missed radioInterface"
fi

# --- everything applied -----------------------------------------------------
reset_tree patched 1.6
check_status "patched tree: status passes" 0 \
    env MODEMCTL_TARGET="$TREE" MODEMCTL_RADIO_CONF="$RADIO" bash "$ROOT/modemctl" status
out=$(run_status)
TESTS_RUN=$((TESTS_RUN + 1))
if echo "$out" | grep -q "everything in place"; then
    ok "patched tree: says so"
else
    TESTS_FAILED=$((TESTS_FAILED + 1)); fail "patched tree: unexpected verdict" "$out"
fi

# --- upstream moved ---------------------------------------------------------
#
# The dangerous case. A file that is neither ours nor the one the patch was
# written against must be reported, never patched: patch(1) would find the
# context somewhere else and land the change in the wrong place.
reset_tree original 1.6
python3 - "$TREE/mm_modem_signal.py" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
# Upstream rewrites the block the patch anchors on.
s = s.replace("if 'org.ofono.NetworkMonitor' in self.ofono_interfaces:",
              "if 'org.ofono.NetworkMonitor' in self.ofono_interfaces and self.enabled:")
s = s.replace("tech = cellinfo.get('Technology', Variant('s', '')).value",
              "tech = str(cellinfo.get('Technology', Variant('s', '')).value or '')")
open(p, 'w').write(s)
PY
out=$(run_status)
TESTS_RUN=$((TESTS_RUN + 1))
if echo "$out" | grep -q "mm_modem_signal.py patch no longer fits"; then
    ok "moved upstream: reported, not patched over"
else
    TESTS_FAILED=$((TESTS_FAILED + 1)); fail "moved upstream: not detected" "$out"
fi

# --- ofono2mm not installed at all ------------------------------------------
rm -rf "$WORK/usr"; mkdir -p "$TREE"
out=$(run_status)
TESTS_RUN=$((TESTS_RUN + 1))
if echo "$out" | grep -q "mm_modem.py missing"; then
    ok "no ofono2mm: says the file is missing"
else
    TESTS_FAILED=$((TESTS_FAILED + 1)); fail "no ofono2mm: unexpected output" "$out"
fi

# --- refusals ---------------------------------------------------------------
check_status "an unknown command is an error" 2 bash "$ROOT/modemctl" wat
if [ "$(id -u)" -ne 0 ]; then
    check_status "apply without root refuses" 1 \
        env MODEMCTL_TARGET="$TREE" MODEMCTL_RADIO_CONF="$RADIO" bash "$ROOT/modemctl" apply
fi

# --- quiet ------------------------------------------------------------------
#
# The boot unit and the apt hook run with --quiet. If that still chatters, a
# healthy boot prints a wall of text every time.
reset_tree patched 1.6
out=$(MODEMCTL_TARGET="$TREE" MODEMCTL_RADIO_CONF="$RADIO" \
      bash "$ROOT/modemctl" status --quiet 2>/dev/null)
check "quiet status on a healthy tree says nothing" "" "$out"

summary
