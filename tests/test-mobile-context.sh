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
    #
    # NetworkManager defaults to the healthy case - carrying the connection,
    # everything switched on - so every test written before that half existed
    # still describes what it meant to describe. nm_scenario changes it.
    cat > "$STUBDIR/scenario" <<EOF
POWERED="$1"
ATTACHED="$2"
STATUS="$3"
ACTIVE="$4"
HAS_ADDR="$5"
CALLS="$6"
NM_STATE="connected"
NM_WWAN="enabled"
NM_DEV_AUTO="yes"
NM_PROFILE="yes"
EOF
}

nm_scenario() {
    # nm_scenario <device state> <wwan radio> <device autoconnect> <profile autoconnect>
    # Appended, so it has to follow the scenario call it belongs to.
    cat >> "$STUBDIR/scenario" <<EOF
NM_STATE="$1"
NM_WWAN="$2"
NM_DEV_AUTO="$3"
NM_PROFILE="$4"
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

# Enough nmcli to answer the four questions the tool asks, in nmcli -t shape:
# colon-separated, one record a line, no headers.
cat > "$STUBDIR/nmcli" <<'STUB'
#!/bin/sh
. "$(dirname "$0")/scenario"
printf '%s\n' "$*" >> "$(dirname "$0")/nmcli.args"
case "$*" in
  *"device status"*)   echo "/ril_0:gsm:$NM_STATE" ;;
  *"radio"*)           echo "$NM_WWAN" ;;
  *"device show"*)     echo "GENERAL.AUTOCONNECT:$NM_DEV_AUTO" ;;
  *"connection show"*) [ "$NM_PROFILE" = yes ] && echo "gsm:yes" ;;
  *"device connect"*)  ;;
esac
exit 0
STUB
chmod +x "$STUBDIR/nmcli"

run_tool() {
    rm -f "$STUBDIR/dbus.args" "$STUBDIR/nmcli.args"
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
# The only nmcli call that changes anything. Everything else it asks is a
# question.
nm_acted() {
    local n
    n=$(grep -c 'device connect' "$STUBDIR/nmcli.args" 2>/dev/null)
    echo "${n:-0}"
}

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

printf '\n\033[1m== the half NetworkManager holds\033[0m\n'

# The car park, 14 September. The cell goes away, NetworkManager spends its
# four autoconnect attempts in three seconds and blocks the profile, the cell
# comes back, this daemon puts the data call back - and the phone still has an
# interface with an address, no DNS servers and a UI that says mobile data is
# off. Nothing in the old tool ever looked at that, because the context was up
# and up was the whole question.
scenario true true registered true yes no
nm_scenario disconnected enabled yes yes
run_tool
check "data call up, NetworkManager not using it - activates it" 1 "$(nm_acted)"
# And it fixes that through NetworkManager, not by poking oFono again. The
# context is already up; setting Active on it a second time achieves nothing
# and is how oFono ends up answering without acting.
check "and does not touch the context that is already up" 0 "$(acted)"

scenario true true registered true yes no
run_tool
check "NetworkManager already carrying it - left alone" 0 "$(nm_acted)"

# Same three switches as the oFono half, and the same rule: a switch somebody
# threw is not a fault to repair.
scenario true true registered true yes no
nm_scenario disconnected disabled yes yes
run_tool
check "WWAN switched off stays off" 0 "$(nm_acted)"

# NetworkManager clears the device's autoconnect flag when a connection is
# taken down by hand. That is "stay disconnected" in switch form, and it is
# the one an unasked-for activation would be rudest about.
scenario true true registered true yes no
nm_scenario disconnected enabled no yes
run_tool
check "a device told to stay disconnected is left that way" 0 "$(nm_acted)"

scenario true true registered true yes no
nm_scenario disconnected enabled yes no
run_tool
check "no profile allowed to autoconnect - nothing to activate" 0 "$(nm_acted)"

# Mid-activation. NetworkManager gets there on its own in a second or two, and
# a second activation on top of the first tears down what it just built.
scenario true true registered true yes no
nm_scenario connecting enabled yes yes
run_tool
check "an activation in flight is not interrupted" 0 "$(nm_acted)"

printf '\n\033[1m== which half first\033[0m\n'

# With the data call down, the radio is the thing to fix. Asking
# NetworkManager to activate over a cell that is not there spends the four
# autoconnect attempts that caused the outage in the first place.
scenario true true registered false no no
nm_scenario disconnected enabled yes yes
run_tool
check "context down - the radio is fixed first, not NetworkManager" 0 "$(nm_acted)"
check "and the context is what gets activated" 1 "$(activated)"

# The other order of the same rule. NetworkManager activating brings the
# context up itself, through ModemManager and ofono2mm; setting Active
# underneath it at that moment is two things racing on one property, which is
# exactly the state that made cycling Powered necessary.
scenario true true registered false no no
nm_scenario connecting enabled yes yes
run_tool
check "does not reach past a NetworkManager activation into oFono" 0 "$(acted)"

# Mobile data switched off outranks both halves. Nothing here may put it back.
scenario false true registered false no no
nm_scenario disconnected enabled yes yes
run_tool
check "mobile data off - neither half acts" 0 "$(( $(acted) + $(nm_acted) ))"

printf '\n\033[1m== without NetworkManager at all\033[0m\n'

# nmcli missing means NetworkManager is not installed, not running, or has no
# modem. The oFono half is older than the NetworkManager half and must keep
# working exactly as it did - a daemon that stops reviving data calls because
# it cannot find nmcli would have traded a fixed defect for a new one.
NONM="$WORK/nonm"; mkdir -p "$NONM"
cp "$STUBDIR/dbus-send" "$STUBDIR/ip" "$NONM/"
ln -sf "$STUBDIR/scenario" "$NONM/scenario"
for t in timeout grep sed tr head dirname cat; do
    ln -sf "$(command -v "$t")" "$NONM/$t"
done

# The stub writes its transcript next to itself, so here that is $NONM. Bring
# it back where count() looks - without this the counts are taken from a file
# that was never written, every one of them comes out 0, and a test that
# expects 0 passes while testing nothing.
run_tool_nonm() {
    rm -f "$STUBDIR/dbus.args" "$STUBDIR/nmcli.args" "$NONM/dbus.args"
    PATH="$NONM" /bin/bash "$TOOL" --once --quiet 2>/dev/null
    [ -f "$NONM/dbus.args" ] && cp "$NONM/dbus.args" "$STUBDIR/dbus.args"
    return 0
}

scenario true true registered false no no
run_tool_nonm
check "no nmcli - the oFono half still revives the data call" 1 "$(activated)"

scenario true true registered true yes no
run_tool_nonm
check "no nmcli - and a healthy context is still left alone" 0 "$(acted)"
# Proof the two checks above are reading anything at all: a pass that looked
# at the modem leaves a transcript behind. Without this, "no nmcli" failing
# open would look exactly like "no nmcli, nothing done wrong".
check "and it did look, rather than fall over" yes \
      "$([ -s "$STUBDIR/dbus.args" ] && echo yes || echo no)"

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

# The same for the NetworkManager half, and it matters more there, not less:
# every activation tears the data call down and rebuilds it. A list without an
# end would be a phone that drops its own connection on a timer.
nm_steps=$(sed -n 's/^NM_BACKOFF=${FURIOS_MOBILE_CONTEXT_NM_BACKOFF:-"\(.*\)"}.*/\1/p' "$TOOL")
rising=yes; prev=0
for w in $nm_steps; do
    [ "$w" -lt "$prev" ] && rising=no
    prev=$w
done
check "the NetworkManager backoff never shortens either" yes "$rising"
check "and it gives up too" yes \
      "$([ -n "$nm_steps" ] && [ "$(set -- $nm_steps; echo $#)" -le 5 ] && echo yes \
        || echo "no (${nm_steps:-unset})")"

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
