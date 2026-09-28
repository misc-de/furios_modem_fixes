#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
#
# The SIM switch rewrites a config file that belongs to another package. What
# matters is that it writes exactly the three lines it means to, that going
# back leaves the file as it shipped, and that it keeps its hands off a file it
# does not understand.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
. "$HERE/lib.sh"

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
STUB="$WORK/bin"; mkdir -p "$STUB" "$WORK/target"
# As FuriOS ships it on the FLX1 (radioInterface 1.4 - see modemctl).
SHIPPED="$WORK/shipped.conf"
cat > "$SHIPPED" <<'CONF'
[Settings]
ExpectSlots = slot1
useDataProfiles=true
mmsDataProfileId=1001
emptyPinQuery=false
3GLTEHandover = false
MaxNonDataMode = none
signalStrengthRange=-113,-51

[slot1]
path = /ril_0
slot = 0
radioInterface = 1.4
CONF
CONF="$WORK/radio-interface-binder.conf"
SIMF="$WORK/sim"

# Two slots, a card in slot 1 only - the phone this was written on.
cat > "$STUB/getprop" <<'STUB'
#!/bin/sh
case "$1" in
  ro.telephony.sim.count) echo "${FAKE_SLOTS:-2}" ;;
  gsm.sim.preiccid_0)     echo 8949360 ;;
  gsm.sim.preiccid_1)     echo "${FAKE_ICCID_1:-}" ;;
esac
STUB
# Nothing here may restart anything on the machine running the tests.
printf '#!/bin/sh\nexit 0\n' > "$STUB/systemctl"
printf '#!/bin/sh\nexit 1\n' > "$STUB/dbus-send"
chmod +x "$STUB"/*

mc() {
    env PATH="$STUB:$PATH" MODEMCTL_TARGET="$WORK/target" MODEMCTL_RADIO_CONF="$CONF" \
        MODEMCTL_SIM="$SIMF" MODEMCTL_SHARE="$ROOT" bash "$ROOT/modemctl" "$@"
}
key() { mc sim 2>/dev/null | sed -n "s/^$1: *//p"; }

cp "$SHIPPED" "$CONF"
check "two slots reported"            2      "$(key slots)"
check "slot 1 is the shipped choice"  1      "$(key active)"
check "nothing recorded reads as 1"   1      "$(key recorded)"
check "a card only in slot 1"         1      "$(key present)"
check "a card in both"                "1 2"  "$(FAKE_ICCID_1=894900 key present)"

mc sim 2 --no-restart >/dev/null 2>&1
check "switching to 2 succeeds"       2      "$(key active)"
check "ExpectSlots names slot 2"      1      "$(grep -c '^ExpectSlots = slot2$' "$CONF")"
check "slot 1 is ignored"             1      "$(grep -c '^IgnoreSlots = slot1$' "$CONF")"
check "the index moves with it"       1      "$(grep -c '^slot = 1$' "$CONF")"
check "the path stays /ril_0"         1      "$(grep -c '^path = /ril_0$' "$CONF")"
check "radioInterface is untouched"   1      "$(grep -c '^radioInterface = 1.4$' "$CONF")"
check "no other line changed"         4      "$(diff "$SHIPPED" "$CONF" | grep -c '^>' )"
check "the choice is recorded"        2      "$(cat "$SIMF" 2>/dev/null)"

mc sim 2 --no-restart >/dev/null 2>&1
check_status "a second switch to 2 is a no-op" 0 cmp -s "$CONF" "$CONF"

mc sim 1 --no-restart >/dev/null 2>&1
check "back to 1 is the shipped file byte for byte" same \
      "$(cmp -s "$SHIPPED" "$CONF" && echo same || echo differs)"
check "slot 1 removes the record"     no     "$([ -e "$SIMF" ] && echo yes || echo no)"

check_status "slot 3 does not exist" 2 mc sim 3 --no-restart
check_status "neither does slot x"   2 mc sim x --no-restart
export FAKE_SLOTS=1
check_status "a one-slot phone has no slot 2" 2 mc sim 2 --no-restart
unset FAKE_SLOTS
check "refusals leave the file alone" same \
      "$(cmp -s "$SHIPPED" "$CONF" && echo same || echo differs)"

# A package update puts the shipped file back. boot is what the apt hook and
# the boot unit run, and it has to bring the chosen slot back.
echo 2 > "$SIMF"
mc boot --quiet --no-restart >/dev/null 2>&1
check "boot restores the recorded slot" 2 "$(key active)"
mc status 2>/dev/null | grep -q 'SIM slot 2 of 2'
check "status shows it" 0 $?

# Nothing recorded is nothing chosen: boot does not touch the file.
rm -f "$SIMF"
mc boot --quiet --no-restart >/dev/null 2>&1
check "without a record boot leaves slot 2 alone" 2 "$(key active)"
check_status "and status calls the difference out" 1 mc status

# A file with two slot sections is not one this was written for.
printf '[Settings]\nExpectSlots = slot1,slot2\n[slot1]\npath = /ril_0\n[slot2]\npath = /ril_1\n' > "$CONF"
cp "$CONF" "$WORK/two"
check_status "two slot sections are refused" 1 mc sim 1 --no-restart
check "and left as they were" same "$(cmp -s "$WORK/two" "$CONF" && echo same || echo differs)"
check "the query says so" unknown "$(key active)"

summary
