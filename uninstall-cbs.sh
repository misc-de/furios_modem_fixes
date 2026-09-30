#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
# Puts oFono's cell broadcast channel list back to what the phone shipped with.
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
# DBUS_SEND may name a stand-in for tests.
DBUS_SEND=${DBUS_SEND:-dbus-send}

# What the phone listened to before (FINDINGS.md, 13.9.2026, before apply).
SHIPPED='4370,4372,4378,4383,4385,4391,4396-4397'
# After the bus policy alone (4372 lost), and after the serviceproviders.xml fix.
OURS=('919,4370-4371,4373-4392,4396-4397' '919,4370-4392,4396-4397')

ofono() {
    timeout 5 "$DBUS_SEND" --system --print-reply --dest=org.ofono "$@" 2>/dev/null
}

modems=$(ofono / org.ofono.Manager.GetModems \
    | sed -n 's/^ *object path "\(.*\)"$/\1/p')
if [ -z "$modems" ]; then
    echo "oFono is not answering - cell broadcast channels left as they are." >&2
    exit 0
fi

rc=0
for m in $modems; do
    topics=$(ofono "$m" org.ofono.CellBroadcast.GetProperties \
        | grep -A1 '"Topics"' | sed -n 's/.*variant *string "\(.*\)".*/\1/p' | head -1)
    for o in "${OURS[@]}"; do
        [ "$topics" = "$o" ] || continue
        if ofono "$m" org.ofono.CellBroadcast.SetProperty \
                string:Topics variant:string:"$SHIPPED" >/dev/null; then
            echo "$m: cell broadcast channels back to $SHIPPED"
        else
            echo "$m: could not put the cell broadcast channels back" >&2
            rc=1
        fi
    done
done
exit $rc
