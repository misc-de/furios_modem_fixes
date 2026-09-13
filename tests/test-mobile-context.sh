#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
#
# A daemon that activates mobile data is only as good as the times it refuses
# to. Switching the radio on behind somebody's back, or retrying into a cell
# that is not there, would both be worse than the outage this repairs - so
# most of what follows checks that it does nothing.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
. "$HERE/lib.sh"

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
STUBDIR="$WORK/bin"; mkdir -p "$STUBDIR"
TOOL="$ROOT/tools/furios-mobile-context"

scenario() {
    # scenario <powered> <attached> <status> <active> <has address> <calls>
    cat > "$STUBDIR/scenario" <<EOF
POWERED="$1"
ATTACHED="$2"
STATUS="$3"
ACTIVE="$4"
HAS_ADDR="$5"
CALLS="$6"
EOF
}

# Speaks just enough dbus-send to answer what the tool asks, in the exact
# shape dbus-send prints: name and value on consecutive lines.
cat > "$STUBDIR/dbus-send" <<'STUB'
#!/bin/sh
. "$(dirname "$0")/scenario"
printf '%s\n' "$*" >> "$(dirname "$0")/dbus.args"
case "$*" in
  *Manager.GetModems*)
      echo '   array [ object path "/ril_0"' ;;
  *ConnectionManager.GetContexts*)
      echo '   array [ object path "/ril_0/context1" object path "/ril_0/context2"' ;;
  *context1*ConnectionContext.GetProperties*)
      echo '         string "Type"'
      echo '         variant             string "internet"'
      echo '         string "Active"'
      echo "         variant             boolean $ACTIVE"
      echo '         string "Interface"'
      echo '         variant             string "ccmni0"' ;;
  *context2*ConnectionContext.GetProperties*)
      echo '         string "Type"'
      echo '         variant             string "mms"'
      echo '         string "Active"'
      echo '         variant             boolean false' ;;
  *ConnectionManager.GetProperties*)
      echo '         string "Powered"'
      echo "         variant             boolean $POWERED"
      echo '         string "Attached"'
      echo "         variant             boolean $ATTACHED" ;;
  *NetworkRegistration.GetProperties*)
      echo '         string "Status"'
      echo "         variant             string \"$STATUS\"" ;;
  *VoiceCallManager.GetCalls*)
      [ "$CALLS" = yes ] && echo '   object path "/ril_0/voicecall01"' ;;
esac
exit 0
STUB
chmod +x "$STUBDIR/dbus-send"

cat > "$STUBDIR/ip" <<'STUB'
#!/bin/sh
. "$(dirname "$0")/scenario"
[ "$HAS_ADDR" = yes ] && echo "2: ccmni0    inet 10.13.195.47/24 scope global ccmni0"
exit 0
STUB
chmod +x "$STUBDIR/ip"

run_tool() {
    rm -f "$STUBDIR/dbus.args"
    PATH="$STUBDIR:$PATH" bash "$TOOL" --once --quiet 2>/dev/null
}
# grep -c prints 0 AND exits 1 when nothing matches, so "|| echo 0" appends a
# second zero and every count comes out as "0\n0". Count in one place instead.
count() {
    local n
    n=$(grep -c "$@" "$STUBDIR/dbus.args" 2>/dev/null)
    echo "${n:-0}"
}
# Only the calls that change the modem count. Everything else is looking.
acted()     { count 'SetProperty'; }
activated() { count 'string:Active variant:boolean:true'; }

printf '\033[1m== when it must keep its hands off\033[0m\n'

# The one that matters most. Powered false is somebody having switched mobile
# data off - in the settings, or to save data, or because they are abroad.
scenario false true registered false no no
run_tool
check "mobile data switched off stays off" 0 "$(acted)"

# No packet service. There is nothing to activate against, and asking anyway
# keeps a radio busy that is trying to find a cell.
scenario true false registered false no no
run_tool
check "not attached - nothing to activate against" 0 "$(acted)"

scenario true true unregistered false no no
run_tool
check "unregistered - no network to ask" 0 "$(acted)"

# "unregistered" contains "registered". A loose match here would have the tool
# retrying hardest exactly when there is no network at all.
scenario true true searching false no no
run_tool
check "searching is not registered either" 0 "$(acted)"

scenario true true registered false no yes
run_tool
check "never during a call" 0 "$(acted)"

printf '\n\033[1m== when there is nothing wrong\033[0m\n'

scenario true true registered true yes no
run_tool
check "context up with an address - left alone" 0 "$(acted)"

# The state that started all of this: oFono says Active=true, the data call is
# gone, and the interface has no address. Believing Active would mean sitting
# out exactly the outage this exists for.
scenario true true registered true no no
run_tool
check "Active=true without an address is still down" 1 "$(activated)"

printf '\n\033[1m== when it should act\033[0m\n'

scenario true true registered false no no
run_tool
check "context down and everything else ready - activates" 1 "$(activated)"

scenario true true roaming false no no
run_tool
check "roaming counts as registered" 1 "$(activated)"

# The MMS context is context2 here. Activating that is defect 2 all over
# again - about 1,700 failed activations an hour.
scenario true true registered false no no
run_tool
check "acts on the internet context, not the MMS one" 0 \
      "$(count 'context2.*SetProperty')"

printf '\n\033[1m== restraint over time\033[0m\n'

# Each attempt waits longer than the last, and the list of waits is also the
# limit: when it runs out the tool stops asking until the radio says something
# changed. At -132 dBm no amount of asking helps.
steps=$(sed -n 's/^BACKOFF=${FURIOS_MOBILE_CONTEXT_BACKOFF:-"\(.*\)"}.*/\1/p' "$TOOL")
rising=yes; prev=0
for w in $steps; do
    [ "$w" -lt "$prev" ] && rising=no
    prev=$w
done
check "the backoff never shortens" yes "$rising"
check "there is a limited number of attempts" yes \
      "$([ "$(set -- $steps; echo $#)" -ge 3 ] && echo yes || echo no)"

# The escalation exists because oFono can answer SetProperty cleanly and do
# nothing. It must not be the first move: cycling Powered drops data outright.
esc=$(sed -n 's/^ESCALATE_AFTER=${FURIOS_MOBILE_CONTEXT_ESCALATE:-\([0-9]*\)}.*/\1/p' "$TOOL")
check "asking politely comes before cycling the radio" yes \
      "$([ -n "$esc" ] && [ "$esc" -ge 2 ] && echo yes || echo "no ($esc)")"

# A single pass must never cycle Powered on the first failure, whatever else
# is true - that is what --once does, and the boot unit runs it.
scenario true true registered false no no
run_tool
check "one pass alone never cycles Powered" 0 \
      "$(count 'string:Powered')"

printf '\n\033[1m== asking properly\033[0m\n'

# dbus-send without --print-reply exits 0 on errors it never showed anybody.
# A supervisor built on that reports success while achieving nothing.
scenario true true registered false no no
run_tool
check "every call asks for a reply" 0 \
      "$(count -v -e '--print-reply')"

summary
