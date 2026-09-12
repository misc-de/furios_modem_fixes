#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
#
# The two things that are supposed to survive a package update. Both fail
# silently when they are wrong, which is the worst way for them to fail: the
# running daemon still has the old code in memory, so everything looks healthy
# until the next reboot.
#
# This suite exists because the apt hook was written as
# DPkg::Post-Invoke-Success, which parses cleanly, appears in "apt-config
# dump", and is never executed - only APT::Update has a -Success variant.
# Reinstalling ofono2mm found every patch gone afterwards.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
. "$HERE/lib.sh"

HOOK="$ROOT/apt/99furios-modem-fixes"
UNIT="$ROOT/systemd/furios-modem-fixes.service"

# --- the apt hook -----------------------------------------------------------
# Comments are stripped first: this file explains in prose why the -Success
# variant is wrong, and a naive grep would find the warning and call it the
# bug.
directives=$(grep -v '^[[:space:]]*//' "$HOOK")

TESTS_RUN=$((TESTS_RUN + 1))
if printf '%s\n' "$directives" | grep -q '^DPkg::Post-Invoke'; then
    ok "hook uses a directive apt actually runs"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    fail "hook does not use DPkg::Post-Invoke"
fi

TESTS_RUN=$((TESTS_RUN + 1))
if printf '%s\n' "$directives" | grep -q 'Post-Invoke-Success'; then
    TESTS_FAILED=$((TESTS_FAILED + 1))
    fail "hook uses Post-Invoke-Success" "apt parses it and never runs it"
else
    ok "hook avoids the -Success variant, which apt ignores for DPkg"
fi

# apt must never fail because of us: the command has to swallow its own errors.
TESTS_RUN=$((TESTS_RUN + 1))
if printf '%s\n' "$directives" | grep -q '|| true'; then
    ok "hook cannot make an apt run fail"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    fail "hook command is not guarded with '|| true'"
fi

# Post-Invoke also runs after a failed dpkg run, so the guards matter.
TESTS_RUN=$((TESTS_RUN + 1))
if printf '%s\n' "$directives" | grep -q 'if \[ -x /usr/bin/modemctl \]' \
   && printf '%s\n' "$directives" | grep -q '\-d /usr/lib/ofono2mm'; then
    ok "hook checks that both sides are actually there"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    fail "hook runs unguarded"
fi

# The shell fragment inside the quotes has to parse. A typo there is only
# noticed at the worst possible moment, in the middle of somebody's upgrade.
TESTS_RUN=$((TESTS_RUN + 1))
frag=$(printf '%s\n' "$directives" | sed -n 's/^ *"\(.*\)";$/\1/p' | head -1)
if [ -n "$frag" ] && sh -n -c "$frag" 2>/dev/null; then
    ok "the shell fragment in the hook parses"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    fail "the shell fragment in the hook does not parse" "$frag"
fi

# apt itself has to accept the file. Only meaningful where apt exists.
if command -v apt-config >/dev/null 2>&1; then
    TESTS_RUN=$((TESTS_RUN + 1))
    tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
    cp "$HOOK" "$tmp/99test"
    if apt-config -c /dev/null -o "Dir::Etc::parts=$tmp" dump 2>/dev/null | grep -q 'DPkg::Post-Invoke::'; then
        ok "apt parses the hook and records it as a list entry"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        fail "apt does not pick the hook up"
    fi
fi

# --- the boot unit ----------------------------------------------------------
#
# The hook covers apt. The boot unit covers everything else - a dpkg -i by
# hand, an image update, a restore.
TESTS_RUN=$((TESTS_RUN + 1))
if grep -q '^Before=.*ModemManager.service' "$UNIT"; then
    ok "unit runs before ModemManager, not after"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    fail "unit is not ordered before ModemManager" \
         "patched files must be on disk before ofono2mm imports them"
fi

TESTS_RUN=$((TESTS_RUN + 1))
if grep -q '^ExecStart=.*--no-restart' "$UNIT"; then
    ok "unit does not restart the services it is ordered against"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    fail "unit restarts services it is ordered before" "that is how you build a deadlock"
fi

TESTS_RUN=$((TESTS_RUN + 1))
if grep -q '^WantedBy=' "$UNIT"; then
    ok "unit has an [Install] section, so enabling it does something"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    fail "unit has no WantedBy - 'systemctl enable' would be a no-op"
fi

# install.sh rewrites the unit's ExecStart for /usr/local. A sed that stops
# matching leaves a unit pointing at a binary the hand install never created,
# and it only shows at the next boot.
TESTS_RUN=$((TESTS_RUN + 1))
rewritten=$(sed "s|^ExecStart=/usr/bin/modemctl|ExecStart=/usr/local/bin/modemctl|" "$UNIT" \
    | sed -n 's/^ExecStart=//p')
case "$rewritten" in
    /usr/local/bin/modemctl\ *) ok "install.sh's rewrite still finds the ExecStart line" ;;
    *) TESTS_FAILED=$((TESTS_FAILED + 1))
       fail "install.sh's sed no longer matches the unit" "got [$rewritten]" ;;
esac

# Same for the hook: install.sh points it at /usr/local too.
TESTS_RUN=$((TESTS_RUN + 1))
if printf '%s\n' "$directives" | grep -q '/usr/bin/modemctl'; then
    ok "the hook names a path install.sh knows how to rewrite"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    fail "the hook does not name /usr/bin/modemctl" "install.sh's rewrite would miss it"
fi

summary
