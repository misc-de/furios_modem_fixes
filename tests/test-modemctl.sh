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
    echo '         variant             string "lte"' ;;
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
# modemctl reloads the system bus when it installs the cell broadcast policy.
# A test suite must not do that to the machine it runs on - and a reload that
# really happened would hide a drop-in written to the wrong place.
cat > "$STUBDIR/systemctl" <<'STUB'
#!/bin/sh
exit 0
STUB
chmod +x "$STUBDIR"/*
PATH="$STUBDIR:$PATH"; export PATH

# Every modemctl call below is aimed at a directory this test owns, including
# the ones that do not name it: without this, apply would write its bus policy
# into the real /etc/dbus-1/system.d.
DBUSD="$WORK/dbus-1-system.d"; mkdir -p "$DBUSD"
export MODEMCTL_DBUS_CONF_D="$DBUSD"
# The baseline is a healthy phone, the same way the checks above assume a
# healthy oFono. The missing case is exercised on purpose further down.
install -m644 "$ROOT/dbus/furios-modem-cellbroadcast.conf" "$DBUSD/"

# The alert channel database. Baseline is a healthy phone, like the policy
# above; what the distribution actually ships - de and nl subscribing to
# EU-Alert level 2 with 4371, 4384 and 4385, and not 4372 - is written in
# further down, where that case is the point.
CBSDB="$WORK/serviceproviders.xml"
export MODEMCTL_CBS_DB="$CBSDB"
write_cbs_db() {
    # $1: "de" channel line, $2: "nl" channel line
    cat > "$CBSDB" <<XML
<serviceproviders format="2.0">
<country code="de">
	<name>Germany</name>
	<cbs>
		<level type="presidential">
			<channels start="4370" end="4370"/>
		</level>
		<level type="extreme">
			$1
			<channels start="4384" end="4384"/>
			<channels start="4385" end="4385"/>
		</level>
	</cbs>
</country>
<country code="nl">
	<name>Netherlands</name>
	<cbs>
		<level type="extreme">
			$2
			<channels start="4385" end="4385"/>
		</level>
	</cbs>
</country>
<country code="us">
	<name>United States</name>
	<cbs>
		<level type="extreme">
			<channels start="4371" end="4372"/>
		</level>
	</cbs>
</country>
</serviceproviders>
XML
}
SHIPPED='<channels start="4371" end="4371"/>'
FIXED='<channels start="4371" end="4372"/>'
write_cbs_db "$FIXED" "$FIXED"

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
# 1.6 is not a value the plugin knows. It falls back to 1.2 without a word,
# which costs NR and two interface versions - so modemctl has to call it out.
reset_tree original 1.6
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
if echo "$out" | grep -q "radioInterface not 1.4"; then
    ok "shipped tree: notices an unrecognised radioInterface"
else
    TESTS_FAILED=$((TESTS_FAILED + 1)); fail "shipped tree: missed radioInterface"
fi

# --- everything applied -----------------------------------------------------
reset_tree patched 1.4
check_status "patched tree: status passes" 0 \
    env MODEMCTL_TARGET="$TREE" MODEMCTL_RADIO_CONF="$RADIO" bash "$ROOT/modemctl" status
out=$(run_status)
TESTS_RUN=$((TESTS_RUN + 1))
if echo "$out" | grep -q "everything in place"; then
    ok "patched tree: says so"
else
    TESTS_FAILED=$((TESTS_FAILED + 1)); fail "patched tree: unexpected verdict" "$out"
fi

# Asking for NR on this modem is one "Error 44 setting pref mode" a second,
# for as long as the preference stands, and the phone registers on LTE anyway.
# That is a failure, not a preference: it has to fail the check, or the noise
# goes unnoticed the way it did for a day.
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
reset_tree patched 1.4
out=$(run_status)
TESTS_RUN=$((TESTS_RUN + 1))
if echo "$out" | grep -q "one Error 44 a second"; then
    ok "a preference of nr is called out"
else
    TESTS_FAILED=$((TESTS_FAILED + 1)); fail "a preference of nr passed unmentioned" "$out"
fi
check_status "and it is treated as a failure" 1 \
    env MODEMCTL_TARGET="$TREE" MODEMCTL_RADIO_CONF="$RADIO" bash "$ROOT/modemctl" status
# back to the healthy stub for the rest
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

# --- upstream moved ---------------------------------------------------------
#
# The dangerous case. A file that is neither ours nor the one the patch was
# written against must be reported, never patched: patch(1) would find the
# context somewhere else and land the change in the wrong place.
reset_tree original 1.4
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
reset_tree original 1.6
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
check "apply sets radioInterface" "radioInterface = 1.4" "$(cat "$RADIO")"
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
reset_tree patched 1.4
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
check "revert leaves the shipped radioInterface" "radioInterface = 1.4" \
    "$(cat "$RADIO")"

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

# And EVERY override has to be in that list, not just most of them. Adding a
# new one and forgetting the guard is how an escape hatch opens without anybody
# deciding to open it - MODEMCTL_PROFILE arrived the same day as this check.
used=$(grep -oE '\$\{MODEMCTL_[A-Z_]+' "$ROOT/modemctl" | sed 's/^\${//' | sort -u)
guarded=$(sed -n '/for v in MODEMCTL_/,/do$/p' "$ROOT/modemctl" \
          | grep -oE 'MODEMCTL_[A-Z_]+' | sort -u)
for v in $used; do
    TESTS_RUN=$((TESTS_RUN + 1))
    case " $(printf '%s ' $guarded)" in
        *" $v "*) ok "$v is refused as root" ;;
        *) TESTS_FAILED=$((TESTS_FAILED + 1))
           fail "$v is honoured but not guarded" "as root it would point modemctl anywhere" ;;
    esac
done

# --- quiet ------------------------------------------------------------------
#
# The boot unit and the apt hook run with --quiet. If that still chatters, a
# healthy boot prints a wall of text every time.
reset_tree patched 1.4
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
# Laid out the way the phone is, not flat: apply writes the symlink as
# "../run/NetworkManager/resolv.conf", relative to the directory resolv.conf
# sits in. Flat paths made that resolve to nothing, so the DNS half of a fix
# could never reach "applied" in here - which is fine for a check that builds
# the link by hand, and useless for one that asks whether apply got there.
mkdir -p "$WORK/etc" "$WORK/run/NetworkManager"
NMRESOLV="$WORK/run/NetworkManager/resolv.conf"; echo "nameserver 127.0.0.1" > "$NMRESOLV"
RC="$WORK/etc/resolv.conf"

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

PROFILEF="$WORK/profile"
sandbox() {
    env MODEMCTL_TARGET="$TREE" MODEMCTL_RADIO_CONF="$RADIO" \
        MODEMCTL_NM_CONF_D="$NMD" MODEMCTL_RESOLV="$RC" \
        MODEMCTL_NM_RESOLV="$NMRESOLV" MODEMCTL_SHARE="$ROOT" \
        MODEMCTL_DBUS_CONF_D="$DBUSD" MODEMCTL_CBS_DB="$CBSDB" \
        MODEMCTL_PROFILE="$PROFILEF" \
        "$@"
}

install_old() {
    reset_tree original 1.4
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

# ...and radioInterface must survive it untouched.
check "and leaves radioInterface alone" "radioInterface = 1.4" "$(cat "$RADIO")"

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
# A full revert has nothing to undo here any more: what we want is what the
# package ships.
check "a full revert leaves radioInterface at the shipped value" \
    "radioInterface = 1.4" "$(cat "$RADIO")"

# ---------------------------------------------------------------------------
# Defect 13: the bus policy that decides whether emergency alert channels can
# be set at all.
#
# The interesting part is not "is the file there". It is that a missing policy
# is INVISIBLE: the modem stays registered, data flows, mmcli is green, and
# the only sign is one rejected message in the journal at boot. So status has
# to call it a fault, and apply has to be able to put it right without being
# told twice.

cb_state() {
    local out
    out=$(sandbox bash "$ROOT/modemctl" status 2>&1)
    case "$out" in
        *"emergency channels set"*)              echo applied ;;
        *"oFono reports no channels"*)           echo applied-noreply ;;
        *"bus policy denies it"*)                echo missing ;;
        *"cannot check cell broadcast"*)         echo absent ;;
        *)                                       echo unknown ;;
    esac
}

reset_tree patched 1.4
rm -f "$DBUSD/furios-modem-cellbroadcast.conf"
check "a phone without the policy is not called healthy" missing "$(cb_state)"

sandbox bash "$ROOT/modemctl" apply --quiet --no-restart >/dev/null 2>&1
TESTS_RUN=$((TESTS_RUN + 1))
if [ -f "$DBUSD/furios-modem-cellbroadcast.conf" ]; then
    ok "apply installs the bus policy"
else
    TESTS_FAILED=$((TESTS_FAILED + 1)); fail "apply did not install the bus policy"
fi

# The stubbed dbus-send answers oFono's GetProperties without Topics, which is
# exactly the case where the policy is in place but nothing reached the modem.
# That must read as a warning, not as success.
check "policy without channels is not reported as done" applied-noreply "$(cb_state)"

# Idempotent, because a boot unit and an apt hook run this on every boot and
# every package operation.
out=$(sandbox bash "$ROOT/modemctl" apply --no-restart 2>&1)
TESTS_RUN=$((TESTS_RUN + 1))
if echo "$out" | grep -q "already reachable"; then
    ok "a second apply leaves the policy alone"
else
    TESTS_FAILED=$((TESTS_FAILED + 1)); fail "second apply touched the policy again" "$out"
fi

# The day ModemManager grows the allow itself, this drop-in stops being ours.
OTHERD="$WORK/other-system.d"; mkdir -p "$OTHERD"
rm -f "$DBUSD/furios-modem-cellbroadcast.conf"
cat > "$DBUSD/zz-upstream-test.conf" <<'POLICY'
<busconfig><policy context="default">
  <allow send_destination="org.freedesktop.ModemManager1"
         send_interface="org.freedesktop.ModemManager1.Modem.CellBroadcast"/>
</policy></busconfig>
POLICY
out=$(sandbox bash "$ROOT/modemctl" apply --no-restart 2>&1)
TESTS_RUN=$((TESTS_RUN + 1))
if echo "$out" | grep -q "own policy allows"; then
    ok "an upstream allow makes apply stand back"
else
    TESTS_FAILED=$((TESTS_FAILED + 1)); fail "apply added a drop-in that is not needed" "$out"
fi
TESTS_RUN=$((TESTS_RUN + 1))
if [ ! -f "$DBUSD/furios-modem-cellbroadcast.conf" ]; then
    ok "and writes no drop-in of its own"
else
    TESTS_FAILED=$((TESTS_FAILED + 1)); fail "apply wrote a drop-in anyway"
fi
rm -f "$DBUSD/zz-upstream-test.conf"

# Work that needs no modem restart still has to be reported as work. This said
# "Nothing to do - everything is already in place" right after replacing the
# policy, which is the kind of line that sends the next person hunting for why
# their fix had no effect.
rm -f "$DBUSD/furios-modem-cellbroadcast.conf"
out=$(sandbox bash "$ROOT/modemctl" apply --no-restart 2>&1)
TESTS_RUN=$((TESTS_RUN + 1))
if echo "$out" | grep -q "Nothing to do"; then
    TESTS_FAILED=$((TESTS_FAILED + 1)); fail "apply called its own work nothing" "$out"
else
    ok "installing the policy is not reported as nothing to do"
fi

# A policy of ours that changed must actually reach a phone that already has
# the old one - "the file is there" and "the file is right" are not the same
# question, and the DNS drop-in above answers only the first.
sandbox bash "$ROOT/modemctl" apply --quiet --no-restart >/dev/null 2>&1
printf '<!-- stale -->\n' >> "$DBUSD/furios-modem-cellbroadcast.conf"
out=$(sandbox bash "$ROOT/modemctl" apply --no-restart 2>&1)
TESTS_RUN=$((TESTS_RUN + 1))
if cmp -s "$ROOT/dbus/furios-modem-cellbroadcast.conf" "$DBUSD/furios-modem-cellbroadcast.conf"; then
    ok "apply replaces an outdated policy"
else
    TESTS_FAILED=$((TESTS_FAILED + 1)); fail "apply left the outdated policy in place" "$out"
fi

# revert takes back only what is ours.
sandbox bash "$ROOT/modemctl" apply --quiet --no-restart >/dev/null 2>&1
sandbox bash "$ROOT/modemctl" revert --quiet >/dev/null 2>&1
TESTS_RUN=$((TESTS_RUN + 1))
if [ ! -f "$DBUSD/furios-modem-cellbroadcast.conf" ]; then
    ok "revert removes the bus policy"
else
    TESTS_FAILED=$((TESTS_FAILED + 1)); fail "revert left the bus policy behind"
fi

# ---------------------------------------------------------------------------
# Defect 14: the alert channel database that lists the translation of a warning
# without the warning.
#
# This one edits a file belonging to a third package that upstream rewrites
# constantly, so the checks that matter are the ones about NOT editing: an
# unfamiliar block, and an upstream that has fixed it already.
cbs_verdict() {
    local out
    out=$(sandbox bash "$ROOT/modemctl" status 2>&1)
    case "$out" in
        *"level 2 complete"*)            echo applied ;;
        *"missing channel 4372"*)        echo missing ;;
        *"looks different than expected"*) echo unknown ;;
        *"no alert channel database"*)   echo absent ;;
        *)                               echo unrecognised ;;
    esac
}

write_cbs_db "$SHIPPED" "$SHIPPED"
check "the shipped database is called incomplete" missing "$(cbs_verdict)"

sandbox bash "$ROOT/modemctl" apply --quiet --no-restart >/dev/null 2>&1
check "apply completes EU-Alert level 2" applied "$(cbs_verdict)"

TESTS_RUN=$((TESTS_RUN + 1))
if grep -q '<channels start="4371" end="4372"/><!--.*-->' "$CBSDB"; then
    ok "the edited line carries a marker saying who changed it"
else
    TESTS_FAILED=$((TESTS_FAILED + 1)); fail "the edit left no marker" "$(grep 4371 "$CBSDB")"
fi

# Both countries, because a German phone roaming in the Netherlands reads the
# Dutch list - and the same slip is in both.
check "both de and nl were corrected" 2 "$(grep -c 'end="4372"/><!--' "$CBSDB")"

# The file has to survive as XML. If it does not, the whole alert list is gone,
# which is worse than the one channel this fixes.
TESTS_RUN=$((TESTS_RUN + 1))
if python3 -c 'import sys,xml.etree.ElementTree as E; E.parse(sys.argv[1])' "$CBSDB" 2>/dev/null; then
    ok "the database still parses after the edit"
else
    TESTS_FAILED=$((TESTS_FAILED + 1)); fail "the edit broke the XML"
fi

out=$(sandbox bash "$ROOT/modemctl" apply --no-restart 2>&1)
TESTS_RUN=$((TESTS_RUN + 1))
if echo "$out" | grep -q "already lists 4372"; then
    ok "a second apply leaves the database alone"
else
    TESTS_FAILED=$((TESTS_FAILED + 1)); fail "second apply edited the database again" "$out"
fi

# An upstream that fixed this itself must not be undone, and must not be
# re-marked as ours.
write_cbs_db "$FIXED" "$FIXED"
sandbox bash "$ROOT/modemctl" apply --quiet --no-restart >/dev/null 2>&1
check "an upstream fix is left untouched" 0 "$(grep -c 'furios-modem-fixes' "$CBSDB")"
sandbox bash "$ROOT/modemctl" revert --quiet >/dev/null 2>&1
check "and revert does not take upstream's fix away" applied "$(cbs_verdict)"

# A block that no longer looks the way this expects is a block to leave alone.
write_cbs_db '<channels start="4371" end="4378"/>' "$SHIPPED"
check "an unfamiliar block is not guessed at" unknown "$(cbs_verdict)"
before=$(md5sum "$CBSDB")
sandbox bash "$ROOT/modemctl" apply --quiet --no-restart >/dev/null 2>&1
check "and apply does not touch it" "$before" "$(md5sum "$CBSDB")"

# revert undoes only our own line.
write_cbs_db "$SHIPPED" "$SHIPPED"
sandbox bash "$ROOT/modemctl" apply --quiet --no-restart >/dev/null 2>&1
sandbox bash "$ROOT/modemctl" revert --quiet >/dev/null 2>&1
check "revert puts the shipped line back" missing "$(cbs_verdict)"
check "and leaves no marker behind" 0 "$(grep -c 'furios-modem-fixes' "$CBSDB")"

# A missing database is not a fault - the phone simply has no list.
rm -f "$CBSDB"
check "a missing database is not called a fault" absent "$(cbs_verdict)"
write_cbs_db "$FIXED" "$FIXED"

printf '\n\033[1m== the profile switch\033[0m\n'

# One switch between the phone as it shipped and the phone as this package
# repairs it, and the difference between "for now" and "for good" is one file.
#
# Reverting was always temporary by accident: the boot unit put the patches
# back at the next start, and there was no way to say "shipped, and mean it".
# So "try" is what revert already did, and "set" is the thing that was missing.

patch_count() {
    local f n=0
    for f in $FILES; do
        grep -q "netmask_to_prefix\|sync_net_ports\|signal_quality\|ModemManagerBus\|ip-type" \
            "$(tree_path "$f")" 2>/dev/null && n=$((n + 1))
    done
    echo "$n"
}

# Start from the shipped state on every side, not just the patches. The checks
# above leave the alert database repaired but WITHOUT our marker, and revert
# rightly refuses to undo a line it did not write - which would leave one piece
# applied for ever and every answer below stuck at "mixed".
rm -f "$PROFILEF" "$DBUSD"/furios-modem-cellbroadcast.conf
write_cbs_db "$SHIPPED" "$SHIPPED"
reset_tree original 1.4
check "with no file recorded, the phone is meant to be fixed" "recorded: fixed" \
      "$(sandbox bash "$ROOT/modemctl" profile | head -1)"

# boot is what the unit and the hook run. With nothing recorded it applies.
sandbox bash "$ROOT/modemctl" boot --quiet --no-restart >/dev/null 2>&1
check "and boot puts the repairs in" fixed \
      "$(sandbox bash "$ROOT/modemctl" profile | sed -n 's/^actual: *//p')"

# try: switch now, record nothing.
sandbox bash "$ROOT/modemctl" try shipped --quiet --no-restart >/dev/null 2>&1
check "try shipped takes them out" shipped \
      "$(sandbox bash "$ROOT/modemctl" profile | sed -n 's/^actual: *//p')"
check "and records nothing" no \
      "$([ -f "$PROFILEF" ] && echo yes || echo no)"
sandbox bash "$ROOT/modemctl" boot --quiet --no-restart >/dev/null 2>&1
check "so the next boot brings them back" fixed \
      "$(sandbox bash "$ROOT/modemctl" profile | sed -n 's/^actual: *//p')"

# set: switch now, and mean it.
sandbox bash "$ROOT/modemctl" set shipped --quiet --no-restart >/dev/null 2>&1
check "set shipped takes them out too" shipped \
      "$(sandbox bash "$ROOT/modemctl" profile | sed -n 's/^actual: *//p')"
check "and records the choice" shipped "$(cat "$PROFILEF" 2>/dev/null)"
sandbox bash "$ROOT/modemctl" boot --quiet --no-restart >/dev/null 2>&1
check "and the next boot leaves them out" shipped \
      "$(sandbox bash "$ROOT/modemctl" profile | sed -n 's/^actual: *//p')"
# The apt hook runs the same verb after every package operation. A recorded
# "shipped" that an ofono2mm update quietly undid would be the worst of both.
sandbox bash "$ROOT/modemctl" boot --quiet --no-restart >/dev/null 2>&1
check "and so does the apt hook, however often it runs" shipped \
      "$(sandbox bash "$ROOT/modemctl" profile | sed -n 's/^actual: *//p')"

sandbox bash "$ROOT/modemctl" set fixed --quiet --no-restart >/dev/null 2>&1
check "set fixed puts them back" fixed \
      "$(sandbox bash "$ROOT/modemctl" profile | sed -n 's/^actual: *//p')"
check "and records that" fixed "$(cat "$PROFILEF" 2>/dev/null)"

# A file nobody here wrote. Deciding for ourselves which way it meant is worse
# than doing nothing, in both directions.
printf 'sideways\n' > "$PROFILEF"
check "an unreadable profile is not guessed at" "recorded: unknown" \
      "$(sandbox bash "$ROOT/modemctl" profile 2>/dev/null | head -1)"
before_state=$(sandbox bash "$ROOT/modemctl" profile 2>/dev/null | sed -n 's/^actual: *//p')
sandbox bash "$ROOT/modemctl" boot --quiet --no-restart >/dev/null 2>&1
check "and boot leaves the phone exactly as it found it" "$before_state" \
      "$(sandbox bash "$ROOT/modemctl" profile 2>/dev/null | sed -n 's/^actual: *//p')"

# Half is a real state - a patch that no longer fits, an update caught in the
# middle - and calling it either name would be wrong in both directions.
printf 'fixed\n' > "$PROFILEF"
cp "$ROOT/original-files/mm_modem.py" "$(tree_path mm_modem)"
check "half applied is called half applied" mixed \
      "$(sandbox bash "$ROOT/modemctl" profile | sed -n 's/^actual: *//p')"

rm -f "$PROFILEF"

# The two words the app on the phone reads this by. It lives in another
# package (furios_pipewire), so these keys are a contract between two
# repositories - and a contract only one side checks is a hope. The other half
# asserts that the app parses exactly these two; this half asserts that they
# are what gets printed.
out=$(sandbox bash "$ROOT/modemctl" profile 2>/dev/null)
check "profile names the recorded state in a word the app knows" 1 \
      "$(printf '%s\n' "$out" | grep -c '^recorded:')"
check "and the running one" 1 \
      "$(printf '%s\n' "$out" | grep -c '^actual:')"
# Three values and no others: the app turns each into a sentence, and a fourth
# would arrive on the phone as a blank row.
for v in fixed shipped mixed; do
    check "\"$v\" is a state this can report" yes \
          "$(grep -q "echo $v" "$ROOT/modemctl" && echo yes || echo no)"
done

printf '\n\033[1m== a no-op is a no-op\033[0m\n'

# The boot unit and the apt hook both run apply, the hook after every single
# package operation on the phone. Their whole claim to being harmless is that
# apply with nothing to do changes nothing - so it has to be true down to the
# mtime, not only for the files it patches.
#
# It was not. prune_backups ran before the state was even known, so a run whose
# own output said "Nothing to do" still deleted backups: sixteen went to eleven
# on the phone, measured.
#
# Two things this test got wrong before it got them right. The backlog is faked
# rather than accumulated, because reset_tree wipes the tree between runs and
# the backup name carries a one-second timestamp - applying in a loop leaves
# one backup and nothing to prune, so the broken code passed. And the claim is
# not "the run prints Nothing to do": the sandbox is shared, an earlier test
# takes the bus policy away, and a run that puts it back is right to say it
# did. What has to hold is that the SECOND run of two changes nothing.
reset_tree patched 1.4
sandbox bash "$ROOT/modemctl" apply --quiet --no-restart >/dev/null 2>&1
for n in 1 2 3 4 5; do
    cp "$TREE/mm_modem.py" "$TREE/mm_modem.py.bak.2026090$n-120000"
done

snapshot() {
    find "$WORK/usr" "$DBUSD" -type f -printf '%p %T@ %s\n' 2>/dev/null | sort
}
before=$(snapshot)
backups_before=$(find "$WORK/usr" -name '*.bak.*' 2>/dev/null | wc -l)

out=$(sandbox bash "$ROOT/modemctl" apply --no-restart 2>&1)
check "a second apply reports no patch work" 6 \
      "$(printf '%s\n' "$out" | grep -c 'already patched')"
check "and changes no file at all" "$before" "$(snapshot)"
check "and deletes none of the 5 backups" "$backups_before" \
      "$(find "$WORK/usr" -name '*.bak.*' 2>/dev/null | wc -l)"

# And the pruning still happens where it belongs. Same backlog, but this time
# one file is back to the shipped version, so apply has real work to do - and
# the backups of THAT file get trimmed while it takes its own.
cp "$ROOT/original-files/mm_modem.py" "$TREE/mm_modem.py"
sandbox bash "$ROOT/modemctl" apply --quiet --no-restart >/dev/null 2>&1
kept=$(find "$TREE" -name 'mm_modem.py.bak.*' 2>/dev/null | wc -l)
check "a run that patches prunes the backlog it is adding to" yes \
      "$([ "$kept" -le 3 ] && echo yes || echo "no - $kept backups")"

printf '\n\033[1m== settling what a ModemManager restart knocked over\033[0m\n'

# "settle" runs as root and restarts a service in somebody else's session.
# Every one of these tests therefore lies to modemctl about all three: who it
# is, what the journal saw, and what systemd did about it. What is being
# tested is the decision, not systemd.
SETTLEBIN="$WORK/settle-bin"; mkdir -p "$SETTLEBIN"
SETTLE_REC="$WORK/settle-systemctl.args"
SETTLE_KILLED="$WORK/settle-killed"

settle_stubs() {
    # settle_stubs <journal lines> <phosh uid, empty for none> <call: yes/no>
    local journal=$1 uid=$2 call=$3
    rm -f "$SETTLE_REC" "$SETTLE_KILLED"
    {
        printf '#!/bin/sh\n'
        [ -n "$journal" ] && printf "cat <<'OUT'\n%s\nOUT\n" "$journal"
        printf 'exit 0\n'
    } > "$SETTLEBIN/journalctl"
    {
        printf '#!/bin/sh\n'
        printf 'printf "%%s\\n" "$*" >> "%s"\n' "$SETTLE_REC"
        printf 'case "$*" in\n'
        # A new MainPID only after the kill: that is the whole difference
        # between "the shell is back" and "the shell has not died yet".
        printf '  *"kill --signal=KILL"*) : > "%s" ;;\n' "$SETTLE_KILLED"
        printf '  *"show -p MainPID"*) [ -f "%s" ] && echo 4242 || echo 1111 ;;\n' "$SETTLE_KILLED"
        printf '  *is-active*) echo active ;;\n'
        # When ModemManager started. The default is "a moment ago", which is
        # what every test here is about; the one test that wants an old
        # ModemManager overwrites this stub itself.
        printf '  *"-p ActiveEnterTimestamp"*) date -d "@$(( $(date +%%s) - 5 ))" ;;\n'
        printf 'esac\nexit 0\n'
    } > "$SETTLEBIN/systemctl"
    {
        printf '#!/bin/sh\n'
        [ -n "$uid" ] && printf 'echo %s\n' "$uid"
        printf 'exit 0\n'
    } > "$SETTLEBIN/ps"
    printf '#!/bin/sh\necho "furios:x:32011:32011::/home/furios:/bin/bash"\n' > "$SETTLEBIN/getent"
    # A shell that has been running since long before the restart, which is the
    # case every test here is about. The one about a shell that came back
    # afterwards overwrites this.
    printf '#!/bin/sh\necho 4242\n' > "$SETTLEBIN/pgrep"
    printf '#!/bin/sh\ndate -d "@$(( $(date +%%s) - 3600 ))"\n' > "$SETTLEBIN/ps"
    printf '#!/bin/sh\nexit 0\n' > "$SETTLEBIN/sleep"
    printf '#!/bin/sh\necho 0\n' > "$SETTLEBIN/id"
    {
        printf '#!/bin/sh\n'
        printf 'case "$*" in\n'
        printf '  *"-f DEVICE,TYPE"*) echo "ril_0:gsm" ;;\n'
        printf '  *"-f DEVICE,STATE"*) echo "ril_0:connected" ;;\n'
        printf 'esac\nexit 0\n'
    } > "$SETTLEBIN/nmcli"
    {
        printf '#!/bin/sh\n'
        printf 'case "$*" in\n'
        printf '  *GetCalls*) %s ;;\n' \
            "$([ "$call" = yes ] && echo 'echo "   object path \"/ril_0/voicecall01\""' || echo ':')"
        printf '  *GetModems*) echo "   object path \\"/ril_0\\"" ;;\n'
        printf 'esac\nexit 0\n'
    } > "$SETTLEBIN/dbus-send"
    chmod +x "$SETTLEBIN"/*
}

settle_run() {
    # With no MODEMCTL_* in the environment, because these runs claim to be
    # root and root refuses to honour them - on purpose, as root they would be
    # an arbitrary-file patch. settle touches no file of ours anyway.
    PATH="$SETTLEBIN:$PATH" env -u MODEMCTL_DBUS_CONF_D -u MODEMCTL_CBS_DB \
        bash "$ROOT/modemctl" settle 2>&1
}
shell_was_killed() {
    grep -q -- 'kill --signal=KILL mobi.phosh.Shell.service' "$SETTLE_REC" 2>/dev/null \
        && echo yes || echo no
}

# The line that started all this, 14.9. The identifier is what the journal
# really prints, PID and all.
LOST_SHELL='Sep 14 06:47:04 FuriS gsd-wwan[4154]: Error calling GetManagedObjects() when name owner (null) for name org.freedesktop.ModemManager1 came back: GDBus.Error:org.freedesktop.DBus.Error.AccessDenied: Rejected send message, 1 matched rules; type="method_call", sender=":1.72" (uid=32011 pid=4154 comm="/usr/libexec/gsd-wwan" label="kernel") interface="org.freedesktop.DBus.ObjectManager" member="GetManagedObjects" error name="(unset)" requested_reply="0" destination=":1.3188" (uid=0 pid=294265 comm="/usr/bin/python3 /usr/sbin/ofono2mm" label="kernel")'
LOST_WP='Sep 14 06:47:04 FuriS wireplumber[66701]: GLib-GIO: Error calling GetManagedObjects() when name owner (null) for name org.freedesktop.ModemManager1 came back: GDBus.Error:org.freedesktop.DBus.Error.AccessDenied: Rejected send message, 1 matched rules; type="method_call" destination=":1.3188" (uid=0 pid=294265 comm="/usr/bin/python3 /usr/sbin/ofono2mm" label="kernel")'
# Defect 13 in the journal: also AccessDenied, also ModemManager, and nothing
# to do with a restart. Counting it would send the next person after the wrong
# failure.
CBS_DENIED='Sep 14 06:47:04 FuriS cellbroadcastd[1234]: GDBus.Error:org.freedesktop.DBus.Error.AccessDenied: Rejected send message, 1 matched rules; interface="org.freedesktop.ModemManager1.Modem.CellBroadcast" member="SetChannels"'
# The same restart, seen by cellbroadcastd a moment later: the old unique name
# is gone now. It is not a client that gave up - oFono keeps the channels, and
# measured on 14.9. they were all still there afterwards.
CBS_GONE="Sep 14 06:47:04 FuriS cellbroadcastd[1234]: Failed to set channel list in '/org/freedesktop/ModemManager1/Modem/0': GDBus.Error:org.freedesktop.DBus.Error.ServiceUnknown: The name :1.20 was not provided by any .service files"
# And the shell losing it with a different error than the first time. Measured
# 14.9.: the same restart hands out AccessDenied, ServiceUnknown or nothing at
# all depending on where in the gap the client's call lands, so the error text
# is exactly the wrong thing to key on.
LOST_SHELL_SU='Sep 14 06:47:04 FuriS gsd-wwan[4154]: Error calling GetManagedObjects() when name owner (null) for name org.freedesktop.ModemManager1 came back: GDBus.Error:org.freedesktop.DBus.Error.ServiceUnknown: The name :1.20 was not provided by any .service files'

settle_stubs "$LOST_SHELL" 32011 no
out=$(settle_run)
# The one thing this must never do on its own. mobi.phosh.Shell.service has
# OnFailure=gnome-session-shutdown.target with OnFailureJobMode=
# replace-irreversibly, so killing it is a coin toss between "back in two
# seconds" and "no shell until somebody starts the target by hand" - measured
# both ways on 14.9., ten minutes apart, on this phone.
check "the shell is never killed to repair an icon" no "$(shell_was_killed)"
check "but the loss is reported in terms of what the user can see" yes \
      "$(printf '%s\n' "$out" | grep -qi 'signal icon' && echo yes || echo no)"
# Defect 23: the way back is a ModemManager restart, not the shell. phosh
# picks the modem up again by itself when the name comes back - measured on
# the device on 14.9., and confirmed by eye. Killing the shell was never
# needed for this, and it is the one move here that can end the session.
check "and the way back is printed, and it is not the shell" yes \
      "$(printf '%s\n' "$out" \
         | grep -q 'systemctl restart ModemManager.service' && echo yes || echo no)"
check "no shell kill is suggested any more" no \
      "$(printf '%s\n' "$out" | grep -q 'kill --signal' && echo yes || echo no)"
check "and the rest of the stack is not made to sound broken" yes \
      "$(printf '%s\n' "$out" | grep -qi 'Everything else is fine' && echo yes || echo no)"

settle_stubs "$LOST_WP" 32011 no
out=$(settle_run)
check "a client that is not the shell is not confused with it" no \
      "$(printf '%s\n' "$out" | grep -qi 'signal icon' && echo yes || echo no)"
check "but it is named, because nothing else will notice" yes \
      "$(printf '%s\n' "$out" | grep -q 'wireplumber' && echo yes || echo no)"
check "and wireplumber is left alone on purpose, out loud" yes \
      "$(printf '%s\n' "$out" | grep -qi 'Bluetooth card' && echo yes || echo no)"

# An empty journal used to end it: "no client lost ModemManager - nothing to
# put back". Measured 14.9.: that is also exactly what a shell which never
# found a ModemManager at all looks like, because a client only logs when a
# call fails and this one never made one. So the age of the shell decides.
settle_stubs "" 32011 no
out=$(settle_run)
check "a shell older than this ModemManager is not called healthy" no \
      "$(printf '%s\n' "$out" | grep -q 'the shell is younger' && echo yes || echo no)"
check "the silence itself is explained" yes \
      "$(printf '%s\n' "$out" | grep -q 'says nothing at all' && echo yes || echo no)"
check "and it is about the icon, not about the modem" yes \
      "$(printf '%s\n' "$out" | grep -q 'nothing else is affected' && echo yes || echo no)"
check "the way back is offered, not taken" no "$(shell_was_killed)"
check "and the remedy named is the ModemManager restart" yes \
      "$(printf '%s\n' "$out" \
         | grep -q 'systemctl restart ModemManager.service' && echo yes || echo no)"

# The healthy boot: ModemManager comes up first, the shell after it. Nothing
# to warn about, and warning anyway is how a check stops being read.
settle_stubs "" 32011 no
printf '#!/bin/sh\ndate\n' > "$SETTLEBIN/ps"; chmod +x "$SETTLEBIN/ps"
out=$(settle_run)
check "a shell younger than ModemManager has it" yes \
      "$(printf '%s\n' "$out" | grep -q 'the shell is younger than it' && echo yes || echo no)"
check "and nothing is said about the icon" no \
      "$(printf '%s\n' "$out" | grep -qi 'signal icon' && echo yes || echo no)"

# No shell at all - a phone in SSH, or one whose session has not started yet.
settle_stubs "" 32011 no
printf '#!/bin/sh\nexit 1\n' > "$SETTLEBIN/pgrep"; chmod +x "$SETTLEBIN/pgrep"
out=$(settle_run)
check "no shell running is said plainly" yes \
      "$(printf '%s\n' "$out" | grep -q 'no shell is running' && echo yes || echo no)"

# Neither of these is a client that lost ModemManager, so neither may be named
# as one - what is left is the age question, which is asked of every phone.
settle_stubs "$CBS_DENIED" 32011 no
out=$(settle_run)
check "the cell broadcast denial is not mistaken for this one" no \
      "$(printf '%s\n' "$out" | grep -q 'cellbroadcastd' && echo yes || echo no)"
check "and it is not reported as the shell losing anything" no \
      "$(printf '%s\n' "$out" | grep -q 'the shell lost ModemManager' && echo yes || echo no)"

settle_stubs "$CBS_GONE" 32011 no
out=$(settle_run)
check "nor is cellbroadcastd losing the old name" no \
      "$(printf '%s\n' "$out" | grep -q 'cellbroadcastd' && echo yes || echo no)"
check "that one is not the shell either" no \
      "$(printf '%s\n' "$out" | grep -q 'the shell lost ModemManager' && echo yes || echo no)"

settle_stubs "$LOST_SHELL_SU" 32011 no
out=$(settle_run)
check "the shell is found whatever error it was given" yes \
      "$(printf '%s\n' "$out" | grep -qi 'signal icon' && echo yes || echo no)"

# Nagging about a fault that has already been repaired is how a check stops
# being read at all. A shell younger than the restart cannot still be missing
# what that restart took away.
settle_stubs "$LOST_SHELL" 32011 no
printf '#!/bin/sh\ndate\n' > "$SETTLEBIN/ps"; chmod +x "$SETTLEBIN/ps"
out=$(settle_run)
check "a shell that came back since is not reported as broken" yes \
      "$(printf '%s\n' "$out" | grep -q 'restarted since' && echo yes || echo no)"
check "and the missing icon is not announced again" no \
      "$(printf '%s\n' "$out" | grep -qi 'signal icon' && echo yes || echo no)"

# A journal that cannot be read is not a phone where nothing happened. Both
# answers are empty; only one of them is the truth.
settle_stubs "$LOST_SHELL" 32011 no
printf '#!/bin/sh\nexit 1\n' > "$SETTLEBIN/journalctl"; chmod +x "$SETTLEBIN/journalctl"
out=$(settle_run)
check "an unreadable journal is admitted, not read as silence" yes \
      "$(printf '%s\n' "$out" | grep -q 'cannot read the journal' && echo yes || echo no)"
check "and it does not claim nobody lost anything" no \
      "$(printf '%s\n' "$out" | grep -q 'no client lost ModemManager' && echo yes || echo no)"

# Without a recent restart there is no stale proxy to repair, and restarting
# NetworkManager over a merely unavailable modem - airplane mode, no SIM -
# would blink the Wi-Fi for nothing.
settle_stubs "" 32011 no
cat > "$SETTLEBIN/systemctl" <<STUB
#!/bin/sh
printf "%s\\n" "\$*" >> "$SETTLE_REC"
case "\$*" in
  *"-p ActiveEnterTimestamp"*) date -d "@\$(( \$(date +%s) - 4000 ))" ;;
esac
exit 0
STUB
chmod +x "$SETTLEBIN/systemctl"
out=$(settle_run)
check "an old ModemManager means NetworkManager is left alone" yes \
      "$(printf '%s\n' "$out" | grep -q 'leaving NetworkManager alone' && echo yes || echo no)"
check "and NetworkManager is really not restarted" no \
      "$(grep -q 'restart NetworkManager' "$SETTLE_REC" && echo yes || echo no)"
check "but the journal is still looked at" yes \
      "$(printf '%s\n' "$out" | grep -q 'no client lost ModemManager' && echo yes || echo no)"

# Root, because it restarts NetworkManager. Saying so is better than half of
# it failing with systemd's wording.
settle_stubs "$LOST_SHELL" 32011 no
printf '#!/bin/sh\necho 32011\n' > "$SETTLEBIN/id"; chmod +x "$SETTLEBIN/id"
out=$(settle_run)
check "settle without root refuses instead of half-working" yes \
      "$(printf '%s\n' "$out" | grep -q 'needs root' && echo yes || echo no)"

printf '\n\033[1m== nothing assumed that can be asked\033[0m\n'

# /ril_0 is what oFono calls the modem on THIS phone, and it was written into
# four checks as though it were a constant. On a phone that calls it something
# else every one of them reports "unreadable" for a modem that is answering
# perfectly - a wrong answer in the voice of a right one. Comments may mention
# it; code may not.
code=$(grep -v '^[[:space:]]*#' "$ROOT/modemctl")
check "the modem path is asked for, not assumed" 0 \
      "$(printf '%s\n' "$code" | grep -c '/ril_0')"

# Same for the route metric. furios-mobile-route makes it configurable, so a
# copy of the number here agrees with it right up to the day it is overridden,
# and then reports a missing route on a phone whose route is where it belongs.
# One fallback for "the tool is not installed" is allowed; a second copy is not.
check "the route metric is asked of the tool" yes \
      "$(printf '%s\n' "$code" | grep -c '\b1050\b' | awk '{print ($1<=1)?"yes":"no ("$1" copies)"}')"
check "and it is asked with --metric" yes \
      "$(printf '%s\n' "$code" | grep -q -- '--metric' && echo yes || echo no)"
check "the tool answers --metric" yes \
      "$(grep -q -- '--metric)' "$ROOT/tools/furios-mobile-route" && echo yes || echo no)"

# The MMS context used to be addressed by its number. Contexts are numbered in
# the order they were added, so adding or removing one renumbers the rest and
# the APN check starts reading a different context without a word.
check "the MMS context is found by type, not by number" yes \
      "$(printf '%s\n' "$code" | grep -q 'context_path mms' && echo yes || echo no)"

# --- defect 23: what systemd is told, and when the name is really up --------
#
# Upstream ModemManager.service is Type=dbus with BusName=...: the unit is
# started when the name is on the bus. ofono2mm's own drop-in sets
# Type=simple, so systemd calls it started at fork - 4.5 s early on 14.9.
# 14:50, and on the boot where ofono2mm never took the name at all it looked
# like a perfectly healthy service (defect 17). Our drop-in puts Type=dbus
# back; it no longer orders anything after oFono, because that ordering was
# what pushed the name past the shell in the first place.
#
# systemctl is stubbed for this block, and has to be: "does this unit already
# answer to its bus name" is a question about the machine the test happens to
# run on, and on this phone the answer changes the moment apply has run once.
SYSD="$WORK/systemd-system"; mkdir -p "$SYSD"
STUB="$WORK/stub-bin"; mkdir -p "$STUB"
cat > "$STUB/systemctl" <<'STUBEOF'
#!/bin/bash
# Only the questions this block is about; everything else answers the way an
# absent unit does, which is what the rest of status already copes with.
if [ "${1:-}" = show ] && [ "${3:-}" = -p ] && [ "${4:-}" = LoadState ]; then
    # Set-but-empty has to stay empty here: it is one of the answers.
    printf '%s\n' "${STUB_LOADSTATE-loaded}"
    exit 0
fi
if [ "${1:-}" = show ] && [ "${3:-}" = -p ] && [ "${4:-}" = Type ]; then
    printf '%s\n' "${STUB_TYPE:-simple}"
    exit 0
fi
if [ "${1:-}" = show ] && [ "${3:-}" = -p ] && [ "${4:-}" = BusName ]; then
    printf '%s\n' "${STUB_BUSNAME:-}"
    exit 0
fi
exit 0
STUBEOF
chmod +x "$STUB/systemctl"

# journalctl too, for the same reason: "when did the bus name appear" is a
# question about this boot of this machine. On the phone the line is in the
# journal, anywhere else it is not, and status would then stop at "no 'is
# ours' line" instead of reaching the comparison the next checks are about.
cat > "$STUB/journalctl" <<'STUBEOF'
#!/bin/bash
for a in "$@"; do
    [ "$a" = ModemManager.service ] && \
        exec printf '%s.000000 phone ofono2mm[1]: org.freedesktop.ModemManager1 is ours\n' \
                    "$(date +%s)"
done
exit 0
STUBEOF
chmod +x "$STUB/journalctl"

DROPIN=50-furios-modemmanager-name.conf

order_state() {
    local out
    out=$(env PATH="$STUB:$PATH" \
              MODEMCTL_TARGET="$TREE" MODEMCTL_RADIO_CONF="$RADIO" \
              MODEMCTL_SYSTEMD_CONF_D="$1" \
              bash "$ROOT/modemctl" status 2>&1)
    case "$out" in
        *"started when its bus name is up"*)  echo applied ;;
        *"is Type=simple"*)                   echo missing ;;
        *"no ModemManager.service here - cannot check"*) echo unknown ;;
        *"cannot check the unit type"*)       echo absent ;;
        *)                                    echo unknown ;;
    esac
}

check "shipped state is not mistaken for fixed" missing "$(order_state "$SYSD")"

mkdir -p "$SYSD/ModemManager.service.d"
install -m644 "$ROOT/systemd/$DROPIN" "$SYSD/ModemManager.service.d/$DROPIN"
check "the drop-in is what makes it applied" applied "$(order_state "$SYSD")"

rm -rf "$SYSD/ModemManager.service.d"
check "and removing it is noticed" missing "$(order_state "$SYSD")"

# If ofono2mm ever stops throwing Type=dbus away, ours is not needed and must
# not be reported as missing - nor put back by apply, nor claimed by revert.
check "an upstream that fixes this itself counts as covered" applied \
      "$(STUB_TYPE=dbus STUB_BUSNAME=org.freedesktop.ModemManager1 \
         order_state "$SYSD")"

# Half of it is not it: Type=dbus pointing at nothing must not count.
check "Type=dbus without the BusName is not covered" missing \
      "$(STUB_TYPE=dbus STUB_BUSNAME= order_state "$SYSD")"

check "a phone without systemd is not a failure" absent \
      "$(order_state "$WORK/no-such-systemd")"

# And a machine that has systemd but no ModemManager at all - a build runner,
# a container - is not a broken phone either. It used to read as Type=simple
# and fail the whole status, which is how this suite came to pass only where
# it was written.
check "a machine without the unit is not a failure" unknown \
      "$(STUB_LOADSTATE=not-found order_state "$SYSD")"

# And one where the question cannot be put at all - no systemd behind
# systemctl, or no systemctl - answers nothing. That is the same "cannot
# tell", not a verdict: the runner turned out to be this one, not the one
# above.
check "a systemctl that answers nothing is not a failure" unknown \
      "$(STUB_LOADSTATE= order_state "$SYSD")"

# status also compares two moments of this boot: the bus name appearing and
# the shell starting. The stubbed systemctl answers nothing for the shell's
# start time - and `date -d ""` is midnight this morning, not an error. Left
# ungarded that read as "the bus name was fifteen hours late" and failed a
# healthy phone; it has to say it cannot tell instead.
status_out=$(env PATH="$STUB:$PATH" \
                 MODEMCTL_TARGET="$TREE" MODEMCTL_RADIO_CONF="$RADIO" \
                 MODEMCTL_SYSTEMD_CONF_D="$SYSD" \
                 bash "$ROOT/modemctl" status 2>&1)
check "an unreadable shell start time is not read as midnight" yes \
      "$(printf '%s\n' "$status_out" | grep -q 'AFTER .* started' && echo no || echo yes)"
check "and status says it cannot tell" yes \
      "$(printf '%s\n' "$status_out" | grep -q 'cannot compare with the shell' \
         && echo yes || echo no)"

# The drop-in has to say the two things it exists to say. A file that
# installs cleanly and changes nothing would pass every check above.
check "the drop-in sets Type=dbus" yes \
      "$(grep -q '^Type=dbus$' "$ROOT/systemd/$DROPIN" && echo yes || echo no)"
check "and names the bus it waits for" yes \
      "$(grep -q '^BusName=org.freedesktop.ModemManager1$' \
              "$ROOT/systemd/$DROPIN" && echo yes || echo no)"
# The whole point of defect 23: this file must not push ModemManager behind
# oFono's nine seconds in binder-wait ever again.
check "and it no longer orders ModemManager after oFono" yes \
      "$(grep -q '^After=' "$ROOT/systemd/$DROPIN" && echo no || echo yes)"
check "and it does not restart anything to do it" yes \
      "$(grep -qE '^(ExecStart|Restart)' "$ROOT/systemd/$DROPIN" \
         && echo no || echo yes)"

# apply puts it in place and revert takes it away - both without root, both
# against the work tree, so the real unit directory is never touched here.
rm -rf "$SYSD/ModemManager.service.d"
env PATH="$STUB:$PATH" MODEMCTL_TARGET="$TREE" MODEMCTL_RADIO_CONF="$RADIO" \
    MODEMCTL_SYSTEMD_CONF_D="$SYSD" MODEMCTL_SHARE="$ROOT" \
    bash "$ROOT/modemctl" apply -q >/dev/null 2>&1
check "apply installs the drop-in" yes \
      "$([ -f "$SYSD/ModemManager.service.d/$DROPIN" ] && echo yes || echo no)"

# A phone upgrading from defect 20 still carries the old file, and a drop-in
# is whatever is in the directory: left there, it would keep ordering
# ModemManager after oFono and undo the whole fix.
: > "$SYSD/ModemManager.service.d/50-furios-after-ofono.conf"
env PATH="$STUB:$PATH" MODEMCTL_TARGET="$TREE" MODEMCTL_RADIO_CONF="$RADIO" \
    MODEMCTL_SYSTEMD_CONF_D="$SYSD" MODEMCTL_SHARE="$ROOT" \
    bash "$ROOT/modemctl" apply -q >/dev/null 2>&1
check "apply takes the defect 20 drop-in back out" yes \
      "$([ -f "$SYSD/ModemManager.service.d/50-furios-after-ofono.conf" ] \
         && echo no || echo yes)"

env PATH="$STUB:$PATH" MODEMCTL_TARGET="$TREE" MODEMCTL_RADIO_CONF="$RADIO" \
    MODEMCTL_SYSTEMD_CONF_D="$SYSD" MODEMCTL_SHARE="$ROOT" \
    bash "$ROOT/modemctl" revert -q >/dev/null 2>&1
check "revert takes it away again" yes \
      "$([ -f "$SYSD/ModemManager.service.d/$DROPIN" ] && echo no || echo yes)"

summary
