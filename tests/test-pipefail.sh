#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
#
# modemctl runs with pipefail. That is the right default - "dbus-send | grep"
# used to say nothing about whether oFono answered - and it has one trap: a
# reader that stops early (grep -q, head) leaves its writer to die of SIGPIPE,
# and pipefail then calls a match a failure. The places where that decides
# something are pinned down here with replies too big for a pipe buffer, so
# the writer really is still writing when the reader leaves:
#   - a call in progress must stay a call (or apply restarts the stack under it)
#   - a SIM that is there must stay there
#   - a registered modem must stay registered (nr-boot waits on it)
#   - a channel list must stay a list, not "could not ask"
#   - a journal without matches is "nobody lost ModemManager", not unreadable
#   - an upstream bus policy is found with a directory missing beside it
# The functions are taken out of modemctl itself and run under its options.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
# shellcheck source=lib.sh
. "$HERE/lib.sh"

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
STUBDIR="$WORK/bin"; mkdir -p "$STUBDIR"

code=$(grep -v '^[[:space:]]*#' "$ROOT/modemctl")
check "modemctl runs with pipefail" 1 "$(printf '%s\n' "$code" | grep -cx 'set -o pipefail')"
# set -e would end the script on every question whose "no" is an answer -
# "cbs_record; case \$?", "x=\$(f)" with f failing by design. Kept out, and
# the reason is written next to pipefail.
check "and not with set -e" 0 "$(printf '%s\n' "$code" | grep -cE '^set -[a-z]*e|^set -o errexit')"
check "the reason is written down" yes \
      "$(grep -q 'Not set -e, on purpose' "$ROOT/modemctl" && echo yes || echo no)"
# No status may hang on a reader that stops early. A here-string, or a last
# reader that reads everything, is how it is done here.
check "no pipe ends in grep -q" "" \
      "$(printf '%s\n' "$code" | grep -nE '\|[[:space:]]*grep -[a-zA-Z]*q' | head -3)"

# Every function this needs, as modemctl defines it.
fn() {
    sed -n "/^$1() {/,/^}/p" "$ROOT/modemctl"
}
for f in modem_path call_in_progress ofono_sim_present nr_registered cbs_topics \
         cellbroadcast_state clients_that_lost_modemmanager; do
    body=$(fn "$f")
    check "modemctl defines $f" yes "$([ -n "$body" ] && echo yes || echo no)"
    eval "$body"
done
eval "$(grep -E '^(set -o pipefail|CB_DROPIN=|CB_IFACE=)' "$ROOT/modemctl")"

# Far more than a pipe holds (64 KiB): 20000 lines after the answer.
filler() { seq 1 20000 | sed 's/^/      string "filler"/'; }
cat > "$STUBDIR/dbus-send" <<STUB
#!/bin/bash
case "\$*" in
  *GetModems*)    echo '   object path "/ril_0"' ;;
  *GetCalls*)     echo '   object path "/ril_0/voicecall01"' ;;
  *SimManager*)   echo '         string "Present"'
                  echo '         variant             boolean true' ;;
  *NetworkRegistration*)
                  echo '         string "Status"'
                  echo '         variant             string "registered"' ;;
  *CellBroadcast*)
                  echo '         string "Topics"'
                  echo '         variant             string "919,4370-4392"'
                  echo '         string "Topics"'
                  echo '         variant             string "again"' ;;
esac
$(declare -f filler)
filler
STUB
chmod +x "$STUBDIR/dbus-send"
PATH="$STUBDIR:$PATH"

MODEM_PATH=
check "a call in progress is a call, however long the reply" 0 \
      "$(call_in_progress; echo $?)"
check "a SIM that is there is there" 0 "$(ofono_sim_present /ril_0; echo $?)"
check "a registered modem is registered" 0 "$(nr_registered; echo $?)"
check "the channel list is read" "919,4370-4392" "$(cbs_topics /ril_0)"
check "and reading it is a success" 0 "$(cbs_topics /ril_0 >/dev/null; echo $?)"

# And "no" still comes out as no.
cat > "$STUBDIR/dbus-send" <<'STUB'
#!/bin/bash
case "$*" in
  *GetModems*)    echo '   object path "/ril_0"' ;;
  *SimManager*)   echo '         string "Present"'
                  echo '         variant             boolean false' ;;
  *NetworkRegistration*)
                  echo '         string "Status"'
                  echo '         variant             string "searching"' ;;
  *CellBroadcast*) echo '         string "Other"' ;;
esac
exit 0
STUB
MODEM_PATH=
check "no call is no call" 1 "$(call_in_progress; echo $?)"
check "no SIM is no SIM" 1 "$(ofono_sim_present /ril_0; echo $?)"
check "searching is not registered" 1 "$(nr_registered; echo $?)"
check "a reply without Topics is still could-not-ask" 1 "$(cbs_topics /ril_0 >/dev/null; echo $?)"

# The journal: nothing matching is the healthy answer; unreadable is not.
printf '#!/bin/sh\necho "Oct 06 12:00:00 phone systemd[1]: Started something."\n' > "$STUBDIR/journalctl"
chmod +x "$STUBDIR/journalctl"
check "a journal with nobody in it is read, not unreadable" 0 \
      "$(clients_that_lost_modemmanager 0 >/dev/null; echo $?)"
printf '#!/bin/sh\nexit 1\n' > "$STUBDIR/journalctl"
check "a journal that cannot be read still says so" 2 \
      "$(clients_that_lost_modemmanager 0 >/dev/null; echo $?)"

# An upstream allow is found although the other directory grep is told to
# read does not exist here - grep -rl then exits 2, match or not.
DBUS_CONF_D="$WORK/system.d"; mkdir -p "$DBUS_CONF_D"
printf '<allow send_interface="%s"/>\n' "$CB_IFACE" > "$DBUS_CONF_D/zz-upstream.conf"
check "an upstream policy counts as covered" covered \
      "$(sed "s|/usr/share/dbus-1/system.d|$WORK/no-such-dir|" <<<"$(fn cellbroadcast_state)" \
         > "$WORK/cb.sh"; . "$WORK/cb.sh"; cellbroadcast_state)"
rm -f "$DBUS_CONF_D/zz-upstream.conf"
check "and none is missing" missing "$(cellbroadcast_state)"

summary
