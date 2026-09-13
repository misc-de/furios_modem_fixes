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

# The net under the whole thing. Everything else here is woken by a signal;
# this is the one look taken for no reason, and it is the only thing that would
# ever notice the state context_up() exists for - oFono reporting Active=true
# on a context whose data call has gone. Nothing changed, so nothing is
# announced, and no filter can catch what is never sent.
#
# Bounded from both sides. Too long and that state stands for as long as the
# bound; it was an hour, and survived only because the wake-up filter used to
# be wide enough to catch oFono's signal strength ten times a minute. Too short
# and the net becomes the polling this daemon was written not to be: 60 s is
# 0.145 % of a core for looks that are almost always wasted.
idle=$(sed -n 's/^IDLE=${FURIOS_MOBILE_CONTEXT_IDLE:-\([0-9]*\)}.*/\1/p' "$TOOL")
check "there is an idle safety net at all" yes \
      "$([ -n "$idle" ] && echo yes || echo no)"
check "the blind window is minutes, not an hour" yes \
      "$([ -n "$idle" ] && [ "$idle" -le 600 ] && echo yes || echo "no (${idle:-unset} s)")"
check "and the net is not a poll" yes \
      "$([ -n "$idle" ] && [ "$idle" -ge 120 ] && echo yes || echo "no (${idle:-unset} s)")"

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

printf '\n\033[1m== the loop that waits for oFono\033[0m\n'

# Everything above runs one pass with --once. This is the other half: the
# loop the service actually runs, and the two ways it can go wrong without
# anybody noticing - by spinning, and by waking for nothing.

# A dbus-monitor that is gone. The bus went away under it, or it never got to
# attach at all because the bus was not up yet when the unit started. "read"
# then returns end-of-stream AT ONCE rather than blocking, and a loop that
# cannot tell that from a timeout does not wait - it spins, at 74 dbus-send
# calls a second, for as long as the phone has battery. systemd reports the
# service healthy throughout, because the process is alive.
cat > "$STUBDIR/dbus-monitor" <<'STUB'
#!/bin/sh
exit 0
STUB
chmod +x "$STUBDIR/dbus-monitor"

scenario true true registered true yes no
rm -f "$STUBDIR/dbus.args"
PATH="$STUBDIR:$PATH" timeout 3 bash "$TOOL" --quiet >/dev/null 2>&1
loop_rc=$?
check "it stops when dbus-monitor is gone instead of spinning" yes \
      "$([ "$loop_rc" -ne 124 ] && echo yes || echo "no - still running after 3 s")"
# 124 is timeout's "I had to kill it". Anything else means the tool decided to
# leave; it has to leave non-zero, or Restart= has nothing to react to and the
# phone is left with a supervisor that is not supervising.
check "and exits non-zero so the service is restarted" yes \
      "$([ "$loop_rc" -ne 0 ] && [ "$loop_rc" -ne 124 ] && echo yes || echo "no - exit $loop_rc")"
# One startup pass is expected and costs a handful of calls. A spin makes
# hundreds; this fails long before it gets near the real number.
calls=$(count '')
check "and does not hammer the bus on its way out" yes \
      "$([ "$calls" -le 20 ] && echo yes || echo "no - $calls calls in 3 s")"

# Which signals wake it. The filter is not tidiness: NetworkRegistration
# announces Strength, ten or more times a minute on a weak cell, and waking
# for each one to re-read a number this daemon never looks at measured 0.53 %
# of a core on an idle phone - more than oFono and ModemManager together.
rules=$(sed -n '/^WAKE_ON=(/,/^)/p' "$TOOL" | grep "type='signal'")

# First that there is anything to look at. Without this the two checks below
# pass on a tool that has no WAKE_ON list at all - an empty set of rules
# contains no broad one and no Strength either, and "nothing found" would read
# as "nothing wrong", which is how a test quietly stops testing.
rule_count=$(printf '%s\n' "$rules" | grep -c "type='signal'")
check "the wake-up filter is where this test looks for it" yes \
      "$([ "${rule_count:-0}" -ge 5 ] && echo yes || echo "no - found $rule_count match rules")"

narrowed=yes
while IFS= read -r rule; do
    [ -n "$rule" ] || continue
    case "$rule" in
        *arg0=*|*member=\'Context*) ;;
        *) narrowed="no - $rule" ;;
    esac
done <<EOF
$rules
EOF
check "no rule wakes it for a whole interface" yes "$narrowed"
check "Strength is not a wake-up" yes \
      "$(printf '%s\n' "$rules" | grep -q Strength && echo no || echo yes)"

# What it must still hear. Each of these is a state this daemon exists to act
# on, and a filter that dropped one would be quiet in exactly the wrong way.
for want in "arg0='Status'" "arg0='Powered'" "arg0='Attached'" \
            "arg0='Active'" "arg0='Settings'" "member='ContextAdded'"; do
    check "still woken by $want" yes \
          "$(printf '%s\n' "$rules" | grep -qF "$want" && echo yes || echo no)"
done

summary
