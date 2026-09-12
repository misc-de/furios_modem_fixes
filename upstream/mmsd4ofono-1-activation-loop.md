# Unbounded MMS context reactivation loop when the MMS APN is not usable — ~1700 activations/hour, destabilises mobile data

**Repo:** furilabs/mmsd4ofono
**Checked against:** `forky` @ `9b04724b4e68dbcd899b827250eb8e07f57bb796` (`main.py` unchanged from the released version)
**Observed on:** mmsd4ofono 1.6.0+git20260118002621.d86954e.forky.production, ofono 1.29+git8-11, ofono-binder-plugin 1.1.22-6, FuriPhone / MTK `MOLY.NR15.R3.MP.V189`, SIM MCC/MNC 262-23

## Summary

When the MMS context cannot be activated, `mmsd` retries it forever with no
backoff and no failure limit. On this device that produced **25,257 activation
attempts in 15 hours** (~1,690/h, roughly one every two seconds), each one
rejected by the network.

The existing guard against this is too narrow: it only fires when the internet
and MMS APNs are *identical*.

## The loop

`main.py:462` — every `Active=False` spawns a fresh activation task:

```python
async def context_active_changed(self, prop, propvalue):
    if prop == "Active" and not self.context_property_setting:
        if propvalue.value == False:
            mmsd_print("oFono MMS connection dropped while we still need it, reactivating context", ...)
            if self.activation_task and not self.activation_task.done():
                self.activation_task.cancel()
            self.activation_task = self.loop.create_task(self.force_activate_context())
```

`main.py:444` — which loops until `activate_mms_context()` returns `True`:

```python
async def force_activate_context(self):
    while True:
        ...
        ret = await self.activate_mms_context()
        if ret == True:
            return
        ...
        await asyncio.sleep(2)
```

`main.py:508` — and `activate_mms_context()` returns `True` as soon as the
D-Bus call is *accepted*, not when activation *succeeds*:

```python
await ofono_mms_ctx_interface.call_set_property("Active", Variant('b', True))
return True
```

oFono accepts the property write and fails asynchronously, so the loop exits,
`Active` stays `False`, `context_active_changed` fires again, and a new task is
created. There is no attempt counter and no backoff anywhere on this path.

## The guard that should have caught it

`main.py:500`:

```python
# if internet and MMS context APNs clash, MMS won't work and it will cause an
# infinite loop here which causes data instability
if (ofono_internet_ctx_interface is not None and
    internet_apn is not None and
    mms_apn is not None and
    internet_apn == mms_apn):
    mmsd_print(f"Internet and MMS contexts use the same APN ({internet_apn}), no activation needed", ...)
    return True
```

The comment names this exact failure mode, including "causes data instability".
But equality is only one way for an MMS APN to be unusable. Here:

- internet APN: `web.vodafone.de`
- MMS APN: `mms` — a placeholder oFono provisioned because
  `mobile-broadband-provider-info` has no MMS entry for MCC/MNC 262-23

Different strings, so the guard never fires.

## Evidence

```
ofonod: Activating context: 2
ofonod: Unexpected data call status 28
```

repeating every ~2 s. Aggregated over 15 hours (deduplicated — journald records
each ofono message twice):

```
25257  Activating context: 2
22828  Unexpected data call status 28    # PDP_FAIL_UNKNOWN_PDP_ADDRESS_TYPE
 2427  Unexpected data call status 55    # MULTI_CONN_TO_SAME_PDN_NOT_ALLOWED
```

Caller confirmed with `dbus-monitor` as root — note that an unprivileged
`dbus-monitor --system` shows nothing at all on this system bus policy, which
makes this loop easy to misattribute to oFono itself:

```
sender=:1.107 -> destination=org.ofono path=/ril_0; member=GetContexts
sender=:1.107 -> destination=org.ofono path=/ril_0/context2; member=SetProperty
   string "Active"
   variant       boolean true
```

`:1.107` = pid 3399 = `/usr/bin/python3 /usr/bin/mmsd`.

## Impact

Beyond the wasted cycles, this is a continuous stream of PDP activation
requests at the modem. On this device it ran alongside — and made much harder
to diagnose — genuine data connectivity failures. Cause 55
(`MULTI_CONN_TO_SAME_PDN_NOT_ALLOWED`) appearing in the mix suggests the
retries were also colliding with the internet context's own PDN.

## Workaround

Setting the MMS APN equal to the internet APN makes the existing guard fire,
and the loop stops immediately:

```bash
dbus-send --system --print-reply --dest=org.ofono /ril_0/context2 \
  org.ofono.ConnectionContext.SetProperty \
  string:"AccessPointName" variant:string:"web.vodafone.de"
```

Note that `org.ofono.ConnectionManager.RemoveContext` is not an option — the
binder plugin answers `org.ofono.Error.NotSupported`, so a bogus provisioned
MMS context cannot simply be deleted.

## Suggested fix

Three things, any of which would have prevented this:

1. **Give up after N attempts.** MMS is not time-critical; an APN that has
   failed twenty times in a row will not start working on the twenty-first.
   Stop and let the next outbound MMS or push notification trigger a fresh
   attempt.

2. **Back off.** A fixed 2-second interval is aggressive for something that
   talks to the radio. Exponential backoff with a ceiling would make even an
   unbounded loop harmless.

3. **Broaden the guard.** Equality is a special case of "this APN is not
   usable". Treating an empty or obviously-placeholder APN (`mms`, or one that
   does not resolve to a provisioned context) the same way would catch the
   general case, as would keying off repeated activation failures rather than
   off the APN strings.

The immediate one-line improvement is (1): a failure counter in
`force_activate_context()`, since `while True:` there is what turns a
misconfiguration into a permanent radio load.
