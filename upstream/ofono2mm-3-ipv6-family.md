# Bearer advertises IPv4v6 and the generated NM profile requests IPv6, on a context that is brought up IPv4-only

**Repo:** furilabs/oFono2MM
**Checked against:** `forky` @ `2b1d012f3d37722f97151c52f989e239d91ee4bc`
**Observed on:** ofono2mm 1.8.0+git20260520152015.3b02630.forky.production, NetworkManager 1.56.0

## Summary

`doConnect()` brings the oFono context up with whatever `read_setting("protocol", "ip")`
returns — IPv4-only unless the user configured otherwise. Two places contradict
that default:

1. `mm_bearer.py:53` reports `ip-type` as `4` (`MM_BEARER_IP_FAMILY_IPV4V6`),
   hardcoded, regardless of the protocol actually used.
2. `mm_modem_simple.py:300` generates the NetworkManager profile with
   `'ipv6': {'method': 'auto'}`, unconditionally.

With an IPv4-only context oFono never emits `IPv6.Settings`, so `Ip6Config.method`
stays `0` (`MM_BEARER_IP_METHOD_UNKNOWN`). NetworkManager, having been asked to
do IPv6, looks for a usable IPv6 method, finds none and logs on **every**
activation:

```
NetworkManager: modem-broadband[/ril_0]: IPv4 static configuration:
NetworkManager:   address 10.14.30.20/24 brd* 10.14.30.255
NetworkManager:   gateway 10.14.30.20
NetworkManager:   DNS 61.8.132.52
NetworkManager:   DNS 202.71.137.208
NetworkManager: <warn> device (/ril_0): retrieving IP configuration failed: modem IP method unsupported
```

Activation still succeeds, because `ipv6.may-fail` defaults to yes — so this is
log noise rather than a functional break. But on a device that reconnects often
it is constant noise that hides real problems, and the repo already carries a
comment acknowledging the underlying mismatch (`mm_bearer.py`, in `doConnect`):

```python
# NetworkManager falls back to SLAAC without an address, and these modems
# never answer a router solicitation.
```

That comment describes the symptom of asking NM for IPv6 on a connection that
has none.

## Note on the existing profile

The generated profile is only written when it does not already exist, so
changing the generator is not enough for devices that have already been
provisioned. Those keep `ipv6.method=auto` until someone runs:

```bash
nmcli connection modify "<name>" ipv6.method disabled
```

Worth mentioning in the fix, or handling by updating the existing connection.

## Suggested fix

Let both values follow the protocol that is actually used.

`mm_modem_simple.py`:

```diff
             'ipv6': {
-                'method': 'auto'
+                # The bearer is brought up with whatever protocol doConnect()
+                # asks oFono for. Claiming IPv6 on an IPv4-only context just
+                # makes NM ask for an IPv6 config that will never exist.
+                'method': 'auto' if read_setting("protocol", "ip").strip() in ('ipv6', 'dual') else 'disabled'
             }
```

`mm_bearer.py`, in `set_props()`:

```diff
             new_properties = dict(self.props['Properties'].value)
             new_properties['apn'] = Variant('s', chosen_apn)
+
+            # Report the family we actually bring the context up with rather
+            # than always claiming IPv4v6. MM_BEARER_IP_FAMILY_IPV4 = 1,
+            # IPV6 = 2, IPV4V6 = 4.
+            protocol = read_setting("protocol", "ip").strip()
+            new_properties['ip-type'] = Variant('u', {'ip': 1, 'ipv6': 2, 'dual': 4}.get(protocol, 1))
```

## Verified

Applying both changes, plus `nmcli connection modify … ipv6.method disabled`
for the pre-existing profile, removed the warning. The activation sequence went
from minutes (for unrelated reasons, see the `Connect()` hang report) to:

```
device (/ril_0): state change: disconnected -> prepare
device (/ril_0): state change: prepare -> config      (+0.7 s)
device (/ril_0): state change: config -> ip-config
modem-broadband[/ril_0]:   address 10.14.30.20/24 brd* 10.14.30.255
device (/ril_0): Activation: successful, device activated.
```

No `modem IP method unsupported` line.
