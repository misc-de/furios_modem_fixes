#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
#
# The tests themselves must never reach the machine they run on. modemctl
# touches /etc, /usr/lib and /var/lib unless every MODEMCTL_* override says
# otherwise, and a sandboxed "modemctl set fixed" once ran without
# MODEMCTL_SYSTEMD_CONF_D - straight at the real /etc/systemd/system. Since
# then the overrides are set in one place (tests/lib.sh, modemctl_sandbox),
# and $MODEMCTL refuses to start modemctl while any one of them is missing.
# What is held here is the rule, not any one call:
#   - no test runs modemctl except through $MODEMCTL,
#   - modemctl_sandbox has a path for every override modemctl knows, and
#     every one of them lies under the sandbox (or the work tree, read-only),
#   - $MODEMCTL with one override missing does not start modemctl, and takes
#     the test that called it down,
#   - "unsandboxed" is the one way around that, and it names its reason.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
# shellcheck source=lib.sh
. "$HERE/lib.sh"

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

# --- nobody goes around the door --------------------------------------------
# Executing modemctl from the work tree - "bash $ROOT/modemctl", "$ROOT/modemctl"
# at the start of a command, or through env/exec. Reading it (sed, grep, awk,
# cp, eval of a function taken out of it) is fine and common.
direct=$(grep -nE "(bash|exec|env[^|]*)[[:space:]]+[\"']?\\\$\{?ROOT\}?/modemctl|^[[:space:]]*[\"']?\\\$\{?ROOT\}?/modemctl[\"']?[[:space:]]" \
             "$HERE"/*.sh | grep -v "^$HERE/lib.sh:" | grep -vE '^[^:]*:[0-9]+:[[:space:]]*#')
check "no test runs modemctl except through \$MODEMCTL" "" "${direct//$HERE\//}"
n=$(grep -l '"\$MODEMCTL"\|'"'"'\$MODEMCTL'"'" "$HERE"/test-*.sh | wc -l)
check "and the tests that run it do so through \$MODEMCTL" yes "$([ "$n" -ge 4 ] && echo yes || echo "no ($n)")"
for t in $(grep -l '\$MODEMCTL' "$HERE"/test-*.sh); do
    [ "$t" = "$HERE/test-harness.sh" ] && continue
    check "$(basename "$t") builds its sandbox first" yes \
          "$(grep -q '^modemctl_sandbox ' "$t" && echo yes || echo no)"
done

# --- every override, every time ---------------------------------------------
SB="$WORK/sandbox"
modemctl_sandbox "$SB"
known=$(modemctl_overrides)
check "modemctl's guard names overrides at all" yes "$([ -n "$known" ] && echo yes || echo no)"
for v in $known; do
    val=${!v:-}
    case "$v:$val" in
        MODEMCTL_SHELL_SYSTEM_UNIT:*.service) where=ok ;;
        MODEMCTL_SHARE:"$ROOT"|MODEMCTL_PATCHES:"$ROOT/patches") where=ok ;;
        *:"$SB"/*) where=ok ;;
        *) where="outside: ${val:-unset}" ;;
    esac
    check "$v is set into the sandbox" ok "$where"
done

# modemctl itself, through the door, never sees anything else. Its own guard
# list is what the wrapper checks, so a status run is enough to show the
# wrapper lets a complete environment through.
out=$("$MODEMCTL" help 2>&1); rc=$?
check "a complete sandbox starts modemctl" 0 "$rc"

# One missing override: modemctl must not start, and the test must end. Run
# as a test of its own, since ending is the point.
cat > "$WORK/forgets.sh" <<T
#!/bin/bash
. "$HERE/lib.sh"
modemctl_sandbox "$WORK/sb2"
unset MODEMCTL_SYSTEMD_CONF_D
x=\$("\$MODEMCTL" set fixed --no-restart)
echo "still running" >> "$WORK/after"
T
bash "$WORK/forgets.sh" >/dev/null 2>"$WORK/forgets.err"; rc=$?
check "an override missing ends the test" 99 "$rc"
check "and goes no further" no \
      "$([ -e "$WORK/after" ] && echo yes || echo no)"
check "and the sandbox it was given saw nothing written" "" \
      "$(find "$WORK/sb2" -type f ! -path '*/bin/*' ! -name diversions)"
check "and it says which one" yes \
      "$(grep -q 'without MODEMCTL_SYSTEMD_CONF_D' "$WORK/forgets.err" && echo yes || echo no)"

# An empty one is as good as none: modemctl reads ${X:-default}.
cat > "$WORK/empty.sh" <<T
#!/bin/bash
. "$HERE/lib.sh"
modemctl_sandbox "$WORK/sb3"
MODEMCTL_PROFILE= "\$MODEMCTL" help >/dev/null 2>&1
echo "still running" >> "$WORK/after-empty"
T
bash "$WORK/empty.sh" >/dev/null 2>&1; rc=$?
check "an empty override ends the test too" 99 "$rc"

# The way around it, for the one case that needs it, says why.
out=$(unsandboxed "the harness checks its own escape hatch" "$MODEMCTL" help 2>&1); rc=$?
check "unsandboxed runs modemctl with no override at all" 0 "$rc"
check "and only with a reason" yes \
      "$(sed -n '/^unsandboxed()/,/^}/p' "$HERE/lib.sh" | grep -q 'MODEMCTL_TEST_UNSANDBOXED="\$reason"' \
         && echo yes || echo no)"
uses=$(grep -hE '^[^#]*(^|[[:space:]($])unsandboxed[[:space:]]' "$HERE"/test-*.sh \
       | grep -vcE '(^|[[:space:]($])unsandboxed "[^"]{12,}"')
check "every use of it in the tests names a reason" 0 "$uses"

summary
