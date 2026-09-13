#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
#
# modemctl decides what to touch on someone else's package. The interesting
# question is not "does it patch" but "does it know when NOT to": a file the
# patch no longer fits is the case where doing something is worse than doing
# nothing.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
. "$HERE/lib.sh"

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
STUBDIR="$WORK/bin"; mkdir -p "$STUBDIR"
FILES="utils mm_bearer mm_modem mm_modem_simple mm_modem_signal main"

# A healthy stack, so the runtime part of "status" does not drown out the part
# this test is about.
cat > "$STUBDIR/mmcli" <<'STUB'
#!/bin/sh
echo "           |         signal quality: 26% (recent)"
STUB
cat > "$STUBDIR/dbus-send" <<'STUB'
#!/bin/sh
case "$*" in
  *RadioSettings*)
    echo '         string "TechnologyPreference"'
    echo '         variant             string "nr"' ;;
  *)
    echo '      dict entry('
    echo '         string "AccessPointName"'
    echo '         variant             string "web.vodafone.de"' ;;
esac
STUB
cat > "$STUBDIR/nmcli" <<'STUB'
#!/bin/sh
case "$*" in
  *"-f NAME,TYPE"*) echo "Willkommen:gsm"; echo "Home WLAN:802-11-wireless" ;;
  *)                echo "ipv6.method:disabled" ;;
esac
STUB
chmod +x "$STUBDIR"/*
PATH="$STUBDIR:$PATH"; export PATH

RADIO="$WORK/radio-interface-binder.conf"
TREE="$WORK/usr/lib/ofono2mm/ofono2mm"

# main.py lives one level above the module directory, the way the package
# lays it out; modemctl knows that and so must the tree we hand it.
tree_path() {
    case "$1" in
        main) echo "$TREE/../main.py" ;;
        *)    echo "$TREE/$1.py" ;;
    esac
}

reset_tree() {
    # $1: shipped | patched
    rm -rf "$WORK/usr"; mkdir -p "$TREE"
    for f in $FILES; do cp "$ROOT/$1-files/$f.py" "$(tree_path "$f")"; done
    printf 'radioInterface = %s\n' "$2" > "$RADIO"
}

run_status() {
    MODEMCTL_TARGET="$TREE" MODEMCTL_RADIO_CONF="$RADIO" \
        bash "$ROOT/modemctl" status 2>&1
}

# --- nothing applied --------------------------------------------------------
reset_tree original 1.4
out=$(run_status)
check_status "shipped tree: status fails" 1 \
    env MODEMCTL_TARGET="$TREE" MODEMCTL_RADIO_CONF="$RADIO" bash "$ROOT/modemctl" status
TESTS_RUN=$((TESTS_RUN + 1))
if echo "$out" | grep -q "mm_modem_signal.py NOT patched"; then
    ok "shipped tree: names the unpatched file"
else
    TESTS_FAILED=$((TESTS_FAILED + 1)); fail "shipped tree: did not name the unpatched file" "$out"
fi
TESTS_RUN=$((TESTS_RUN + 1))
if echo "$out" | grep -q "radioInterface not 1.6"; then
    ok "shipped tree: notices radioInterface 1.4"
else
    TESTS_FAILED=$((TESTS_FAILED + 1)); fail "shipped tree: missed radioInterface"
fi

# --- everything applied -----------------------------------------------------
reset_tree patched 1.6
check_status "patched tree: status passes" 0 \
    env MODEMCTL_TARGET="$TREE" MODEMCTL_RADIO_CONF="$RADIO" bash "$ROOT/modemctl" status
out=$(run_status)
TESTS_RUN=$((TESTS_RUN + 1))
if echo "$out" | grep -q "everything in place"; then
    ok "patched tree: says so"
else
    TESTS_FAILED=$((TESTS_FAILED + 1)); fail "patched tree: unexpected verdict" "$out"
fi

# A preference other than nr means nobody is asking for 5G. It is not a
# failure - it is a legitimate choice - so it warns rather than failing, but it
# must be visible: this was silently reset once and cost a day of wondering
# where 5G had gone.
cat > "$STUBDIR/dbus-send" <<'STUB'
#!/bin/sh
case "$*" in
  *RadioSettings*)
    echo '         string "TechnologyPreference"'
    echo '         variant             string "lte"' ;;
  *)
    echo '         string "AccessPointName"'
    echo '         variant             string "web.vodafone.de"' ;;
esac
STUB
chmod +x "$STUBDIR/dbus-send"
reset_tree patched 1.6
out=$(run_status)
TESTS_RUN=$((TESTS_RUN + 1))
if echo "$out" | grep -q "5G is not being asked for"; then
    ok "an LTE-only preference is reported"
else
    TESTS_FAILED=$((TESTS_FAILED + 1)); fail "a preference of lte passed unmentioned" "$out"
fi
check_status "but it is not treated as a failure" 0 \
    env MODEMCTL_TARGET="$TREE" MODEMCTL_RADIO_CONF="$RADIO" bash "$ROOT/modemctl" status
# back to the healthy stub for the rest
cat > "$STUBDIR/dbus-send" <<'STUB'
#!/bin/sh
case "$*" in
  *RadioSettings*)
    echo '         string "TechnologyPreference"'
    echo '         variant             string "nr"' ;;
  *)
    echo '         string "AccessPointName"'
    echo '         variant             string "web.vodafone.de"' ;;
esac
STUB
chmod +x "$STUBDIR/dbus-send"

# --- upstream moved ---------------------------------------------------------
#
# The dangerous case. A file that is neither ours nor the one the patch was
# written against must be reported, never patched: patch(1) would find the
# context somewhere else and land the change in the wrong place.
reset_tree original 1.6
python3 - "$TREE/mm_modem_signal.py" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
# Upstream rewrites the block the patch anchors on.
s = s.replace("if 'org.ofono.NetworkMonitor' in self.ofono_interfaces:",
              "if 'org.ofono.NetworkMonitor' in self.ofono_interfaces and self.enabled:")
s = s.replace("tech = cellinfo.get('Technology', Variant('s', '')).value",
              "tech = str(cellinfo.get('Technology', Variant('s', '')).value or '')")
open(p, 'w').write(s)
PY
out=$(run_status)
TESTS_RUN=$((TESTS_RUN + 1))
if echo "$out" | grep -q "mm_modem_signal.py patch no longer fits"; then
    ok "moved upstream: reported, not patched over"
else
    TESTS_FAILED=$((TESTS_FAILED + 1)); fail "moved upstream: not detected" "$out"
fi

# --- ofono2mm not installed at all ------------------------------------------
rm -rf "$WORK/usr"; mkdir -p "$TREE"
out=$(run_status)
TESTS_RUN=$((TESTS_RUN + 1))
if echo "$out" | grep -q "mm_modem.py missing"; then
    ok "no ofono2mm: says the file is missing"
else
    TESTS_FAILED=$((TESTS_FAILED + 1)); fail "no ofono2mm: unexpected output" "$out"
fi

# --- apply and revert, for real ---------------------------------------------
#
# Possible at all because apply asks "can I write these files", not "am I
# root": the test owns a tree, so the command that does all the work can be
# exercised without handing a test suite root.
reset_tree original 1.4
out=$(MODEMCTL_TARGET="$TREE" MODEMCTL_RADIO_CONF="$RADIO" \
      bash "$ROOT/modemctl" apply --no-restart 2>&1)
rc=$?
check "apply on a shipped tree succeeds" 0 "$rc"
for f in $FILES; do
    TESTS_RUN=$((TESTS_RUN + 1))
    if diff -q "$(tree_path "$f")" "$ROOT/patched-files/$f.py" >/dev/null; then
        ok "apply produced the shipped patched $f.py"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1)); fail "apply left $f.py wrong"
    fi
done
check "apply sets radioInterface" "radioInterface = 1.6" "$(cat "$RADIO")"
TESTS_RUN=$((TESTS_RUN + 1))
if ls "$TREE"/mm_modem.py.bak.* >/dev/null 2>&1; then
    ok "apply keeps a backup"
else
    TESTS_FAILED=$((TESTS_FAILED + 1)); fail "apply kept no backup"
fi

# Running it again must be a no-op, because a boot unit and an apt hook do
# exactly that on every boot and every package operation.
before=$(md5sum "$TREE"/*.py | md5sum)
out=$(MODEMCTL_TARGET="$TREE" MODEMCTL_RADIO_CONF="$RADIO" \
      bash "$ROOT/modemctl" apply --no-restart 2>&1)
check "a second apply changes nothing" "$before" "$(md5sum "$TREE"/*.py | md5sum)"
TESTS_RUN=$((TESTS_RUN + 1))
if echo "$out" | grep -q "Nothing to do"; then
    ok "a second apply says there was nothing to do"
else
    TESTS_FAILED=$((TESTS_FAILED + 1)); fail "second apply was not a no-op" "$out"
fi

# Backups must not grow without bound - they did, to 28 files in one day.
for i in 1 2 3 4 5; do
    touch "$TREE/mm_modem.py.bak.2026010${i}-000000"
done
MODEMCTL_TARGET="$TREE" MODEMCTL_RADIO_CONF="$RADIO" \
    bash "$ROOT/modemctl" revert >/dev/null 2>&1
MODEMCTL_TARGET="$TREE" MODEMCTL_RADIO_CONF="$RADIO" \
    bash "$ROOT/modemctl" apply --no-restart >/dev/null 2>&1
kept=$(ls -1 "$TREE"/mm_modem.py.bak.* 2>/dev/null | wc -l)
check "old backups are pruned" 3 "$kept"

# revert has to put back exactly what the package shipped, or the uninstall
# path leaves ofono2mm in a state neither side knows about.
reset_tree patched 1.6
MODEMCTL_TARGET="$TREE" MODEMCTL_RADIO_CONF="$RADIO" \
    bash "$ROOT/modemctl" revert >/dev/null 2>&1
for f in $FILES; do
    TESTS_RUN=$((TESTS_RUN + 1))
    if diff -q "$(tree_path "$f")" "$ROOT/original-files/$f.py" >/dev/null; then
        ok "revert restored the shipped $f.py"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1)); fail "revert left $f.py wrong"
    fi
done
check "revert puts radioInterface back" "radioInterface = 1.4" "$(cat "$RADIO")"

# --- refusals ---------------------------------------------------------------
check_status "an unknown command is an error" 2 bash "$ROOT/modemctl" wat
if [ "$(id -u)" -ne 0 ]; then
    # Against the real system tree, which this test user cannot write.
    check_status "apply on an unwritable tree refuses" 1 \
        bash "$ROOT/modemctl" apply
    TESTS_RUN=$((TESTS_RUN + 1))
    if bash "$ROOT/modemctl" apply 2>&1 | grep -q "try: sudo"; then
        ok "and says how to do it properly"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1)); fail "no hint about sudo"
    fi
fi

# SECURITY: as root the overrides must be refused outright. Anyone who can run
# "sudo modemctl" would otherwise be able to point them anywhere and have root
# apply an arbitrary diff to an arbitrary file.
TESTS_RUN=$((TESTS_RUN + 1))
guard=$(grep -c 'refusing to honour' "$ROOT/modemctl")
if [ "$guard" -ge 1 ]; then
    ok "root refuses the test overrides"
else
    TESTS_FAILED=$((TESTS_FAILED + 1)); fail "no guard against overrides as root"
fi

# --- quiet ------------------------------------------------------------------
#
# The boot unit and the apt hook run with --quiet. If that still chatters, a
# healthy boot prints a wall of text every time.
reset_tree patched 1.6
out=$(MODEMCTL_TARGET="$TREE" MODEMCTL_RADIO_CONF="$RADIO" \
      bash "$ROOT/modemctl" status --quiet 2>/dev/null)
check "quiet status on a healthy tree says nothing" "" "$out"

# --- the DNS half of defect 7 -----------------------------------------------
#
# Both halves have to be there before this counts as fixed. The drop-in alone
# changes nothing that anybody resolves through, and the symlink alone gets
# undone by the next thing that calls the broken resolvconf. A check that said
# "applied" for half of it would be worse than no check.
NMD="$WORK/nm-conf.d"; mkdir -p "$NMD"
NMRESOLV="$WORK/nm-resolv.conf"; echo "nameserver 127.0.0.1" > "$NMRESOLV"
RC="$WORK/resolv.conf"

# Read through "status", not by sourcing modemctl: the script has a dispatcher
# at the bottom, so sourcing it runs a whole status pass and prints it.
dns_state() {
    local out
    out=$(env MODEMCTL_TARGET="$TREE" MODEMCTL_RADIO_CONF="$RADIO" \
              MODEMCTL_NM_CONF_D="$NMD" MODEMCTL_RESOLV="$RC" \
              MODEMCTL_NM_RESOLV="$NMRESOLV" \
              bash "$ROOT/modemctl" status 2>&1)
    case "$out" in
        *"resolv.conf -> NetworkManager"*)        echo applied ;;
        *"does not point at NetworkManager"*)     echo missing ;;
        *"cannot check DNS"*)                     echo absent ;;
        *)                                        echo unknown ;;
    esac
}

rm -f "$NMD"/*.conf "$RC"
ln -sfn /run/systemd/resolve/stub-resolv.conf "$RC"
check "shipped state is not mistaken for fixed" missing "$(dns_state)"

printf 'rc-manager=symlink\n' > "$NMD/99-furios-modem-resolvconf.conf"
check "drop-in alone is not enough" missing "$(dns_state)"

rm -f "$NMD"/*.conf
ln -sfn "$NMRESOLV" "$RC"
check "symlink alone is not enough" missing "$(dns_state)"

printf 'rc-manager=symlink\n' > "$NMD/99-furios-modem-resolvconf.conf"
check "both halves together are applied" applied "$(dns_state)"

# A drop-in that mentions rc-manager but sets something else must not pass.
printf 'rc-manager=resolvconf\n' > "$NMD/99-furios-modem-resolvconf.conf"
check "the wrong rc-manager is not applied" missing "$(dns_state)"

# --- upgrading a patch that changed ----------------------------------------
#
# The case that cost an hour on 2026-09-13. A released patch gains a hunk. The
# installed file is now neither what ofono2mm ships nor what the new patch
# produces, so it applies in NEITHER direction and modemctl rightly refuses to
# touch it - which means the fix cannot be installed at all onto a phone that
# already has the package. dpkg's answer is prerm: revert from the OLD package,
# while its patches still describe the files on disk.

OLDP="$WORK/old-patches"; mkdir -p "$OLDP"
for f in $FILES; do cp "$ROOT/patches/ofono2mm-$f.patch" "$OLDP/"; done

# The actual previous release of this patch: today's file without the block
# that defect 11 added. Appending a line at the end would NOT do - a reverse
# patch still applies around it, and the tree would read as already patched.
# The difference has to fall inside a hunk, which is what really happens when
# a patch grows.
mkdir -p "$WORK/old/ofono2mm"
awk '/^        if iface == "org.ofono.RadioSettings":$/ { skip = 1 }
     /^        if iface == "org.ofono.FuriLabs.AT":$/   { skip = 0 }
     !skip' "$ROOT/patched-files/mm_modem.py" > "$WORK/old/ofono2mm/mm_modem.py"
TESTS_RUN=$((TESTS_RUN + 1))
if ! diff -q "$WORK/old/ofono2mm/mm_modem.py" "$ROOT/patched-files/mm_modem.py" >/dev/null; then
    ok "the stand-in for the previous release really differs"
else
    TESTS_FAILED=$((TESTS_FAILED + 1)); fail "the previous release was not reconstructed"
fi
diff -u --label a/ofono2mm/mm_modem.py --label b/ofono2mm/mm_modem.py \
    "$ROOT/original-files/mm_modem.py" "$WORK/old/ofono2mm/mm_modem.py" \
    > "$OLDP/ofono2mm-mm_modem.patch" || true

sandbox() {
    env MODEMCTL_TARGET="$TREE" MODEMCTL_RADIO_CONF="$RADIO" \
        MODEMCTL_NM_CONF_D="$NMD" MODEMCTL_RESOLV="$RC" \
        MODEMCTL_NM_RESOLV="$NMRESOLV" MODEMCTL_SHARE="$ROOT" \
        "$@"
}

install_old() {
    reset_tree original 1.6
    sandbox MODEMCTL_PATCHES="$OLDP" bash "$ROOT/modemctl" apply --quiet --no-restart >/dev/null 2>&1
    return 0
}

install_old
TESTS_RUN=$((TESTS_RUN + 1))
if diff -q "$TREE/mm_modem.py" "$WORK/old/ofono2mm/mm_modem.py" >/dev/null; then
    ok "the previous release installs cleanly"
else
    TESTS_FAILED=$((TESTS_FAILED + 1)); fail "the previous release did not install"
fi

# With today's patches that tree is unrecognisable, and saying so is correct.
out=$(sandbox bash "$ROOT/modemctl" apply --quiet --no-restart 2>&1)
TESTS_RUN=$((TESTS_RUN + 1))
if echo "$out" | grep -q "mm_modem.py: patch does not fit"; then
    ok "a changed patch is refused rather than forced"
else
    TESTS_FAILED=$((TESTS_FAILED + 1)); fail "a changed patch was not refused" "$out"
fi

# prerm's half: revert with the old patches, which still fit.
sandbox MODEMCTL_PATCHES="$OLDP" bash "$ROOT/modemctl" revert --patches-only --quiet >/dev/null 2>&1
TESTS_RUN=$((TESTS_RUN + 1))
if diff -q "$TREE/mm_modem.py" "$ROOT/original-files/mm_modem.py" >/dev/null; then
    ok "the old package reverts its own work"
else
    TESTS_FAILED=$((TESTS_FAILED + 1)); fail "the old package left its patch behind"
fi

# ...and radioInterface must survive it, or an upgrade that stops here leaves
# the phone on the value that brings back the Error-44 loop.
check "and leaves radioInterface alone" "radioInterface = 1.6" "$(cat "$RADIO")"

# postinst's half: today's patches now apply.
sandbox bash "$ROOT/modemctl" apply --quiet --no-restart >/dev/null 2>&1
TESTS_RUN=$((TESTS_RUN + 1))
if diff -q "$TREE/mm_modem.py" "$ROOT/patched-files/mm_modem.py" >/dev/null; then
    ok "and the new one applies on top of the shipped file"
else
    TESTS_FAILED=$((TESTS_FAILED + 1)); fail "the new patch did not land"
fi

# The whole point of --patches-only is that it stops there.
install_old
sandbox MODEMCTL_PATCHES="$OLDP" bash "$ROOT/modemctl" revert --quiet >/dev/null 2>&1
check "a full revert does undo radioInterface" "radioInterface = 1.4" "$(cat "$RADIO")"

summary
