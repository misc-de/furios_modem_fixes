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

# --- every modemctl run is sandboxed ----------------------------------------
#
# modemctl reads and writes /etc, /usr/lib and /var/lib unless told otherwise,
# one MODEMCTL_* override per path. Setting them call by call is how a test
# came to run "set fixed" without MODEMCTL_SYSTEMD_CONF_D and reach into the
# real /etc/systemd/system: one forgotten variable among twenty-five, on one
# call among hundreds. So it is not left to the call.
#
#   modemctl_sandbox <dir>   exports every override, pointing under <dir>,
#                            and $MODEMCTL - the only way a test runs modemctl
#   $MODEMCTL ...            refuses to start modemctl while any override is
#                            unset or empty, and takes the whole test down
#
# Both read the list from modemctl's own root guard, so a new override is
# required by the harness the moment it is added there - and modemctl_sandbox
# aborts when it has no sandbox path for one. tests/test-harness.sh holds that
# no test runs modemctl any other way.
#
# A test that must run modemctl without them - "settle" plays root, and root
# refuses every override - says so: unsandboxed <reason> <command...>.
LIB_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

modemctl_overrides() {
    sed -n '/for v in MODEMCTL_/,/do$/p' "$LIB_ROOT/modemctl" | grep -oE 'MODEMCTL_[A-Z_]+' | sort -u
}

harness_abort() {
    printf '\n  \033[31mABORT\033[0m %s\n' "$*" >&2
    exit 99
}
# The wrapper runs in a child, often inside $(...): it cannot end the test
# itself, so it signals the test's own shell.
MODEMCTL_TEST_PID=$$
export MODEMCTL_TEST_PID
trap 'harness_abort "modemctl was started outside the sandbox - see the line above"' USR1

modemctl_sandbox() {
    local d=$1 v p
    mkdir -p "$d/bin" "$d/var/lib/dpkg" || harness_abort "cannot make the sandbox $d"
    make_divert_stub "$d/bin/dpkg-divert" "$d/var/lib/dpkg/diversions"
    for v in $(modemctl_overrides); do
        case "$v" in
            MODEMCTL_TARGET)         p="$d/usr/lib/ofono2mm/ofono2mm" ;;
            MODEMCTL_RADIO_CONF)     p="$d/etc/ofono/binder.d/radio-interface-binder.conf" ;;
            MODEMCTL_SHARE)          p="$LIB_ROOT" ;;
            MODEMCTL_PATCHES)        p="$LIB_ROOT/patches" ;;
            MODEMCTL_NM_CONF_D)      p="$d/etc/NetworkManager/conf.d" ;;
            MODEMCTL_RESOLV)         p="$d/etc/resolv.conf" ;;
            MODEMCTL_NM_RESOLV)      p="$d/run/NetworkManager/resolv.conf" ;;
            MODEMCTL_DBUS_CONF_D)    p="$d/etc/dbus-1/system.d" ;;
            MODEMCTL_CBS_DB)         p="$d/usr/share/mobile-broadband-provider-info/serviceproviders.xml" ;;
            MODEMCTL_PROFILE)        p="$d/etc/furios-modem-fixes.profile" ;;
            MODEMCTL_SYSTEMD_CONF_D) p="$d/etc/systemd/system" ;;
            # A unit name, not a path - but an override all the same.
            MODEMCTL_SHELL_SYSTEM_UNIT) p=phosh.service ;;
            MODEMCTL_SIM)            p="$d/etc/furios-modem-fixes.sim" ;;
            MODEMCTL_SIM_NAMES)      p="$d/var/lib/furios-modem-fixes/sim-names" ;;
            MODEMCTL_SIM_LOCK)       p="$d/run/furios-modem-fixes.sim.lock" ;;
            MODEMCTL_SIM_DROPIN)     p="$d/etc/ofono/binder.d/zz-furios-sim.conf" ;;
            MODEMCTL_NR)             p="$d/etc/furios-modem-fixes.nr" ;;
            # Not there: the radio HAL is never asked unless a test stubs it.
            MODEMCTL_NRPROBE)        p="$d/no-nrprobe/nrprobe" ;;
            MODEMCTL_ORIGINAL)       p="$d/var/lib/furios-modem-fixes/original" ;;
            MODEMCTL_MTK_PLUGIN)     p="$d/usr/lib/no-mtk/mtkbinderpluginext.so" ;;
            MODEMCTL_MTK_BUILD)      p="$d/var/lib/furios-modem-mtk" ;;
            MODEMCTL_DIVERT)         p="$d/bin/dpkg-divert" ;;
            MODEMCTL_WATCH_MARK)     p="$d/run/furios-modem-fixes.watchers" ;;
            MODEMCTL_DPKG_INFO)      p="$d/var/lib/dpkg/info" ;;
            *) harness_abort "modemctl knows $v, tests/lib.sh has no sandbox path for it" ;;
        esac
        export "$v=$p"
    done
    cat > "$d/bin/modemctl" <<WRAP
#!/bin/bash
missing=
for v in \$(sed -n '/for v in MODEMCTL_/,/do\$/p' "$LIB_ROOT/modemctl" | grep -oE 'MODEMCTL_[A-Z_]+' | sort -u); do
    [ -n "\${!v:-}" ] || missing="\$missing \$v"
done
if [ -n "\$missing" ] && [ -z "\${MODEMCTL_TEST_UNSANDBOXED:-}" ]; then
    printf '  \\033[31mABORT\\033[0m modemctl %s without%s\\n' "\$*" "\$missing" >&2
    kill -USR1 "\${MODEMCTL_TEST_PID:-0}" 2>/dev/null
    exit 99
fi
exec bash "$LIB_ROOT/modemctl" "\$@"
WRAP
    chmod +x "$d/bin/modemctl"
    MODEMCTL="$d/bin/modemctl"
    export MODEMCTL
}

# unsandboxed <reason> <command...>: with no override at all, said out loud.
unsandboxed() {
    local reason=$1 v; shift
    local args=()
    for v in $(modemctl_overrides); do args+=(-u "$v"); done
    env "${args[@]}" MODEMCTL_TEST_UNSANDBOXED="$reason" "$@"
}
