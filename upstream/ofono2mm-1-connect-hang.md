# Unbounded retry in `activate_ofono_context` makes `Connect()` hang forever and permanently wedges the bearer

**Repo:** furilabs/oFono2MM
**Checked against:** `forky` @ `2b1d012f3d37722f97151c52f989e239d91ee4bc`
**Observed on:** ofono2mm 1.8.0+git20260520152015.3b02630.forky.production, ofono 1.29+git8-11, ofono-binder-plugin 1.1.22-6, NetworkManager 1.56.0, FuriPhone / MTK `MOLY.NR15.R3.MP.V189`

## Summary

`activate_ofono_context()` is decorated with `@async_retryable()`, which means
`times=0` — retry forever. When context activation fails persistently (weak
signal, a PDP cause the network keeps rejecting), that coroutine never returns.

Because it never returns, the `finally` block in `doConnect()` that releases
`active_connect` — added precisely to prevent this — is never reached, and the
D-Bus method `org.freedesktop.ModemManager1.Modem.Simple.Connect` never
returns either.

The result is a modem that cannot be reconnected by any means short of
restarting ModemManager or rebooting. Toggling mobile data off and on does not
help, because `Disconnect()` does not reset the counter.

## The code path

`mm_bearer.py:214`

```python
@async_retryable()
async def activate_ofono_context(self, ofono_ctx_interface, protocol):
```

`utils.py:8` — `times=0` is the documented "retry indefinitely" mode:

```python
def async_retryable(times=0):
    ...
    while times == 0 or current_try < times:
        try:
            result = await func(*args, **kwargs)
        except Exception:
            if current_try == times-1:   # times-1 == -1, never true when times == 0
                raise
            await asyncio.sleep(5)
            current_try += 1
        else:
            return result
```

With `times=0` the `raise` is unreachable, so a persistently failing
`activate_ofono_context` loops at 5-second intervals without end.

`mm_bearer.py:240` — `doConnect()` awaits it:

```python
try:
    await self.activate_ofono_context(ofono_ctx_interface, protocol)   # never returns
    ...
finally:
    # Release the slot on failure too, or one failed activation blocks every
    # later Connect() for this bearer.
    if self.active_connect >= 1:
        self.active_connect -= 1
```

The comment states the hazard exactly. But `finally` only runs when control
leaves the `try` block, and control never leaves the `await`. The guard cannot
fire.

`mm_modem_simple.py:173` — and that is what the counter gates:

```python
if self.mm_modem.bearers[b].active_connect == 0:
    self.mm_modem.bearers[b].active_connect += 1
    await self.mm_modem.bearers[b].doConnect()
    return b
```

With the counter stuck at 1, every later `Connect()` for this APN skips the
bearer (see the separate report on the silent fall-through).

## What we observed

NetworkManager sat in `prepare` indefinitely — over three minutes in one case,
and across several ModemManager restarts:

```
NetworkManager[1070]: device (/ril_0): state change: disconnected -> prepare (reason 'none')
... nothing further ...
```

During that time `dbus-monitor --system` (as root) showed **zero** method calls
from ofono2mm to `org.ofono`, and zero calls on
`org.freedesktop.ModemManager1.Modem.Simple`. The modem itself was healthy:

```
mmcli -m any
  Status | state: registered
         | packet service state: attached
```

Activating the oFono context directly worked on the first try:

```
dbus-send --system --dest=org.ofono /ril_0/context1 \
  org.ofono.ConnectionContext.SetProperty string:"Active" variant:boolean:true
→ ofonod: Activating context: 1
→ ofonod: setting up data call
```

So the stack was capable of connecting; only the bearer slot was wedged.

## Why it triggers here

This modem rejects the first few activations of a freshly attached context with
data call cause 28 (`PDP_FAIL_UNKNOWN_PDP_ADDRESS_TYPE`) before succeeding —
typically 6 to 8 attempts:

```
ofonod: Activating context: 1
ofonod: Unexpected data call status 28     (×8)
ofonod: Activating context: 1
ofonod: setting up data call               ← succeeds
```

Any device or network that can fail activation for longer than one retry cycle
will reach the same state. Poor coverage is enough.

## Suggested fix

Bound the retry so the coroutine can terminate and let `doConnect()`'s
`finally` do its job:

```diff
-@async_retryable()
+# Bounded: an unbounded retry never returns while the context keeps failing,
+# so the caller's finally never runs and active_connect stays occupied.
+@async_retryable(6)
 async def activate_ofono_context(self, ofono_ctx_interface, protocol):
```

Six attempts at the decorator's 5-second interval is roughly 30 seconds, after
which `Connect()` raises, NetworkManager records a failed activation and
retries on its own schedule — which is the behaviour NM is built for.

A belt-and-braces alternative is to wrap the await in `asyncio.wait_for()`, or
to have `Connect()` own the counter with its own `try/finally`, so that no
future change to the retry policy can reintroduce the wedge.

## Related

`Disconnect()` does not reset `active_connect` either, so once wedged there is
no D-Bus route back to a working state.
