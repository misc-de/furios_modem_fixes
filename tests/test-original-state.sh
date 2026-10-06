#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
#
# The rule of 30.9.2026, checked from the outside: before the first change,
# what was there is written down; a second run never overwrites that; the way
# back puts exactly that back - and only where the value is still ours. A value
# somebody changed after us is left alone and reported. Without a record the
# old behaviour stays, but it says so.
#
# Every case is snapshot -> change -> revert -> compare with the snapshot,
# never "compare with what the default is supposed to be": a test that knows
# the default shares the assumption this rule exists to get rid of.
#
# Everything runs in a directory this test owns, with stand-ins for oFono,
# systemd and the radio HAL. MODEMCTL_* is passed to each call and never
# exported: a stray export reaches the runs that pretend to be root, and root
# refuses every MODEMCTL_* - which once turned fifteen unrelated checks red.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
. "$HERE/lib.sh"

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
BIN="$W/bin"; ST="$W/state"; mkdir -p "$BIN" "$ST"
FILES="utils mm_bearer mm_modem mm_modem_simple mm_modem_signal main"

# oFono: one modem, one SIM, a channel list, a preference - each in a file, so
# a test can play cellbroadcastd or a user changing something behind our back.
# ST/down makes it stop answering. Every SetProperty is logged.
cat > "$BIN/dbus-send" <<STUB
#!/bin/bash
args="\$*"
[ -e "$ST/down" ] && exit 1
case "\$args" in
  *Manager.GetModems*)    printf 'method return\n   array [\n      struct {\n         object path "/ril_0"\n' ;;
  *VoiceCallManager.GetCalls*) echo 'array [' ;;
  *SimManager.GetProperties*)
      printf '      dict entry(\n         string "SubscriberIdentity"\n         variant             string "%s"\n' "\$(cat "$ST/imsi")" ;;
  *CellBroadcast.GetProperties*)
      printf '      dict entry(\n         string "Topics"\n         variant             string "%s"\n' "\$(cat "$ST/topics")" ;;
  *CellBroadcast.SetProperty*)
      v=\${args##*variant:string:}; printf '%s' "\$v" > "$ST/topics"; echo "topics \$v" >> "$ST/log" ;;
  *RadioSettings.GetProperties*)
      printf '         string "TechnologyPreference"\n         variant             string "%s"\n' "\$(cat "$ST/pref")" ;;
  *SetProperty*TechnologyPreference*)
      v=\${args##*string:}; echo "\$v" > "$ST/pref"; echo "pref \$v" >> "$ST/log" ;;
  *NetworkRegistration.GetProperties*)
      printf '         string "Status"\n         variant             string "registered"\n' ;;
  *SetProperty*Online*)   echo "online \${args##*boolean:}" >> "$ST/log" ;;
esac
exit 0
STUB
# systemd: ModemManager is there, and started when its process is (Type=simple)
# - the state in which apply puts the start-order drop-in down.
cat > "$BIN/systemctl" <<'STUB'
#!/bin/bash
case "$*" in
  *"-p LoadState"*) echo loaded ;;
  *"-p Type"*)      echo simple ;;
esac
exit 0
STUB
# The radio HAL: remembers the bitmap. ST/hal-down: no answer.
cat > "$BIN/nrprobe" <<STUB
#!/bin/bash
[ -e "$ST/hal-down" ] && exit 1
b=\$(cat "$ST/bits")
case "\$1" in
  get)        echo "  <- response 194 serial 0x4e520003 error 0 (NONE) value \$b (\$(printf '%#x' \$b))" ;;
  setallowed) echo \$(( \$2 )) > "$ST/bits" ;;
esac
exit 0
STUB
printf '#!/bin/sh\nexit 0\n' > "$BIN/logger"
chmod +x "$BIN"/*

# The ofono2mm files are diverted; never in this machine's dpkg database.
make_divert_stub "$BIN/dpkg-divert" "$W/diversions"
# Every other override into the sandbox too (tests/lib.sh); mc sets its own.
modemctl_sandbox "$W/sandbox"

TREE="$W/usr/lib/ofono2mm/ofono2mm"
RADIO="$W/etc/ofono/binder.d/radio-interface-binder.conf"
NMD="$W/etc/NetworkManager/conf.d"
RC="$W/etc/resolv.conf"
NMRESOLV="$W/run/NetworkManager/resolv.conf"
STUBRESOLV="$W/run/systemd/resolve/stub-resolv.conf"
DBUSD="$W/etc/dbus-1/system.d"
SYSD="$W/etc/systemd/system"
MMD="$SYSD/ModemManager.service.d"
CBSDB="$W/usr/share/mobile-broadband-provider-info/serviceproviders.xml"
ORIG="$W/var/lib/furios-modem-fixes/original"

mc() {
    env PATH="$BIN:$PATH" \
        MODEMCTL_TARGET="$TREE" MODEMCTL_RADIO_CONF="$RADIO" MODEMCTL_SHARE="$ROOT" \
        MODEMCTL_NM_CONF_D="$NMD" MODEMCTL_RESOLV="$RC" MODEMCTL_NM_RESOLV="$NMRESOLV" \
        MODEMCTL_DBUS_CONF_D="$DBUSD" MODEMCTL_CBS_DB="$CBSDB" \
        MODEMCTL_SYSTEMD_CONF_D="$SYSD" MODEMCTL_PROFILE="$W/etc/profile" \
        MODEMCTL_ORIGINAL="$ORIG" MODEMCTL_NR="$W/etc/nr" MODEMCTL_NRPROBE="$BIN/nrprobe" \
        MODEMCTL_SIM="$W/etc/sim" MODEMCTL_SIM_DROPIN="$W/etc/ofono/binder.d/zz-furios-sim.conf" \
        MODEMCTL_SIM_LOCK="$W/sim.lock" MODEMCTL_SIM_NAMES="$W/var/lib/sim-names" \
        MODEMCTL_MTK_PLUGIN="$W/no-mtk/mtkbinderpluginext.so" MODEMCTL_MTK_BUILD="$W/mtk-build" \
        MODEMCTL_DIVERT="$BIN/dpkg-divert" MODEMCTL_DPKG_INFO="$W/dpkg-info" \
        NR_OFF_SECONDS=0 NR_REG_WAIT=1 \
        "$MODEMCTL" "$@"
}

# What the distribution ships for the alert database: de subscribes to EU-Alert
# level 2 without 4372.
write_cbs_db() {
    mkdir -p "$(dirname "$CBSDB")"
    cat > "$CBSDB" <<'XML'
<serviceproviders format="2.0">
<country code="de">
	<cbs>
		<level type="extreme">
			<channels start="4371" end="4371"/>
			<channels start="4385" end="4385"/>
		</level>
	</cbs>
</country>
</serviceproviders>
XML
}

# A phone as it shipped. resolv.conf is whatever $1 says.
fresh() {
    rm -rf "$W/usr" "$W/etc" "$W/run" "$W/var"; : > "$W/diversions"
    mkdir -p "$TREE" "$(dirname "$RADIO")" "$NMD" "$DBUSD" "$SYSD" \
             "$(dirname "$NMRESOLV")" "$(dirname "$STUBRESOLV")"
    for f in $FILES; do
        case "$f" in main) cp "$ROOT/original-files/main.py" "$TREE/../main.py" ;;
                     *)    cp "$ROOT/original-files/$f.py" "$TREE/$f.py" ;; esac
    done
    printf '[slot1]\npath = /ril_0\nslot = 0\nradioInterface = 1.4\n' > "$RADIO"
    echo "nameserver 127.0.0.1"  > "$NMRESOLV"
    echo "nameserver 127.0.0.53" > "$STUBRESOLV"
    case "${1:-stub}" in
        stub)    ln -s ../run/systemd/resolve/stub-resolv.conf "$RC" ;;
        file)    printf 'nameserver 9.9.9.9\nsearch example.org\n' > "$RC"; chmod 640 "$RC" ;;
        absent)  ;;
    esac
    write_cbs_db
    echo 262019876543210 > "$ST/imsi"
    printf '%s' '4370,4372,4378,4383,4385,4391,4396-4397' > "$ST/topics"
    echo lte > "$ST/pref"
    echo $((0x9ce0e)) > "$ST/bits"
    rm -f "$ST/down" "$ST/hal-down"
    : > "$ST/log"
}

# How a path looks, symlink text and all - compared, not interpreted.
snap() {
    local p=$1
    if [ -L "$p" ]; then echo "link $(readlink "$p")"
    elif [ -f "$p" ]; then echo "file $(stat -c %a "$p") $(sha256sum < "$p" | cut -c1-16)"
    elif [ -d "$p" ]; then echo "dir $(ls -A "$p" | tr '\n' ' ')"
    else echo absent; fi
}
records() { ls -A "$ORIG" 2>/dev/null | tr '\n' ' '; }
OURS26='919,4370-4392,4396-4397'

# --- resolv.conf ------------------------------------------------------------
printf '\n== resolv.conf\n'
for kind in stub file absent; do
    fresh "$kind"
    before=$(snap "$RC")
    mc apply --no-restart >/dev/null 2>&1
    check "$kind: apply points it at NetworkManager" "$NMRESOLV" "$(readlink -f "$RC")"
    check "$kind: the original is recorded before the change" yes \
        "$(ls "$ORIG"/resolv.conf.* >/dev/null 2>&1 && echo yes || echo no)"
    mc revert >/dev/null 2>&1
    check "$kind: revert puts back exactly what was there" "$before" "$(snap "$RC")"
    check "$kind: and the drop-in goes" absent "$(snap "$NMD/99-furios-modem-resolvconf.conf")"
    check "$kind: the record is used up" "" "$(records | tr ' ' '\n' | grep '^resolv' )"
done

# A second apply - the boot unit, a reinstall - must not write down our own
# link as "the original".
fresh stub
before=$(snap "$RC")
mc apply --no-restart >/dev/null 2>&1
rm -f "$NMD/99-furios-modem-resolvconf.conf"     # only the drop-in went missing
mc apply --no-restart >/dev/null 2>&1
check "a second apply does not overwrite the record" \
    "link ../run/systemd/resolve/stub-resolv.conf" "$(snap "$ORIG/resolv.conf.path")"
mc revert >/dev/null 2>&1
check "and revert still goes back to the first original" "$before" "$(snap "$RC")"

# Changed by somebody after us: theirs now.
fresh stub
mc apply --no-restart >/dev/null 2>&1
ln -sfn /etc/my-own-resolv.conf "$RC"
out=$(mc revert 2>&1)
check "a resolv.conf changed since apply is left alone" "link /etc/my-own-resolv.conf" "$(snap "$RC")"
check "and it says so, with what was there before" yes \
    "$(printf '%s' "$out" | grep -q 'changed since apply' && printf '%s' "$out" \
       | grep -q 'stub-resolv.conf' && echo yes || echo no)"
check "our drop-in goes all the same" absent "$(snap "$NMD/99-furios-modem-resolvconf.conf")"
check "and the record, which describes nothing of ours any more" "" "$(records)"

# No record: a phone an older version set up. Old behaviour, said out loud.
fresh stub
mc apply --no-restart >/dev/null 2>&1
rm -rf "$ORIG"
out=$(mc revert 2>&1)
check "without a record revert falls back to the resolved stub" "$STUBRESOLV" "$(readlink -f "$RC")"
check "and says it had no record" yes \
    "$(printf '%s' "$out" | grep -q 'no record of' && echo yes || echo no)"

# Could not record: no change either.
fresh stub
mkdir -p "$(dirname "$ORIG")"; : > "$ORIG"     # a file where the directory belongs
before=$(snap "$RC")
mc apply --no-restart >/dev/null 2>&1
check "no way to record, no change to resolv.conf" "$before" "$(snap "$RC")"
rm -f "$ORIG"

# --- ModemManager.service.d -------------------------------------------------
printf '\n== the drop-in directory on ModemManager\n'
fresh stub
mc apply --no-restart >/dev/null 2>&1
check "apply puts the start-order drop-in down" yes \
    "$([ -f "$MMD/50-furios-modemmanager-name.conf" ] && echo yes || echo no)"
mc revert >/dev/null 2>&1
check "a directory apply made goes with it" absent "$(snap "$MMD")"

fresh stub
mkdir -p "$MMD"
mc apply --no-restart >/dev/null 2>&1
mc revert >/dev/null 2>&1
check "a directory that was there before stays, even empty" "dir " "$(snap "$MMD")"

fresh stub
mc apply --no-restart >/dev/null 2>&1
echo '[Service]' > "$MMD/10-somebody.conf"
mc revert >/dev/null 2>&1
check "somebody's file in a directory we made keeps it" "dir 10-somebody.conf " "$(snap "$MMD")"
check "no record left behind" "" "$(records)"

# --- the alert database -----------------------------------------------------
printf '\n== serviceproviders.xml\n'
fresh stub
chmod 640 "$CBSDB"
before=$(snap "$CBSDB")
mc apply --no-restart >/dev/null 2>&1
check "apply adds 4372" yes "$(grep -q 'end="4372"' "$CBSDB" && echo yes || echo no)"
mc revert >/dev/null 2>&1
check "revert gives back the same bytes and the same mode" "$before" "$(snap "$CBSDB")"

# --- the warning channel list oFono keeps -----------------------------------
printf '\n== the warning channel list\n'
fresh stub
before=$(cat "$ST/topics")
mc apply --no-restart >/dev/null 2>&1
check "the list is recorded per SIM before the first change" "$before" \
    "$(cat "$ORIG/cbs-topics-262019876543210.value" 2>/dev/null)"
printf '%s' "$OURS26" > "$ST/topics"             # cellbroadcastd, through our policy
mc apply --no-restart >/dev/null 2>&1
check "a second apply does not record our own list" "$before" \
    "$(cat "$ORIG/cbs-topics-262019876543210.value" 2>/dev/null)"
mc revert >/dev/null 2>&1
check "revert sets the recorded list back" "$before" "$(cat "$ST/topics")"
check "through oFono, once" 1 "$(grep -c '^topics' "$ST/log")"
check "and uses the record up" "" "$(records)"

# An empty list is an original too.
fresh stub
printf '' > "$ST/topics"
mc apply --no-restart >/dev/null 2>&1
printf '%s' "$OURS26" > "$ST/topics"
mc revert >/dev/null 2>&1
check "an empty original comes back empty" "" "$(cat "$ST/topics")"
check "and was set, not skipped" 1 "$(grep -c '^topics' "$ST/log")"

# Changed by somebody after us.
fresh stub
mc apply --no-restart >/dev/null 2>&1
printf '%s' '4370,4371' > "$ST/topics"
out=$(mc revert 2>&1)
check "a list changed since apply is left alone" '4370,4371' "$(cat "$ST/topics")"
check "and nothing is sent" 0 "$(grep -c '^topics' "$ST/log")"
check "and it says so" yes "$(printf '%s' "$out" | grep -q 'changed since apply' && echo yes || echo no)"

# Already ours at the first apply of this version: nothing to record, and
# revert says it has nothing to go back to instead of guessing.
fresh stub
printf '%s' "$OURS26" > "$ST/topics"
mc apply --no-restart >/dev/null 2>&1
check "our own list is never recorded as the original" "" "$(records | tr ' ' '\n' | grep '^cbs-')"
out=$(mc revert 2>&1)
check "revert without a record leaves it" "$OURS26" "$(cat "$ST/topics")"
check "and says why" yes "$(printf '%s' "$out" | grep -q 'no record of the channels' && echo yes || echo no)"

# oFono not answering at revert: the record waits for the next try.
fresh stub
mc apply --no-restart >/dev/null 2>&1
printf '%s' "$OURS26" > "$ST/topics"
touch "$ST/down"
mc revert >/dev/null 2>&1
rm -f "$ST/down"
check "oFono away at revert keeps the record" "cbs-topics-262019876543210.value " "$(records)"

# uninstall-cbs.sh reads the same record.
run_cbs() { env DBUS_SEND="$BIN/dbus-send" CBS_ORIGINAL="$ORIG" "$ROOT/uninstall-cbs.sh" 2>&1; }
out=$(run_cbs)
check "uninstall-cbs.sh puts back the recorded list, not the measured one" \
    '4370,4372,4378,4383,4385,4391,4396-4397' "$(cat "$ST/topics")"
check "and uses the record up" "" "$(records)"
fresh stub
mkdir -p "$ORIG"; printf '%s' '4383' > "$ORIG/cbs-topics-262019876543210.value"
printf '%s' "$OURS26" > "$ST/topics"
run_cbs >/dev/null
check "a recorded list that differs from the measured one wins" '4383' "$(cat "$ST/topics")"
fresh stub
printf '%s' "$OURS26" > "$ST/topics"
out=$(run_cbs)
check "without a record it still falls back to the measured list" \
    '4370,4372,4378,4383,4385,4391,4396-4397' "$(cat "$ST/topics")"
check "and calls it a guess" yes "$(printf '%s' "$out" | grep -q 'a guess' && echo yes || echo no)"

# --- oFono's TechnologyPreference -------------------------------------------
printf "\n== oFono's preference\n"
for orig in lte umts nr; do
    fresh stub
    echo "$orig" > "$ST/pref"
    mc nr on >/dev/null 2>&1
    check "$orig: recorded at the first nr on" "$orig" "$(cat "$ORIG/ofono-technology-preference.value" 2>/dev/null)"
    mc nr on >/dev/null 2>&1
    check "$orig: a second nr on keeps the first record" "$orig" \
        "$(cat "$ORIG/ofono-technology-preference.value" 2>/dev/null)"
    mc nr off >/dev/null 2>&1
    check "$orig: nr off puts exactly it back" "$orig" "$(cat "$ST/pref")"
    check "$orig: and uses the record up" "" "$(records)"
done

fresh stub
mc nr on >/dev/null 2>&1
echo gsm > "$ST/pref"
out=$(mc nr off 2>&1)
check "a preference changed since nr on is left alone" gsm "$(cat "$ST/pref")"
check "and it says so" yes "$(printf '%s' "$out" | grep -q 'changed since 5G was switched on' && echo yes || echo no)"

fresh stub
mc nr on >/dev/null 2>&1
touch "$ST/hal-down"
mc nr off >/dev/null 2>&1
check "nr off puts the preference back even when the HAL does not answer" lte "$(cat "$ST/pref")"

fresh stub
echo nr > "$ST/pref"; echo on > "$W/etc/nr"
out=$(mc nr off 2>&1)
check "without a record nr off still goes to lte" lte "$(cat "$ST/pref")"
check "and says it is assuming" yes "$(printf '%s' "$out" | grep -q 'assuming lte' && echo yes || echo no)"

# --- the SIM drop-in --------------------------------------------------------
printf '\n== the SIM slot drop-in\n'
fresh stub
printf '[Settings]\nExpectSlots = slot2\n' > "$W/etc/ofono/binder.d/zz-furios-sim.conf"
mc sim 1 --no-restart >/dev/null 2>&1
check "a drop-in modemctl did not write is not deleted" yes \
    "$([ -f "$W/etc/ofono/binder.d/zz-furios-sim.conf" ] && echo yes || echo no)"

# --- uninstall --------------------------------------------------------------
printf '\n== uninstall.sh\n'
check "nr off also runs when only the preference record is left" 1 \
    "$(grep -c 'ofono-technology-preference.value' "$ROOT/uninstall.sh")"
check "records that could not be used are reported before they go" 1 \
    "$(grep -c 'Not put back - recorded before the first change' "$ROOT/uninstall.sh")"
check "the package's prerm puts the preference back too" 1 \
    "$(grep -c 'modemctl nr off' "$ROOT/packaging/build-deb.sh")"

summary
