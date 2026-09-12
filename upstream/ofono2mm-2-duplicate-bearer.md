# `Connect()` silently falls through when a bearer is busy and creates a second bearer for the same APN

**Repo:** furilabs/oFono2MM
**Checked against:** `forky` @ `2b1d012f3d37722f97151c52f989e239d91ee4bc`
**Observed on:** ofono2mm 1.8.0+git20260520152015.3b02630.forky.production

## Summary

In `MMModemSimpleInterface.Connect()` the branch that matches an existing
bearer by APN only returns that bearer when `active_connect == 0`. When the
bearer is busy the `if` simply does not fire, the `for` loop continues, and
control reaches `doCreateBearer()` — which builds a *second* bearer for the
very same APN.

The caller is never told that the bearer it should have received was skipped.

## The code

`mm_modem_simple.py:169`

```python
for b in self.mm_modem.bearers:
    bearer_apn = self.mm_modem.bearers[b].props['Properties'].value['apn'].value if ... else ''
    if bearer_apn == apn:
        self.mm_modem.bearers[b].props['Properties'] = Variant('a{sv}', properties)
        if self.mm_modem.bearers[b].active_connect == 0:
            self.mm_modem.bearers[b].active_connect += 1
            await self.mm_modem.bearers[b].doConnect()

            ofono2mm_print(f"Bearer activated at path {b}", self.verbose)
            return b
        # active_connect != 0 → no return, no log, loop continues
try:
    bearer = await self.mm_modem.doCreateBearer(properties)
```

Note the asymmetry: the identical check at `mm_modem_simple.py:181`, on the
newly created bearer, *does* log when the counter is occupied:

```python
else:
    ofono2mm_print(f"Failed to create bearer, active connect is {...}", self.verbose)
    bearer = self.fallback_bearer_path()
```

The first one says nothing at all, which makes the state very hard to see when
debugging.

## Impact

Two bearers end up describing the same PDP context. `doCreateBearer()` writes
`Protocol` on the internet context, which — per the commit message of
`mm_modem: don't bounce a context that already has the wanted protocol` —
oFono only accepts while the context is down. Creating that redundant bearer
is therefore not free; it is exactly the situation that commit set out to
avoid, reached by a different route.

Combined with the unbounded retry in `activate_ofono_context` (separate
report), this is what a wedged modem looks like from the outside:
NetworkManager asks to connect, gets a bearer path back, and that bearer is
not the one holding the context.

## Suggested fix

Return the matching bearer either way. A connect already in flight for this
APN is not a reason to build a second bearer:

```diff
             if self.mm_modem.bearers[b].active_connect == 0:
                 self.mm_modem.bearers[b].active_connect += 1
-                await self.mm_modem.bearers[b].doConnect()
-
-                ofono2mm_print(f"Bearer activated at path {b}", self.verbose)
-                return b
+                try:
+                    await self.mm_modem.bearers[b].doConnect()
+                finally:
+                    self.mm_modem.bearers[b].active_connect = 0
+
+                ofono2mm_print(f"Bearer activated at path {b}", self.verbose)
+                return b
+
+            # A connect is already in flight for this bearer. Hand back the same
+            # bearer rather than falling through and creating a second one for
+            # the very same APN.
+            ofono2mm_print(f"Connect already in progress for bearer {b}", self.verbose)
+            return b
```

The `try/finally` is the belt-and-braces part mentioned in the other report:
with the caller owning the counter, a future change to the retry policy in
`activate_ofono_context` cannot strand it again.
