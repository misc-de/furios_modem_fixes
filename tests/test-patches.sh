#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
#
# The patches are the product. If one of them stops reproducing the file we
# actually ship, everything else in this repository is decoration.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
. "$HERE/lib.sh"

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
FILES="utils mm_bearer mm_modem mm_modem_simple mm_modem_signal main"

# main.py sits beside the module directory rather than in it, exactly as it
# does on the phone - the patches carry those paths and have to find them.
sub_path() {
    case "$1" in
        main) echo "main.py" ;;
        *)    echo "ofono2mm/$1.py" ;;
    esac
}

mkdir -p "$WORK/ofono2mm"
for f in $FILES; do cp "$ROOT/original-files/$f.py" "$WORK/$(sub_path "$f")"; done

for f in $FILES; do
    if patch -s -f -p1 -d "$WORK" < "$ROOT/patches/ofono2mm-$f.patch" 2>/dev/null; then
        ok "$f.py: patch applies to the shipped file"
        TESTS_RUN=$((TESTS_RUN + 1))
    else
        TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAILED=$((TESTS_FAILED + 1))
        fail "$f.py: patch does not apply to the shipped file"
        continue
    fi
    # Not "it applied" but "it produced exactly what we ship". A patch can
    # apply with fuzz and land in the wrong place.
    if diff -q "$WORK/$(sub_path "$f")" "$ROOT/patched-files/$f.py" >/dev/null; then
        ok "$f.py: result is byte-for-byte the shipped patched file"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        fail "$f.py: result differs from patched-files/$f.py"
    fi
    TESTS_RUN=$((TESTS_RUN + 1))
done

# modemctl revert applies every patch backwards. If that is not clean, the
# uninstall path leaves a half-reverted file behind - worse than either state.
for f in $FILES; do
    TESTS_RUN=$((TESTS_RUN + 1))
    if patch -R -s -f --dry-run -p1 -d "$WORK" < "$ROOT/patches/ofono2mm-$f.patch" >/dev/null 2>&1; then
        ok "$f.py: reverts cleanly"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        fail "$f.py: cannot be reverted"
    fi
done

# A patched file that does not parse takes the whole modem stack down at the
# next start, and the phone has no modem until someone notices.
for f in $FILES; do
    TESTS_RUN=$((TESTS_RUN + 1))
    if python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$ROOT/patched-files/$f.py" 2>/dev/null; then
        ok "$f.py: parses"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        fail "$f.py: syntax error"
    fi
done

# Every patch must be known to modemctl, or apply silently skips it forever.
listed=$(grep -m1 '^FILES=' "$ROOT/modemctl" | cut -d'"' -f2)
for p in "$ROOT"/patches/ofono2mm-*.patch; do
    name=$(basename "$p" .patch); name=${name#ofono2mm-}
    TESTS_RUN=$((TESTS_RUN + 1))
    case " $listed " in
        *" $name "*) ok "modemctl knows about $name" ;;
        *) TESTS_FAILED=$((TESTS_FAILED + 1)); fail "modemctl's FILES list is missing $name" ;;
    esac
done

summary
