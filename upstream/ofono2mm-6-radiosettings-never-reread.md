# An oFono interface that arrives late is never read again, and the modem keeps `SupportedModes` empty for the rest of the boot

**Repo:** furilabs/oFono2MM
**Checked against:** `forky` @ `2b1d012f3d37722f97151c52f989e239d91ee4bc` (fetched 18.9.2026, still HEAD)
**Observed on:** ofono2mm 1.8.0+git20260520152015.3b02630.forky.production, FuriPhone FLX1

## Summary

`org.ofono.RadioSettings` is read exactly twice per process life, both times in
a burst at startup. If oFono has not registered the interface yet — which on a
Halium device is normal, because ofono2mm starts seconds before `ofonod` has
the modem up — the read fails silently, nothing retries, and nothing ever asks
again.

The modem then reports, for the whole uptime:

```
Hardware |  supported: lte                              <- gsm and umts are gone
Modes    |  supported: allowed: none; preferred: none   <- no mode at all
```

with oFono sitting next to it holding `AvailableTechnologies = gsm, umts, lte`.

## Why the values come out like that

`set_props()`, `mm_modem.py:877`:

```python
caps = 0
modes = 0
if 'org.ofono.RadioSettings' in self.ofono_interface_props:
    if 'AvailableTechnologies' in self.ofono_interface_props['org.ofono.RadioSettings'].props:
        ...                       # caps |= 4/8/64,  modes |= 2/4/8/16
```

With nothing to read, `caps` stays 0 and the fallback at `mm_modem.py:922`
pins LTE alone. `modes` stays 0, which matches none of the four totals the
table is written for (30, 14, 6, 2), so `supported_modes` is never appended to
and the explicit branch at `mm_modem.py:975` publishes

```python
self.props['SupportedModes'] = Variant('a(uu)', [[0, 0]])
self.props['CurrentModes'] = Variant('(uu)', [0, 0])
```

Note the outer guard is not a guard: `DBusInterfaceProperties.__contains__`
answers for interfaces that have merely been *accessed*, so
`'org.ofono.RadioSettings' in self.ofono_interface_props` is true with an empty
property dict behind it.

## Why it never repairs itself

**1. The failure is invisible to the retry loop.** `add_ofono_interface`
(`mm_modem.py:155`) looks like it retries five times over 2.5 s and gives up
loudly. It does neither, because `DBusInterface.init()`
(`dbus_interface_properties.py:25`) catches its own exception:

```python
while retries_left > 0:
    try:
        self.ofono_proxy[self.interface].on_property_changed(self._on_property_changed)
        self.props = await self.ofono_proxy[self.interface].call_get_properties()
        return
    except Exception as e:
        retries_left -= 1
        if retries_left > 0:
            await asyncio.sleep(0.5)
        else:
            ofono2mm_print(f"Interface {self.interface} doesn't have properties? ...")
```

It returns normally with `self.props == {}`. Nothing propagates, so the outer
loop sees success and breaks. The proxy itself never fails either: it is built
from the static XML shipped with the package (`ofono.py`, `CachedClient`), so
asking for `org.ofono.RadioSettings` hands back a perfectly good object whether
or not oFono has ever registered that interface.

**2. There are only two enumerations, and both are early.**
`add_ofono_interface` is called from `init_ofono_interfaces()`
(`mm_modem.py:141`), when the modem object is built, and from `sim_unlocked()`
(`mm_modem.py:683`). Nothing else enumerates, ever.

**3. The one announcement that would help is not listened to.** oFono publishes
the modem's `Interfaces` property when an interface appears, and the handler is
`mm_modem.py:1586`:

```python
async def ofono_changed(self, name, varval):
    await self.set_props()          # recompute from what we have
```

For every other interface that is enough, because a property that changes
carries its value with the signal. `RadioSettings` is the exception — its
properties are static, `AvailableTechnologies` does not change while the modem
runs, so no `PropertyChanged` is ever emitted for it. The `Interfaces` list is
the only announcement it will ever make, and nobody reads it.

## Evidence

Boot of 13.9.2026, from the journal:

| | |
| --- | --- |
| 15:15:31 | ModemManager (ofono2mm) started |
| 15:15:39 | `ofono.service` starts waiting for the radio HAL |
| 15:15:48 | `IRadio/slot1` appears, `ofonod` starts |
| 15:15:51 | SIM OK — the modem is still coming up |
| 15:17 | `CurrentCapabilities 8`, `SupportedModes (0, 0)`, oFono has gsm, umts, lte |

`systemctl restart ModemManager` at 15:20, with oFono long settled, nothing
else touched:

| | before | after |
| --- | --- | --- |
| `CurrentCapabilities` | `8` (lte) | `12` (gsm-umts, lte) |
| `SupportedModes` | `(0, 0)` | 2g, 3g, 4g |
| `CurrentModes` | `(0, 0)` | allowed 4g |

So it is a startup race, not a permanent state — an earlier boot the same day
won it. That is also why it is easy to miss: the data path is unaffected,
`AccessTechnologies` is correct, and only the modem's *capabilities* and
*modes* are wrong.

## Suggested fix

Re-read on the announcement, for anything that was asked for before oFono had
it:

```python
async def ofono_changed(self, name, varval):
    if name == 'Interfaces':
        await self.resync_ofono_interfaces(varval.value)

    await self.set_props()
```

where `resync_ofono_interfaces` re-inits only interfaces whose property dict is
still empty. Once a read works the condition is false forever, which matters:
oFono republishes that whole list every time any interface comes or goes. The
interfaces ofono2mm deliberately keeps without properties
(`interfaces_without_props` — `NetworkMonitor`, `FuriLabs.AT`) must be
excluded, or their permanently empty dict has them re-read for the life of the
process.

Two things to fix alongside it, both in `add_ofono_interface`:

- It registers the property watcher unconditionally on every run:

  ```python
  if iface not in self.interfaces_without_props:
      self.ofono_interface_props[iface].on('*', self.ofono_interface_changed(iface))
  ```

  `DBusInterfaceProperties.__getitem__` caches the `DBusInterface` object and
  `on()` appends to a list, so going through this function a second time for
  the same interface (which `sim_unlocked` already does today) registers a
  second watcher, and every later change recomputes everything twice, forever.
  Register once per interface.

- Consider letting `DBusInterface.init()` raise after its last retry. As it
  stands, its caller's retry loop cannot work by construction, which is what
  made this defect look like a missing feature rather than a broken retry.

A recompute alone is not enough, and our first attempt proved it: recomputing
finds nothing to compute from when the read never succeeded, so the re-read has
to come first.
