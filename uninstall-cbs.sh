#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
# Puts oFono's cell broadcast channel list back to what it was before our first
# change - recorded, not assumed.
#
# The list is nothing install.sh writes: with our bus policy in place,
# cellbroadcastd sets it through ModemManager, and oFono keeps it in
# /var/lib/ofono/<IMSI>/cbs. Removing the policy does not take it back - on the
# shipped policy cellbroadcastd is refused and nobody ever writes the list
# again, so our 26 channels would outlive the uninstall for good.
#
# Only a list that is exactly one of ours is touched; any other one was chosen
# by somebody else. Through oFono, not by editing the file: oFono rewrites it
# from memory, and a file edited under a running oFono is overwritten.
#
# What it goes back to is what modemctl apply recorded for this SIM before its
# first change (/var/lib/furios-modem-fixes/original/cbs-topics-<IMSI>.value).
# "modemctl revert" - which uninstall.sh runs first - already uses that record
# and drops it, so on a phone set up by this version there is normally
# nothing left to do here. What is left is the phone an older version set up,
# which recorded nothing: then the list measured on the developer's phone
# before the first apply is all there is, and it is said to be a guess.
#
# DBUS_SEND and CBS_ORIGINAL may name stand-ins for tests.
DBUS_SEND=${DBUS_SEND:-dbus-send}
ORIG_DIR=${CBS_ORIGINAL:-/var/lib/furios-modem-fixes/original}

# What one phone listened to before (FINDINGS.md, 13.9.2026, before apply).
# NOT a record: only the fallback when there is none.
MEASURED='4370,4372,4378,4383,4385,4391,4396-4397'
# After the bus policy alone (4372 lost), and after the serviceproviders.xml fix.
OURS=('919,4370-4371,4373-4392,4396-4397' '919,4370-4392,4396-4397')

ofono() {
    timeout 5 "$DBUS_SEND" --system --print-reply --dest=org.ofono "$@" 2>/dev/null
}

is_ours() {
    local o
    for o in "${OURS[@]}"; do [ "$1" = "$o" ] && return 0; done
    return 1
}

set_topics() {
    ofono "$1" org.ofono.CellBroadcast.SetProperty \
        string:Topics variant:string:"$2" >/dev/null
}

modems=$(ofono / org.ofono.Manager.GetModems \
    | sed -n 's/^ *object path "\(.*\)"$/\1/p')
if [ -z "$modems" ]; then
    echo "oFono is not answering - cell broadcast channels left as they are." >&2
    exit 0
fi

rc=0
for m in $modems; do
    reply=$(ofono "$m" org.ofono.CellBroadcast.GetProperties)
    printf '%s\n' "$reply" | grep -q '"Topics"' || continue
    topics=$(printf '%s\n' "$reply" | grep -A1 '"Topics"' \
        | sed -n 's/.*variant *string "\(.*\)".*/\1/p' | head -1)
    imsi=$(ofono "$m" org.ofono.SimManager.GetProperties | grep -A1 '"SubscriberIdentity"' \
        | sed -n 's/.*variant *string "\([0-9]*\)".*/\1/p' | head -1)
    rec_file="$ORIG_DIR/cbs-topics-$imsi.value"
    if [ -n "$imsi" ] && [ -f "$rec_file" ]; then
        rec=$(cat "$rec_file")
        if [ "$topics" = "$rec" ]; then
            :
        elif is_ours "$topics"; then
            if set_topics "$m" "$rec"; then
                echo "$m: cell broadcast channels back to ${rec:-none}, as recorded before the first apply"
            else
                echo "$m: could not put the cell broadcast channels back - the record stays" >&2
                rc=1
                continue
            fi
        else
            echo "$m: cell broadcast channels were changed since apply (now: $topics) - left as they are;" >&2
            echo "$m: before the first apply they were: ${rec:-none}" >&2
        fi
        rm -f "$rec_file"
        continue
    fi
    is_ours "$topics" || continue
    echo "$m: no record of the channels from before the first apply (an older version set this up)" >&2
    echo "$m: falling back to the list measured on one phone on 13.9.2026 - a guess for any other" >&2
    if set_topics "$m" "$MEASURED"; then
        echo "$m: cell broadcast channels back to $MEASURED"
    else
        echo "$m: could not put the cell broadcast channels back" >&2
        rc=1
    fi
done
exit $rc
