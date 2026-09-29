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
# sim-check reports its fallback through logger; not into this machine's journal.
printf '#!/bin/sh\nexit 0\n' > "$STUB/logger"
chmod +x "$STUB"/*

mc() {
    env PATH="$STUB:$PATH" MODEMCTL_TARGET="$WORK/target" MODEMCTL_RADIO_CONF="$CONF" \
        MODEMCTL_SIM="$SIMF" MODEMCTL_SIM_LOCK="$WORK/lock" MODEMCTL_SHARE="$ROOT" \
        bash "$ROOT/modemctl" "$@"
}
key() { mc sim 2>/dev/null | sed -n "s/^$1: *//p"; }

cp "$SHIPPED" "$CONF"
check "two slots reported"            2      "$(key slots)"
check "slot 1 is the shipped choice"  1      "$(key active)"
check "nothing recorded reads as 1"   1      "$(key recorded)"
check "a card only in slot 1"         1      "$(key present)"
check "a card in both"                "1 2"  "$(FAKE_ICCID_1=894900 key present)"

DROPIN="$WORK/zz-furios-sim.conf"
mc sim 2 --no-restart >/dev/null 2>&1
check "switching to 2 succeeds"       2      "$(key active)"
check "oFono's own file stays as shipped" same \
      "$(cmp -s "$SHIPPED" "$CONF" && echo same || echo differs)"
check "ExpectSlots names slot 2"      1      "$(grep -c '^ExpectSlots = slot2$' "$DROPIN")"
check "slot 1 is ignored"             1      "$(grep -c '^IgnoreSlots = slot1$' "$DROPIN")"
check "the index moves with it"       1      "$(grep -c '^slot = 1$' "$DROPIN")"
check "the path is the one oFono's file gives" 1 "$(grep -c '^path = /ril_0$' "$DROPIN")"
check "and so is radioInterface"      1      "$(grep -c '^radioInterface = 1.4$' "$DROPIN")"
check "no half-written file is left behind" 0 \
      "$(find "$WORK" -maxdepth 1 -name '.furios-sim.*' | wc -l)"
check "the choice is recorded"        2      "$(cat "$SIMF" 2>/dev/null)"

mc sim 2 --no-restart >/dev/null 2>&1
check_status "a second switch to 2 is a no-op" 0 cmp -s "$CONF" "$CONF"

mc sim 1 --no-restart >/dev/null 2>&1
check "back to 1 removes our file"    no     "$([ -e "$DROPIN" ] && echo yes || echo no)"
check "and oFono's is still as shipped" same \
      "$(cmp -s "$SHIPPED" "$CONF" && echo same || echo differs)"
check "slot 1 removes the record"     no     "$([ -e "$SIMF" ] && echo yes || echo no)"

# An earlier version wrote the slot into oFono's own file. The next switch
# puts that file back as shipped and keeps the choice in ours.
{ sed -e 's/^ExpectSlots = slot1$/ExpectSlots = slot2\nIgnoreSlots = slot1/' \
      -e 's/^\[slot1\]$/[slot2]/' -e 's/^slot = 0$/slot = 1/' "$SHIPPED"; } > "$CONF"
check "an old-style edit reads as slot 2" 2 "$(key active)"
export FAKE_ICCID_1=894900
mc sim 2 --no-restart >/dev/null 2>&1
unset FAKE_ICCID_1
check "the next switch puts oFono's file back byte for byte" same \
      "$(cmp -s "$SHIPPED" "$CONF" && echo same || echo differs)"
check "and keeps slot 2 in ours" 2 "$(key active)"
mc sim 1 --no-restart >/dev/null 2>&1

check_status "slot 3 does not exist" 2 mc sim 3 --no-restart
check_status "neither does slot x"   2 mc sim x --no-restart
export FAKE_SLOTS=1
check_status "a one-slot phone has no slot 2" 2 mc sim 2 --no-restart
unset FAKE_SLOTS
check "refusals leave the file alone" same \
      "$(cmp -s "$SHIPPED" "$CONF" && echo same || echo differs)"

# A real switch (not --no-restart) to a slot with no card is refused: that is
# a phone without mobile network. Seen 28.9. with the tray pulled out.
check_status "a switch to an empty slot is refused" 1 mc sim 2
check "and writes nothing" no "$([ -e "$DROPIN" ] && echo yes || echo no)"
check "and records nothing" no "$([ -e "$SIMF" ] && echo yes || echo no)"

# The way back to slot 1 must not hang on Android's properties: a FuriLabs
# update that renames them would otherwise leave a phone on slot 2 for good.
mc sim 2 --no-restart >/dev/null 2>&1
cat > "$STUB/getprop" <<'NOPROPS'
#!/bin/sh
case "$1" in ro.telephony.sim.count) echo 2 ;; esac
NOPROPS
check_status "slot 1 needs no card detected" 0 env SIM_RESTART_WAIT=1 bash -c \
    "PATH='$STUB:$PATH' MODEMCTL_TARGET='$WORK/target' MODEMCTL_RADIO_CONF='$CONF' \
     MODEMCTL_SIM='$SIMF' MODEMCTL_SIM_LOCK='$WORK/lock' MODEMCTL_SHARE='$ROOT' \
     bash '$ROOT/modemctl' sim 1"
check "and is back on it" 1 "$(key active)"
cat > "$STUB/getprop" <<'STUB'
#!/bin/sh
case "$1" in
  ro.telephony.sim.count) echo "${FAKE_SLOTS:-2}" ;;
  gsm.sim.preiccid_0)     echo 8949360 ;;
  gsm.sim.preiccid_1)     echo "${FAKE_ICCID_1:-}" ;;
esac
STUB
chmod +x "$STUB/getprop"

# ofono2mm moved or went: the SIM switch writes only oFono's directory, so the
# way back does not depend on ofono2mm's files being writable.
chmod a-w "$WORK/target"
check_status "switching needs no writable ofono2mm" 0 mc sim 1 --no-restart
chmod u+w "$WORK/target"
# Only the file, card or not: that is how uninstall puts slot 1 back.
check_status "--no-restart writes the file without a card" 0 \
    mc sim 2 --no-restart
mc sim 1 --no-restart >/dev/null 2>&1

# Two at once restart oFono under each other.
( flock 9; sleep 3 ) 9>"$WORK/lock" &
sleep 0.5
export FAKE_ICCID_1=894900
check_status "a second switch while one runs is refused" 1 mc sim 2 --no-restart
unset FAKE_ICCID_1
wait
check "and changed nothing" same "$(cmp -s "$SHIPPED" "$CONF" && echo same || echo differs)"

# A package update puts the shipped file back. boot is what the apt hook and
# the boot unit run, and it has to bring the chosen slot back.
echo 2 > "$SIMF"
rm -f "$DROPIN"
mc boot --quiet --no-restart >/dev/null 2>&1
check "boot restores the recorded slot" 2 "$(key active)"
mc status 2>/dev/null | grep -q 'SIM slot 2 of 2'
check "status shows it" 0 $?

# Nothing recorded is nothing chosen: boot does not touch the file.
rm -f "$SIMF"
mc boot --quiet --no-restart >/dev/null 2>&1
check "without a record boot leaves slot 2 alone" 2 "$(key active)"
check_status "and status calls the difference out" 1 mc status

# After boot: a chosen slot that shows no card falls back to slot 1, and the
# choice is forgotten - otherwise every boot would go through it again.
rm -f "$DROPIN"; cp "$SHIPPED" "$CONF"
export FAKE_ICCID_1=894900
mc sim 2 --no-restart >/dev/null 2>&1
unset FAKE_ICCID_1
check "set up on slot 2" 2 "$(key active)"
env SIM_CHECK_WAIT=3 bash -c "$(declare -f mc); $(declare -p WORK CONF SIMF STUB ROOT); mc sim-check --no-restart" >/dev/null 2>&1
check "no card after the wait: back to slot 1" 1 "$(key active)"
check "and the choice is forgotten" no "$([ -e "$SIMF" ] && echo yes || echo no)"

export FAKE_ICCID_1=894900
mc sim 2 --no-restart >/dev/null 2>&1
unset FAKE_ICCID_1
cat > "$STUB/dbus-send" <<'PRESENT'
#!/bin/sh
case "$*" in
  *GetModems*)   echo '         object path "/ril_0"' ;;
  *SimManager*)  echo '         string "Present"'; echo '         variant             boolean true' ;;
  *) exit 1 ;;
esac
PRESENT
chmod +x "$STUB/dbus-send"
env SIM_CHECK_WAIT=3 bash -c "$(declare -f mc); $(declare -p WORK CONF SIMF STUB ROOT); mc sim-check --no-restart" >/dev/null 2>&1
check "with a card it stays on slot 2" 2 "$(key active)"
printf '#!/bin/sh\nexit 1\n' > "$STUB/dbus-send"
rm -f "$SIMF"
check_status "without a choice sim-check does nothing" 0 mc sim-check --no-restart
check "not even with slot 2 configured by hand" 2 "$(key active)"
mc sim 1 --no-restart >/dev/null 2>&1

# A file with two slot sections is not one this was written for.
printf '[Settings]\nExpectSlots = slot1,slot2\n[slot1]\npath = /ril_0\n[slot2]\npath = /ril_1\n' > "$CONF"
cp "$CONF" "$WORK/two"
check_status "two slot sections are refused" 1 mc sim 1 --no-restart
check "and left as they were" same "$(cmp -s "$WORK/two" "$CONF" && echo same || echo differs)"
check "the query says so" unknown "$(key active)"

# --- names ------------------------------------------------------------------
cp "$SHIPPED" "$CONF"; rm -f "$SIMF"
NAMES="$WORK/sim-names"
DB="$WORK/providers.xml"
cat > "$DB" <<'XML'
<serviceproviders>
<country code="de">
<provider><name>1&amp;1 Mobile</name><gsm><network-id mcc="262" mnc="23"/>
<apn value="x"><name>not this one</name></apn></gsm></provider>
<provider><name>Vodafone</name><gsm><network-id mcc="262" mnc="02"/></gsm></provider>
<provider><name>Some reseller</name><gsm><network-id mcc="262" mnc="02"/></gsm></provider>
</country>
</serviceproviders>
XML
cat > "$STUB/getprop" <<'STUB'
#!/bin/sh
case "$1" in
  ro.telephony.sim.count)          echo 2 ;;
  gsm.sim.preiccid_0)              echo 8949360 ;;
  gsm.sim.preiccid_1)              echo "${FAKE_ICCID_1:-8949024}" ;;
  vendor.gsm.ril.uicc.mccmnc)      echo 26202 ;;
  vendor.gsm.ril.uicc.mccmnc.1)    echo "${FAKE_MCCMNC_1:-26223}" ;;
esac
STUB
mcn() {
    env PATH="$STUB:$PATH" MODEMCTL_TARGET="$WORK/target" MODEMCTL_RADIO_CONF="$CONF" \
        MODEMCTL_SIM="$SIMF" MODEMCTL_SIM_NAMES="$NAMES" MODEMCTL_CBS_DB="$DB" \
        MODEMCTL_SIM_LOCK="$WORK/lock" \
        MODEMCTL_SHARE="$ROOT" bash "$ROOT/modemctl" sim 2>/dev/null | sed -n "s/^$1: *//p"
}
check "a code with one provider gives its name, entities decoded" "1&1 Mobile" "$(mcn name2)"
check "a code shared with a reseller gives no name at all" "" "$(mcn name1)"

printf '2\t8949024\tRemembered\n' > "$NAMES"
check "a remembered name wins over the database" Remembered "$(mcn name2)"
check "a swapped card does not inherit it" "1&1 Mobile" "$(FAKE_ICCID_1=8949111 mcn name2)"

# The active slot asks oFono, and what the SIM says is text from outside.
cat > "$STUB/dbus-send" <<'STUB'
#!/bin/sh
case "$*" in
  *GetModems*)    echo '         object path "/ril_0"' ;;
  *SimManager*)   echo '         string "ServiceProviderName"'
                  printf '         variant             string "Live\033]0;x\007 SIM"\n' ;;
  *)              exit 1 ;;
esac
STUB
chmod +x "$STUB/dbus-send"
check "the active slot shows what its SIM says, control bytes stripped" \
      "Live]0;x SIM" "$(mcn name1)"

summary
