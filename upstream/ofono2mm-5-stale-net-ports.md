# `Ports` only ever grows, so a modem keeps advertising a net port that no longer exists

**Repo:** furilabs/oFono2MM
**Checked against:** `forky` @ `2b1d012f3d37722f97151c52f989e239d91ee4bc` (fetched 18.9.2026, still HEAD)
**Observed on:** ofono2mm 1.8.0+git20260520152015.3b02630.forky.production, FuriPhone FLX1

## Summary

Three places append an interface name to the modem's `Ports` property. Not one
of them ever removes an entry, and nothing rebuilds the list. An interface that
carried an earlier data call therefore stays in `Ports` for the life of the
process.

ModemManager then offers NetworkManager two net ports for one modem.
NetworkManager picks one. When it picks the stale one, it hands the carrier's
resolvers to dnsmasq bound to an interface that is down — and every name lookup
fails on a phone that is passing packets perfectly over the live interface.

## The code

```
mm_modem.py:119    'Ports': Variant('a(su)', [[self.modem_name, 1]])   # initial value
mm_modem.py:550    check_ofono_contexts     -> append [iface, 2]
mm_modem.py:663    ofono_context_added      -> append [iface, 2]
mm_bearer.py:332   ofono_context_changed    -> append [iface, 2]
mm_modem.py:1442   Ports property getter
```

`grep -n Ports ofono2mm/*.py` on HEAD returns exactly these: one initialiser,
three appends, one getter. There is no `remove`, no rebuild, and no code path
that reacts to a context going down by shortening the list.

All three appends are guarded with `if port not in ...`, so the list does not
grow without bound — it grows to the union of every interface any context has
ever reported, which is the problem.

## What it looks like from outside

`mmcli -m 0`, on a phone whose data call is on `ccmni0`:

```
modem.generic.ports.value[2] : ccmni0 (net)
modem.generic.ports.value[3] : ccmni2 (net)   <- from an earlier data call
```

`ccmni2` is down and has no address. Every other component in the chain names
`ccmni0`: the ofono2mm bearer (`connected: yes, interface ccmni0`), oFono
(`/ril_0/context1  Active=true`), the address, the route. Only ofono2mm's port
list still mentions `ccmni2`, and that is the one NetworkManager chose:

```
policy: set 'Willkommen' (ccmni2) as default for IPv4 routing and DNS
dnsmasq: using nameserver 61.8.132.52#53(via ccmni2)
```

## Impact

A nameserver bound to a down interface is not a slow nameserver; it is no
nameserver. dnsmasq accepts the query, finds it cannot send from that
interface, forwards nothing and answers REFUSED in 0 ms. Measured with one
dnsmasq instance per row, same version, same moment, same servers — only the
binding differs:

| server given to dnsmasq | answer | dnsmasq's own log |
|---|---|---|
| `61.8.132.52` | NOERROR | query → forwarded → reply |
| `61.8.132.52@ccmni0` (live) | NOERROR | query → forwarded → reply |
| `61.8.132.52@ccmni2` (down) | **REFUSED** | query — and nothing after it |

Its counters agree: `queries answered locally` rises, `queries forwarded` does
not move.

Because NetworkManager tests connectivity by resolving a name, the phone also
reports `nmcli networking connectivity` → `none` while `ping` over mobile data
loses nothing. With Wi-Fi off, the phone is "offline" with a working data call.

After the port list is corrected, on the same phone with Wi-Fi off:

| | before | after |
|---|---|---|
| dnsmasq | REFUSED | **NOERROR** |
| `getent hosts github.com` | nothing | 140.82.121.4 |
| `curl https://heise.de` | — | **HTTP 301 in 0.15 s** |
| `nmcli networking connectivity` | `none` | **`full`** |

## What HEAD already fixes, and what it does not

`de4894c` ("mm_bearer: clear the interface when a context goes down") clears
the *bearer's* `Interface` when its context deactivates, which is the right
half of this. The modem's `Ports` list is untouched by that commit: the name is
still in it, and it is `Ports` that NetworkManager reads when it looks for a
data port.

## Suggested fix

Derive the list instead of appending to it — the net ports are exactly the
interfaces the bearers name right now:

```python
def sync_net_ports(self):
    ports = [[self.modem_name, 1]]  # MM_MODEM_PORT_TYPE_UNKNOWN

    for bearer in self.bearers.values():
        iface = bearer.props['Interface'].value
        if iface and [iface, 2] not in ports:  # MM_MODEM_PORT_TYPE_NET
            ports.append([iface, 2])

    if ports != self.props['Ports'].value:
        self.props['Ports'] = Variant('a(su)', ports)
        self.emit_properties_changed({'Ports': ports})
```

and call it from the three places that currently append, plus wherever a
bearer's `Interface` is cleared (`ofono_context_changed`, `Active` → false)
and from `DeleteBearer`.

Two mistakes worth avoiding, both of which we made first:

- Do not emit `PropertiesChanged` unconditionally. This runs on every context
  property change, and an unchanged list emitted every few seconds is a lot of
  wakeups for nothing.
- Do not drop a second *live* ccmni. A modem with an IMS context genuinely has
  two net ports; the rule is "what the bearers name now", not "one port".

We hold this in place with a test that parses the shipped file with `ast` and
fails if a fourth place appends to `Ports` directly.
