#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
#
# The 5G switch. What matters: only the NR bit moves, the radio registers
# afresh exactly when the network would otherwise never hear about it - and
# never during a call - and nothing touches the modem when 5G is not on.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
. "$HERE/lib.sh"

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
STUB="$WORK/bin"; mkdir -p "$STUB"
NRF="$WORK/nr"
LOG="$WORK/log"          # what reached the "modem"
BITS="$WORK/bits"        # the RIL's allowed-types bitmap
PREF="$WORK/pref"        # oFono's TechnologyPreference

# The HAL: remembers the bitmap. FAKE_REFUSE=1 answers but keeps the old
# value; FAKE_TAKE_AWAY=1 answers the next get without NR, the way oFono's
# own request does when it comes after ours - once the radio is back on.
cat > "$STUB/nrprobe" <<STUB
#!/bin/bash
echo "\$NRPROBE_INSTANCE" >> "$WORK/instances"
b=\$(cat "$BITS")
case "\$1" in
  get)
    [ -n "\${FAKE_TAKE_AWAY:-}" ] && [ "\$(tail -1 "$LOG")" = "online true" ] \
        && b=\$(( b & ~0x100000 )) && echo \$b > "$BITS"
    echo "  <- response 194 serial 0x4e520003 error 0 (NONE) value \$b (\$(printf '%#x' \$b))" ;;
  setallowed)
    echo "setallowed \$2" >> "$LOG"
    [ -n "\${FAKE_REFUSE:-}" ] || echo \$(( \$2 )) > "$BITS" ;;
esac
exit 0
STUB
# oFono: one modem, registered, a call when FAKE_CALL is set; every Online
# change is logged.
cat > "$STUB/dbus-send" <<STUB
#!/bin/bash
args="\$*"
case "\$args" in
  *GetModems*)       echo '   object path "/ril_0"' ;;
  *GetCalls*)        [ -n "\${FAKE_CALL:-}" ] && echo '   object path "/ril_0/voicecall01"'; echo 'array [' ;;
  *NetworkRegistration.GetProperties*)
                     printf '         string "Status"\n         variant             string "%s"\n' "\${FAKE_REG:-registered}" ;;
  *SetProperty*Online*) echo "online \${args##*boolean:}" >> "$LOG" ;;
  *RadioSettings.GetProperties*)
                     printf '         string "TechnologyPreference"\n         variant             string "%s"\n' "\$(cat "$PREF")" ;;
  *SetProperty*TechnologyPreference*)
                     p=\${args##*string:}; echo "pref \$p" >> "$LOG"; echo "\$p" > "$PREF" ;;
esac
exit 0
STUB
printf '#!/bin/sh\nexit 0\n' > "$STUB/logger"
# oFono on slot 1, as shipped; a SIM switch writes our drop-in next to it.
CONF="$WORK/radio-interface-binder.conf"; DROPIN="$WORK/zz-furios-sim.conf"
printf '[slot1]\npath = /ril_0\nslot = 0\n' > "$CONF"
chmod +x "$STUB"/*

mc() {
    env PATH="$STUB:$PATH" MODEMCTL_SHARE="$ROOT" MODEMCTL_NR="$NRF" \
        MODEMCTL_RADIO_CONF="$CONF" MODEMCTL_SIM_DROPIN="$DROPIN" \
        MODEMCTL_NRPROBE="$STUB/nrprobe" NR_OFF_SECONDS=0 NR_SETTLE=0 \
        NR_RECHECK=0 NR_REG_WAIT=1 NR_BOOT_WAIT=3 \
        bash "$ROOT/modemctl" "$@"
}
key() { mc nr 2>/dev/null | sed -n "s/^$1: *//p"; }
fresh() { echo $((0x9ce0e)) > "$BITS"; echo lte > "$PREF"; : > "$LOG"; }
bits() { printf '%#x' "$(cat "$BITS")"; }

fresh
check "nothing recorded reads as off"      off  "$(key recorded)"
check "the bitmap FuriOS boots with has no NR" no "$(key allowed)"

mc nr on --no-restart >/dev/null 2>&1
check "--no-restart records the choice"    on   "$(cat "$NRF")"
check "and leaves the modem alone"         ""   "$(cat "$LOG")"

fresh
check_status "nr on"                       0    mc nr on
check "only the NR bit is added"           0x19ce0e "$(bits)"
check "then the radio goes off and on again, in that order" \
      "setallowed 0x19ce0e|pref nr|online false|online true" "$(paste -sd'|' "$LOG")"

: > "$LOG"
check_status "nr on a second time"         0    mc nr on
check "sends nothing and registers nothing" "" "$(cat "$LOG")"

echo $((0x19ce0f)) > "$BITS"
check_status "nr off"                      0    mc nr off
check "takes only the NR bit away"         0x9ce0f "$(bits)"
check "and forgets the choice"             no   "$([ -e "$NRF" ] && echo yes || echo no)"
check "oFono goes back to lte"             lte  "$(cat "$PREF")"
echo umts > "$PREF"; echo $((0x19ce0e)) > "$BITS"; mc nr off >/dev/null 2>&1
check "a preference of umts is someone's choice" umts "$(cat "$PREF")"

fresh
FAKE_CALL=1 mc nr on >/dev/null 2>&1
check "during a call: allowed"             0x19ce0e "$(bits)"
check "but the radio stays on"             "setallowed 0x19ce0e|pref nr" "$(paste -sd'|' "$LOG")"

fresh
check_status "a HAL that does not take it is an error" 1 env FAKE_REFUSE=1 bash -c "$(declare -f mc); $(declare -p ROOT STUB NRF CONF DROPIN); mc nr on"
check "and nothing is re-registered for it" "setallowed 0x19ce0e" "$(paste -sd'|' "$LOG")"

check_status "nr maybe"                    2    mc nr maybe

# The side door follows the slot oFono uses.
rm -f "$WORK/instances"; mc nr >/dev/null 2>&1
check "slot 1 is asked through em1"        em1  "$(sort -u "$WORK/instances")"
printf '[slot2]\npath = /ril_0\nslot = 1\n' > "$DROPIN"
rm -f "$WORK/instances"; fresh; mc nr on >/dev/null 2>&1
check "slot 2 through em2, never anything else" em2 "$(sort -u "$WORK/instances")"
rm -f "$DROPIN"
printf '[weird]\n' > "$CONF"; rm -f "$WORK/instances"; fresh
check_status "a config without a slot is refused" 1 mc nr on
check "and nobody is asked"                no   "$([ -e "$WORK/instances" ] && echo yes || echo no)"
printf '[slot1]\npath = /ril_0\nslot = 0\n' > "$CONF"

# Boot
rm -f "$NRF"; fresh
check_status "nr-boot without 5G switched on"  0 mc nr-boot
check "does not touch the modem"           ""   "$(cat "$LOG")"

echo on > "$NRF"; fresh
check_status "nr-boot"                     0    mc nr-boot
check "allows NR, tells oFono, registers afresh" "setallowed 0x19ce0e|pref nr|online false|online true" "$(paste -sd'|' "$LOG")"

# Allowed before the modem registered (a FuriOS that gets NR right by
# itself): nothing to send, and no reason to drop the connection.
echo $((0x19ce0e)) > "$BITS"; echo nr > "$PREF"; : > "$LOG"
check_status "nr-boot with NR already allowed" 0 mc nr-boot
check "leaves the radio alone"             ""   "$(cat "$LOG")"

# 30.9.: NR allowed, oFono still on lte - oFono fights it every two seconds.
# The preference follows; the radio stays on.
echo $((0x19ce0e)) > "$BITS"; echo lte > "$PREF"; : > "$LOG"
check_status "nr-boot with oFono still on lte" 0 mc nr-boot
check "only oFono is told"                 "pref nr" "$(paste -sd'|' "$LOG")"

fresh
check_status "an unregistered modem is waited for, then left alone" 0 \
      env FAKE_REG=searching bash -c "$(declare -f mc); $(declare -p ROOT STUB NRF CONF DROPIN); mc nr-boot"
check "without touching it"                ""   "$(cat "$LOG")"

fresh
check_status "5G that never stays allowed fails after three rounds" 1 \
      env FAKE_TAKE_AWAY=1 bash -c "$(declare -f mc); $(declare -p ROOT STUB NRF CONF DROPIN); mc nr-boot"
check "three times allowed"                3    "$(grep -c setallowed "$LOG")"

summary
