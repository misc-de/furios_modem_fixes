# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
# A test harness small enough to read in one sitting.
#
# No framework on purpose: this has to run on the phone itself, where every
# extra dependency is one more thing that can be missing at the moment you
# need the tests most.

TESTS_RUN=0
TESTS_FAILED=0

ok()   { printf '  \033[32mok\033[0m   %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }

check() {
    # check <description> <expected> <actual>
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$2" = "$3" ]; then
        ok "$1"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        fail "$1" "expected [$2], got [$3]"
    fi
}

check_status() {
    # check_status <description> <expected exit code> <command...>
    local desc=$1 want=$2; shift 2
    TESTS_RUN=$((TESTS_RUN + 1))
    "$@" >/dev/null 2>&1
    local got=$?
    if [ "$got" = "$want" ]; then
        ok "$desc"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        fail "$desc" "expected exit $want, got $got"
    fi
}

summary() {
    printf '\n  %d checks, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
    [ "$TESTS_FAILED" -eq 0 ]
}

# Put a stub on PATH that prints whatever the test wants it to print.
#
# The point is to pin down what these tools do with the *output* of mmcli,
# dbus-send and ip, without a modem anywhere near them - and without a test
# that only passes on a phone that happens to be registered right now.
make_stub() {
    # make_stub <name> <exit code> <stdout...>
    #
    # No output means no output - not an empty line. The difference matters:
    # "mmcli -L" with no modem prints zero bytes, and a stub that printed a
    # blank line instead would let an empty-line-tolerant check pass a test it
    # should fail.
    local name=$1 code=$2; shift 2
    {
        printf '#!/bin/sh\n'
        if [ -n "$*" ]; then
            printf "cat <<'OUT'\n%s\nOUT\n" "$*"
        fi
        printf 'exit %s\n' "$code"
    } > "$STUBDIR/$name"
    chmod +x "$STUBDIR/$name"
}

# The same, but it also writes down how it was called.
#
# Sometimes what matters is not what a command answered but that it was asked
# at all, and with what - "every dbus-send carried --print-reply" is exactly
# that kind of check, and no answer from a stub can show it.
make_recording_stub() {
    # make_recording_stub <name> <exit code> <stdout...>
    local name=$1 code=$2; shift 2
    {
        printf '#!/bin/sh\n'
        printf 'printf "%%s\\n" "$*" >> "%s/%s.args"\n' "$STUBDIR" "$name"
        if [ -n "$*" ]; then
            printf "cat <<'OUT'\n%s\nOUT\n" "$*"
        fi
        printf 'exit %s\n' "$code"
    } > "$STUBDIR/$name"
    chmod +x "$STUBDIR/$name"
}

# A dpkg-divert that keeps its list in a file, for --truename and for
# --add/--remove with --rename, the way modemctl calls it. Like the real one,
# --remove --rename refuses to move the .distrib over a file that is there.
# Nothing here may touch the dpkg database of the machine running the tests.
make_divert_stub() {
    # make_divert_stub <path of the stub> <list file>
    local stub=$1 list=$2
    : > "$list"
    cat > "$stub" <<STUB
#!/bin/bash
list="$list"; op=; to=; path=
while [ \$# -gt 0 ]; do
    case "\$1" in
        --truename) op=truename ;;
        --add) op=add ;;
        --remove) op=remove ;;
        --divert) to=\$2; shift ;;
        --local|--rename) ;;
        *) path=\$1 ;;
    esac
    shift
done
case "\$op" in
    truename) t=\$(awk -v p="\$path" '\$1 == p { print \$2 }' "\$list")
              echo "\${t:-\$path}" ;;
    add)      grep -q "^\$path " "\$list" && exit 0
              [ -e "\$path" ] && mv "\$path" "\$to"
              echo "\$path \$to" >> "\$list" ;;
    remove)   t=\$(awk -v p="\$path" '\$1 == p { print \$2 }' "\$list")
              [ -n "\$t" ] || exit 0
              [ -e "\$path" ] && { echo "would overwrite \$path" >&2; exit 1; }
              [ -e "\$t" ] && mv "\$t" "\$path"
              grep -v "^\$path " "\$list" > "\$list.new"; mv "\$list.new" "\$list" ;;
esac
STUB
    chmod +x "$stub"
}
