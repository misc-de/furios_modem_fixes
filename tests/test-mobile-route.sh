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
    # scenario <bearers> <addr iface> <existing route iface>
    cat > "$STUBDIR/scenario" <<EOF
BEARERS="$1"
ADDR_IFACE="$2"
ROUTE_IFACE="$3"
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
case "$*" in
  "-4 -o addr show dev "*" scope global")
      [ -n "$ADDR_IFACE" ] && [ "$dev" = "$ADDR_IFACE" ] &&
          echo "2: $dev    inet 10.13.195.47/24 scope global $dev" ;;
  "-4 route show default dev "*)
      [ -n "$ROUTE_IFACE" ] && [ "$dev" = "$ROUTE_IFACE" ] &&
          echo "default dev $dev scope link metric 1050" ;;
  "-4 route show default metric "*)
      [ -n "$ROUTE_IFACE" ] &&
          echo "default dev $ROUTE_IFACE scope link metric 1050" ;;
esac
exit 0
STUB
chmod +x "$STUBDIR/ip"

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

summary
