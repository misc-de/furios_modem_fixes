#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
#
# Defect 25: oFono's MTK plugin, built on the phone and put in with
# dpkg-divert. What has to hold:
#   - a build is only ever put in front of the shipped plugin it was made for,
#   - a package update under the diversion is noticed (stale) and undone,
#   - going back leaves exactly the shipped file where it was,
#   - the apt hook rebuilds before boot looks, never the other way round.
# dpkg-divert is a stand-in that keeps its list in a file; nothing here
# touches /usr/lib or the dpkg database.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
. "$HERE/lib.sh"

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
BIN="$WORK/bin"; mkdir -p "$BIN" "$WORK/plugins"
LIST="$WORK/diversions"

make_divert_stub "$BIN/dpkg-divert" "$LIST"

PLUGIN="$WORK/plugins/mtkbinderpluginext.so"
BUILD="$WORK/build"
MTK_PLUGIN=$PLUGIN MTK_BUILD=$BUILD DIVERT="$BIN/dpkg-divert"

# The MTK block of modemctl, and nothing else of it: from its heading to the
# command that builds (which needs the rest of the script).
eval "$(sed -n '/^# --- MTK plugin (defect 25)/,/^cmd_mtk_build()/p' "$ROOT/modemctl" | sed '$d')"

ship() { printf 'shipped %s\n' "$1" > "$PLUGIN"; }
build_for() {
    mkdir -p "$BUILD"
    printf 'ours\n' > "$BUILD/mtkbinderpluginext.so"
    sha256sum "$1" | cut -d' ' -f1 > "$BUILD/built-for"
}

check "no plugin at all: absent" absent "$(mtk_state)"

ship 1.0
check "shipped plugin, nothing built: unbuilt" unbuilt "$(mtk_state)"

build_for "$PLUGIN"
check "a build for exactly this plugin: missing" missing "$(mtk_state)"

check_status "putting it in works" 0 mtk_install
check "then: applied" applied "$(mtk_state)"
check "ours is in place" "ours" "$(cat "$PLUGIN")"
check "the shipped one is kept as .distrib" "shipped 1.0" "$(cat "$PLUGIN.distrib")"
check_status "a second install changes nothing" 0 mtk_install
check "still applied" applied "$(mtk_state)"

# A package update with our diversion in place writes the .distrib.
ship_update() { printf 'shipped %s\n' "$1" > "$PLUGIN.distrib"; }
ship_update 1.1
check "package updated underneath: stale" stale "$(mtk_state)"

check_status "undoing a stale build works" 0 mtk_undivert
check "the updated shipped plugin is back in place" "shipped 1.1" "$(cat "$PLUGIN")"
check "no .distrib left behind" no "$([ -e "$PLUGIN.distrib" ] && echo yes || echo no)"
check "no diversion left" "" "$(cat "$LIST")"
check "the old build does not fit the new plugin: unbuilt" unbuilt "$(mtk_state)"

# A build that is in place but differs (rebuilt with another build id).
build_for "$PLUGIN"; mtk_install
printf 'ours, rebuilt\n' > "$BUILD/mtkbinderpluginext.so"
check "a new build for the same plugin: missing again" missing "$(mtk_state)"
mtk_install
check "and put in: applied" applied "$(mtk_state)"
check "with the new build" "ours, rebuilt" "$(cat "$PLUGIN")"

mtk_undivert
check "revert: shipped file back byte for byte" "shipped 1.1" "$(cat "$PLUGIN")"
check "revert twice is harmless" 0 "$(mtk_undivert; echo $?)"

# Fixed upstream: mtk-build left upstream-fixed for this plugin.
rm -f "$BUILD/mtkbinderpluginext.so" "$BUILD/built-for"
sha256sum "$PLUGIN" | cut -d' ' -f1 > "$BUILD/upstream-fixed"
check "the shipped plugin has the fix: upstream" upstream "$(mtk_state)"

# The apt hook: mtk-build --if-stale must come before boot. The other way
# round boot removes the outdated build and there is nothing stale to rebuild.
hook=$(grep -n 'modemctl' "$ROOT/apt/99furios-modem-fixes" | grep -v '^[0-9]*://')
b=$(printf '%s\n' "$hook" | grep -n 'mtk-build --quiet --if-stale' | cut -d: -f1)
a=$(printf '%s\n' "$hook" | grep -n 'modemctl boot' | cut -d: -f1)
check "apt hook rebuilds an outdated MTK plugin" yes "$([ -n "$b" ] && echo yes || echo no)"
check "and does so before boot" yes "$([ -n "$b" ] && [ -n "$a" ] && [ "$b" -lt "$a" ] && echo yes || echo no)"

summary
