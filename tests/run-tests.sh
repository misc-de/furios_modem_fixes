#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
# Everything that can be checked without a SIM in the phone.
#
# What is here: the conversions, the patches, and modemctl's judgement about
# when to leave a file alone.
#
# What is not here, and cannot be: whether the bar on the screen moves. That
# needs a radio, a cell and a look at the phone. "modemctl check" is the thing
# to run for that, on the device.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
FAILED=0

run() {
    printf '\n\033[1m== %s\033[0m\n' "$1"
    shift
    "$@" || FAILED=$((FAILED + 1))
}

run "the patches reproduce what we ship" bash "$HERE/test-patches.sh"
run "modemctl's judgement"               bash "$HERE/test-modemctl.sh"
run "signal conversions"                 python3 "$HERE/test-signal.py"
run "the modem's port list"              python3 "$HERE/test-ports.py"
run "every bearer hears its context"     python3 "$HERE/test-bearer-wiring.py"
run "the modem's own properties"        python3 "$HERE/test-radio-settings.py"
run "what the ObjectManager announces"   python3 "$HERE/test-object-manager.py"
run "taking the bus name"                python3 "$HERE/test-bus-name.py"
run "what survives a package update"     bash "$HERE/test-persistence.sh"
run "the mobile fallback route"          bash "$HERE/test-mobile-route.sh"
run "reviving the data context"          bash "$HERE/test-mobile-context.sh"

# What a file is written in is decided by its shebang, not by the directory it
# sits in. tools/ held nothing but Python until a shell script moved in there,
# and sorting by directory then reported it as broken Python.
is_python() { head -1 "$1" 2>/dev/null | grep -q 'python'; }

printf '\n\033[1m== shell scripts parse\033[0m\n'
for f in "$ROOT"/*.sh "$ROOT"/modemctl "$ROOT"/tests/*.sh "$ROOT"/packaging/*.sh \
         "$ROOT"/tools/*; do
    # -f, not -e: tools/ grows a __pycache__ directory as soon as anything
    # imports from it.
    [ -f "$f" ] || continue
    # Skip only what is actually Python, so a shell file without a shebang
    # still gets checked here rather than quietly falling through both loops.
    is_python "$f" && continue
    if bash -n "$f" 2>/dev/null; then
        printf '  \033[32mok\033[0m   %s\n' "${f#$ROOT/}"
    else
        printf '  \033[31mFAIL\033[0m %s\n' "${f#$ROOT/}"
        FAILED=$((FAILED + 1))
    fi
done

printf '\n\033[1m== python scripts parse\033[0m\n'
for f in "$ROOT"/tools/* "$ROOT"/tests/*.py; do
    # -f, not -e: tools/ grows a __pycache__ directory the moment anything
    # imports from it, and py_compile on a directory is a failure that means
    # nothing.
    [ -f "$f" ] || continue
    is_python "$f" || continue
    if python3 -m py_compile "$f" 2>/dev/null; then
        printf '  \033[32mok\033[0m   %s\n' "${f#$ROOT/}"
    else
        printf '  \033[31mFAIL\033[0m %s\n' "${f#$ROOT/}"
        FAILED=$((FAILED + 1))
    fi
done

# The boot unit is the part nobody looks at until a boot goes wrong.
printf '\n\033[1m== systemd unit\033[0m\n'
# Two complaints are expected off the device and are not defects: units this
# one is merely ordered against may not exist here, and modemctl is not
# installed until install.sh has run.
noise='Unit .* not found|Command /usr/bin/(modemctl|furios-mobile-route|furios-mobile-context) is not executable'
[ -x /usr/bin/modemctl ] && [ -x /usr/bin/furios-mobile-route ] \
    && [ -x /usr/bin/furios-mobile-context ] && noise='Unit .* not found'
if ! command -v systemd-analyze >/dev/null 2>&1; then
    printf '  \033[33mskipped\033[0m - systemd-analyze not available\n'
else
    for u in "$ROOT"/systemd/*.service; do
        [ -f "$u" ] || continue
        if systemd-analyze verify "$u" 2>&1 | grep -vE "$noise" | grep -q .; then
            printf '  \033[31mFAIL\033[0m %s\n' "$(basename "$u")"
            systemd-analyze verify "$u" 2>&1 | grep -vE "$noise" | sed 's/^/       /'
            FAILED=$((FAILED + 1))
        else
            printf '  \033[32mok\033[0m   %s\n' "$(basename "$u")"
        fi
    done
fi

# A bus policy is not like the other config files here: it is read by the
# system bus itself, and malformed XML in system.d is a complaint at boot in a
# file nobody thinks to look at. Cheap to check, so it gets checked.
printf '\n\033[1m== bus policy parses\033[0m\n'
for f in "$ROOT"/dbus/*.conf; do
    [ -f "$f" ] || continue
    if err=$(python3 -c 'import sys,xml.etree.ElementTree as E; E.parse(sys.argv[1])' "$f" 2>&1); then
        printf '  \033[32mok\033[0m   %s\n' "$(basename "$f")"
    else
        printf '  \033[31mFAIL\033[0m %s\n' "$(basename "$f")"
        printf '       %s\n' "$err"
        FAILED=$((FAILED + 1))
    fi
done

printf '\n'
if [ "$FAILED" -eq 0 ]; then
    printf '\033[32mall suites passed\033[0m\n'
else
    printf '\033[31m%d suite(s) failed\033[0m\n' "$FAILED"
fi
exit $([ "$FAILED" -eq 0 ] && echo 0 || echo 1)
