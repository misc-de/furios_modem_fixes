#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
#
# Builds oFono's MTK plugin (ofono-binder-plugin-ext-mtk) with our fix for a
# refused VoLTE call that stays "dialing" for ever - see
# upstream/ofono-binder-plugin-ext-mtk-1-phantom-dialing.md.
#
#   build.sh PATCH OUTDIR
#
# The source is exactly the commit the installed package was built from: its
# version carries the short git hash (…+git20250826014945.837f943.forky…). Writes
# OUTDIR/mtkbinderpluginext.so and OUTDIR/built-for, the sha256 of the shipped
# plugin it replaces - modemctl only ever installs a build whose built-for
# matches what the package has on disk now, so after a package update an old
# build is never put in front of a newer oFono.
#
# Exit 0 built, 2 the fix is already upstream (nothing to build, OUTDIR holds
# upstream-fixed instead), 1 anything else. Run as root, it does the fetching
# and compiling as nobody: root only reads the result.
set -eu

PATCH=$(readlink -f "$1")
OUT=$2
PKG=ofono-binder-plugin-ext-mtk
REPO=${MTK_REPO:-https://github.com/FuriLabs/ofono-binder-plugin-ext-mtk}
MULTIARCH=$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || gcc -dumpmachine)
PLUGIN=/usr/lib/$MULTIARCH/ofono/plugins/mtkbinderpluginext.so

die() { echo "mtk build: $*" >&2; exit 1; }

version=$(dpkg-query -W -f='${Version}' "$PKG" 2>/dev/null) || die "$PKG is not installed"
[[ $version =~ git[0-9]{8,14}\.([0-9a-f]{7,40}) ]] || die "no git hash in version $version"
commit=${BASH_REMATCH[1]}

# With our diversion in place the package's own file is the .distrib.
stock=$PLUGIN
[ "$(dpkg-divert --truename "$PLUGIN")" = "$PLUGIN.distrib" ] && stock=$PLUGIN.distrib
[ -f "$stock" ] || die "$stock not found"
built_for=$(sha256sum "$stock" | cut -d' ' -f1)

missing=
for t in git make gcc pkg-config dpkg-buildflags patch strip; do
    command -v "$t" >/dev/null || missing="$missing $t"
done
for m in libofonobinderpluginext libgbinder-radio libgbinder libglibutil libandroid-properties ofono; do
    pkg-config --exists "$m" 2>/dev/null || missing="$missing $m(pc)"
done
[ -z "$missing" ] || die "missing:$missing - apt install git make gcc pkg-config \
libofonobinderpluginext-dev libgbinder-radio-dev ofono-dev libandroid-properties-dev"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
as_builder() { "$@"; }
if [ "$(id -u)" -eq 0 ]; then
    chown nobody:nogroup "$work"
    as_builder() { setpriv --reuid=nobody --regid=nogroup --clear-groups \
        env HOME="$work" "$@"; }
fi
cp "$PATCH" "$work/fix.patch" && chmod 644 "$work/fix.patch"

as_builder git clone -q "$REPO" "$work/src" || die "could not fetch $REPO"
as_builder git -C "$work/src" -c advice.detachedHead=false checkout -q "$commit" \
    || die "commit $commit not in $REPO"

mkdir -p "$OUT"
rm -f "$OUT/mtkbinderpluginext.so" "$OUT/built-for" "$OUT/upstream-fixed"
if as_builder patch -R -s -f --dry-run -p1 -d "$work/src" < "$work/fix.patch" >/dev/null 2>&1; then
    echo "$built_for" > "$OUT/upstream-fixed"
    echo "mtk build: $PKG $version already has the fix - nothing to build"
    exit 2
fi
as_builder patch -s -f -p1 -d "$work/src" < "$work/fix.patch" \
    || die "the fix does not fit $PKG $version - upstream moved"
# 837f943 misses a space before -I in its Makefile; harmless where it is not.
as_builder sed -i 's/\(--cflags $(PKGS))\)-I/\1 -I/' "$work/src/Makefile"
# gcc 15 defaults to C23, where mtk_radio_ext_new_req_id() takes no arguments.
as_builder make -s -C "$work/src" release LIBDIR="usr/lib/$MULTIARCH" \
    CFLAGS="-std=gnu17 $(dpkg-buildflags --get CFLAGS)" \
    LDFLAGS="$(dpkg-buildflags --get LDFLAGS)" >/dev/null 2>"$work/build.log" \
    || { tail -20 "$work/build.log" >&2; die "build failed"; }

so=$work/src/build/release/mtkbinderpluginext.so
[ -f "$so" ] || die "build produced no plugin"
install -m644 "$so" "$OUT/mtkbinderpluginext.so"
strip --strip-unneeded "$OUT/mtkbinderpluginext.so"
echo "$built_for" > "$OUT/built-for"
echo "mtk build: $PKG $version ($commit) built with the fix"
