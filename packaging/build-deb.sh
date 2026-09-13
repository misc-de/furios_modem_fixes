#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
# Builds a .deb from the work tree. Architecture-independent - this ships
# patches and two scripts, nothing compiled.
set -e
cd "$(dirname "$0")/.."
ROOT=$(pwd)

PKG="furios-modem-fixes"
# The commit COUNT leads the version, not the hash: dpkg compares digit runs
# numerically and anything else as text, so a hash would decide the order
# between two builds - and hashes are not monotonic.
COUNT=$(git rev-list --count HEAD 2>/dev/null || echo 0)
DATE=$(git log -1 --format=%cd --date=format:%Y%m%d 2>/dev/null || date +%Y%m%d)
HASH=$(git rev-parse --short HEAD 2>/dev/null || echo 0)
VERSION="0.1.0+git$COUNT.$DATE.$HASH"
[ -n "$(git status --porcelain 2>/dev/null)" ] && VERSION="$VERSION+dirty$(date +%Y%m%d%H%M%S)"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
# mktemp makes it 0700, and that mode travels into the package as the mode of
# "./". Nothing should be able to learn the root directory's permissions from
# a package of ours.
chmod 755 "$STAGE"
echo "package $PKG $VERSION (all)"

install -Dm755 modemctl                  "$STAGE/usr/bin/modemctl"
install -Dm755 tools/furios-modem-signal "$STAGE/usr/bin/furios-modem-signal"
install -Dm755 tools/furios-modem-signal "$STAGE/usr/share/furios-modem/tools/furios-modem-signal"
install -Dm755 tools/furios-mobile-route "$STAGE/usr/bin/furios-mobile-route"
install -Dm755 tools/furios-mobile-route "$STAGE/usr/share/furios-modem/tools/furios-mobile-route"
install -Dm755 tools/furios-mobile-context "$STAGE/usr/bin/furios-mobile-context"
install -Dm755 tools/furios-mobile-context "$STAGE/usr/share/furios-modem/tools/furios-mobile-context"

for p in patches/*.patch; do
    install -Dm644 "$p" "$STAGE/usr/share/furios-modem/$p"
done
# The rescue path for the day a patch stops fitting: modemctl points at these
# instead of forcing a patch into a file that has moved underneath it.
for f in patched-files/*; do
    [ -f "$f" ] || continue   # a test run can leave a __pycache__ here
    install -Dm644 "$f" "$STAGE/usr/share/furios-modem/$f"
done

install -Dm644 networkmanager/99-furios-modem-resolvconf.conf \
    "$STAGE/usr/share/furios-modem/networkmanager/99-furios-modem-resolvconf.conf"
# Shipped as a template under /usr/share and put in place by apply, not
# installed straight into /etc/dbus-1/system.d: revert has to be able to take
# it away again, and dpkg would keep putting a conffile back.
install -Dm644 dbus/furios-modem-cellbroadcast.conf \
    "$STAGE/usr/share/furios-modem/dbus/furios-modem-cellbroadcast.conf"
install -Dm644 systemd/furios-modem-fixes.service \
    "$STAGE/usr/lib/systemd/system/furios-modem-fixes.service"
install -Dm644 systemd/furios-mobile-route.service \
    "$STAGE/usr/lib/systemd/system/furios-mobile-route.service"
install -Dm644 systemd/furios-mobile-context.service \
    "$STAGE/usr/lib/systemd/system/furios-mobile-context.service"
install -Dm644 apt/99furios-modem-fixes \
    "$STAGE/etc/apt/apt.conf.d/99furios-modem-fixes"
# Straight into place, not under /usr/share/furios-modem: polkit reads its
# actions from this directory only, and the file describes what the package's
# own /usr/bin/modemctl is allowed to do - so it belongs to the package and
# goes away with it.
install -Dm644 polkit/de.misc-de.modemctl.policy \
    "$STAGE/usr/share/polkit-1/actions/de.misc-de.modemctl.policy"

install -Dm644 README.md   "$STAGE/usr/share/doc/$PKG/README.md"
install -Dm644 FINDINGS.md "$STAGE/usr/share/doc/$PKG/FINDINGS.md"
install -Dm644 LICENSE     "$STAGE/usr/share/doc/$PKG/LICENSE"
install -Dm644 NOTICE      "$STAGE/usr/share/doc/$PKG/NOTICE"

# The patches are diffs against ofono2mm's own files, so they carry ofono2mm's
# licences - BSD-3-Clause for five of them, GPL-2.0 for mm_modem_signal.py.
# The package as a whole is therefore GPL-2.0, whatever our own scripts are.
cat > "$STAGE/usr/share/doc/$PKG/copyright" <<'COPY'
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: furios_modem_fixes
Source: https://github.com/misc-de/furios_modem_fixes

Files: *
Copyright: 2026 misc-de
License: MIT

Files: patches/ofono2mm-utils.patch
       patches/ofono2mm-mm_bearer.patch
       patches/ofono2mm-mm_modem.patch
       patches/ofono2mm-mm_modem_simple.patch
       patches/ofono2mm-main.patch
       patched-files/utils.py
       patched-files/mm_bearer.py
       patched-files/mm_modem.py
       patched-files/mm_modem_simple.py
       patched-files/main.py
Copyright: 2023 Erik Inkinen <erik.inkinen@gmail.com>
           2025 Bardia Moshiri <fakeshell@bardia.tech>
           2026 misc-de
Comment: Modifications to files of the ofono2mm package, which carries these
 files under BSD-3-Clause.
License: BSD-3-Clause

Files: patches/ofono2mm-mm_modem_signal.patch
       patched-files/mm_modem_signal.py
Copyright: 2025 Bardia Moshiri <fakeshell@bardia.tech>
           2025 Jesus Higueras <jesus@dabbleam.com>
           2026 misc-de
Comment: Modifications to ofono2mm/mm_modem_signal.py, which ofono2mm
 distributes under GPL-2.0. The package as a whole is therefore GPL-2.0.
License: GPL-2.0

License: MIT
 Permission is hereby granted, free of charge, to any person obtaining a
 copy of this software and associated documentation files (the "Software"),
 to deal in the Software without restriction, including without limitation
 the rights to use, copy, modify, merge, publish, distribute, sublicense,
 and/or sell copies of the Software, and to permit persons to whom the
 Software is furnished to do so, subject to the following conditions:
 .
 The above copyright notice and this permission notice shall be included
 in all copies or substantial portions of the Software.
 .
 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
 OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
 MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
 IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
 CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
 TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
 SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

License: BSD-3-Clause
 On Debian systems the full text is in
 /usr/share/common-licenses/BSD.

License: GPL-2.0
 On Debian systems the full text is in
 /usr/share/common-licenses/GPL-2.
COPY
chmod 644 "$STAGE/usr/share/doc/$PKG/copyright"

mkdir -p "$STAGE/DEBIAN"
# Depends carries the programs the services refuse to run without, not just
# the ones the patches belong to. Both watchers check for theirs by hand and
# exit on the first line when one is missing - dbus-send and dbus-monitor for
# the context supervisor, ip and mmcli for the route watcher - and modemctl
# asks nmcli for the cellular profile and has to restart NetworkManager after
# a ModemManager restart. A package that installs cleanly and leaves a service
# dying on its first line is worse than one that refuses to install.
# "dbus-bin | dbus" because the two dbus tools moved out of the dbus package
# and an older system still has them there.
cat > "$STAGE/DEBIAN/control" <<CONTROL
Package: $PKG
Version: $VERSION
Architecture: all
Maintainer: misc-de <11610690+misc-de@users.noreply.github.com>
Section: net
Priority: optional
Depends: ofono2mm, ofono, patch, python3, python3-dbus, modemmanager, dbus-bin | dbus, network-manager, iproute2
Description: Keeps fifteen fixes to the FuriOS modem stack applied
 Defects in ofono2mm, in oFono's binder configuration, in oFono itself, in how
 FuriOS wires up DNS, in ModemManager's own bus policy and in the database the
 emergency alert channel list comes from: a signal bar that can never leave
 zero, LTE RSRP and RSRQ reported swapped and without their sign, a missing
 netmask, a bearer that claims IPv6 it never has, a connect that can hang until
 the next reboot, mobile data with no default route and no resolver anybody
 asks, a data call that stays down once it drops, a modem offered to the shell
 with no technology and no mode, a phone with no signal icon at all, emergency
 alert channels the bus refuses to let anyone set, one such channel missing
 from the database, and a bearer that never hears its own context.
 .
 The fixes live in files owned by the ofono2mm package, so every update of
 that package removes them. This package applies them again - from a boot unit
 and from an apt hook - and refuses to touch a file whose patch no longer fits
 rather than mangling it. modemctl reports what is in place and what the radio
 really receives.
CONTROL

cat > "$STAGE/DEBIAN/postinst" <<'POST'
#!/bin/sh
set -e
if [ "$1" = configure ]; then
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable furios-modem-fixes.service >/dev/null 2>&1 || true
    # --now for the watcher: it is a long-running service, and one that is
    # installed but not started leaves the phone without a fallback route
    # until the next reboot, which is exactly the failure it exists to prevent.
    systemctl enable --now furios-mobile-route.service >/dev/null 2>&1 || true
    systemctl enable --now furios-mobile-context.service >/dev/null 2>&1 || true
    # "enable --now" does NOT restart a unit that is already running, so an
    # upgrade would install new code and leave the old process in charge - and
    # the old process is exactly the one with the bug that was just fixed.
    # try-restart touches only what is actually running.
    systemctl try-restart furios-mobile-route.service furios-mobile-context.service \
        >/dev/null 2>&1 || true
    # Apply now rather than at the next boot. Quiet, and never fatal: a
    # package that fails to configure because a patch did not fit would leave
    # dpkg half-done, which is a worse problem than an unpatched modem.
    /usr/bin/modemctl boot --quiet || \
        echo "furios-modem-fixes: could not apply everything - run 'modemctl status'" >&2
fi
exit 0
POST
chmod 755 "$STAGE/DEBIAN/postinst"

cat > "$STAGE/DEBIAN/prerm" <<'PRE'
#!/bin/sh
set -e
# Put ofono2mm's own code back while the patches are still on disk to do it
# with. After the files are gone there is nothing left to revert with, and the
# next ofono2mm update would be the only thing that could repair it.
case "$1" in
remove)
    systemctl disable --now furios-modem-fixes.service >/dev/null 2>&1 || true
    systemctl disable --now furios-mobile-route.service >/dev/null 2>&1 || true
    systemctl disable --now furios-mobile-context.service >/dev/null 2>&1 || true
    /usr/bin/modemctl revert --quiet || true
    ;;
upgrade)
    # dpkg runs this from the OLD package, before the new one is unpacked -
    # the only moment when the patches on disk still describe the files on
    # disk. Without it, a patch that CHANGED reads as "upstream moved": the
    # installed file is neither the shipped version nor what the new patch
    # produces, so it applies in neither direction and the new postinst gives
    # up. That is not hypothetical - on 2026-09-13 the fix for defect 11 could
    # not be installed onto a phone that already had this package, and the
    # file had to be copied into place by hand.
    #
    # Files only. The configuration is what the new postinst is about to set
    # again anyway, and undoing it here would mean an upgrade that stops
    # between the two halves leaves the phone without the DNS wiring, without
    # the cell broadcast policy and without the alert channel - none of which
    # the package it is upgrading from would have put back either.
    /usr/bin/modemctl revert --patches-only --quiet || true
    ;;
esac
exit 0
PRE
chmod 755 "$STAGE/DEBIAN/prerm"

rm -f "$ROOT/packaging/${PKG}_"*.deb
OUT="$ROOT/packaging/${PKG}_${VERSION}_all.deb"
dpkg-deb --root-owner-group --build "$STAGE" "$OUT" >/dev/null
echo "done: $OUT"

[ "${1:-}" = --install ] && sudo dpkg -i "$OUT"
exit 0
