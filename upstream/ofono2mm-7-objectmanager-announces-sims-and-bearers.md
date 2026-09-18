# The ObjectManager announces SIMs and bearers as top-level objects, and clients that take the first one get no modem

**Repo:** furilabs/oFono2MM
**Checked against:** `forky` @ `2b1d012f3d37722f97151c52f989e239d91ee4bc` (fetched 18.9.2026, still HEAD)
**Observed on:** ofono2mm 1.8.0+git20260520152015.3b02630.forky.production, python3-dbus-fast 4.3.0, FuriPhone FLX1 (phosh 0.49)

## Summary

`GetManagedObjects` on `/org/freedesktop/ModemManager1` answers with every
exported sub-path — the modem, but also every SIM and every bearer. Real
ModemManager answers with modems and nothing else.

Clients that follow ModemManager's contract and take "the first managed object"
therefore latch onto a bearer or a SIM, find no `org.freedesktop.ModemManager1.Modem`
interface on it, and give up. On this phone that means **no mobile signal icon
at all**, on a modem that is registered, attached and carrying traffic.

## What is announced

Asked through libmm-glib, the way any GUI asks:

```
Objects in the ObjectManager: 4
  /org/freedesktop/ModemManager1/Bearer/1   modem-proxy: NULL
  /org/freedesktop/ModemManager1/Modem/0    modem-proxy: OK    15 interfaces
  /org/freedesktop/ModemManager1/SIM/0      modem-proxy: NULL
  /org/freedesktop/ModemManager1/Bearer/0   modem-proxy: NULL
```

ofono2mm has no ObjectManager of its own (`grep -rn ObjectManager main.py
ofono2mm/` on HEAD finds nothing). dbus_fast synthesises one from the export
table, `message_bus.py`:

```python
nodes = [
    node
    for node in self._path_exports
    if msg.path == "/" or node.startswith(msg.path + "/")
]
```

and emits `InterfacesAdded` from `export()` for every path, whatever it is
(`MessageBus.export` → `_emit_interface_added`). ofono2mm exports the SIM at
`mm_modem.py:283` and bearers at `mm_modem.py:560`, `:673` and `:1106`, so all
of them are announced.

## What ModemManager does instead

ModemManager 1.24.2 exports SIMs and bearers on the bus at exactly these paths,
but does not put them in the ObjectManager:

```
src/mm-base-manager.c:2108   object_manager = g_dbus_object_manager_server_new (MM_DBUS_PATH);
src/mm-device.c:395          g_dbus_object_manager_server_export (object_manager,
                                 G_DBUS_OBJECT_SKELETON (self->priv->modem));   <- modems only
src/mm-base-sim.c:1598       g_dbus_interface_skeleton_export (...)             <- plain export
src/mm-base-bearer.c:1395    g_dbus_interface_skeleton_export (...)             <- plain export
```

A client reaches a bearer through the modem's `Bearers` property and a SIM
through `Sim`, never by enumeration. Being reachable and being enumerable are
two different things, and the difference is the whole of this defect.

## Why it is fatal rather than untidy

phosh, `src/wwan/phosh-wwan-mm.c` (verified against `main`, 18.9.2026):

```c
modems = g_dbus_object_manager_get_objects (G_DBUS_OBJECT_MANAGER (self->manager));
if (modems) {
  /* Cold plug first modem */
  on_mm_object_added (self, modems->data, self->manager);
}
```

and in `on_mm_object_added`:

```c
if (!self->object) {
  self->object = g_object_ref (MM_OBJECT (object));
  /* Modem interface is always present */
  modem_init_modem (self, MM_OBJECT (object));
```

`modems->data` is the first entry of the list, and the comment states the
assumption plainly. Against ModemManager the assumption holds. Against ofono2mm
it is a coin toss — and worse, `self->object` is assigned *before*
`modem_init_modem` asserts, so once phosh has latched onto a bearer the
`if (!self->object)` guard is false for every object that arrives afterwards,
including the modem. It does not retry. There is no icon until something
restarts phosh or ModemManager.

The only trace anywhere in the journal:

```
phosh[3678]: (../libmm-glib/mm-object.c:108):mm_object_get_modem:
             runtime check failed: (MM_IS_MODEM (modem))
phosh[3678]: modem_init_modem: assertion 'self->modem' failed
```

`mmcli` prints the same warning, once per non-modem object, and then prints all
the right values anyway — which is why it reads as cosmetic for a long time.

The order of the list is GLib hash order over the paths, so this looks
intermittent across reboots and correlates with nothing obvious. The bearers
exist at all only if the data call came up before the client started, so a boot
that connects slowly hides the bug and a boot that connects quickly shows it.

## Suggested fix

Announce modems only. The SIM and the bearers stay exported and stay reachable
at their own paths — they simply stop being enumerable, which is the contract
libmm-glib clients are written against.

We do it by narrowing the three ObjectManager entry points in a `MessageBus`
subclass, which needs no changes anywhere else in the daemon:

```python
MM_ROOT = '/org/freedesktop/ModemManager1'
MM_MODEM_PREFIX = MM_ROOT + '/Modem/'

class ModemManagerBus(MessageBus):
    @staticmethod
    def _is_announced(path):
        if not path.startswith(MM_ROOT + '/'):
            return True
        return path.startswith(MM_MODEM_PREFIX)
```

- `GetManagedObjects` runs against a narrowed `_path_exports` and restores it
  afterwards in a `finally`. Restoring is not a detail: dbus_fast serves every
  later call from that same table, so leaking the narrowed one makes the daemon
  forget its own SIM.
- `InterfacesAdded` / `InterfacesRemoved` are suppressed for paths that should
  never have been announced.

If you would rather not subclass the bus, the equivalent is to export SIMs and
bearers on a path that is not below `/org/freedesktop/ModemManager1` — but that
would break `mmcli -b`, so narrowing the announcement is the smaller change.

## Proof

Same query after the change, ModemManager restarted, nothing else touched:

```
Objects in the ObjectManager: 1
  /org/freedesktop/ModemManager1/Modem/0    modem-proxy: OK    15 interfaces
```

No warnings from `mmcli` on any invocation, `mmcli -m 0 --sim 0` still prints
the IMSI, `mmcli -b 0` still reports the bearer connected on `ccmni0`, and the
signal icon is back.
