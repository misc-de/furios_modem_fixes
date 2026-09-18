# A bearer built by `doCreateBearer` never subscribes to its oFono context, and nothing ever repairs it

**Repo:** furilabs/oFono2MM
**Checked against:** `forky` @ `2b1d012f3d37722f97151c52f989e239d91ee4bc` (fetched 18.9.2026, still HEAD)
**Observed on:** ofono2mm 1.8.0+git20260520152015.3b02630.forky.production, FuriPhone FLX1

## Summary

ofono2mm builds an `MMBearerInterface` in three places. Two of them subscribe
to the oFono context's `PropertyChanged`; the third, the one
`Simple.Connect()` goes through, does not.

| builder | called from | subscribes |
|---|---|---|
| `check_ofono_contexts` (`mm_modem.py:426`) | startup | yes — `mm_modem.py:555` |
| `ofono_context_added` (`mm_modem.py:574`) | oFono announcing a context | yes — `mm_modem.py:668` |
| `doCreateBearer` (`mm_modem.py:1039`) | `Simple.Connect`, i.e. NetworkManager | **no** |

Everything a bearer knows — `Connected`, `Interface`, the addresses, its entry
in the modem's port list, the reconnect logic — arrives through that one
callback. Without it the object answers with its constructor defaults.

## Why nothing repairs it

Both other builders skip a context that a bearer already owns
(`mm_modem.py:462`/`466`, and `:579`/`580`):

```python
existing_contexts = [bearer.ofono_ctx for bearer in self.bearers.values()]
for ctx in contexts:
    if ctx[0] in existing_contexts:
        continue
```

The deaf bearer owns `/ril_0/context1`, so the path that would have subscribed
properly skips it from then on. Nothing reopens the question for the life of
the process.

## What it costs, on HEAD

`adopt_active_context` (`mm_bearer.py:196`, added in `713e342`) changes the
symptom but not the defect, because it reads the context state once at connect
time:

- **Context already active at `Connect()`** — `adopt_active_context` feeds
  `Settings`/`Active` into `ofono_context_changed` by hand, so the connect
  succeeds. The bearer is still deaf afterwards: a later re-activation, a
  changed address, a context that drops, are all unheard. `Connected` and
  `Interface` stay frozen at whatever that one read saw, the reconnect path in
  `ofono_context_changed` can never fire for this bearer, and the modem's
  `Ports` never learns about the change.
- **Context not active at `Connect()`** — `activate_ofono_context` bounces
  `Active`, and `doConnect` then polls `has_usable_config()` for
  `INTERFACE_WAIT_SECONDS`. `Interface` is only ever written by
  `ofono_context_changed` (`mm_bearer.py:331`) and `set_props` does not touch
  it, so the poll can never succeed: after 5 s `doConnect` raises
  `"oFono context ... reported no usable configuration after activation"` and
  the connect fails, with the data call up.

On the older build we run, where neither `adopt_active_context` nor the
usable-config check exist yet, the same defect is silent instead: the bearer is
exported `connected: no`, with no `Interface`, and NetworkManager rejects it:

```
device (/ril_0): state change: disconnected -> prepare
modem-broadband[/ril_0]: failed to connect modem: missing data port
device (/ril_0): state change: prepare -> failed (reason 'config-failed')
```

```
Bearer/0:     connected: no,  no interface
Modem Ports:  [("/ril_0", 0)]        <- the control port, and nothing else
```

The phone comes up with the radio registered on LTE, oFono holding the internet
context `Active` with an address on `ccmni0`, and no mobile data at all.

## Why it is intermittent

Which builder runs first is a race between oFono publishing the internet
context and NetworkManager's autoconnect:

- oFono first → `check_ofono_contexts` builds the bearer, it listens, data works;
- NetworkManager first → `doCreateBearer` builds it, and it is deaf.

On the boot of 13.9.2026 17:03, NetworkManager won by four seconds. Four
minutes earlier, the previous boot of the same phone with the same packages had
working mobile data. Weak reception makes losing the race more likely, because
registration is what oFono waits for; it was -119 dBm RSRP that evening.

## Ruling out the other explanations

A missing dbus_fast subscription has three plausible causes, so each was
measured rather than argued:

1. **Does oFono announce it?** `dbus-monitor --system
   "type='signal',path='/ril_0/context1'"` while toggling `Active` by hand:

   ```
   PropertyChanged  "Settings"  {}
   PropertyChanged  "Active"    false
   PropertyChanged  "Settings"  {Interface: ccmni0, Address: 10.9.54.198, ...}
   PropertyChanged  "Active"    true
   ```

   It does. `Bearer/0` stayed `connected: no` throughout.

2. **Is the idiom sound?** A 20-line script subscribing through ofono2mm's own
   `Ofono` client, with the same static XML, dropping the proxy reference and
   calling `gc.collect()`, received every one of those signals. So dbus_fast,
   the XML and object lifetime are all fine.

3. **Does the subscribing path work on the same phone?** `systemctl restart
   ModemManager` let `check_ofono_contexts` build the bearer instead, and the
   same radio and the same context went to `connected: yes, interface ccmni0`
   with NetworkManager connected in seconds.

(If you reproduce this: `dbus-send` without `--print-reply` does not wait for a
reply and returns 0 whether the call worked or not. Two toggles "sent" that way
produced no signal and pointed at exactly the wrong culprit.)

## Suggested fix

Subscribe in `doCreateBearer` too, in **both** branches that get hold of a
context — the provisioned one and the one it adds itself when MBPI provisioned
nothing, or a carrier that is not in the database keeps the old silence:

```diff
             if name.lower() == "internet":
                 ofono_ctx = ctx[0]
                 ofono_ctx_interface = self.ofono_client["ofono_context"][ofono_ctx]['org.ofono.ConnectionContext']
+                ofono_ctx_interface.on_property_changed(mm_bearer_interface.ofono_context_changed)
 
                 # Setting Protocol needs the context down, so writing the value it
                 # already holds would cost a live PDN.
                 ctx_props = await ofono_ctx_interface.call_get_properties()
```

and the same one line in the `if ofono_ctx is None:` branch, right after
`call_add_context("internet")` hands back a path.

Subscribe *before* writing `Active`, or the activation being asked for happens
before anyone is listening. Subscribing there does not make the bearer react to
its own `Active` bounce: `activate_ofono_context` already sets
`self.disconnecting` around it, which is exactly what that flag is for.

A test that reads the shipped file with `ast` and asserts that every place
constructing an `MMBearerInterface` also registers `ofono_context_changed`
keeps a fourth builder from repeating this; that is what we run, and it costs
nothing.

## Measured

Straight into the repaired path with `mmcli -m 0 --create-bearer`, which is
`doCreateBearer` and nothing else:

```
before:  Bearer/1  connected: no
after:   Bearer/1  connected: yes, interface ccmni1, 100.80.165.176/24
```
