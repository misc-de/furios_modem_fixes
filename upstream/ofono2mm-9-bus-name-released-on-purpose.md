# ofono2mm drops its own bus name 150 ms after taking it, and clients that call during the gap never come back

**Repo:** furilabs/oFono2MM
**Checked against:** `forky` @ `2b1d012f3d37722f97151c52f989e239d91ee4bc` (fetched 18.9.2026, still HEAD)
**Observed on:** ofono2mm 1.8.0+git20260520152015.3b02630.forky.production, FuriPhone FLX1 (phosh 0.49, gsd-wwan, chatty, wireplumber)

## Summary

`release_request_modemmanager()` (`mm_modem.py:696`) releases
`org.freedesktop.ModemManager1` and immediately requests it again, to "make
other apps realize we're here". It is called from `init_ofono_interfaces`
(`:153`), from `sim_unlocked` (`:694`) and from `set_props` when the modem is
brought online (`:733`) — so it happens a fraction of a second after the daemon
first takes the name, and again later.

During each release nobody owns the name. A client whose call lands in that
window gets an error, and on this phone the clients do not recover from it:
after `systemctl restart ModemManager` the mobile signal icon is gone — not for
a moment, for good, with every measurable thing about the modem correct.

## Measured

`dbus-monitor` on `NameOwnerChanged` plus the bus driver's own method calls,
across one restart (14.9.2026):

```
t+0.000  :1.211 -> ""        old process stops
t+0.418  ""     -> :1.356    new process takes the name
t+0.564  :1.356 -> ""        ReleaseName   <- from :1.356 itself
t+0.569  ""     -> :1.356    RequestName
t+0.578  :1.356 -> ""        ReleaseName
t+0.587  ""     -> :1.356    RequestName
```

The same connection gives the name up and takes it back twice, 150 ms after it
first got it. With `MODEM_DEBUG=true` ofono2mm says so itself:

```
MMModemInterface(/ril_0).release_request_modemmanager: Releasing and requesting the bus name
```

What a client sees, from the journal of that restart:

```
gsd-wwan[4154]: Error calling GetManagedObjects() when name owner (null)
  for name org.freedesktop.ModemManager1 came back:
  GDBus.Error:org.freedesktop.DBus.Error.AccessDenied: Rejected send message,
  1 matched rules; ... member="GetManagedObjects" ...
  destination=":1.3188" (uid=0 comm="/usr/bin/python3 /usr/sbin/ofono2mm")
```

The `AccessDenied` is not a permission problem and there is nothing to grant. A
policy rule keyed on a well-known name

```xml
<allow send_destination="org.freedesktop.ModemManager1"/>
```

matches nothing while nobody owns that name, so what is left is the catch-all
`<deny>` at the top of the policy — *1 matched rules*. A moment later the same
call gets `ServiceUnknown: The name :1.20 was not provided by any .service
files` instead, once the old unique name is gone for good. The only policy that
would cover the gap is one allowing the call to **any** destination on the bus.

Hit at the same moment, on the same restart: `phosh` (the status icon),
`chatty` (SMS), `wireplumber`. Hours later the icon was still missing, while:

```
mmcli -m any       registered, attached, lte, signal 3% (recent)
ObjectManager      1 object, the modem
rfkill             no block, WWAN on
```

## It is a race, not a certainty

Ten minutes later, the same command on the same phone: not one
`GetManagedObjects` error, and the icon stayed. Whether a client is hit depends
on where in the gap its call happens to land. That is also why this is easy to
dismiss as "restarting ModemManager is just like that".

Two things in the journal at that moment that are *not* casualties of this, in
case you see them too: `cellbroadcastd` logging `ServiceUnknown` for
`SetChannels` (the channel list lives in oFono, which was not restarted — all
26 channels were still set immediately afterwards), and the `AccessDenied` from
a missing `Modem.CellBroadcast` rule in ModemManager 1.24.2's own bus policy,
which is a different failure that matches on the same two words.

## Why the poke is not needed

The comment above the call already suspects it:

```python
# Release and request the name so other apps realize we're here.
# TODO: this feels like it shouldn't be necessary. We are signaling InterfacesAdded, so... why?
```

It is right. dbus_fast emits `org.freedesktop.DBus.ObjectManager.InterfacesAdded`
from `MessageBus.export()` itself (`_emit_interface_added`), so every modem,
SIM and bearer is already announced when it is exported. A GDBus object manager
client is written to act on exactly that signal. What the release adds is not
an extra announcement but a window in which the name does not exist, and the
clients that were about to enumerate fall into it — which is why they are hit a
moment *after* the restart, all at once, rather than while systemd swaps the
processes.

## Suggested fix

Delete `release_request_modemmanager()` and its three call sites.

If a poke is genuinely needed for some client, re-emitting `InterfacesAdded`
for the modem path is the same announcement without the gap:

```python
self.bus._emit_interface_added(f'/org/freedesktop/ModemManager1/Modem/{self.index}', self)
```

While you are in there: the return value of `request_name` is discarded at
`mm_modem.py:713`. `MessageBus.request_name` returns a `RequestNameReply` and
raises only on a call error, so if anything else takes the name during the
release — a real ModemManager, a second ofono2mm — the daemon carries on
running, without the name, and says nothing. Checking for
`RequestNameReply.PRIMARY_OWNER` and exiting otherwise would turn a silent
"phone has no mobile data this boot" into a unit that systemd can restart.

## The client half

phosh does not recover on its own, and neither does gsd-wwan; restarting
`gsd-wwan` alone does not bring the icon back, because phosh holds a proxy of
its own. That is arguably a phosh bug too — but it is only ever provoked here,
and the gap is ofono2mm's to close.
