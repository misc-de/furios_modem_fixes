#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
#
# The watcher writes a default route. The interesting question is not "does it
# write one" but "does it write it to the right interface, and does it keep
# quiet otherwise": a default route pointed at the IMS bearer would send the
# whole phone's traffic down an APN that carries nothing but SIP, and a watcher
# that writes on every event it causes is an endless loop.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
. "$HERE/lib.sh"

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
STUBDIR="$WORK/bin"; mkdir -p "$STUBDIR"
TOOL="$ROOT/tools/furios-mobile-route"

# The scenario file is what each test rewrites; both stubs read it fresh on
# every call, so a test is three assignments and a run.
scenario() {
    # scenario <bearers> <addr iface> <our on-link route iface> [via gateway]
    #
    # The two route arguments are independent, because on this phone both
    # routes really do sit in the table at once: ours on-link, and
    # NetworkManager's "via" the interface's own address, same destination and
    # same metric. A gateway given here puts such a route on the addr iface.
    cat > "$STUBDIR/scenario" <<EOF
BEARERS="$1"
ADDR_IFACE="$2"
ROUTE_IFACE="$3"
VIA_GW="${4:-}"
EOF
}

# BEARERS is a list of type:connected:interface triples.
cat > "$STUBDIR/mmcli" <<'STUB'
#!/bin/sh
. "$(dirname "$0")/scenario"
case "$1" in
  -L) echo "    /org/freedesktop/ModemManager1/Modem/0 [QUALCOMM] MODEM"; exit 0 ;;
  -m) i=1
      for b in $BEARERS; do
          echo "modem.generic.bearers.value[$i] : /org/freedesktop/ModemManager1/Bearer/$i"
          i=$((i + 1))
      done
      exit 0 ;;
  -b) n=${2##*/}; i=1
      for b in $BEARERS; do
          if [ "$i" = "$n" ]; then
              echo "bearer.type             : $(echo "$b" | cut -d: -f1)"
              echo "bearer.status.connected : $(echo "$b" | cut -d: -f2)"
              echo "bearer.status.interface : $(echo "$b" | cut -d: -f3)"
          fi
          i=$((i + 1))
      done
      exit 0 ;;
esac
exit 0
STUB
chmod +x "$STUBDIR/mmcli"

cat > "$STUBDIR/ip" <<'STUB'
#!/bin/sh
. "$(dirname "$0")/scenario"
printf '%s\n' "$*" >> "$(dirname "$0")/ip.args"
dev=$(echo "$*" | awk '{print $6}')
# One on-link line for ours, one via line for NetworkManager's, exactly as
# "ip route show" renders them.
lines_for() {
    [ -n "$ROUTE_IFACE" ] && [ "$1" = "$ROUTE_IFACE" ] &&
        echo "default dev $1 scope link metric 1050"
    [ -n "$VIA_GW" ] && [ "$1" = "$ADDR_IFACE" ] &&
        echo "default via $VIA_GW dev $1 proto static metric 1050"
}
case "$*" in
  "-4 -o addr show dev "*" scope global")
      [ -n "$ADDR_IFACE" ] && [ "$dev" = "$ADDR_IFACE" ] &&
          echo "2: $dev    inet 10.10.95.220/24 scope global $dev" ;;
  "-4 -o addr show dev "*)
      [ -n "$ADDR_IFACE" ] && [ "$dev" = "$ADDR_IFACE" ] &&
          echo "2: $dev    inet 10.10.95.220/24 scope global $dev" ;;
  "-4 route show default dev "*)
      lines_for "$dev" ;;
  "-4 route show default metric "*)
      [ -n "$ROUTE_IFACE" ] && echo "default dev $ROUTE_IFACE scope link metric 1050"
      [ -n "$VIA_GW" ] && [ -n "$ADDR_IFACE" ] &&
          echo "default via $VIA_GW dev $ADDR_IFACE proto static metric 1050" ;;
  # The netlink stream the daemon blocks on. A burst first, then the stream is
  # held open for a while and closes - which is how the real one ends when
  # something takes netlink away.
  "monitor address route link")
      i=0
      while [ "$i" -lt "${MONITOR_BURST:-0}" ]; do
          echo "5: $ADDR_IFACE    inet 10.10.95.220/24 scope global $ADDR_IFACE"
          i=$((i + 1))
      done
      [ "${MONITOR_HOLD:-0}" != 0 ] && sleep "$MONITOR_HOLD" ;;
esac
exit 0
STUB
chmod +x "$STUBDIR/ip"

# Appended to the scenario, so the stub picks them up like everything else.
monitor_emits() {
    # monitor_emits <burst lines> <seconds to hold the stream open afterwards>
    printf 'MONITOR_BURST=%s\nMONITOR_HOLD=%s\n' "$1" "$2" >> "$STUBDIR/scenario"
}

run_tool() {
    rm -f "$STUBDIR/ip.args"
    PATH="$STUBDIR:$PATH" bash "$TOOL" --once --quiet 2>/dev/null
}
# What the tool actually wrote, as one line. Reads, which every run does, are
# not interesting here - only writes change the machine.
writes() {
    grep -E '^route (replace|del) ' "$STUBDIR/ip.args" 2>/dev/null | tr '\n' ';'
}

printf '\033[1m== picking the interface\033[0m\n'

scenario "default:yes:ccmni0" ccmni0 ""
run_tool
check "writes the route to the default bearer's interface" \
      "route replace default dev ccmni0 metric 1050;" "$(writes)"

# The one that matters. The IMS bearer is connected and has an address of its
# own, and it is listed first, so anything that just takes the first connected
# bearer gets this wrong.
scenario "ims:yes:ccmni1 default:yes:ccmni0" ccmni0 ""
run_tool
check "ignores the IMS bearer and takes the default one" \
      "route replace default dev ccmni0 metric 1050;" "$(writes)"

scenario "default:no:ccmni0" ccmni0 ""
run_tool
check "a bearer that is not connected gets no route" "" "$(writes)"

printf '\n\033[1m== knowing when to do nothing\033[0m\n'

# The window right after the bearer flips to connected: oFono has not put the
# address on the interface yet. A route written now would point at an
# interface that cannot source a packet.
scenario "default:yes:ccmni0" "" ""
run_tool
check "no address on the interface yet - no route" "" "$(writes)"

# This is the loop guard. Our own write comes back as a netlink event, which
# runs the check again; if a correct state still produced a write, it would
# never stop.
scenario "default:yes:ccmni0" ccmni0 ccmni0
run_tool
check "route already correct - nothing written" "" "$(writes)"

printf '\n\033[1m== NetworkManager own route is not ours\033[0m\n'

# When NetworkManager does process the bearer connect it installs
# "default via <the interface own address>" at this very metric. The kernel
# takes it and it drops every packet - measured at 100% loss while ip route
# looks healthy and NM reports connectivity "full". Treating that as "the route
# is there" would leave the phone with a black hole and a watcher reporting
# success.
# Only NetworkManager's route is there. Ours has to be written, and its black
# hole taken out of the table.
scenario "default:yes:ccmni0" ccmni0 "" 10.10.95.220
run_tool
check "a via-route alone is not mistaken for ours" \
      "route replace default dev ccmni0 metric 1050;route del default via 10.10.95.220 dev ccmni0 metric 1050;" \
      "$(writes)"

# Both in the table at once - which is the state the phone was actually found
# in. Ours is correct, so nothing is rewritten; the black hole still goes.
scenario "default:yes:ccmni0" ccmni0 ccmni0 10.10.95.220
run_tool
check "with ours already right, only the black hole is removed" \
      "route del default via 10.10.95.220 dev ccmni0 metric 1050;" "$(writes)"

# A next hop that is NOT one of the interface's own addresses is somebody
# else's correct configuration. Deleting that would be this tool inventing a
# defect to fix.
scenario "default:yes:ccmni0" ccmni0 ccmni0 10.99.99.1
run_tool
check "a real gateway is left alone" "" "$(writes)"

printf '\n\033[1m== cleaning up after itself\033[0m\n'

# Mobile data is gone but our route is still in the table. A default route to
# an interface with nothing behind it is worse than no default route: traffic
# leaves and never comes back, instead of failing immediately.
scenario "" "" ccmni0
run_tool
check "no mobile data - the stale route is removed" \
      "route del default dev ccmni0 metric 1050;" "$(writes)"

scenario "" "" ""
run_tool
check "no mobile data and no route - nothing to do" "" "$(writes)"

printf '\n\033[1m== the metric stays below Wi-Fi\033[0m\n'

# 1050 is not decoration. NetworkManager gives Wi-Fi 600, and a mobile route
# with a metric at or under that would take traffic off Wi-Fi permanently, on
# a metered connection, without anybody asking for it.
metric=$(sed -n 's/^METRIC=${FURIOS_MOBILE_ROUTE_METRIC:-\([0-9]*\)}.*/\1/p' "$TOOL")
check "default metric is higher than Wi-Fi's 600" yes \
      "$([ -n "$metric" ] && [ "$metric" -gt 600 ] && echo yes || echo "no ($metric)")"


printf '\n\033[1m== asking without acting\033[0m\n'

# modemctl status needs to know which interface mobile data is on. It asks
# here rather than keeping a second copy of the rule - and a status command
# that wrote a route as a side effect would be a trap.
scenario "ims:yes:ccmni1 default:yes:ccmni0" ccmni0 ""
rm -f "$STUBDIR/ip.args"
iface=$(PATH="$STUBDIR:$PATH" bash "$TOOL" --iface 2>/dev/null)
check "--iface names the default bearer's interface" ccmni0 "$iface"
check "--iface writes nothing" "" "$(writes)"

scenario "" "" ccmni0
rm -f "$STUBDIR/ip.args"
iface=$(PATH="$STUBDIR:$PATH" bash "$TOOL" --iface 2>/dev/null)
check "--iface says nothing when there is no mobile data" "" "$iface"
# The stale route is left alone: a question must not change the answer.
check "--iface does not clean up either" "" "$(writes)"

printf '\n\033[1m== the loop the service actually runs\033[0m\n'

# Everything above runs a single pass. This is the other half - the loop the
# unit starts and never stops - and the two ways it can go wrong while looking
# perfectly healthy from outside.

# ip monitor gone: netlink was taken away, or it never started. The tool has to
# leave, and leave non-zero, because Restart= is the only thing that will give
# the phone a working watcher back. The alternative is the shape that cost the
# context supervisor 74 dbus-send calls a second: a read that returns at once
# being treated as "something happened, look again".
scenario "default:yes:ccmni0" ccmni0 ccmni0
rm -f "$STUBDIR/ip.args"
PATH="$STUBDIR:$PATH" timeout 3 bash "$TOOL" --quiet >/dev/null 2>&1
loop_rc=$?
check "it leaves when ip monitor is gone instead of spinning" yes \
      "$([ "$loop_rc" -ne 124 ] && echo yes || echo "no - still running after 3 s")"
check "and leaves non-zero, so the service is restarted" yes \
      "$([ "$loop_rc" -ne 0 ] && [ "$loop_rc" -ne 124 ] && echo yes || echo "no - exit $loop_rc")"

# A bearer coming up is a burst of a dozen netlink events at once, and every
# one of them would otherwise mean three mmcli calls. The tool swallows
# whatever lands inside the settling window and looks once. Counted in writes
# because the stub has no memory: every look at a missing route writes one, so
# the number of writes IS the number of looks.
scenario "default:yes:ccmni0" ccmni0 ""
monitor_emits 20 2
rm -f "$STUBDIR/ip.args"
PATH="$STUBDIR:$PATH" timeout 5 bash "$TOOL" --quiet >/dev/null 2>&1
looks=$(grep -c '^route replace' "$STUBDIR/ip.args" 2>/dev/null)
# One for the pass before the loop, one for the whole burst.
check "a burst of twenty events is one look, not twenty" 2 "${looks:-0}"

summary
