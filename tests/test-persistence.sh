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

# --- the packaged maintainer scripts ---------------------------------------
#
# postinst and prerm run as root in the middle of a dpkg transaction. A syntax
# error there leaves the package half-configured, which is a worse state than
# anything this project is trying to fix.
BUILD="$ROOT/packaging/build-deb.sh"
for script in postinst prerm; do
    TESTS_RUN=$((TESTS_RUN + 1))
    frag=$(sed -n "/^cat > \"\$STAGE\/DEBIAN\/$script\"/,/^POST\$\|^PRE\$/p" "$BUILD" \
           | sed '1d;$d')
    if [ -n "$frag" ] && sh -n -c "$frag" 2>/dev/null; then
        ok "the packaged $script parses"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        fail "the packaged $script does not parse"
    fi
done

# prerm must revert while the patches are still on disk to revert with. After
# dpkg removes them there is nothing left that could put ofono2mm back.
TESTS_RUN=$((TESTS_RUN + 1))
if grep -q 'modemctl revert' "$BUILD"; then
    ok "prerm puts ofono2mm's own code back"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    fail "prerm does not revert" "removal would leave ofono2mm patched with nothing to undo it"
fi

# --- the signal tool --------------------------------------------------------
#
# It imports its conversions from the patched module rather than keeping a
# copy. When that module is not there it has to say so in a sentence, not in a
# traceback - this is what somebody sees when the fix has been wiped.
TESTS_RUN=$((TESTS_RUN + 1))
out=$(FURIOS_MODEM_OFONO2MM=/nonexistent python3 "$ROOT/tools/furios-modem-signal" 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "not installed" \
   && ! printf '%s' "$out" | grep -q "Traceback"; then
    ok "the signal tool explains a missing fix instead of crashing"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    fail "the signal tool crashed when the fix is absent" "$out"
fi

# --- what a ModemManager restart costs --------------------------------------
#
# Restarting ModemManager leaves NetworkManager holding a proxy for the modem
# object of the process that just died, and mobile data then sits in
# "connecting (prepare)" indefinitely. Measured: every restart, no recovery in
# 80 s, and neither disconnecting the device nor taking it unmanaged and back
# helps. Two consequences are pinned here.
TESTS_RUN=$((TESTS_RUN + 1))
if printf '%s\n' "$directives" | grep -q -- '--no-restart'; then
    ok "the apt hook does not restart the modem stack"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    fail "the apt hook restarts ModemManager" \
         "that kills mobile data until NetworkManager is restarted too"
fi

TESTS_RUN=$((TESTS_RUN + 1))
if grep -A4 'ok "ModemManager restarted' "$ROOT/modemctl" | grep -q settle_networkmanager; then
    ok "an interactive restart is followed by settling NetworkManager"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    fail "nothing settles NetworkManager after the restart"
fi

# The device lookup has to happen inside the wait loop. For a moment after the
# restart NetworkManager does not list the modem at all, and a single lookup
# followed by "no device, nothing to do" made this check silently do nothing
# the first time it ran for real - it returned before the device reappeared,
# and mobile data stayed down.
TESTS_RUN=$((TESTS_RUN + 1))
body=$(sed -n '/^settle_networkmanager()/,/^}/p' "$ROOT/modemctl")
loop_line=$(printf '%s\n' "$body" | grep -n 'for i in' | cut -d: -f1)
dev_line=$(printf '%s\n' "$body" | grep -n 'dev=\$(nmcli' | cut -d: -f1)
if [ -n "$loop_line" ] && [ -n "$dev_line" ] && [ "$dev_line" -gt "$loop_line" ]; then
    ok "settle looks for the device inside the wait loop"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    fail "settle looks for the device only once, before waiting" \
         "right after the restart it is not listed yet, so the check does nothing"
fi

# --- not restarting the stack during a call ---------------------------------
TESTS_RUN=$((TESTS_RUN + 1))
if grep -q 'call_in_progress' "$ROOT/modemctl"; then
    ok "apply checks for a call before restarting the modem stack"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    fail "apply would restart the modem stack during a call"
fi

# --- the package can update a patch it already shipped ----------------------
#
# dpkg runs prerm from the OLD package before unpacking the new one - the only
# moment when the patches on disk still describe the files on disk. Without
# that, a patch that grew a hunk cannot be installed at all onto a phone that
# already has this package: the file applies in neither direction and the new
# postinst gives up. It happened once, on 2026-09-13, and the file had to be
# copied into place by hand.
PRERM=$(sed -n "/DEBIAN\/prerm/,/^PRE$/p" "$ROOT/packaging/build-deb.sh")

TESTS_RUN=$((TESTS_RUN + 1))
if printf '%s' "$PRERM" | grep -q "^upgrade)"; then
    ok "prerm reverts on upgrade, not only on removal"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    fail "prerm ignores upgrade - a changed patch could not be installed"
fi

# Files only. A full revert here would put radioInterface back to 1.4, and an
# upgrade that stops between prerm and postinst would leave the phone on the
# value that brings back the Error-44 loop.
TESTS_RUN=$((TESTS_RUN + 1))
if printf '%s' "$PRERM" | grep -q -- "revert --patches-only"; then
    ok "and touches the files only, not the configuration"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    fail "prerm would undo radioInterface mid-upgrade"
fi

TESTS_RUN=$((TESTS_RUN + 1))
if grep -q -- "--patches-only" "$ROOT/modemctl"; then
    ok "and modemctl knows the option the prerm calls it with"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    fail "prerm calls an option modemctl does not have"
fi

# Both run "boot", not "apply". The difference is the whole profile switch: a
# phone recorded as "shipped" would otherwise have the repairs put back at the
# next boot, and again after every package operation, with nothing saying why -
# which is exactly the silent overriding this project exists to stop doing to
# people.
TESTS_RUN=$((TESTS_RUN + 1))
if grep -q '^ExecStart=.*modemctl boot' "$UNIT"; then
    ok "the boot unit honours the recorded profile"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    fail "the boot unit runs something other than 'modemctl boot'" \
         "a recorded 'shipped' would be overridden at every boot"
fi

TESTS_RUN=$((TESTS_RUN + 1))
if printf '%s\n' "$directives" | grep -q 'modemctl boot'; then
    ok "the apt hook honours it too"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    fail "the apt hook runs something other than 'modemctl boot'" \
         "a recorded 'shipped' would be undone by the next package operation"
fi

TESTS_RUN=$((TESTS_RUN + 1))
if grep -q 'modemctl boot' "$BUILD"; then
    ok "and so does the package's postinst"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    fail "postinst does not honour the recorded profile"
fi

# --- the polkit action ------------------------------------------------------
#
# What lets the switch in the app do what "sudo modemctl" does in a terminal.
# Every line of it is a decision about who may change the modem, so every line
# is checked - a policy that quietly widened would look exactly like one that
# did not.
POLKIT="$ROOT/polkit/de.misc-de.modemctl.policy"

TESTS_RUN=$((TESTS_RUN + 1))
if err=$(python3 -c 'import sys,xml.etree.ElementTree as E; E.parse(sys.argv[1])' "$POLKIT" 2>&1); then
    ok "the polkit action parses"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    fail "the polkit action does not parse" "$err"
fi

# active yes: there is no authentication agent on this phone, so auth_admin
# would be a switch that cannot ask and therefore cannot work.
# any/inactive no: a remote login or a switched-away seat has no business
# changing what the modem is doing - verified on the device, where phosh is
# authorised for this action and an ssh session is not.
for pair in "allow_any:no" "allow_inactive:no" "allow_active:yes"; do
    key=${pair%%:*}; want=${pair#*:}
    got=$(sed -n "s|.*<$key>\(.*\)</$key>.*|\1|p" "$POLKIT")
    check "$key is $want" "$want" "$got"
done

# pkexec only honours the action if the annotation names the program being
# run. A policy naming /usr/bin while the app starts /usr/local/bin does not
# fail loudly - pkexec just refuses, and the switch looks broken.
TESTS_RUN=$((TESTS_RUN + 1))
if grep -q 'org.freedesktop.policykit.exec.path">/usr/bin/modemctl<' "$POLKIT"; then
    ok "the action names the program it authorises"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    fail "the action does not name /usr/bin/modemctl"
fi

# ...which is why install.sh has to rewrite it for a hand installation, the
# same way it rewrites the unit and the hook.
TESTS_RUN=$((TESTS_RUN + 1))
rewritten=$(sed 's|>/usr/bin/modemctl<|>/usr/local/bin/modemctl<|' "$POLKIT" \
    | grep -c 'exec.path">/usr/local/bin/modemctl<')
if [ "$rewritten" = 1 ] && grep -q 'de.misc-de.modemctl.policy' "$ROOT/install.sh"; then
    ok "install.sh can point the action at its own copy"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    fail "install.sh does not rewrite the polkit action" "pkexec would refuse silently"
fi

# And it has to be taken away again, or an uninstalled package leaves an
# authorisation behind for a program that is no longer there.
TESTS_RUN=$((TESTS_RUN + 1))
if grep -q 'de.misc-de.modemctl.policy' "$ROOT/uninstall.sh"; then
    ok "uninstall.sh takes the action away again"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    fail "uninstall.sh leaves the polkit action behind"
fi

TESTS_RUN=$((TESTS_RUN + 1))
if grep -q 'polkit-1/actions' "$BUILD"; then
    ok "the package ships it where polkit reads"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    fail "the package does not ship the polkit action"
fi

# --- the bus policy ---------------------------------------------------------
#
# This grants a capability, so what it does NOT grant is as much the point as
# what it does. Checked against the daemon that needs it rather than against an
# idea of what it might need: cellbroadcastd's binary carries
# mm_modem_cell_broadcast_set_channels_sync and mm_modem_cell_broadcast_list
# and nothing for Delete, so Delete has no business being reachable.
#
# It is granted to a group rather than a user because the consumer is a user
# session service - it runs as whoever is using the phone. That is also why
# this file cannot be the thing that keeps anybody out: ofono2mm's own drop-in
# already hands the same group the whole Modem interface. Narrowing here keeps
# this file out of the problem without pretending to solve it.
POLICY="$ROOT/dbus/furios-modem-cellbroadcast.conf"
CB_IF=org.freedesktop.ModemManager1.Modem.CellBroadcast

for m in SetChannels List; do
    TESTS_RUN=$((TESTS_RUN + 1))
    if grep -q "send_member=\"$m\"" "$POLICY"; then
        ok "the policy allows $m, which cellbroadcastd calls"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        fail "the policy does not allow $m" "cellbroadcastd cannot set the alert channels"
    fi
done

TESTS_RUN=$((TESTS_RUN + 1))
if ! grep -q 'send_member="Delete"' "$POLICY"; then
    ok "and does not allow Delete, which it does not call"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    fail "the policy allows Delete" "nothing on this phone calls it"
fi

# An <allow> with no send_member is the whole interface, whatever methods a
# later ModemManager adds to it. That is how this file started.
TESTS_RUN=$((TESTS_RUN + 1))
if ! grep -A2 '<allow' "$POLICY" | grep -q "send_interface=\"$CB_IF\"/>"; then
    ok "no rule grants the interface as a whole"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    fail "a rule grants the whole interface" "every method a future MM adds comes with it"
fi

# modemctl finds the drop-in by the interface name. Narrowing the rules must
# not cost it the ability to see its own file.
TESTS_RUN=$((TESTS_RUN + 1))
if grep -q "$CB_IF" "$POLICY"; then
    ok "modemctl can still recognise the drop-in by interface name"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    fail "the interface name is gone from the policy" "cellbroadcast_state would report it missing"
fi

# --- the two watchers -------------------------------------------------------
#
# The boot unit above is a one-shot: it either applied the patches or it did
# not, and modemctl status says which. These two are different in kind - they
# run for the life of the session, and every way they can quietly stop is a
# phone that is fine until the day it is not. Both failures are invisible:
# a watcher that died leaves a phone that works until Wi-Fi goes away, and one
# that was started but never enabled works until the next reboot.
for w in furios-mobile-route furios-mobile-context; do
    unit="$ROOT/systemd/$w.service"

    TESTS_RUN=$((TESTS_RUN + 1))
    if grep -q '^Restart=always' "$unit"; then
        ok "$w restarts when it dies"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        fail "$w has no Restart=always" "a watcher that dies stays dead, and nothing says so"
    fi

    # Fast restarts help nothing here: what these supervise is a radio.
    sec=$(sed -n 's/^RestartSec=\([0-9]*\).*/\1/p' "$unit")
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ -n "$sec" ] && [ "$sec" -ge 5 ]; then
        ok "$w waits ${sec}s before restarting"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        fail "$w restarts too eagerly or not deliberately" "RestartSec=[$sec]"
    fi

    TESTS_RUN=$((TESTS_RUN + 1))
    if grep -q '^WantedBy=multi-user.target' "$unit"; then
        ok "$w is wanted at boot"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        fail "$w has no WantedBy" "enable would do nothing and it would be gone after a reboot"
    fi

    TESTS_RUN=$((TESTS_RUN + 1))
    if grep -q '^Type=simple' "$unit"; then
        ok "$w is a long-running service, and says so"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        fail "$w is not Type=simple"
    fi

    # Deliberately Wants=, never Requires=. With the modem stack switched off
    # there is nothing to watch, and the right answer is to stay quiet rather
    # than fail in a loop against a phone that is doing what it was told.
    TESTS_RUN=$((TESTS_RUN + 1))
    if ! grep -q '^Requires=' "$unit"; then
        ok "$w does not fail in a loop when the modem stack is off"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        fail "$w uses Requires=" "with the modem off this would fail over and over"
    fi

    # The unit has to name a program this repository actually ships, whatever
    # prefix it is rewritten to at install time.
    prog=$(sed -n 's|^ExecStart=.*/\([a-z-]*\)$|\1|p' "$unit")
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ -n "$prog" ] && [ -f "$ROOT/tools/$prog" ]; then
        ok "$w starts $prog, which is in tools/"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        fail "$w starts something this repository does not ship" "ExecStart names [$prog]"
    fi

    # Both installers have to enable AND start it - a watcher that waits for
    # the next reboot is a fix that is not in place yet - and both have to hand
    # a running one the new code, which "enable --now" does not do.
    for installer in "$ROOT/install.sh" "$ROOT/packaging/build-deb.sh"; do
        TESTS_RUN=$((TESTS_RUN + 1))
        if grep -q "enable --now $w" "$installer" && grep -q "try-restart.*$w" "$installer"; then
            ok "$(basename "$installer") enables, starts and refreshes $w"
        else
            TESTS_FAILED=$((TESTS_FAILED + 1))
            fail "$(basename "$installer") does not fully install $w" \
                 "needs both 'enable --now' and 'try-restart'"
        fi
    done
done

# --- what the package has to pull in ----------------------------------------
#
# Not the packages the patches belong to - those were never in doubt - but the
# programs the two services refuse to run without. Both check for theirs by
# hand and exit on their first line when one is missing, and modemctl asks
# nmcli for the cellular profile and restarts NetworkManager after a
# ModemManager restart. A package that installs cleanly and leaves a service
# dying immediately is worse than one that refuses to install: the failure is
# a phone with no fallback route, and nothing says so.
#
# The command-to-package mapping lives here rather than being derived, because
# there is nothing to derive it from - the tools name commands, dpkg names
# packages, and the only honest link between the two is written down once.
DEPENDS=$(sed -n 's/^Depends: //p' "$ROOT/packaging/build-deb.sh")

TESTS_RUN=$((TESTS_RUN + 1))
if [ -n "$DEPENDS" ]; then
    ok "the package declares dependencies"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    fail "no Depends line found in build-deb.sh" "every check below would pass vacuously"
fi

# command:package, for every command a tool exits over.
for pair in "dbus-send:dbus-bin" "dbus-monitor:dbus-bin" "ip:iproute2" \
            "mmcli:modemmanager" "nmcli:network-manager" "patch:patch"; do
    cmd=${pair%%:*}; pkg=${pair#*:}
    TESTS_RUN=$((TESTS_RUN + 1))
    case " $DEPENDS " in
        *"$pkg"*) ok "Depends covers $cmd ($pkg)" ;;
        *)
            TESTS_FAILED=$((TESTS_FAILED + 1))
            fail "Depends is missing $pkg, which provides $cmd" ;;
    esac
done

# Every command the tools refuse to start without has to be in that table, or
# the table stops covering the tools without anybody noticing.
for tool in "$ROOT/tools/furios-mobile-context" "$ROOT/tools/furios-mobile-route"; do
    for cmd in $(sed -n "s/^command -v \([a-z-]*\) .*exit 1.*/\1/p" "$tool"); do
        TESTS_RUN=$((TESTS_RUN + 1))
        case "dbus-send dbus-monitor ip mmcli nmcli patch" in
            *"$cmd"*) ok "$(basename "$tool") needs $cmd, and the table knows it" ;;
            *)
                TESTS_FAILED=$((TESTS_FAILED + 1))
                fail "$(basename "$tool") exits without $cmd, which no check above covers" ;;
        esac
    done
done

summary
