# What we found out

The README says what this does and how to run it. This file says *why*: the
measurements behind each fix, and the things that cost hours because they are
not what the documentation of the parts involved suggests.

Device: FuriPhone FLX1 (radon), MediaTek modem `MOLY.NR15.R3.MP.V189`, SIM
262-23, APN `web.vodafone.de`. Package versions in
[paket-versionen.txt](paket-versionen.txt).

Four symptoms started this, on different days:

- the data connection would only come up reliably after a reboot, and the UI
  said "mobile data unavailable" in between;
- the signal icon sat at the emptiest bar no matter where the phone was;
- switching Wi-Fi off left the phone with no network at all, although mobile
  data was connected and every component called itself healthy;
- and finally the signal icon disappeared altogether, on a boot where every
  measurable thing about the modem was correct.

None was a radio problem. All twenty-three causes are in software. Fifteen
are in code that shipped with the phone, two are a shipped fault our own fix
only half covered, and six we introduced ourselves while fixing the others.
The six are marked as such where they appear - and the newest of them,
defect 23, was caused by the fix for defect 20 and by the reason we gave for
it, which turned out not to survive measurement.

---

## Result

| | before (~15 h) | after (~15 min) |
|---|---|---|
| `Error 44 setting pref mode` | 26,940 (~1,800/h) | 0 |
| MMS context activations | 25,257 (~1,690/h) | 0 |
| data registration lost | every 30-50 s | 0 |
| NetworkManager state changes | continuous | 0 |
| NM `prepare` -> `config` | minutes, or never | 0.7 s |
| `mmcli` signal quality | `0% (cached)`, always | `26% (recent)`, moves |
| `mmcli` LTE RSRP / RSRQ | `+10 dBm` / `+120 dB` | `-120 dBm` / `-10 dB` |

A note on the counts: journald records every oFono message twice (`ofonod[PID]:
X` and `X`). The numbers above are deduplicated.

---

## 1. Runaway loop: the modem rejects the preferred mode

`/var/lib/ofono/<IMSI>/radiosetting` contains `TechnologyPreference=8` (NR/5G).
`/etc/ofono/binder.d/radio-interface-binder.conf` pinned the HAL to
`radioInterface = 1.4`. Over IRadio 1.4, NR goes through
`setPreferredNetworkTypeBitmap`, which this MTK modem rejects with RIL error 44
(`RIL_E_INVALID_ARGUMENTS`). oFono notices that the setting did not take and
retries every two seconds, forever.

The consequence is not the log noise. The modem was in permanent RAT
re-evaluation and never got to a clean cell reselection. **That, not weak
reception, was the cause of the flapping connection.**

The modem advertises IRadio 1.0 through **1.6**.

**Fix:** leave `radioInterface` at the shipped `1.4` and stop asking for NR -
`TechnologyPreference = lte`. Nothing else stops the loop, because the loop is
the request itself.

### The fix this used to be, and why it was wrong

For one day this said **`radioInterface = 1.6`**, and the loop did stop. Both
halves of that were wrong.

`1.6` is not a value `ofono-binder-plugin` accepts. Its name table runs `1.0`
to `1.5` and stops, today's upstream master included, and the parser says
nothing about a value it does not know:

```c
for (i = RADIO_INTERFACE_1_0; i < RADIO_INTERFACE_COUNT; i++)
    if (!g_strcmp0(name, binder_plugin_radio_interface_name(i)))
        return i;
return BINDER_DEFAULT_RADIO_INTERFACE;      /* = RADIO_INTERFACE_1_2 */
```

So the phone ran IRadio **1.2** - two versions *below* the one it shipped with
- while the config file claimed 1.6. Confirmed against the installed binary:
the strings `1.0` through `1.5` are in it, `1.6` is not.

And that is also why the loop stopped, which is the part that fooled us. Right
after the parse comes:

```c
if (slot->version < RADIO_INTERFACE_1_4)
    config->techs &= ~OFONO_RADIO_ACCESS_MODE_NR;
```

At 1.2 the plugin drops NR from the technology list altogether, so oFono never
asks the modem for NR and the modem never rejects anything. The symptom was
gone because the request was gone. 5G went with it - see **5G** below.

Measured 2026-09-13, three values, everything else untouched:

| `radioInterface` | modem comes up | `nr` offered | Error 44 while preference is `nr` |
|---|---|---|---|
| `1.4` (shipped) | yes, 26 interfaces in 10 s | **yes** | **60 in 60 s** |
| `1.5` | **no** - stuck at 5 interfaces, `Power request failed` every 30 s | - | - |
| `1.6` (i.e. 1.2) | yes | no | 0 |

So there is no version of this setting that buys anything: `1.5` does not boot
the modem, `1.6` does not exist, and `1.4` is what the phone already had.

## 2. Runaway loop: MMS context with a placeholder APN

oFono context 2 (type `mms`) had the APN `mms`, a placeholder - the provider
database has no MMS entry for 262-23 at all. `mmsd` set `Active=true` about
every two seconds; the network refused with data call cause 28
(`PDP_FAIL_UNKNOWN_PDP_ADDRESS_TYPE`) or 55
(`MULTI_CONN_TO_SAME_PDN_NOT_ALLOWED`).

The loop is a bug in `mmsd` (`/usr/lib/mmsd/main.py`), and its author knows:

```python
# if internet and MMS context APNs clash, MMS won't work and it will cause an
# infinite loop here which causes data instability
if internet_apn == mms_apn:
    return True
```

The guard only fires when the two APNs are *equal*. A placeholder that is
merely wrong slips past it.

**Fix:** set the MMS context APN to the internet APN, which makes the guard
fire. Persistent in `/var/lib/ofono`, so no package update undoes it.

## 3. The netmask is dropped, and the address becomes a `/0`

oFono reports `Netmask: 255.255.255.0` in `ConnectionContext.Settings`.
ofono2mm copied `Address`, `Gateway` and `DomainNameServers` into `Ip4Config`
**but never the netmask**. ModemManager then has no `prefix` key and
NetworkManager uses 0:

```
modem-broadband[/ril_0]: address 10.44.112.50/0
ccmni0  UP  10.44.112.50/8  10.44.112.50/0
```

A `/0` address tells the kernel that the entire IPv4 internet is on-link on the
modem interface.

**Fix:** `netmask_to_prefix()` in `utils.py`, used at all three places that
build an `Ip4Config` (the signal path in `mm_bearer.py`, twice in
`mm_modem.py`). Upstream has since grown a function of the same name, so this
patch is in effect a backport.

## 4. `modem IP method unsupported` on every activation

`mm_bearer.doConnect()` brings the context up with
`Protocol = read_setting("protocol", "ip")` - IPv4-only by default. oFono then
never emits `IPv6.Settings` and `Ip6Config.method` stays 0 (`UNKNOWN`).
ofono2mm nonetheless generated the NetworkManager profile with
`ipv6.method: 'auto'` and reported `ip-type = 4` (IPV4V6), hardcoded.

**Fix:** the generated profile's `ipv6.method` follows the protocol actually
used, and `ip-type` reports the real family. The **existing** profile had to be
corrected once by hand - it is not regenerated when it already exists:

```bash
nmcli connection modify "Willkommen" ipv6.method disabled
```

## 5. Deadlock: NetworkManager waits in `prepare` forever

**This is the "you have to reboot the phone" bug.**

In `mm_modem_simple.Connect`:

```python
if self.mm_modem.bearers[b].active_connect == 0:
    self.mm_modem.bearers[b].active_connect += 1
    await self.mm_modem.bearers[b].doConnect()
    return b
# active_connect != 0 -> no return, falls silently through
```

`active_connect` was only decremented on `doConnect()`'s **success** path, and
`doConnect()` was decorated `@async_retryable()` - `times=0`, meaning retry
without limit. If the context activation kept failing, `doConnect` never
returned, `active_connect` stayed at 1 or more, and every later `Connect`
skipped that bearer without a word and fell through to `doCreateBearer`.
NetworkManager then sat in `prepare` without making another D-Bus call.

That is why toggling mobile data helped only sometimes (`Disconnect` does not
reset the counter) and a reboot always did.

**Fix:** the counter goes in a `finally`; a bearer with a connect in flight
returns that same bearer instead of falling through; `@async_retryable(6)`
instead of unbounded.

## 6. The signal bar can never leave zero

Three independent defects in one chain. They masked each other: the first makes
the bar dead, so nobody sees that the third is reporting impossible numbers.

### 6a. oFono never publishes a signal strength

`org.ofono.NetworkRegistration` has no `Strength` property on this device at
all:

```
$ dbus-send --system --print-reply --dest=org.ofono /ril_0 \
      org.ofono.NetworkRegistration.GetProperties
   Status, Mode, CellId, Technology, MobileCountryCode,
   MobileNetworkCode, Name        <- no Strength
```

75 s of `dbus-monitor` on the interface produced no `PropertyChanged` either.
oFono's core only exposes the property once a driver has reported a value
(`src/network.c`, initial value `-1`), and `signal_strength_callback` returns
silently when the query fails. The binder driver has the path
(`RADIO_IND_CURRENT_SIGNAL_STRENGTH_1_4`); the MTK HAL does not serve it.

Why it does not is still open, and finding out would mean restarting oFono with
debug output - which is not something to do casually on a phone that is also
someone's phone.

**It does now, and the heading above is kept as history rather than as fact.**
Measured again on 13 September, after the later fixes: `Strength` is in the
property list, `byte 6`, ModemManager reports exactly that 6 %, and
`dbus-monitor` counts eleven `PropertyChanged` for it in 75 s. Something
between the two measurements taught the driver to answer - the radio interface
went back to the shipped 1.4 in between, which is the obvious suspect and is
not proof.

Two things follow, and neither is "the fix was pointless". The `SignalQuality`
fallback in 6c is inert while the property is there: `update_signal_quality`
returns early rather than overriding a driver that does report. What still runs
is the poll, which feeds the Signal interface - `Rsrp`, `Rsrq`, `Rssi`, what
`mmcli --signal-get` and `modemctl signal` read - and nothing else fills those.
The two do not agree, either: oFono's own byte says 6 %, while RSRP of
-121 dBm through the curve in 6c says 24 %. Which is the better number for a
bar is not decided here.

### 6b. ofono2mm had no second source

`mm_modem.py` fed `SignalQuality` exclusively from that missing property, and
`mm_modem_simple.py` did the same for its `signal-quality`. With the property
absent, both stay at `(0, false)` for good - which is exactly what `mmcli`
printed as `0% (cached)`, and what a shell draws as the emptiest bar.

The second source was there all along: `org.ofono.NetworkMonitor`, which
ofono2mm already calls in `mm_modem_signal.py`, serves the serving cell's RSRP
and an ASU strength on this very modem.

### 6c. RSRP and RSRQ are swapped, in oFono itself

`plugins/cellinfo-netmon.c`, verbatim:

```c
if (lte->rsrp != OFONO_CELL_INVALID_VALUE) {
        params[n].type = OFONO_NETMON_INFO_RSRQ;   /* rsrp -> the RSRQ field */
        params[n].value = lte->rsrp;
...
if (lte->rsrq != OFONO_CELL_INVALID_VALUE) {
        params[n].type = OFONO_NETMON_INFO_RSRP;   /* rsrq -> the RSRP field */
        params[n].value = lte->rsrq;
```

On top of that, the HAL reports both as positive magnitudes with the sign
dropped, while the ModemManager API is defined in real dBm and dB, and
ofono2mm passed them through untouched. The result was `rsrp=10 dBm` and
`rsrq=120 dB` - both outside anything physics allows, which is what made the
defect findable without knowing anything about this device.

In the same block, `ChannelQualityIndicator` was being written into `rssi`. CQI
is a modulation-quality index from 0 to 15; as a received power it would read
as a better signal than any real cell.

**Fix:** read the two fields crosswise, negate the magnitudes, range-check
everything so the HAL's "unknown" placeholders are dropped rather than
forwarded, take `rssi` from `Strength` (ASU 0-31 per 27.007 §8.5, dBm =
-113 + 2 x ASU), and derive a percentage for `SignalQuality` that both
`mm_modem.py` and `mm_modem_simple.py` use while `Strength` is absent. A driver
that does report a strength keeps precedence.

The percentage anchors follow the level thresholds in AOSP's
`CellSignalStrengthLte` (-128 / -118 / -108 / -98 dBm), so the number of bars
matches what the same radio shows under Android.

### Verified against a third, independent source

`AT+CESQ` through `org.ofono.FuriLabs.AT`, read at the same moment as
`NetworkMonitor`:

```
+CESQ: 99,99,255,255,19,21,62,40,57
         rsrq index 19 -> -19.5 + 19*0.5 = -10.0 dB
         rsrp index 21 -> -140 + 21      = -119 dBm
```

| source | RSRP | RSRQ |
|---|---|---|
| `AT+CESQ` | -119 dBm | -10.0 dB |
| `mmcli --signal-get` after the fix | -120 dBm | -10 dB |
| `mmcli --signal-get` as shipped | **+10 dBm** | **+120 dB** |

`modemctl signal` runs that comparison for you and fails loudly when the two
disagree by more than 6 dB.

One more thing the fix needs: oFono's netmon is on-demand only, so ofono2mm
polls it every 30 seconds (every 3 seconds during startup, at most 20 times,
because the interface is exported long before the SIM is readable). Without
the fast start the bar sits empty for half a minute after every boot; with it,
measured 15 seconds from `systemctl restart ModemManager` to a filled bar.

## 7. Mobile data has no default route, so Wi-Fi off means offline

Found on 13 September 2026, and it had been true the whole time. Switching
Wi-Fi off left the phone with no network at all, while every part of the stack
reported itself healthy:

```
GENERAL.STATE:            100 (connected)
IP4.ADDRESS[1]:           10.13.195.47/8
IP4.GATEWAY:              --          <- nothing here
IP4.ROUTE[1]:             dst = 10.0.0.0/8, nh = 0.0.0.0
IP4-CONNECTIVITY:         3 (limited)
```

An address, an on-link route to its own subnet, and no way out. The only
component that says anything is wrong is NetworkManager's `limited`, and
nothing acts on it.

The cause is one line, three layers down. oFono reports the data call's
`Gateway` as the interface's **own address**:

```
Address:  10.13.195.47
Gateway:  10.13.195.47
```

That is a MediaTek RIL habit and it is not even wrong in spirit - the link is
point-to-point and genuinely has no gateway. `mm_bearer.py` passes the value
through unexamined (it is not ofono2mm's to invent) and ModemManager
republishes it.

**Correction.** This section first said NetworkManager refuses to build a
default route out of a next hop that is the local address. That was wrong, and
the truth is worse. There are two failure modes and this phone has both:

- **NetworkManager never sees the connect.** The data context is activated
  straight through oFono here - that is what the shipped
  `furios-mobile-data.service` does at boot, and what any hand activation
  does - so `modem-broadband` never processes a bearer, NetworkManager holds
  no IPv4 configuration for the device at all, and it installs nothing. The
  interface has an address (oFono put it there), an on-link route to its own
  subnet, and no way out. `IP4-CONNECTIVITY` reports `3 (limited)` and nothing
  acts on it. This is the state the phone is in after a normal boot.
- **NetworkManager does see the connect.** Then it installs the route, using
  the gateway it was given:

  ```
  default via 10.10.95.220 dev ccmni1 proto static metric 1050
  IP4-CONNECTIVITY: 4 (full)
  ```

  The kernel accepts it. It drops every packet:

  ```
  ping -I ccmni1 9.9.9.9 -> 3 packets transmitted, 0 received, 100% packet loss
  ```

  That is the worse one. A blackhole that looks like a working configuration,
  reported as full connectivity, with a plausible route in `ip route`.

Nobody in the chain is doing anything unreasonable, and the result is a phone
that cannot reach the internet either way.

**The link itself was never the problem.** With one route added by hand:

```
# ip route add default dev ccmni0 metric 1050
3 packets transmitted, 3 received, 0% packet loss   # 9.9.9.9, 55-293 ms
dig @61.8.132.52 github.com +short -> 140.82.121.4  # carrier DNS answers
```

No gateway, no `via`, just an on-link device route - which is exactly what
Android installs for these interfaces. The same interface, the same second,
carries nothing over NetworkManager's `via` route and everything over this one.

Replacing NetworkManager's route is safe: watched for 20 s after each replace,
it does not put its own back.

Both can also sit in the table at the same time - same destination, same
metric, different next hop, which the kernel keeps as two routes and picks
between by FIB order. That is a coin flip on every packet, so the watcher
deletes the via-route outright. Only ever when the next hop is one of the
interface's **own** addresses: a real gateway is somebody else's correct
configuration.

**This is why the watcher checks for `via`.** Its first version asked only
whether a default route existed on the interface at its metric - which is
true of NetworkManager's blackhole - and would have left the phone with a
route that eats every packet while reporting itself healthy. Found by
measuring rather than by reading, and only because the end-to-end test finally
had a live bearer to run against.

### Proven with Wi-Fi off

Everything above was measured with Wi-Fi up, on an interface nothing was
routing over. The whole-phone test - Wi-Fi off, does this thing work - had
never once completed: every attempt ran into a data call that dropped before
the test did. On 13 September it completed, in a scripted 25-second window
that switched Wi-Fi back on from a trap rather than from reaching the end.

With Wi-Fi off, `default dev ccmni0 metric 1050` was the only default route in
the table, and it is ours:

| | |
|---|---|
| `ping 1.1.1.1` | 3 of 3, **0% loss**, 56-74 ms |
| `curl http://1.1.1.1` | **HTTP 301 in 0.09 s** |
| `getent hosts heise.de` | nothing |
| `nslookup heise.de 61.8.132.52` | 193.99.144.80 - the carrier's own resolver answers at once |
| `nmcli networking connectivity` | `none` |

So the route carries real traffic to the real internet, which is what this
defect claimed and could not show. What does not work is name resolution, and
that is defect 10 - a different layer, found by this test.

Worth keeping in view: `connectivity none` on a phone that is demonstrably
online. NetworkManager checks connectivity by name, so a dead resolver reads
as a dead network, and defects 7 and 10 are indistinguishable from the
outside. Both end in a phone that says it has no internet.

### Why a watcher and not a connection profile

The obvious fix is `ipv4.routes` on the cellular profile. It was tried:

```
nmcli con mod Willkommen +ipv4.routes "0.0.0.0/0 0.0.0.0 1050"
nmcli dev reapply /ril_0
```

NetworkManager accepted it, reported success, and **flushed the interface** -
address gone, nothing put back. Repeating the reapply with the route removed
did the same, so the route was not the cause: NetworkManager holds no IPv4
configuration for this device at all. It logs the bearer's settings once at
connect time and never sees the address that oFono puts on the interface
afterwards, which is also why the kernel shows a `/8` while ModemManager
insists on a `/24`. Reapplying makes it write down what it believes, and it
believes nothing.

So the route is asserted from outside, by `furios-mobile-route`, driven by
netlink:

- **Which interface** comes from ModemManager's *default* bearer, asked fresh
  each time. Never a glob over `ccmni*`: the IMS bearer has its own `ccmni`
  with its own address, and routing the world down the IMS APN would be a far
  worse bug than the one being fixed.
- **Metric 1050**, above Wi-Fi's 600. Both defaults sit in the table at once,
  Wi-Fi wins while it is there, and the mobile one takes over the moment it is
  not. Nothing switches and nothing reconnects, so a connection in flight
  survives the changeover.
- **It checks before it writes.** Every write comes back as a netlink event; a
  watcher that wrote on every event it saw would be an endless loop.
- **It removes its own route** when the default bearer goes away. A default
  route to an interface with nothing behind it is worse than none: traffic
  leaves and never comes back, instead of failing at once.

Cost: one process blocked on a netlink socket. No timer, no polling, no
wakeups - which on a phone is the difference between a fix and a new problem.

### The standing fight, and who keeps it going

The watcher says the same thing every five minutes, all day:

```
17:19:14  removed the via-10.46.119.239 route on ccmni0 (it drops every packet)
17:24:15  removed the via-10.46.119.239 route on ccmni0 (it drops every packet)
17:29:16  removed the via-10.46.119.239 route on ccmni0 (it drops every packet)
```

301 seconds apart, to the second, and no journal anywhere names what put the
route back. The obvious reading is a timer somewhere in NetworkManager. The
truth is worse and more interesting: **there is no independent timer. The loop
is closed, and this watcher is one of its two halves.**

Caught with `ip -ts monitor route` on one side and NetworkManager's own debug
logging on the other. The route arithmetic gives it away before the log does:

```
18:00:50.176  default via 10.43.240.243 dev ccmni1 proto static metric 21050
18:00:51.710  default via 10.43.240.243 dev ccmni1 proto static metric  1050
18:00:51.710  Deleted  ... metric 21050
18:00:52.331  Deleted  ... metric  1050          <- furios-mobile-route
```

Two additions for one route, at two metrics, 1.5 s apart. 21050 is 1050 plus
20000, and 20000 is what NetworkManager adds to a device's default route while
it considers that device's connectivity degraded. So the route was installed
twice: once under a penalty, once without. Its own log says why:

```
connectivity: (ccmni1,IPv4,364) skip connectivity check due to no global route configured
connectivity: (ccmni1,IPv4,364) check completed: LIMITED; no global route configured
device (/ril_0): connectivity state changed from FULL to LIMITED
platform: (ccmni1) route: append IPv4 route: ... metric 21050
connectivity: (ccmni1,IPv4,365) start request to 'http://conncheck.furios.io'
connectivity: (ccmni1,IPv4,365) check completed: FULL; expected response
device (/ril_0): connectivity state changed from LIMITED to FULL
platform: (ccmni1) route: append IPv4 route: ... metric 1050
platform: (ccmni1) ip4-route: delete ... metric 21050
```

Read it as a cycle and it closes on itself:

1. The watcher deletes NetworkManager's route.
2. NetworkManager now has no default route **of its own** on that device. Ours
   is in the kernel table the whole time - it counts only the ones it
   configured.
3. Five minutes later the connectivity check comes round and **does not run**:
   "skip connectivity check due to no global route configured". It reports
   LIMITED without testing anything.
4. LIMITED means penalty, so the default route goes back in at 21050.
5. Now there is a route, so the check runs for real, fetches
   `conncheck.furios.io`, and comes back FULL.
6. Penalty lifted: the route is reinstalled at 1050 and the 21050 copy deleted.
7. The watcher sees the netlink event, recognises the next hop as the
   interface's own address, and deletes it. Back to 1.

The 301 seconds are `connectivity.interval`, which is 300 by default and is not
set anywhere on this phone, plus the second NetworkManager spends on the second
attempt. The gaps in the list above that are not 301 - 542 s, 503 s - are the
ones where the bearer changed interface in between and the cycle restarted.

**What it costs.** Between the moment NetworkManager reinstalls its route at
metric 1050 and the moment the watcher removes it, both defaults sit in the
table with the same destination and the same metric, and the kernel picks by
FIB order. Measured at **621 ms**, once every five minutes, and only while
traffic is on mobile data. Plus three `ip` writes and the watcher's three
`mmcli` calls per round.

**What it is not.** It is not a fight the phone would have without us. Left
alone, NetworkManager would keep its route, every check would pass, and nothing
would repeat - at the price of a default route that drops every packet, which
is the whole reason section 7 exists. The choice is not between the loop and
quiet; it is between the loop and the black hole.

**What could end it.** `ipv4.never-default=yes` on the cellular profile would
stop NetworkManager installing a default route at all, which ends the cycle at
step 4. The price is that the device then never has a global route by
NetworkManager's reckoning, so it is LIMITED for good - which feeds the primary
connection and metered logic above it. Worth measuring before it is worth
doing. Not done.

## 8. The filled resolver nobody asks

The other half of "Wi-Fi off means offline", found the same day and only
because the route fix made it visible: with routing repaired, packets left the
phone and not a single name resolved.

FuriOS configures NetworkManager in
`/usr/share/furios-quirks/xtables-legacy/99-furios-backend.conf`:

```
[main]
dns=dnsmasq
```

which NetworkManager resolves to:

```
dns-mgr: init: dns=dnsmasq,systemd-resolved rc-manager=resolvconf (auto), plugin=dnsmasq
```

`rc-manager=resolvconf` means NetworkManager writes `/etc/resolv.conf` by
calling `/usr/sbin/resolvconf`. On this system that is a symlink to
`resolvectl`, and NetworkManager calls it with `NetworkManager` as the
interface name. So every single network change ends in:

```
resolvconf[65259]: Failed to resolve interface "NetworkManager": No such device
dns-mgr: could not commit DNS changes: resolvconf failed with status 256
```

Three resolvers, and the wrong one wins:

| | holds | consulted |
|---|---|---|
| NetworkManager's dnsmasq, `127.0.0.1` | Wi-Fi **and** carrier servers, correctly prioritised | never |
| systemd-resolved stub, `127.0.0.53` | Wi-Fi only | by everything |
| `resolvconf` | - | fails, every time |

`/etc/resolv.conf` is a symlink to systemd-resolved's stub, and NetworkManager
is never allowed to replace it with one pointing at the resolver it fills.
`resolvectl status` tells the story plainly: `wlan0` has `192.168.0.1`, and not
one `ccmni` link has a DNS server at all. `nsswitch.conf` is
`hosts: files myhostname dns` - no `resolve` module, so lookups really do hang
on that one file.

Measured, with Wi-Fi up, against the resolver nobody was asking:

```
dig @127.0.0.1 github.com +short   ->  140.82.121.4
```

It was right the whole time.

**Fix:** `rc-manager=symlink` in a drop-in numbered *above* the FuriOS one
(conf.d is read alphabetically and the later file wins), plus setting the
symlink once - NetworkManager will not replace a symlink that points somewhere
else, so that half is ours. `rc-manager` is picked up by
`systemctl reload NetworkManager`; no restart needed.

`modemctl apply` deliberately does **not** reload NetworkManager. A reload makes
oFono clear and re-activate the data context, and on a weak cell that comes
straight back as `Unexpected data call status 65535` and leaves mobile data
down. The symlink works immediately; the drop-in can wait for the next reload
or boot.

## 9. A dropped data call stays dropped

Watched on 13 September, in one hour, on one phone:

```
13:00:55  ofonod: Unexpected data call status 65535
13:06     no address on any ccmni, bearer connected=no
13:12     still down
```

Nothing brings it back. The context is activated once, at boot, and after that
the shipped system has no opinion about whether mobile data exists. Every
recovery that day was a hand-typed `SetProperty Active true`.

That turns fix 7 into half a fix: a fallback route to an interface nobody
revives is not a fallback.

`furios-mobile-context` supervises it, and almost all of its code is about not
acting:

- **`Powered=false` is a decision.** Somebody switched mobile data off. A
  daemon that switches it back on is a bug with a service file.
- **Not attached, or not registered, means there is nothing to ask.** Retrying
  into an absent network keeps a struggling radio busy instead of letting it
  find a cell. `unregistered` contains `registered`, so the match is quoted -
  a loose one would retry hardest exactly when it helps least.
- **Never during a call.**
- **The backoff list is also the attempt limit** (15, 30, 60, 120, 300, 300).
  When it runs out the supervisor stops and waits for the radio to change
  state. At -132 dBm no amount of asking helps and asking costs power.
- **Active=true is not proof.** oFono reports it on a context whose data call
  is gone, so the test is whether the interface it names carries an address.

The escalation exists because of a state this device really reached: oFono
answering `SetProperty` with a clean `method return`, logging nothing, doing
nothing, and swallowing every further request because it already believed
`Active=true`. `Powered` false, four seconds, true - then it came back. It is
not the first move, because cycling `Powered` drops data outright.

Woken by oFono's signals, not a clock: the loop blocks on `dbus-monitor`, and
the timer is a net under it rather than the mechanism. Healthy, one look every
five minutes and nothing at all in between.

**Watched, and it did nothing - correctly.** Deactivating the context by hand
brings it back in about two seconds without the supervisor logging a word, and
it is **oFono itself** that does it - checked by switching NetworkManager's
autoconnect off for the cellular profile and trying again, which changed
nothing:

```
ofonod: Activating context: 1
ofonod: setting up data call
```

Which makes sense: on LTE the default EPS bearer belongs to the attach, and
tearing the context down leaves the modem re-establishing it. A clean
deactivation is therefore not the failure mode at all and cannot stand in for
one.

The failure mode is a data call that fails to *set up* - status 65535 - after
which nothing retries. That cannot be produced on demand, so the acting path
is covered by the tests and not yet by the radio. What has been watched live,
twice, is the supervisor correctly staying quiet.

**Do not run two.** `furios-mobile-data.service` on this phone activated the
same context at boot. Two things racing on one D-Bus property is a good way
back into the state above, so `modemctl status` warns when both are enabled.
It has been switched off here - disabled, not deleted - and the supervisor
carries the boot instead.

Which put a hole in the loop worth closing: `dbus-monitor` only attaches when
the pipeline starts, so anything oFono says while the service is still getting
ready is lost - and at boot that is exactly the registration being waited for.
Missing it used to mean sitting on the idle timer for an hour. The first wait
after startup is now capped at ten seconds.

**And it did carry one, watched once.** A real reboot on 13 September, with
`furios-mobile-data.service` still disabled, so nothing but these three units
was in charge:

```
13:40:58  furios-modem-fixes   starting
13:41:42  furios-modem-fixes   finished - patches in place
13:41:42  furios-mobile-route  started
13:41:59  furios-mobile-context started
13:41:59  furios-mobile-context  no oFono modem or no internet context
13:42:00  furios-mobile-context  no oFono modem or no internet context
13:42:05  furios-mobile-route    default route on ccmni0 (metric 1050)
          (and then nothing)
```

The silence at the end is the evidence, not the absence of it. `pass()` logs
when it acts and when it finds nothing to supervise; a context that is simply
up, with no failures behind it, goes by without a word. So the two lines at
13:41:59 and 13:42:00 are the modem not being there yet, and the quiet after
them is the next pass finding it. That pass happened because of the ten-second
cap above - on the old idle timer the first look would have been an hour away.

Three minutes in: `/ril_0/context1` `Active=true`, ccmni0 carrying an address,
`default dev ccmni0 metric 1050` in the table, `modemctl status` `ok` on every
line.

Two limits on what that proves. The supervisor did not bring the data call up
- oFono did, exactly as described above; what is shown here is that it started,
looked, found the work already done and stayed quiet. And Wi-Fi was up the
whole time, so every packet left over wlan0 at metric 600, and the route on
ccmni0 was carrying nothing at the time. That it carries at all was settled
twenty minutes later, with Wi-Fi actually off - in defect 7.

## 10. The resolver is pinned to an interface that does not exist

Defect 8 got `/etc/resolv.conf` pointing at the resolver NetworkManager
actually fills. This is the next thing down, and it only became visible once
that was true: dnsmasq is now asked, and dnsmasq cannot reach the carrier's
servers, because it is given the right servers over the wrong link.

Watched live first. 13 September, 13:47:27, Wi-Fi switched off from the shell:

```
audit: op="radio-control" arg="wireless-enabled:off" pid=3261 uid=32011
policy: set 'Willkommen' (ccmni2) as default for IPv4 routing and DNS
dnsmasq: using nameserver 61.8.132.52#53(via ccmni2)
```

Wi-Fi was back on nineteen seconds later. Nothing had worked in between.

`ccmni2` is DOWN and has no address. The data call is on `ccmni0` - and every
other component in the chain knows that:

| | interface |
|---|---|
| ModemManager bearer 0, `connected: yes` | **ccmni0** |
| oFono `/ril_0/context1`, `Active=true` | **ccmni0** |
| the address, `10.35.25.230` | **ccmni0** |
| our default route, metric 1050 | **ccmni0** |
| **NetworkManager, connection 'Willkommen'** | **ccmni2**, down, no address |

NetworkManager has not named `ccmni0` once since boot - zero occurrences in
its journal.

### Why dnsmasq says REFUSED

A server bound to an interface that is down is not a slow server. It is no
server at all, and dnsmasq says so in the fastest way it has. Same version,
same moment, same network, one dnsmasq per row - only the binding differs:

| server given to dnsmasq | answer | its own log |
|---|---|---|
| `61.8.132.52` | NOERROR | `query` → `forwarded` → `reply` |
| `61.8.132.52@ccmni0` (live) | NOERROR | `query` → `forwarded` → `reply` |
| `61.8.132.52@ccmni2` (down) | **REFUSED** | `query` - and nothing after it |

The third row is the phone. dnsmasq accepts the query, finds that its only
nameserver sits on an interface it cannot send from, forwards nothing and
refuses - in 0 ms, no timeout, no error. Its own counters agree: `queries
answered locally` rises, `queries forwarded` does not move. It is the same
state it reports at startup as `no upstream servers configured`.

Restarting it does not help - a fresh instance is handed the same bound
servers and refuses just as fast. Neither does the obvious repair of setting
the servers unbound over D-Bus: dnsmasq logs them without the `via`, and still
refuses, for five, ten, fifteen seconds. The same servers passed on the
command line work immediately in a test instance. Why the D-Bus path behaves
differently is **not understood** and is not needed for the fix.

### Where the dead interface comes from

Not from oFono, and not from the bearer: both name `ccmni0` correctly. It is
ofono2mm's port list. Three places learn an interface name and append it -
`mm_modem.py` in `check_ofono_contexts` and `ofono_context_added`,
`mm_bearer.py` in `ofono_context_changed` - and **not one of them ever removes
one**. `check_ofono_contexts` runs exactly once, at startup. So an interface
that carried an earlier data call stays in the list for the life of the
process:

```
modem.generic.ports.value[2] : ccmni0 (net)
modem.generic.ports.value[3] : ccmni2 (net)   <- from the first data call
```

ModemManager offers two net ports for one modem, NetworkManager picks one, and
this phone picks the corpse. That is the whole chain: a list that only grows,
three layers up from a resolver that refuses.

### The fix, and what it proved

The port list is made to say what the bearers actually have: a `sync_net_ports`
that rebuilds it from the bearers' own `Interface` property, called wherever an
interface is learned or lost, instead of three separate appends. A bearer whose
`Settings` go away now clears its interface rather than leaving the name
behind. Pinned down in `tests/test-ports.py`, including the two mistakes in the
other direction - dropping the IMS context's own ccmni, and announcing a change
when nothing changed.

With that in place, and Wi-Fi switched off for real:

```
dnsmasq: using nameserver 61.8.132.52#53(via ccmni0)
```

| | before | after |
|---|---|---|
| dnsmasq | REFUSED | **NOERROR** |
| `getent hosts heise.de` | nothing | answers |
| `getent hosts github.com` | nothing | 140.82.121.4 |
| `ping 1.1.1.1` | 0% loss | 0% loss |
| `curl https://heise.de` (by name) | - | **HTTP 301 in 0.15 s** |
| `nmcli networking connectivity` | `none` | **`full`** |

The last row is the one to keep. `full` means NetworkManager resolved a name
over mobile data on its own - the check that had reported `none` on a phone
that was passing packets the whole time.

Two things this does not settle. Whether NetworkManager picks the live
interface by rule or by luck when a modem really does have two net ports is
untested - here there is now only one to pick. And the fix was proven after a
restart of ModemManager, not across a reboot.

And because NetworkManager tests connectivity by resolving a name, this
reported as `connectivity none` on a phone that was passing packets - which is
exactly what defect 7 looked like from the outside, and why this sat
underneath it undetected for so long. Two different defects, one symptom: Wi-Fi
off means offline.

---

## 11. The modem ends up with no technology and no mode at all

`mmcli` on the 2026-09-13 boot, with oFono sitting right next to it holding
`AvailableTechnologies = gsm, umts, lte`:

```
Hardware |  supported: lte              <- gsm and umts are gone
Modes    |  supported: allowed: none; preferred: none    <- no mode at all
```

The data path was perfect throughout - `curl` over `ccmni0` answered HTTP 301
in 0.21 s - which is why nothing complained. `AccessTechnologies` was correct
too (16384, LTE). Only the modem's *capabilities* and *modes* were wrong, and
they were wrong for the whole uptime.

`mm_modem.py` computes both in `set_props()`:

```python
if 'org.ofono.RadioSettings' in self.ofono_interface_props:
    if 'AvailableTechnologies' in self.ofono_interface_props['org.ofono.RadioSettings'].props:
        ...                       # caps |= 4/8/64, modes |= 2/4/8/16
...
if caps == 0:
    self.props['CurrentCapabilities'] = Variant('u', 8)   # lte, and only lte
...
if modes == 30: ...
if modes == 14: ...
if modes == 6: ...
if modes == 2: ...
self.props['SupportedModes'] = Variant('a(uu)', supported_modes)
```

With no `AvailableTechnologies` to read, `caps` stays 0 and the fallback pins
LTE alone. `modes` stays 0, which matches none of the four totals the table is
written for, so `supported_modes` is never appended to and `SupportedModes`
comes out **empty**. Not "reduced" - empty.

### Why it never repaired itself

`set_props()` re-runs on every *change* of a watched property, so almost
anything wrong here corrects itself within seconds. `org.ofono.RadioSettings`
is the exception: its properties are static. `AvailableTechnologies` does not
change while the modem runs, so no `PropertyChanged` is ever emitted for it,
so nothing ever re-runs the computation. `add_ofono_interface` recomputes the
3GPP interface, the SIM and the signal interface when an interface arrives -
the modem's own properties were the one thing it did not.

The 30-second signal poll does not help either: our own fix for defect 6 emits
`SignalQuality` directly and never goes through `set_props()`.

### Proof

A plain restart of ModemManager, nothing else touched:

| | before | after |
| --- | --- | --- |
| `CurrentCapabilities` | `8` (lte) | `12` (gsm-umts, lte) |
| `SupportedModes` | `(0, 0)` | 2g, 3g, 4g |
| `CurrentModes` | `(0, 0)` | allowed 4g |

So it is a race at startup, not a permanent state - this boot lost it, an
earlier one the same day won it. `TechnologyPreference` stayed `nr` across the
restart and there were no Error 44.

### The fix

Recompute the modem's own properties when `RadioSettings` arrives, and ask
oFono again first if the interface came up with nothing:

```python
if iface == "org.ofono.RadioSettings":
    if 'AvailableTechnologies' not in self.ofono_interface_props[iface].props:
        await self.ofono_interface_props[iface].init()

    await self.set_props()
```

The second half is not decoration. There are two ways to reach this point with
nothing to compute from and they are indistinguishable afterwards: the
interface arrived late, or its one read failed. `DBusInterface.init()` catches
its own failures and leaves the properties empty rather than raising, so the
outer retry loop in `add_ofono_interface` never sees anything to retry. The
first version of this fix recomputed and found nothing to compute from, and
the test caught it.

It is deliberately narrow. Recomputing for every interface would also move the
modem's power-on - which happens inside `set_props()` - earlier into the
startup gather, and boot ordering is exactly what is fragile here.

### 11b. The same symptom again, from an interface that was never there

The boot of 2026-09-13 15:15 came up with exactly the numbers above -
`CurrentCapabilities 8`, `SupportedModes (0, 0)` - with the fix above
installed and applied. So there is a third way in, and it is the one that
actually happens.

`add_ofono_interface` looks like it retries five times over two and a half
seconds and gives up loudly. It does neither. The proxy it asks through is not
built by introspecting oFono; it is built from a static XML file shipped with
the package:

```python
self.cache[hash(introspection)] = f.read()          # ofono_modem.xml, at startup
proxy_object = self.bus.get_proxy_object(self.bus_name, path, self.cache[...])
```

`org.ofono.RadioSettings` is in that file, so asking for it hands back a
perfectly good object whether or not oFono has ever registered the interface.
The call on it fails, but one layer further in:

```python
except Exception as e:
    retries_left -= 1
    ...
    else:
        ofono2mm_print(f"Interface {self.interface} doesn't have properties? ...")
```

`DBusInterface.init()` catches that itself and returns normally with empty
properties. Nothing propagates. So `add_ofono_interface` never sees an
exception, never retries, and reports success for an interface that does not
exist yet - and the immediate second read the 11 fix adds hits the same wall a
millisecond later. oFono registers `RadioSettings` when the modem comes up,
seconds after this, and by then the two bursts are over.

Two bursts is all there are. `add_ofono_interface` is called from
`init_ofono_interfaces()` once when the modem object is built, and from
`sim_unlocked()` if the SIM is unlocked later. Nothing else ever enumerates.
oFono does announce the arrival - it publishes the modem's `Interfaces`
property - and the handler for it recomputed properties without ever going
back to read the interface that had just appeared:

```python
async def ofono_changed(self, name, varval):
    await self.set_props()          # recompute from what we have
```

For every other interface that is enough, because a property that changes
carries its value along with the signal. For the one interface whose
properties never change, that list is the only announcement it will ever make,
and nobody was listening.

Timeline of the boot that failed, from the journal:

| | |
| --- | --- |
| 15:15:31 | ModemManager (ofono2mm) started |
| 15:15:39 | `ofono.service` starts waiting for the radio HAL |
| 15:15:48 | `IRadio/slot1` appears, ofonod starts |
| 15:15:51 | SIM card OK - the modem is still coming up |
| 15:17 | `CurrentCapabilities 8`, `SupportedModes (0, 0)`, oFono has gsm, umts, lte |

Restarting ModemManager at 15:20, with oFono long settled, gave `12` and
twelve supported modes immediately. Same binary, same fix, different starting
order.

The repair is to listen to the announcement, and to ask again for anything in
it that was asked for before oFono had it:

```python
async def ofono_changed(self, name, varval):
    if name == 'Interfaces':
        await self.resync_ofono_interfaces(varval.value)

    await self.set_props()
```

Only interfaces whose properties are still empty are asked again, so once a
read works the condition is false forever - which matters, because oFono
republishes that whole list every time any interface comes or goes. The ones
ofono2mm deliberately keeps without properties (`NetworkMonitor`,
`FuriLabs.AT`) are excluded, or their permanently empty dict would have them
re-read for the life of the process.

One thing had to be fixed alongside it: `add_ofono_interface` registers the
property watcher every time it runs. Going through it a second time would have
registered a second watcher on the same interface, and every later change
would recompute everything twice, forever. The watcher is now registered once
per interface.

### What is NOT claimed

Whether this is what hides the technology label in the shell is **not
established** - and defect 12 later showed that it is not: `AccessTechnologies`
was correct the whole time, as suspected here, and the shell was missing a
modem object entirely for an unrelated reason. What is established for this
defect is that ModemManager reported no capabilities and no modes while oFono
had three technologies, and that the fix removes that.

---

## 12. No signal icon, with a modem that is working perfectly

The 2026-09-13 15:25 boot. Every measurement said the stack was healthy:

```
Status  |  state: registered          packet service state: attached
        |  access tech: lte           signal quality: 22% (recent)
Bearer  |  connected: yes             interface: ccmni0
```

`ping -I ccmni0 1.1.1.1` - 0% loss. Error 44 since boot - none. `modemctl
status` - everything in place, including defect 11's fix holding across a cold
start. And the phone showed **no mobile signal icon at all**.

The only trace anywhere:

```
phosh[3678]: (../libmm-glib/mm-object.c:108):mm_object_get_modem:
             runtime check failed: (MM_IS_MODEM (modem))
phosh[3678]: modem_init_modem: assertion 'self->modem' failed
```

`mmcli` printed the same warning three times per run and was ignored for it -
it printed all the right values afterwards, so it read as cosmetic. It is not.
Three times is once per object that is not a modem.

### What the ObjectManager hands out

Asking libmm-glib for what ModemManager announces, the way any GUI does:

```
Objects in the ObjectManager: 4
  /org/freedesktop/ModemManager1/Bearer/1   modem-proxy: NULL
  /org/freedesktop/ModemManager1/Modem/0    modem-proxy: OK    15 interfaces
  /org/freedesktop/ModemManager1/SIM/0      modem-proxy: NULL
  /org/freedesktop/ModemManager1/Bearer/0   modem-proxy: NULL
```

Real ModemManager answers that question with modems and nothing else. It does
export SIMs and bearers on the bus, at exactly these paths - but it builds its
ObjectManager from modem skeletons alone, and a client reaches a bearer
through the modem's `Bearers` property, never by enumeration.

ofono2mm has no ObjectManager of its own. dbus_fast synthesises one from the
export table:

```python
nodes = [node for node in self._path_exports
         if msg.path == "/" or node.startswith(msg.path + "/")]
```

Every exported sub-path, which is every SIM and every bearer.

### Why that is fatal rather than untidy

phosh, `src/wwan/phosh-wwan-mm.c`:

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
assumption plainly. Against ModemManager the assumption holds. Against ours it
is a coin toss.

Worse than a coin toss, because `self->object` is assigned *before*
`modem_init_modem` asserts. Once phosh has latched onto a bearer, the
`if (!self->object)` guard is false for every object that arrives afterwards -
including the modem. It does not retry. There is no icon until something
restarts phosh or ModemManager.

The order of the list is GLib hash order over the paths, which is why this
looked intermittent across reboots and why it correlates with nothing
obvious. The bearers only exist at all if the data call came up before phosh
started, so a boot that connects slowly hides the bug and a boot that connects
quickly shows it.

This is also the answer to the question left open under defect 11: the
technology label was missing for this reason, not for that one.
`AccessTechnologies` was right all along, as suspected there - phosh simply
never had a modem to read it from.

### The fix

Announce modems, the way ModemManager does. `main.py` gets a bus that narrows
the three ObjectManager entry points and changes nothing else:

```python
class ModemManagerBus(MessageBus):
    @staticmethod
    def _is_announced(path):
        if not path.startswith(MM_ROOT + '/'):
            return True
        return path.startswith(MM_MODEM_PREFIX)
```

`GetManagedObjects` at `/org/freedesktop/ModemManager1` runs against a
narrowed export table and puts it straight back; `InterfacesAdded` and
`InterfacesRemoved` are suppressed for the paths that should never have been
announced. The SIM and the bearers stay exported and stay reachable at their
own paths - they are simply not enumerable, which is the actual contract.

Restoring `_path_exports` afterwards is not a detail: dbus_fast serves every
later call from that same table, so leaking the narrowed one would make the
daemon forget its own SIM. It is restored in a `finally`, and the test proves
it for the throwing case too.

### Proof

Same query, after the fix, with ModemManager restarted and nothing else
touched:

```
Objects in the ObjectManager: 1
  /org/freedesktop/ModemManager1/Modem/0    modem-proxy: OK    15 interfaces
```

No warnings from `mmcli` any more, on any invocation. `mmcli -m 0 --sim 0`
still prints the IMSI, `mmcli -b 0` still reports the bearer connected on
`ccmni0`, and `ping -I ccmni0` still loses nothing. The SIM and bearers went
nowhere; they stopped being announced.

---

## 13. Emergency alerts the phone is not allowed to subscribe to

The whole defect is one line in the journal at boot, in a file nobody opens:

```
dbus-daemon[980]: [system] Rejected send message, 2 matched rules;
  type="method_call", sender=":1.27" (uid=32011 comm="/usr/libexec/cellbroadcastd")
  interface="org.freedesktop.ModemManager1.Modem.CellBroadcast" member="SetChannels"
  error name="(unset)" destination=":1.19" (uid=0 comm="... ofono2mm")
cellbroadcastd: Failed to set channel list in '/org/freedesktop/ModemManager1/Modem/0':
  GDBus.Error:org.freedesktop.DBus.Error.AccessDenied
```

Nothing else shows it. The modem is registered, data flows, `mmcli` is green,
`modemctl status` was green, and the phone would simply have stayed quiet
through a public warning.

### Why the call is refused

`/usr/share/dbus-1/system.d/org.freedesktop.ModemManager1.conf` opens with

```xml
<deny send_destination="org.freedesktop.ModemManager1" send_type="method_call"/>
```

and then lists, interface by interface and member by member, what is allowed
anyway. ModemManager 1.24 added the `Modem.CellBroadcast` interface **and** a
polkit action to guard it (`org.freedesktop.ModemManager1.CellBroadcast`,
`allow_active=yes`) - but no rule in this file. The bus therefore turns the
call away before polkit is ever asked. The polkit action is real, reachable
and never consulted.

Checked against upstream: `data/org.freedesktop.ModemManager1.conf.polkit` at
tag `1.24.2` contains **no** mention of CellBroadcast; on `main` it carries
three rules - `List` for everyone, `Delete` and `SetChannels` behind polkit.
So this is a gap in the shipped version, closed upstream since.

Two policy files of that name exist on this phone, and only the layout saves
us: ofono2mm ships its own in `/etc/dbus-1/system.d`, which takes precedence
over a file of the same name in `/usr/share`. It is 373 bytes and grants group
`radio` the `Modem` interface. Had it been a fuller copy, it would have
replaced ModemManager's entire policy, and far more than cell broadcast would
have been dead.

### What it costs

oFono's own channel list, before the fix:

```
Topics: 4370,4372,4378,4383,4385,4391,4396-4397     8 channels
```

What cellbroadcastd wanted to set, from `serviceproviders.xml` for this
country:

```
Topics: 919,4370-4371,4373-4392,4396-4397          25 channels
```

Eight channels against twenty-five. The gaps are not decoration: 4371-4392 is
where the graded public warnings live.

### The fix

Not a patch - a drop-in of our own, `dbus/furios-modem-cellbroadcast.conf`,
installed by `modemctl apply` and removed by `revert`. Deliberately **narrower
than upstream's**: upstream grants the methods in `context="default"` because
ModemManager checks polkit afterwards, and ofono2mm checks polkit nowhere at
all. Copying it verbatim would put the emergency channel list in reach of
every local account. It goes to group `radio` instead - the group that already
owns the modem here, and the group cellbroadcastd runs in.

`modemctl status` reports the channel count rather than the file, because the
file is only the permission:

```
  ok    cell broadcast: 25 emergency channels set
```

### Measured

13.9., after `systemctl reload dbus` and a restart of cellbroadcastd: no
rejection in the journal, `Channels` on ModemManager and `Topics` on oFono
both at the 25-channel list, `modemctl status` green.

**One channel was lost**: 4372 was in the modem's old list and is not in
`serviceproviders.xml` for `de`, while 4371 and 4373-4378 are. That looks like
a gap in the database rather than a decision - 4371 and 4372 are a pair. Net
effect is +18 channels and -1.

---

## 14. The translation of a warning, without the warning

Found by fixing defect 13. Handing the country's channel list to the modem
raised it from 8 channels to 25 - and took one off it:

```
before:  4370,4372,4378,4383,4385,4391,4396-4397        8
after:   919,4370-4371,4373-4392,4396-4397             25   <- 4372 gone
```

4372 was in the modem's own list and is not in `serviceproviders.xml` for `de`.
It is not a national choice.

### The proof is in the entry itself

`serviceproviders.xml` groups channels by alert level. The German block:

```xml
<level type="extreme">
    <channels start="4371" end="4371"/>
    <channels start="4384" end="4384"/>
    <channels start="4385" end="4385"/>
</level>
```

ETSI TS 102 900 assigns EU-Alert **level 2** four message identifiers -
`1113`, `1114`, `1120`, `1121`, which is 4371, 4372, 4384 and 4385. The pairing
is an offset of 13: 4384 carries the local-language text of 4371, and **4385
carries the local-language text of 4372**.

So the entry subscribes to the translation of a warning without subscribing to
the warning. Nobody chooses that.

Three more things say the same:

- **Every other level in the block pairs cleanly** across that offset:
  presidential 4370/4383, severe 4373-4378/4386-4391, amber 4379/4392. Only
  `extreme` is short one.
- **The countries that get it right write it as a range.** `us` and `il` both
  carry `<channels start="4371" end="4372"/>`. `de` and `nl` carry
  `end="4371"`. One character.
- **`de` and `nl` are otherwise identical here**, so one slip explains both.

### Wrong upstream too

Checked against GNOME's `main`, fetched 13.9.: the same. No package update
brings this channel back, which is why it is fixed here rather than waited out.
The report is in
`upstream/mobile-broadband-provider-info-1-eu-alert-4372.md`.

### The fix

`modemctl apply` rewrites one line in each of the two country blocks and leaves
a marker on it:

```xml
<channels start="4371" end="4372"/><!-- furios-modem-fixes: EU-Alert level 2 is 4371-4372 -->
```

The marker is what `revert` looks for, so an upstream that fixes this itself is
never undone. This is the first file here belonging to a third package that
upstream rewrites constantly, so the caution is in what it refuses to do:

- it walks **only** `<level type="extreme">` inside `de` and `nl`;
- a block that does not look the way it expects reports `unknown` and is left
  alone - no guessing;
- the rewrite goes through a temporary file **beside the original**, never
  `/tmp`, since this runs as root;
- and the result must parse as XML before it replaces anything. A database that
  no longer loads takes the whole alert list with it, which is far worse than
  the one channel this adds.

Both countries are corrected, not just `de`: a German phone roaming in the
Netherlands reads the Dutch list, and the same slip is in both.

### Measured

13.9., after `apply` and a restart of cellbroadcastd, in oFono's `Topics`:

```
919,4370-4392,4396-4397        26 channels, 4372 among them
```

The gap in the middle of the range is gone.

---

## 15. A bearer that never hears its context

The phone came up on 13.9. at 17:03 with no mobile data at all, and nothing
said so. Wi-Fi was on, the signal icon was there, `mmcli` showed the modem
`registered`, `attached`, `lte`, oFono had the internet context `Active` with
an address on `ccmni0`, and `furios-mobile-context` was keeping it that way.
The only hint was one line in `modemctl status`:

```
--    no mobile data connected, no fallback route to check
```

NetworkManager had tried five times in four seconds and given up:

```
device (/ril_0): state change: disconnected -> prepare
modem-broadband[/ril_0]: failed to connect modem: missing data port
device (/ril_0): state change: prepare -> failed (reason 'config-failed')
```

`missing data port` is NetworkManager saying that ModemManager's bearer has no
`Interface`. And it did not:

```
Bearer/0:  connected: no,  no interface
Modem Ports:  [("/ril_0", 0)]        <- the control port, and nothing else
```

A modem with no net port cannot carry a connection, so Wi-Fi off would have
meant offline again - the failure of defect 7, with none of its causes.

### Where the silence comes from

ofono2mm builds an `MMBearerInterface` in three places:

| | called from | subscribes to the context |
|---|---|---|
| `check_ofono_contexts` | startup, and whenever oFono's interfaces resync | yes |
| `ofono_context_added` | oFono announcing a new context | yes |
| `doCreateBearer` | `Simple.Connect`, i.e. NetworkManager | **no** |

The first two end with

```python
ofono_ctx_interface.on_property_changed(mm_bearer_interface.ofono_context_changed)
```

`doCreateBearer` sets `mm_bearer_interface.ofono_ctx` and exports the object,
and never subscribes. Everything a bearer knows - `Connected`, `Interface`,
the addresses, its entry in the modem's port list - arrives through that one
callback. Without it the object answers every question with its constructor
defaults, forever.

Forever is not an exaggeration, and that is the second half of the defect:

```python
existing_contexts = [bearer.ofono_ctx for bearer in self.bearers.values()]
for ctx in contexts:
    if ctx[0] in existing_contexts:
        continue
```

The deaf bearer owns `/ril_0/context1`, so the path that would have subscribed
properly skips it from then on. Nothing reopens the question.

### Why it is intermittent

Which of the three runs first is a race between oFono publishing the internet
context and NetworkManager's autoconnect:

- oFono first - `check_ofono_contexts` builds the bearer, it listens, data works;
- NetworkManager first - `doCreateBearer` builds it, it is deaf, and mobile
  data is gone until something restarts ModemManager.

This boot NetworkManager won. At 17:03:50 `furios-mobile-context` still found
*no internet context at all* ("nothing to supervise"); NetworkManager knocked
at 17:03:54. Four minutes earlier, on the previous boot, the order had been the
other way round and the same phone with the same packages had working mobile
data - which is why this looked like it came out of nowhere.

Weak reception makes losing the race more likely, because registration is what
oFono waits for. It was -119 dBm RSRP that evening.

### Proving it, without guessing

The suspicion was the signal wiring, and there are three ways for a dbus_fast
subscription to be silently absent: no signal sent, a proxy built from static
XML that never matches the sender, or a handler on an object nobody kept. So
each was measured separately rather than argued about:

```
# 1. does oFono actually announce it?
sudo dbus-monitor --system "type='signal',path='/ril_0/context1'"
sudo dbus-send --system --print-reply --dest=org.ofono /ril_0/context1 \
    org.ofono.ConnectionContext.SetProperty string:Active variant:boolean:false
```

```
PropertyChanged  "Settings"  {}
PropertyChanged  "Active"    false
PropertyChanged  "Settings"  {Interface: ccmni0, Address: 10.9.54.198, ...}
PropertyChanged  "Active"    true
```

It does. Meanwhile `Bearer/0` stayed `connected: no` through all of it.

2. is the idiom itself sound? A 20-line script subscribed through ofono2mm's
own `Ofono` client, with the same static XML, dropped the proxy reference and
called `gc.collect()` - and received every one of those signals. So dbus_fast,
the XML and the object lifetime are all fine, and the fault is that ofono2mm
never subscribed at all.

3. `systemctl restart ModemManager` then made `check_ofono_contexts` build the
bearer instead, and the same phone, same radio, same context went to
`connected: yes, interface ccmni0` with NetworkManager connected in seconds.

**Note `dbus-send` without `--print-reply`.** It does not wait for a reply, so
it returns 0 whether the call succeeded or failed. Two toggles were "sent" that
way early on and appeared to produce no signal - which pointed at exactly the
wrong culprit. Always `--print-reply` when the answer is evidence.

### The fix

Subscribe in `doCreateBearer` too, in **both** branches that get hold of a
context - the provisioned one and the one it adds itself when MBPI provisioned
nothing. A phone whose carrier is not in the database would otherwise keep the
old silence.

Subscribe *before* setting `Active`, or the activation being asked for happens
before anyone is listening.

And subscribing is still not enough on its own: `Simple.Connect` can arrive
when the context is **already** active, and then there is no property change
left to hear. So the state is read once, `Settings` before `Active` - a bearer
that reports `Connected` without an `Interface` is precisely what
NetworkManager rejects as `missing data port`.

### Measured

Straight into the repaired path, with `mmcli -m 0 --create-bearer` - which is
`doCreateBearer` and nothing else:

```
before:  Bearer/1  connected: no
after:   Bearer/1  connected: yes, interface ccmni1, 100.80.165.176/24
```

`tests/test-bearer-wiring.py` holds the rule in place: whatever builds a
bearer, subscribes. It reads the shipped file with `ast`, so a fourth builder
added later fails the test instead of failing a boot.

---

## 16. The restart that takes the signal icon with it

`systemctl restart ModemManager` and the mobile signal icon is gone. Not for a
moment - for good. Measured on 14.9.: hours later the status bar still showed
nothing where the technology and the bars belong, on a stack where every
measurable thing was right:

```
modemctl status        everything in place
mmcli -m any           registered, attached, lte, signal 3% (recent)
ObjectManager          1 object
rfkill                 no block, WWAN on
phosh wwan backend     modemmanager
```

Nothing in `mmcli`, `modemctl` or NetworkManager notices, because nothing is
wrong with any of them. What is wrong is in the clients, and exactly one line
in the journal says so:

```
gsd-wwan[4154]: Error calling GetManagedObjects() when name owner (null)
  for name org.freedesktop.ModemManager1 came back:
  GDBus.Error:org.freedesktop.DBus.Error.AccessDenied: Rejected send message,
  1 matched rules; ... member="GetManagedObjects" ...
  destination=":1.3188" (uid=0 comm="/usr/bin/python3 /usr/sbin/ofono2mm")
```

### Why a permission error, for a call that is allowed

Restarting the service means the old process gives up the well-known name and
the new one takes it, and between those two moments nobody owns it. A GDBus
object manager client watching the name sees the owner disappear and re-sends
`GetManagedObjects` to the unique name it last knew - and in that gap no

```xml
<allow send_destination="org.freedesktop.ModemManager1"/>
```

can match, because a rule keyed on a well-known name matches nothing while
nobody owns it. What is left is the catch-all `<deny>` at the top of the
policy: *1 matched rules*. A moment later the same call gets
`ServiceUnknown: The name :1.20 was not provided by any .service files`
instead, once the old unique name is gone for good.

So it is not a permission problem, and there is nothing here to grant:
upstream lets anyone call `ObjectManager`, and the only policy that would
cover this gap is one that allows the call to **any** destination on the bus.
It is a handover gap, and the clients' own answer to it is to give up.

Hit at the same moment, on the same restart: `phosh` (the icon), `chatty`
(SMS), `wireplumber`. None of them retries when the name comes back.

### Where the gap comes from: ofono2mm drops its own name, on purpose

The handover is not systemd's. Measured on 14.9. with `dbus-monitor` on
`NameOwnerChanged` and on the bus driver's own method calls, across a restart:

```
t+0.000  :1.211 -> ""        old process stops
t+0.418  ""     -> :1.356    new process takes the name
t+0.564  :1.356 -> ""        ReleaseName   <- from :1.356 itself
t+0.569  ""     -> :1.356    RequestName
t+0.578  :1.356 -> ""        ReleaseName
t+0.587  ""     -> :1.356    RequestName
```

The same connection gives the name up and takes it back twice, 150 ms after
it first got it. With `MODEM_DEBUG=true` ofono2mm says so itself:

```
MMModemInterface(/ril_0).release_request_modemmanager: Releasing and requesting the bus name
```

`mm_modem.py`, called from `init_ofono_interfaces`, from `sim_unlocked`, and
from `set_props` when the modem is brought online:

```python
async def release_request_modemmanager(self):
    # Release and request the name so other apps realize we're here.
    # TODO: this feels like it shouldn't be necessary. We are signaling InterfacesAdded, so... why?
    await self.bus.release_name('org.freedesktop.ModemManager1')
    await self.bus.request_name('org.freedesktop.ModemManager1')
```

The comment is upstream's own. The poke is meant to make clients notice the
modem - and it is the thing that makes them blind, because every client that
connected during the second between "ModemManager is back" and "the modem is
ready" is holding a proxy that fires `GetManagedObjects` straight into a
release. It also explains the timing: the clients are not hit while systemd
swaps the processes, they are hit a moment *after*, all of them at once.

### It is a race, not a certainty

The second measurement on 14.9. is the one that decided the shape of the fix.
Ten minutes after the first, the same command on the same phone: not one
`GetManagedObjects` error in the journal, and **the icon stayed**. NetworkManager
still logged its own half of the damage (`modem with path ... already exists,
ignoring`), wireplumber still tripped over an assertion in its own bluez5
ModemManager code, and the shell was fine.

Whether a client is hit depends on where in the handover gap its call happens
to land. That rules out repairing unconditionally: killing the shell after
every restart would blink the screen of a phone whose icon was never gone.

Also in the journal at that moment, and deliberately **not** counted:

```
cellbroadcastd: Failed to set channel list in '/org/.../Modem/0':
  ServiceUnknown: The name :1.20 was not provided by any .service files
```

Same race, same restart - but the channel list lives in oFono, which was not
restarted. Measured immediately afterwards: all 26 channels still set. Naming
it as a casualty would send the next person after a failure that did not
happen. Neither is the `AccessDenied` of defect 13 counted, which is a
different failure with a different fix and matches on the same two words.

### Putting it back, and why `modemctl` does not do it for you

Restarting `gsd-wwan` alone does not do it - tried; phosh holds a proxy of its
own and logs nothing at all about it. Restarting the session target does
nothing either: the unit hangs off `gnome-session-initialized.target` and comes
straight back up in the state it was in. What does work is killing the unit:

```
systemctl --user kill --signal=KILL mobi.phosh.Shell.service
```

and that is where the first version of this fix went wrong. It killed the
shell automatically after every restart that cost the icon, and on 14.9. it
did exactly that, twice. The first time the shell was back in two seconds.
The second time the phone had no shell at all until it was started by hand,
because of what is in `mobi.phosh.Shell.service`:

```
OnFailure=gnome-session-shutdown.target
OnFailureJobMode=replace-irreversibly
RefuseManualStart=on
RefuseManualStop=on
```

A killed shell is a *failed* shell, so it drags the session shutdown in with
it, irreversibly - and `Restart=on-failure` then loses the race against that
job:

```
mobi.phosh.Shell.service: Failed to schedule restart job: Transaction for
  mobi.phosh.Shell.service/start is destructive (mobi.phosh.Shell.target has
  'stop' job queued, but 'restart' is included in transaction)
```

Nor can it be put back the obvious way: `systemctl --user start
mobi.phosh.Shell.service` is refused, the unit may only be pulled in by its
target. A repair that sometimes logs the user out is worse than the missing
icon it repairs.

**Fix:** `settle_shell` runs after every ModemManager restart `modemctl` itself
does, next to `settle_networkmanager`, which repairs the other half of the same
restart. For a restart by hand there is `modemctl settle`, which does both. It
reads the journal from the moment of the restart, on the failure signature
rather than the error text - GLib prints that line only when the call failed,
and the same restart hands out `AccessDenied`, `ServiceUnknown` or nothing at
all. Then it *says* what was lost, whose icon it is, that nothing else is
broken, and what the command is. It restarts nothing in the session: not the
shell, for the reason above, and not wireplumber either, because that takes
the Bluetooth card with it.

It looks at the window of the *last* restart, which systemd knows exactly
(`ActiveEnterTimestamp`) - not at "the last two minutes", so noticing the
missing icon an hour later still gets an answer. And without a recent restart
it leaves NetworkManager alone: the proxy it repairs is one a restart just
made stale, while a cellular device that is merely `unavailable` - airplane
mode, no SIM - would otherwise cost a NetworkManager restart and a Wi-Fi blink
for nothing.

A journal it cannot read is said out loud rather than answered with silence:
"nothing lost ModemManager" and "I could not look" are the same empty output,
and only one of them is true.

Measured on 14.9. against the real journal: two clients found from a real
restart the evening before, both named, nothing touched.

**Still open:** whether the shell can be cycled safely at all - a `SIGTERM`
that lets phosh exit cleanly would not trigger `OnFailure`, and the target
could then be started normally. Untested, because the way to test it is to
take the phone's screen away again.

**The better fix is upstream:** stop releasing the name. Nothing here needs a
client to re-enumerate; `InterfacesAdded` is already being signalled, which is
what upstream's own TODO says.

**What this does not catch:** a client that gives up without logging. Then
`modemctl settle` says "no client lost ModemManager" and means it - and the
icon is still gone anyway. The kill above is still the way back, with the
same caveat attached to it.

---

## 17. The fix for 16, booting a phone with no ModemManager at all

Defect 16 moved the bus name: instead of taking
`org.freedesktop.ModemManager1` at once, ofono2mm now waits until a modem is
built and ready to be shown, with a ten second timeout so that a phone with no
modem still gets a ModemManager on the bus. The phone was rebooted on 14.9. to
prove it.

It came up without mobile data. Two minutes in:

```
$ mmcli -L
error: couldn't find the ModemManager process in the bus
$ nmcli -t -f DEVICE,TYPE,STATE d | grep ril      # nothing
$ systemctl status ModemManager
     Active: active (running) since Mon 2026-09-14 08:26:09 CEST
   Main PID: 1254 (ofono2mm)
$ journalctl -b -u ModemManager
Sep 14 08:26:09 FuriS systemd[1]: Started ModemManager.service - Modem Manager.
```

One line in the journal, and that was all of it. The process was up, the event
loop was running - it was opening new sockets minutes after start - oFono had
`/ril_0` online and powered, and nobody owned the bus name.

Restarting the service by hand fixed it every time: the name appeared after
about five seconds. That difference is the whole finding. At boot ofono2mm
starts **seventeen seconds before oFono**, which spends nine of them in
`binder-wait` for `android.hardware.radio@1.0::IRadio/slot1`:

```
08:26:09  ModemManager.service (ofono2mm) started
08:26:17  ofono.service starting, binder-wait waiting for IRadio/slot1
08:26:26  "IRadio/slot1" appeared, oFono 1.29 up
```

By hand, oFono is always already there. The boot path is the one nobody tests
and the only one that matters.

### Three mistakes, and the third one hides the other two

```python
try:
    await bus.request_name('org.freedesktop.ModemManager1')
except Exception as e:
    ofono2mm_print(f"Failed to request ... bus name: {e}", verbose)
    return
```

**It cannot be heard.** `ofono2mm_print` returns immediately when `verbose` is
false, and the service does not run with `-v`. The one failure that decides
whether the phone has mobile data reports itself into nothing. That is why the
journal had a single line: not because nothing went wrong, but because the
only thing that would have said so was switched off.

**It does not read the answer.** `request_name` returns one of four outcomes,
and only `PRIMARY_OWNER` and `ALREADY_OWNER` mean the name is ours. `IN_QUEUE`
- somebody else holds it and we are second in line - raises nothing and was
indistinguishable from success.

**And it gives up in a way systemd cannot see.** `return` from `main()` does
not end the process: `asyncio.run` then waits for the background tasks that
outlive it. The daemon stays up, the loop keeps turning, `Restart=` never
fires, and nothing on the bus answers for ModemManager. A crash would have
been better; this is a service that is healthy by every measure systemd has
and does not exist as far as the rest of the system is concerned.

**Fix:** `take_bus_name` in `main.py`. Every outcome is printed with `print`,
not `ofono2mm_print`, so it is in the journal whether or not anyone asked for
verbose output. The return value is read, and only the two owning answers
count. And it does not come back without the name: it retries, waiting 1, 2,
4, 8, 16 and then 30 seconds, for ever. There is no situation in which a phone
is better off with a daemon that has quietly stopped trying.

`tests/test-bus-name.py`, 35 of its checks: each of the four replies, a bus that
refuses, a bus that does not answer, the doubling and its ceiling, that every
failed attempt says something, and that the shipped `main.py` still routes
through it.

**The wait, and why it is not a retry loop around the waiting:** the ten
second timeout is still there and still does what it was for. What changed is
only what happens after, when the name is asked for.

**Trap for the next one:** a warm restart of the service proves nothing about
any of this. oFono is up by then, the modem is ready in about 150 ms, and
every path that only runs when it is *not* goes untested. The same warning
already applies to defects 11 and 12 - it is the third time in this file.

---

## 18. And the same boot, giving the name straight back

The reboot on 14.9. at 08:51 was to prove defect 17 cold. It proved it - and
found the next one in the same two lines of journal:

```
Sep 14 08:52:30  Started ModemManager.service - Modem Manager.
Sep 14 08:52:31  ofono2mm: org.freedesktop.ModemManager1 is ours (PRIMARY_OWNER)
```

That second line is 17's fix working: it is printed with `print`, so it is in
the journal without `-v`, and it says the name was really taken. Two minutes
later:

```
$ dbus-send ... org.freedesktop.DBus.NameHasOwner string:org.freedesktop.ModemManager1
   boolean false
$ mmcli -L
error: couldn't find the ModemManager process in the bus
$ nmcli -t -f DEVICE,TYPE,STATE d | grep ril      # nothing
```

Taken at 08:52:31, gone by 08:52:33, and never asked for again. oFono was up
and `/ril_0` was online and powered the whole time.

### Nobody took it away. We gave it back

`check_ofono_presence` has exactly one way to say "oFono is not on the bus":
it calls `ofono_removed`. At boot that is the normal case - oFono appears
sixteen seconds after we do, nine of them spent in `binder-wait` - so the
first thing that runs on a cold boot is the method written for oFono
*leaving*:

```python
def ofono_removed(self):
    ...
    self.bus.something_to_show.set()
    self.loop.create_task(self.bus.release_name('org.freedesktop.ModemManager1'))
```

Both lines then do the wrong thing, in the wrong order:

* `something_to_show.set()` releases `main()` from the wait that exists
  precisely so the name appears together with a modem (defect 16). One second
  in, with no oFono and no modem, `take_bus_name` takes the name.
* The release was queued *before* that and runs *after* it, because
  `create_task` schedules and does not execute. It hands back the name that
  was taken a moment ago.

And when oFono did arrive at 08:52:46, `ofono_added` exported the modem and
announced it to a bus where ModemManager no longer had a name. Nothing asks
for it a second time; there is no code that does.

**Fix:** `ofono_removed` touches neither the event nor the name. Releasing the
name was upstream's way of making clients enumerate again, and defect 16
replaced that with `announce_modem`, which says the same thing without costing
anyone their signal icon - so there is nothing left for a release to do. A
modem that goes away is announced as removed; the name stays, the way
ModemManager itself keeps it when a modem is unplugged, and is there when
oFono comes back. The "no oFono at all" case is what the ten second timeout in
`main()` was always for, and it is now the only thing that ends that wait
early.

### Proving it without a reboot, which is harder than it sounds

A warm restart cannot reproduce this: `ModemManager.service` has
`Requires=ofono.service`, so restarting it pulls oFono up in the same second -
and stopping oFono stops ModemManager with it. The boot ordering had to be
built on purpose, with a transient drop-in that makes oFono take as long as
`binder-wait` does:

```
/run/systemd/system/ofono.service.d/99-test-delay.conf
[Service]
ExecStartPre=/bin/sleep 20
```

Measured 14.9. 09:00, with the fix in place:

```
  3s: name=false  ofono=activating      <- waiting for a modem, as intended
  6s: name=false  ofono=activating
  9s: name=false  ofono=activating
 12s: name=true   ofono=activating      <- "no modem after ten seconds"
 18s: name=true   ofono=activating
 22s: name=true   ofono=active          <- oFono arrives, name still ours
 35s: name=true   ofono=active
```

Afterwards: `mmcli -L` lists the modem, `registered` and `home`, and
`nmcli` says `/ril_0:gsm:connected`. On the old code the name was taken after
one second and gone after two, for the rest of the uptime.

`tests/test-bus-name.py` is 42 checks now. The new ones lift `ofono_removed`
out of the shipped `main.py` with `ast` and run it against a bus that writes
down every attempt to give the name away: the modem is unexported and
forgotten, the oFono interface dropped, and nothing is released, queued, or
allowed to cut `main()`'s wait short. Against the previous `main.py` three of
them fail, which is the only thing that makes them worth having.

### The icon was gone, and nothing in the journal said so

Asked afterwards whether the phone showed a signal icon, the answer was no -
and `modemctl settle` had just said `no client lost ModemManager - nothing to
put back`. Both were right, which is the finding.

phosh started at 08:52:52, nineteen seconds into the gap. The journal from
that boot has no `Error calling GetManagedObjects()` line for it, because
there was no call to fail: with nobody owning `org.freedesktop.ModemManager1`,
GLib's name watcher has nothing to fire on. Defect 16 leaves a trail because
the name is *changing hands* and the call lands in the middle; this leaves
none, because the client never asks at all. gsd-wwan, which was already
running, logged its `object_removed_cb: should not be reached` on every
restart - it saw ModemManager go. phosh, which started inside the gap, saw
nothing and had nothing to see.

> **Corrected by [defect 23](#23-the-grey-icon-was-ours-and-the-reason-we-gave-for-it-was-wrong).**
> There was indeed nothing to see at the time, but the conclusion drawn from
> it was wrong. A GLib object manager client built while nobody owns the name
> *does* watch for the owner and re-enumerates when it arrives - measured
> three ways on this phone, and confirmed on the device, where restarting
> ModemManager put the icon back with no shell restart. Everything below
> about killing the shell is superseded: the way back is
> `sudo systemctl restart ModemManager`.

So `settle` asked the wrong question. An empty journal is not evidence that
the shell has a modem; it is also exactly what a shell that never found one
looks like. It now asks a question that has an answer either way: **is the
shell older than the ModemManager currently on the bus?** If it is, it has
lived through at least one ModemManager going away, and on this phone it never
gets the icon back by itself - whether or not it left a line behind. If it is
younger, it started after this ModemManager and has it. A phone that boots
normally takes the second path: ModemManager is up long before the session.

**Trap, and it cost half an hour:** changing one of our *own* patches leaves
the phone in a state both halves of `modemctl` refuse to touch - the file on
disk is our previous patched version, so the new patch does not fit
(`main.py: patch does not fit (upstream moved)`) and revert does not recognise
it either (`main.py is not ours to revert`). The `.deb` handles this in
`prerm`; `install.sh` now does the same for the hand path, taking the previous
version of our own patch out with the old patch still in `/usr/local/share`
before it overwrites it.

---

## 19. The car park: the radio comes back, the connection does not

Reported on 14 September, from the road. Wi-Fi was gone, the phone had
switched to LTE and that worked. Then an underground car park took the cell
away, and on the way out the signal came back - but mobile data did not, until
the connection was switched on by hand.

The journal of that minute, on one boot, with every timestamp real:

```
09:28:14  ofonod: Clearing active context
09:28:14  dnsmasq: setting upstream servers from DBus / cleared cache
09:28:15  NetworkManager: failed to connect modem: missing data port
09:28:15  NetworkManager: state change: prepare -> failed (reason 'config-failed')
09:28:15  ofonod: Unexpected data call status 65535
          ... three more, all within two seconds ...
09:28:17  NetworkManager: Activation: failed for connection 'Willkommen'
          (and then nothing from NetworkManager, for two minutes)
09:28:30  furios-mobile-context: mobile data is down - activating (attempt 2)
09:28:31  furios-mobile-context: mobile data is back up
09:29:42  dnsmasq: using nameserver 192.168.0.1 (via wlan0)     <- Wi-Fi, at home
09:30:04  NetworkManager: op="connection-activate" ... uid=32011 <- by hand
```

Two separate things went wrong, and the second one is ours.

**NetworkManager gave up, in three seconds.** A cellular profile gets four
autoconnect attempts by default (`connection.autoconnect-retries` is `-1`,
which means the global default of 4). A cell that has just gone away fails all
four of them in about two seconds - there is no back-off between them, because
they are not meant to wait for a radio. After the fourth, the profile is
blocked and NetworkManager waits. On a phone whose data context is activated
through oFono, what it is waiting for does not arrive, so the block outlives
the outage by as long as nobody notices.

**And this repository's own supervisor declared victory over half a repair.**
`furios-mobile-context` brought the oFono context back up 13 seconds later,
correctly, and logged *mobile data is back up* - because up, to it, meant an
active context with an address on its interface. It was not wrong about that.
It was answering a smaller question than the one that mattered.

What the phone actually had between 09:28:31 and 09:29:42 was an interface
with an address, a default route on it (defect 7 put it there), and **not one
DNS server**. The resolver is filled from NetworkManager's IP configuration -
that is defects 8 and 10 - and NetworkManager held no IP configuration for a
device it was not connected to. `dnsmasq` cleared its upstreams at 09:28:14 and
got the next one from Wi-Fi, at home, seventy seconds later. A route to a
carrier nobody can look a name up through is not a connection, and the UI was
right to say so.

**Fix: the supervisor now supervises both halves.** With the data call up it
asks NetworkManager whether it is using it, and activates the cellular
connection if it is not - the same `connection-activate` the user reached for
at 09:30:04, made by the daemon instead. The oFono half is untouched and still
runs first: asking NetworkManager to activate over a cell that is not there
just spends the four attempts that caused this.

Its own restraint is the same three switches NetworkManager itself checks
before autoconnecting, because anything else would be a daemon overriding a
decision:

- the **WWAN radio switch** - what the phone's mobile-data toggle throws;
- the **device's autoconnect flag**, which NetworkManager clears when a
  connection is taken down by hand. That is "stay disconnected" in switch
  form, and it is the one an unasked-for activation would be rudest about;
- a **cellular profile allowed to autoconnect**. With that off, a connection
  coming up is something the user asks for.

Plus one it checks for a different reason: a NetworkManager activation already
in flight (`connecting`, `prepare`, `config`) means NetworkManager is bringing
the context up *itself*, through ModemManager and ofono2mm. Setting `Active`
underneath it at that moment is two things racing on one D-Bus property, which
is the state defect 9 had to be dug out of by hand - reached, this time, by
being helpful.

**What was not done: raising `autoconnect-retries`.** Four attempts in two
seconds do not fail because four is too few; they fail because all four land
inside the same dead second. Setting it to `0` makes that unlimited, which on
a phone in a car park is a retry loop with no upper bound on a radio that is
trying to find a cell - the opposite of what defect 9 was careful about. A
supervisor that backs off (10 s, 30 s, 60 s, then stops) answers the actual
shape of the problem.

**Measured at the device, 14 September:**

- All four NetworkManager questions answer correctly under the service's own
  hardening (`ProtectSystem=strict`, `ProtectHome=yes`, empty
  `CapabilityBoundingSet`) - checked by running them through `systemd-run`
  with those settings, not by assuming.
- A healthy phone: one pass, nothing said, nothing touched.
- The race guard, live: `Powered` false and back to true put NetworkManager
  into `connecting (prepare)` for about ten seconds, and the supervisor logged
  *NetworkManager is activating mobile data - letting it finish* and kept its
  hands off. On the old code that window was a `SetProperty Active true`
  against an activation already in progress.
- The restraint that matters most, live: after `nmcli device disconnect`, the
  phone sat for 45 seconds with the oFono context **up** and NetworkManager
  **disconnected** - the car park state exactly, except that the device's
  autoconnect flag was `no`. The supervisor did not touch NetworkManager once.
- The repair itself: `nmcli device connect /ril_0` as root, from that same
  state, brings the connection back - so the call the daemon makes does work
  from where the daemon stands. What is **not** reproduced at the desk is the
  blocked-profile state that made it necessary: that needs four real
  activation failures, which needs a real dead cell. The acting path is
  covered by the tests; the radio will have to confirm it in a car park.

**A trap worth writing down.** `nmcli device connect` prints

```
Error: Connection activation failed: New connection activation was enqueued.
```

and exits non-zero on an activation that succeeds a second later - seen here,
with the connection up afterwards. A daemon that believed the exit status
would back off from something that worked. Whether it worked is a question for
the next pass, asked of NetworkManager.

`modemctl status` reports this state too now, because it was invisible: mobile
data up on an interface, and NetworkManager not carrying it.

---

## 20. Requires is not an ordering, and the icon pays for it

Reported on 14 September, minutes after a boot: no LTE icon, and the signal
bars all grey. The modem was in perfect health the whole time.

```
mmcli -m 0     state: registered   access tech: lte   signal quality: 12% (recent)
GetManagedObjects   exactly one object, the modem, all fifteen interfaces
```

So this is not defect 12 (extra objects in the ObjectManager), not 16 (the bus
name handed back), not 17 or 18 (no owner for the name at all). The name was
owned, by us, from before the shell started. Everything downstream of
ModemManager was right. What was wrong is *when*.

The journal of that boot, to the second:

```
13:27:45  ModemManager.service started            (that is ofono2mm)
13:27:53  ofono.service: ExecStartPre begins      binder-wait, for the radio HAL
13:27:57  ofono2mm: no modem after ten seconds - taking the bus name anyway
13:27:57  ofono2mm: org.freedesktop.ModemManager1 is ours (PRIMARY_OWNER)
13:27:59  phosh starts                            enumerates: nothing there
13:28:02  binder-wait returns, ofono.service active
13:28:02+ the modem appears, and is exported
```

phosh draws the signal icon from the objects it finds when it enumerates, and
nothing later changes its mind - which is the whole reason [defect
16](#16-the-restart-that-takes-the-signal-icon-with-it) mattered and why taking
the bus name early is written in this tree as a last resort. On this boot the
last resort *was* the normal path.

> **Wrong, and the fix built on it caused
> [defect 23](#23-the-grey-icon-was-ours-and-the-reason-we-gave-for-it-was-wrong).**
> "Nothing later changes its mind" is the sentence this section rests on, and
> it does not survive measurement: phosh connects `object-added` before it
> cold-plugs anything, and a client built exactly the way it builds its own
> picked up a modem announced five seconds after the name appeared. Ordering
> ModemManager after oFono put the bus name behind oFono's 8.7 s in
> binder-wait and so behind the shell - the very thing this section set out
> to prevent. The drop-in no longer orders anything: it restores
> `Type=dbus`, and ofono2mm takes the name at once.

**ofono2mm's own drop-in orders nothing.** It says:

```
[Unit]
Requires=ofono.service NetworkManager.service
```

`Requires=` is a dependency, not an ordering. systemd is explicit about this:
it starts both units at the same time unless an `After=` says otherwise. So
ofono2mm and oFono start together, and oFono then spends its `ExecStartPre` in
`binder-wait` for `android.hardware.radio@1.0::IRadio/slot1` - nine seconds on
this phone, on this boot. ofono2mm waits ten seconds for a modem and gives up
five seconds too early.

Nine seconds is not a constant. That is why this is a boot that *sometimes*
comes up without an icon: the two numbers are close, and which one wins is a
question about how quickly the Android side comes up that morning.

The fix is one line, in a drop-in of our own on top of theirs:

```
[Unit]
After=ofono.service
```

Ordering it after oFono makes the ten-second wait in `main()` what it was
written to be - the net under a phone with no SIM and no modem coming - rather
than the path every cold boot takes. Nothing is restarted to do it: restarting
ModemManager is what costs the icon in the first place, and an ordering can do
nothing for a phone that is already up. It applies at the next boot.

`Requires=ofono.service` was already there, so this adds no new way to fail:
if oFono never comes up, ModemManager was going down with it before this
change too. What it adds is at most a wait - oFono's own `TimeoutStartSec` is
90 s - in exchange for the icon.

`modemctl status` now reports both halves separately, because they answer
different questions:

```
ok    ModemManager.service starts after ofono.service     <- will the next boot be right
warn  this boot: ofono2mm took the bus name with no modem behind it
warn       - the signal icon is missing until the shell restarts
```

The second line reads the journal of the boot that actually happened. A phone
fixed for the future is still a phone without an icon right now, and saying
only the first would be the same mistake `settle` made before defect 18: an
answer to an easier question, in the voice of an answer to the real one.


---

## 21. Announced into an empty room, and the modem stays broken all boot

Reported on 14 September: registered on LTE, full health, and no mobile data.
NetworkManager said the same thing over and over, once per activation attempt:

```
modem-broadband[/ril_0]: failed to connect modem: Method "Connect" with
signature "a{sv}" on interface "org.freedesktop.ModemManager1.Modem.Simple"
doesn't exist
```

The method exists. Asked by hand, at the same instant, the daemon answers:

```
Introspect /Modem/0        all fifteen interfaces, Modem.Simple among them
                           <method name="Connect"> in a{sv}, out o
Simple.GetStatus           returns, state 9
GetManagedObjects          one modem, fifteen interfaces, Simple included
```

So the complaint is not about the daemon. It is about what NetworkManager
believes, and it never asks again: **with `dbus-monitor --system` running
unfiltered across a failing activation, not one message goes to
ModemManager**. The error is raised inside NetworkManager, out of a proxy it
built once.

### What it built it from, and when

Earlier in the same boot NetworkManager says something that looks like noise:

```
13:37:36.2305  device (/ril_0): state change: failed -> disconnected
13:37:36.2607  failed to connect modem: Method "Connect" ... doesn't exist
13:37:36.2896  modem-manager: ModemManager now available          <- 59 ms LATER
13:37:36.2897  modem with path .../Modem/0 already exists, ignoring
```

It was connecting to a modem 59 milliseconds *before* it learned ModemManager
existed. It had heard our `InterfacesAdded` and built the modem from it -
correctly, that is what the signal is for - at a moment when nobody owned
`org.freedesktop.ModemManager1`. A proxy built against an unowned name has no
name owner, so it has nothing to send to: it fails every call locally, which
is exactly the silence on the bus. And the modem it built is one it keeps
(`already exists, ignoring`), so the phone has no mobile data for the rest of
the boot with the radio registered on LTE the whole time.

The order was not bad luck. It was the arrangement:

```
announce_modem()   sends InterfacesAdded, and sets something_to_show
main()             waits for something_to_show, and only then asks for the name
```

The event that releases the bus name is set by the announcement itself, so
every announcement went out before the name existed, by construction. Measured
14.9. 13:41:04: announced at `.8245`, the name became ours at `.8261` - one and
a half milliseconds, and NetworkManager was inside them. Which is why it only
bit sometimes.

This is [defect 16](#16-the-restart-that-takes-the-signal-icon-with-it) once
more, from the other end. There the name went away and a client that asked
during the gap was refused for good. Here the name has not arrived yet and a
client that listens during the gap is poisoned for good. Both are the same
rule: **nothing may be said about a modem before the name it has to be reached
by is ours.**

### The fix

`ModemManagerBus` holds every announcement back until the name is taken, and
`main()` says so once `take_bus_name` returns:

```python
def _announce(self, path, interfaces):
    if not self._name_is_ours:
        if path not in self._held_back:
            self._held_back.append(path)
        return
```

The path is remembered, not the interfaces: by the time the name is ours more
have been exported, and an announcement has to carry the whole modem or
NetworkManager throws the object away (defect 12). `something_to_show` is
still set at the old moment - holding *that* back would leave `main()` waiting
ten seconds for an event that only it can release.

Measured after the fix, on the bus: `RequestName` at `…337.792`, the
announcement at `…338.132`. 340 ms later, where it used to be 1.5 ms early.

### What it does not do

It cannot repair a NetworkManager that already holds a poisoned modem. That
object survives a ModemManager restart - NM answers its own re-enumeration
with `already exists, ignoring` and never rebuilds it - so a phone that has
already lost this race needs `systemctl restart NetworkManager`, or a reboot.
Only a cold boot proves the fix; a warm ModemManager restart proves nothing,
because the client state is what was broken.

---

## 22. The manager announced as one of its own objects

The reboot on 14.9. at 14:18 was the cold start meant to prove defects 20 and
21. Both signatures were gone from the journal - no `taking the bus name
anyway`, no `Connect ... doesn't exist` - and the phone still came up with no
mobile data. `nmcli` said `/ril_0: unavailable` and NetworkManager held no DNS
servers for it, so with Wi-Fi off nothing would have resolved. The modem was
in perfect health the whole time:

```
state: registered   access tech: lte   packet service state: attached
operator: Willkommen   SIM/0 present   signal quality 19%
```

The journal of that boot, to the microsecond:

```
14:19:34.480104  NM: modem-manager: ModemManager not available
14:19:34.487845  NM: (../libmm-glib/mm-object.c:135):mm_object_peek_modem:
                     runtime check failed: (MM_IS_MODEM (modem))
14:19:34.487845  NM: modem with path /org/freedesktop/ModemManager1
                     doesn't have the Modem interface, ignoring
14:19:34.488047  ofono2mm: org.freedesktop.ModemManager1 is ours
14:19:34.508400  NM: manager: (/ril_0): new Broadband device
14:19:34.509094  NM: device (/ril_0): modem state 'failed'
14:19:34.509248  NM: modem-broadband[/ril_0]: failed to retrieve SIM object:
                     No SIM object available
14:19:34.536258  NM: modem-manager: ModemManager now available
14:19:34.536316  NM: modem with path .../Modem/0 already exists, ignoring
```

Two separate faults in that one second, and both of them ours.

### The manager is not one of its own managed objects

The path in the second line is `/org/freedesktop/ModemManager1` - the object
manager itself, not a modem. NetworkManager wrapped it in an `MMObject`, asked
for its Modem interface, got NULL and threw it away.

It did not come from `GetManagedObjects`: dbus_fast picks the nodes *below*
the path it was asked about,

```python
nodes = [node for node in self._path_exports
         if msg.path == "/" or node.startswith(msg.path + "/")]
```

and a path is not below itself. It came from our own `InterfacesAdded`, and
the reason is one line of the filter that was supposed to prevent exactly
this:

```python
@staticmethod
def _is_announced(path):
    if not path.startswith(MM_ROOT + '/'):
        return True                       # <- MM_ROOT lands here
    return path.startswith(MM_MODEM_PREFIX)
```

`/org/freedesktop/ModemManager1` does not start with
`/org/freedesktop/ModemManager1/`, so the guard clause meant for foreign paths
- another daemon's objects, which are none of our business - waved the manager
object through. `main()` exports it before the bus name is requested, so it
was first in the held-back queue and first out of it: the very first thing any
client heard about ModemManager was an object with no modem in it.

### And the modem was announced before it was filled in

`modem state 'failed'` is `MM_MODEM_STATE_FAILED`, which is `-1`; `No SIM
object available` is what libmm-glib returns when the `Sim` property is still
the default `/`. Both are the state of a modem in the middle of `set_props`,
which announced itself there:

```python
await self.ofono_proxy['org.ofono.Modem'].call_set_property('Online', ...)
self.was_powered = True
await self.release_request_modemmanager()     # <- thirty lines too early
...
self.props['State'] = Variant('i', 8)         # registered
self.props['Sim'] = self.sim                  # /SIM/0
```

Twenty milliseconds later both were right and it made no difference.
NetworkManager keeps the modem it built - `already exists, ignoring` - so the
phone had no mobile data for the rest of the boot.

### Why the test suite was green

`tests/test-object-manager.py` asked the class what it thought, and its table
of expected answers began:

```python
for path, want in [
    (MM_ROOT, True),        # <- the defect, written down as correct
    (MODEM,   True),
    (SIM,     False),
```

A test that encodes the same assumption as the code cannot find a wrong
assumption. All 46 checks passed on the boot that had no mobile data.

### The fix: stop deciding, keep a list

Defects 12, 16, 21 and 22 are one defect seen four times - *when and to whom
does a modem become visible* - and each of the first three was fixed by
narrowing a predicate over path strings. That is the part that kept failing,
so it is gone. `ModemManagerBus` now holds `_published`, the set of modem
paths a client may see. A path is in it because `modem_ready` put it there
with the bus name already ours, never because a rule about its spelling said
it belonged there. `GetManagedObjects` answers from that set and
`InterfacesAdded` is sent for its members only, so the two doors cannot
disagree, and neither can be opened by the manager object, a SIM, a bearer or
a half-built modem. `_is_announced` and `_is_complete` no longer exist.

The premature announcement is a deletion: `set_props` no longer calls
`release_request_modemmanager`, and `init_ofono_interfaces` announces once the
modem is actually built, which it already did.

The test asks the question NetworkManager and phosh ask instead. It replays a
real startup - manager exported, fifteen interfaces one at a time, SIM,
bearer, `modem_ready`, then the name - and checks only what a client can
observe. It fails on the old code.

### Measured after the change

One announcement on the bus, from the manager's path, naming the modem:

```
$ dbus-monitor --system "type='signal',interface='org.freedesktop.DBus.ObjectManager'"
signal path=/org/freedesktop/ModemManager1; member=InterfacesAdded
   object path "/org/freedesktop/ModemManager1/Modem/0"
      "Sim"    -> object path "/org/freedesktop/ModemManager1/SIM/0"
      "State"  -> int32 8
```

`Sim` filled in and `State` 8 (`REGISTERED`), where the broken boot had `/`
and `-1`. NetworkManager, on the same restart:

```
device (/ril_0): modem state 'registered'
device (/ril_0): state change: unavailable -> disconnected
device (/ril_0): Activation: starting connection 'Willkommen'
modem-broadband[/ril_0]: DNS 61.8.132.52 / 202.71.137.208
device (/ril_0): Activation: successful, device activated.
```

`nmcli` `/ril_0: connected:Willkommen`, both DNS servers held, no
`MM_IS_MODEM` warning anywhere in the boot, and over the mobile interface
`curl https://heise.de` answered HTTP 301 in 0.21 s with `ping -I ccmni1` at
0% loss.

**Trap:** `ping -I` and `curl --interface` need `SO_BINDTODEVICE`, which is
root-only. Run as a user, curl binds the source address instead, the packet
leaves over Wi-Fi with a mobile source address and is dropped - it looks
exactly like mobile data being broken. Both measurements above were taken
with `sudo`.

---

## 23. The grey icon was ours, and the reason we gave for it was wrong

Reported on 14 September, an hour after the cold boot that was supposed to
confirm defects 20, 21 and 22: *no LTE icon, no signal strength, all grey*.
That cold boot had passed every check this repository knows how to run -
`ril_0 connected`, two DNS servers, one modem in the object manager, HTTP 301
over `ccmni0` in 0.45 s. The modem was perfect. Only the drawing of it was
missing.

### What the five boots say

Two moments decide it: when `org.freedesktop.ModemManager1` gets an owner,
and when the shell is up to ask.

```
boot   bus name is ours      "Phosh ready"        icon
 -4    09:20:33.25           09:20:41.83          8.6 s early   ok
 -3    13:27:57.12           13:28:03.51          6.4 s early   ok
 -2    13:37:36.15           13:37:41.02          4.9 s early   ok
 -1    14:19:34.49           14:19:35.38          0.9 s early   ok
  0    14:51:42.07           14:51:40.19          1.9 s LATE    grey
```

The margin had been shrinking all day, and on the fifth boot it went
negative. What pushed it there was this repository:

* `50-furios-after-ofono.conf` - defect 20's own fix, installed at 13:33 -
  ordered ModemManager after oFono. oFono spends **8.7 s** in `binder-wait`
  for `IRadio/slot1` (14:51:28.75 to 14:51:37.43), so ModemManager was not
  allowed to start until 14:51:37.5. phosh had started at **14:51:34**.
* `main()` then waited a second time, for a modem, before taking the name:
  14:51:42.07.

phosh built its ModemManager client somewhere in between, into a gap four and
a half seconds wide that we had dug and then deepened.

### The reason in the comment was disproven three ways

Every one of those two waits was justified by the same sentence, which
appears in `main.py`, in the drop-in and in defect 20: *phosh draws the
signal icon from the objects it finds at one enumeration and nothing later
changes its mind.* It is not true, and the belief is what made the fix look
like the danger.

phosh 0.55.0 (`src/wwan/phosh-wwan-mm.c`) builds its client with
`mm_manager_new (conn, G_DBUS_OBJECT_MANAGER_CLIENT_FLAGS_DO_NOT_AUTO_START,
...)` and connects `object-added` and `object-removed` before it cold-plugs
anything. Measured on the device, against this GLib (2.88):

1. **A replica of phosh's client, built while nobody owned the name, watching
   the real ofono2mm restart.** It got `OBJECT-ADDED
   /org/freedesktop/ModemManager1/Modem/0`, fifteen interfaces, Modem and
   Modem3gpp present. It recovered.
2. **A name that appears with nothing behind it**, the shape ofono2mm would
   have if it stopped waiting: the client saw the name arrive with zero
   objects and still received the object announced five seconds later.
3. **Fifteen runs walking the name's arrival across the client's own
   asynchronous construction**, 0, 1, 2, 3, 5, 8, 12, 20, 30, 50, 80, 120,
   200, 400 and 800 ms. None missed it.

And the running phosh proved it on the phone: `systemctl restart
ModemManager` brought the icon and the bars straight back, with no shell
restart. Defect 16's advice - kill the shell - was never necessary for this,
and killing `mobi.phosh.Shell.service` is the one move in `modemctl` that can
leave the phone with no shell at all. It is gone from `settle`.

**What is still not explained:** why phosh went grey on boot 0 when every
bench reproduction of the same shape recovers. The field is consistent (five
boots, five agreements) and the bench is consistent the other way. So the fix
removes the disputed condition rather than relying on a mechanism nobody has
pinned down, and `status` *reports* the timing instead of failing a phone
over it.

### The fix

* **The name goes up first, empty.** `main()` exports the manager object and
  takes the name at once - upstream ModemManager's own lifecycle, and the one
  every client is written against. Measured after the change: 1.29 s from
  process start to `PRIMARY_OWNER`, against 4.5 s of waiting before.
* **The drop-in stops ordering and starts declaring.** Upstream's unit is
  `Type=dbus` with `BusName=org.freedesktop.ModemManager1`; ofono2mm's own
  `10-ofono2mm.conf` replaces the ExecStart and sets `Type=simple`, so
  systemd counts the service started at fork. On boot 0 that was 4.5 s early.
  `50-furios-modemmanager-name.conf` puts `Type=dbus` back and orders
  nothing. It also closes defect 17 for good: a ofono2mm that never takes the
  name is now a failed unit after `TimeoutStartSec` (5 s here) instead of a
  healthy-looking service nobody can reach.
* **The old drop-in is taken out by name.** A drop-in is whatever is in the
  directory, so a phone upgrading from defect 20 would otherwise keep
  obeying `After=ofono.service` and undo all of it. `apply` and `revert`
  remove it; there is a test for exactly that.

Nothing about `modem_ready` or `_published` changed. Announcing a modem
before the name is owned (defect 21) or before it is finished (defect 22) is
still impossible, and with the name taken in the first second the first of
those two windows is now nearly closed by construction as well.

### Two measurement errors of our own, both worth keeping

**`date -d ""` is midnight this morning, not an error.** The first version of
the new `status` check read the shell's start time from `systemctl show` and
handed it to `date`. Under the test suite's stubbed `systemctl` that string
is empty, `date` cheerfully answered 00:00, and status reported the bus name
as 53502 seconds late on a perfectly healthy phone. The raw value is checked
before `date` sees it, and there is a test that a shell start time which
cannot be read is skipped rather than believed.

**A status check must not assert what it cannot prove.** The same check
first *failed* the phone whenever the name was late - and then said so while
the icon was visibly on the screen, because the ModemManager restart that
put it back also made the name later than the shell. It now stays quiet once
ModemManager has changed hands since the shell started, and warns rather
than fails.

### The tests wrote the wrong belief down, again

`tests/test-bus-name.py` asserted that the ten-second timeout message was
present in the shipped file - the disproven premise, pinned as a
requirement. It now asserts the opposite invariant and reads it off `main()`
rather than off a string: the statements before `take_bus_name` are walked
for anything that waits, and there must be none. Against the previous
`main.py` two checks fail, which is the only thing that makes them worth
having. `tests/test-object-manager.py` gained the startup the daemon actually
performs now - name first, empty, modem seconds later - alongside the old one,
whose guard still has a window to cover.

---

## What it costs, measured

Numbers from the phone, not estimates. Three things here run all the time -
the 30 s poll and the two watchers; everything else happens once at boot or
after a package operation.

| | measured | how |
|---|---|---|
| ofono2mm, polling every 30 s | 30 ms CPU in 600 s = **0.005%** | `/proc/<pid>/stat`, 20 polls |
| ofonod, same window | 410 ms = **0.068%** | same, and this is an upper bound |
| `furios-mobile-context`, idle | **0.53%**, now **0.022%** | `CPUUsageNSec` of the unit over 300 s: one idle look, nothing else |
| `furios-mobile-route`, idle | **0.36%** | same |
| `modemctl apply` as a no-op | **101 ms** | what the boot unit and the apt hook run |
| `modemctl status` | 424 ms | the patch checks are ~40 ms of it; the rest is mmcli, dbus-send and nmcli |

ofonod's share is an upper bound because that process also does everything
else oFono does - registration, contexts, SMS. Even attributing all of it to
the poll puts the whole feature under a tenth of a percent of one core.

The supervisor was the expensive one, and for nothing. It woke on three whole
oFono interfaces, and `NetworkRegistration` is not quiet: it announces
`Strength`, eleven times in 75 s on a cell this weak. Each announcement cost a
full pass - a dozen short-lived processes, 87 ms - to re-read a number this
daemon never looks at, which put it above oFono and ModemManager together on
an idle phone. The match rules now name the properties a pass actually reads.
`arg0` of `PropertyChanged` is the property name, so the bus drops the rest
before anyone is woken; `ContextAdded` and `ContextRemoved` carry an object
path instead and are matched by member, because they are the only
announcement a context that did not exist at startup will ever make. Measured
again with the new rules: zero oFono wake-ups in 70 s, and a unit whose CPU
counter does not move at all while the phone sits there.

That the filter still hears what matters was measured on a real event rather
than argued: at 18:01:37 oFono cleared the context and rebuilt it, and the
unit's CPU counter - motionless for the five minutes before - moved by 219 ms,
two or three passes. The drop this supervisor was written for announces itself.

What the narrowing did take away was an accident. The Strength chatter had been
a heartbeat: a state change matching none of the rules was picked up within
seconds anyway, because something else woke the loop every few seconds. The
only fallback left is the declared one, and an hour was the wrong length for a
net that is now load-bearing. The state it has to catch is the one
`context_up()` exists for - oFono reporting `Active=true` on a context whose
data call has gone. Nothing changed, so nothing is announced, and no filter can
catch what is never sent.

`FURIOS_MOBILE_CONTEXT_IDLE` is therefore five minutes, not an hour. The
arithmetic said 288 looks a day and 0.029 % of a core; the unit measured
**0.065 s of CPU over 300 s, 0.022 %** - a look costs slightly less inside the
daemon than it does when timed from a shell. Either way it is twenty-four times
cheaper than the heartbeat it replaces, and it bounds that blind window at the
same order as NetworkManager's own connectivity check. One minute would be
0.145 % for looks that are almost always wasted, which is the polling this
daemon was written not to be.

The route watcher's share is not polling either - it blocks on netlink, and
`ip monitor address route link` saw no event at all in a 60 s idle sample. What
it pays for is the ~5 minute cadence at which NetworkManager reinstalls its own
`via`-the-own-address default route, which this then removes again; each round
is three `mmcli` calls. Nothing in any journal says who installs it.

Two things keep it that low. The poll only runs while there is a SIM to read:
`set_props` returns at the SimManager check before touching D-Bus, so a phone
with no SIM pays nothing. And a poll enables RIL cell reporting for about half
a second and switches it off again, rather than leaving it on.

## Privacy

Nothing here stores or transmits anything. Two things are worth knowing anyway.

`modemctl signal` prints the serving cell id and EARFCN. Those identify the
tower, which places the phone within roughly a kilometre - they are the one
part of its output that is about the person rather than the radio. Fine on
your own screen, worth trimming out of a bug report.

This repository names the carrier (MCC/MNC 262-23, APN `web.vodafone.de`,
operator name `Willkommen`) because the upstream reports are not reproducible
without it. It contains no IMEI, no IMSI, no cell id and no phone number, and
that is worth re-checking before publishing anything new here.

## Privileges

`apply` and `revert` write files under `/usr/lib`, so they need root and there
is no way around that. Everything else does not, and does not ask:

    modemctl status     reads world-readable files, mmcli, D-Bus - no root
    modemctl signal     D-Bus only - no root
    modemctl check      the same, except the dbus-monitor part, which says so

What `apply` actually checks is not `id -u` but whether it can write the files
it is about to change. That gives a better message when it cannot, and it is
why the test suite can exercise apply and revert against a tree it owns rather
than needing root to test the one command that does all the work.

As root, the nine `MODEMCTL_*` overrides the tests use are refused outright.
Without that, anyone able to run `sudo modemctl` - a NOPASSWD line is the usual
way that happens - could point them anywhere and have root apply an arbitrary
diff to an arbitrary file. sudo's `env_reset` makes that hard today; one
`env_keep` line elsewhere would undo it, and nothing about the overrides is
worth that.

The unprivileged signal tool has an override of its own
(`FURIOS_MODEM_OFONO2MM`) and does not need the same treatment: it holds no
privileges, so redirecting it gains nobody anything.

---

## Traps that cost time

**`dbus-monitor` without `sudo` shows nothing, and says nothing about it.**
The system bus does not let an unprivileged process eavesdrop. A run that
prints no matches looks exactly like a run that proves absence. The first
attempt to confirm the 30-second poll "showed" that no poll was happening.

**`dbus-send` without `--print-reply` does not wait for the reply**, so it
exits 0 whether the call worked or was refused. Two context toggles sent that
way looked like they had produced no signal at all, which pointed the search
for defect 15 at exactly the wrong component. When the answer is evidence,
`--print-reply`.

**oFono serves cell info only on demand.** `GetServingCellInformation` makes
the cellinfo netmon plugin switch RIL cell reporting on at a 500 ms interval,
wait for one update, and switch it off again. Nothing pushes signal
measurements on its own, so without a poll the bar does not move at all - and
polling costs about 2% duty cycle, not continuous reporting.

**`systemctl restart ModemManager` is how you restart ofono2mm.** There is no
`ofono2mm.service`; a drop-in (`10-ofono2mm.conf`) replaces ModemManager's
`ExecStart`. Restarting `ofono` instead is a different and worse idea - it
leaves the modem OFFLINE.

**A ping proves nothing about the radio while Wi-Fi is up.** `ping -I /ril_0`
does not work either: `/ril_0` is NetworkManager's name for the device, while
the kernel calls it `ccmni0` or `ccmni1` depending on the context. Check
`ip route get` first.

**`+CESQ` returns indices, not dBm**, and this modem appends three
MTK-specific fields after the six standard ones. Read by position from the
left.

**`DPkg::Post-Invoke-Success` does not exist.** apt parses it without a
complaint and lists it in `apt-config dump`, so the hook looks installed. Only
`APT::Update` has a `-Success` variant; for DPkg, apt runs `DPkg::Post-Invoke`
and nothing else. Found by reinstalling ofono2mm and discovering every patch
gone afterwards - while the running daemon still had the patched code in
memory and everything therefore looked fine. That gap between what is on disk
and what is running is the reason to test this by actually reinstalling the
package rather than by reading the hook.

**A `mktemp -d` staging directory travels into the .deb as the mode of `./`.**
mktemp makes it 0700, and nothing of ours should be telling dpkg anything
about the root directory's permissions. `chmod 755` on the staging directory
before building.

**`exec a || exec b` is not a fallback.** A failed `exec` ends the shell
outright, so the second one never runs. Pointing the share directory somewhere
empty produced exit 127 and not one word of explanation. Test for an executable
first, then exec.

**Backups pile up where nobody looks.** Every `apply` after a package update
writes another set. After a day of testing there were 28 of them, 1.1 MB, in a
directory that is supposed to hold a Python package. Three are kept now.

**NetworkManager does not survive a ModemManager restart.** It keeps the proxy
for the modem object of the process that just died -

```
NetworkManager: modem-manager: ModemManager now available
NetworkManager: <warn> modem with path .../ModemManager1/Modem/0 already exists, ignoring
```

- and every `Connect` it makes after that goes nowhere. The device sits in
`connecting (prepare)` indefinitely while oFono is never even asked: activating
the context by hand through `org.ofono.ConnectionContext` brings the data call
straight up, which is what proves the modem and the network were fine all
along. Measured on every restart, not occasionally, with no recovery in 80 s.
Disconnecting the device, taking it unmanaged and back, and re-activating the
profile all fail. Only restarting NetworkManager makes it look again.

Two consequences: the apt hook runs `apply --no-restart` (after a package
update the running daemon still holds our patched code, so a restart buys
nothing but the new upstream and costs the connection), and an interactive
`apply` follows its restart with `settle_networkmanager`.

**Wait for the device before deciding it is absent.** For a moment after the
restart NetworkManager does not list the modem at all. The first version of
that settle step looked once, found nothing, concluded "no modem, nothing to
do" and returned - so it did precisely nothing on the one occasion it existed
for, and mobile data stayed down. Look inside the wait loop, not before it.

**Do not restart the modem stack during a call.** The apt hook runs after every
package operation, including an unattended upgrade that lands while the phone
is being used as a phone. `apply` asks `VoiceCallManager.GetCalls` first and
leaves the restart for later - the patched files are on disk either way.

**Stale `__pycache__` outlives a patch.** Python will run bytecode from before
the change if its timestamp still looks newer. `modemctl apply` removes it.

---

## What this does NOT fix

- **Weak reception.** Measured at the desk where this was written: RSRP around
  -120 dBm on LTE band 1 (2100 MHz). Band 20 (800 MHz) is enabled; the phone
  simply picked this cell. The connection is stable now, not fast. Earlier the
  same day, in a different spot, the same phone measured -78 dBm and 63 Mbit/s
  down - which the icon reported as the emptiest bar, because of fault 6.

- **`binder-death=245`** (`/var/lib/ofono/rilerror`). The Android radio HAL has
  crashed 245 times over the life of this device. Each crash takes the modem
  stack with it and only a reboot helps. That is below the Linux stack.

- **The band lock** in `/var/lib/ofono2mm/settings.conf` (`AT+EPBSEH=...`),
  re-applied at every start. Checked against `AT+EPBSEH=?`: every band ofono2mm
  knows about is enabled, band 20 included. A few UMTS bands and one LTE band
  its table does not know are off - irrelevant in Germany.

---

## 5G

Not a defect of its own, but the question defect 1 leaves behind: can this
phone reach NR at all?

**Measured answer: no, and not because of the radio.** `ofono-binder-plugin`
cannot speak the interface version that NR needs on this modem, and no setting
in this repository changes that.

### What is actually in the way

`AvailableTechnologies` is not a question anybody asks the modem. oFono hands
back whatever the plugin was configured with:

```c
/* binder_radio_settings.c */
cbd->cb.available_rats(binder_error_ok(&error), self->settings->techs, cbd->data);
```

and `techs` is `OFONO_RADIO_ACCESS_MODE_ALL` minus NR whenever
`radioInterface` parses below 1.4. Our invalid `1.6` parsed as 1.2, so `nr`
never appeared. Back at the shipped `1.4` it appears immediately:

```
AvailableTechnologies = [ gsm, umts, lte, nr ]
```

Everything else in the chain is already built for it. FuriOS even patched its
oFono for NR - upstream masks the driver's answer with `& 0x7`, this build
uses `& 0xf`, so bit 3 survives (`and w1, w1, #0xf` at `0xf6ab0` in
`/usr/sbin/ofonod`). `ofono_radio_access_mode_to_string` maps bit 3 to `"nr"`.
`mm_modem.py` maps `nr` to `MM_MODEM_ACCESS_TECHNOLOGY_5GNR`.
`gnome-control-center` ships every label up to `2G, 3G, 4G, 5G (Preferred)`.

### And it still does not work

With `radioInterface = 1.4` and `TechnologyPreference = nr`:

```
Sep 13 15:51:54 ofonod: Error 44 setting pref mode
```

**60 of them in 60 seconds**, one a second for as long as the preference
stands, and `NetworkRegistration` reports `lte` throughout. Error 44 is
`RADIO_ERROR_INVALID_ARGUMENTS` (`radio_types.h`) - the modem refusing the
argument it was handed, not a coverage problem. The test ran at a location
with no 5G, which is why nothing could have registered on NR anyway; but an
invalid-argument rejection of a *set* call does not depend on what is on the
air.

So FuriOS out of the box offers 5G in the settings, and choosing it buys one
error a second and LTE.

### What would have to change

The modem advertises `android.hardware.radio@1.6::IRadio/slot1`, so the
hardware is not the limit. Two libraries are, and the plugin is only the
smaller of them:

| | stops at | what it is missing |
|---|---|---|
| `ofono-binder-plugin` 1.1.22 | 1.5 | the name `"1.6"` and a call site |
| `libgbinder-radio` | **1.5** | `RADIO_INTERFACE_1_6`, the interface names, and the request and response codes |

`libgbinder-radio`'s `RADIO_INTERFACE_COUNT` follows `RADIO_INTERFACE_1_5`
directly, and it carries no `android.hardware.radio@1.6::IRadio` string. It
does already know the *names* `setAllowedNetworkTypesBitmap` and
`getAllowedNetworkTypesBitmap`, but only as text in a lookup table - no codes
behind them.

The AIDL route, which the plugin also supports, is closed here: this phone
runs Android 12.1 and publishes no AIDL radio service on `/dev/binder`. AIDL
radio arrived in Android 13.

**The transaction codes, derived and checked.** HIDL numbers methods
consecutively down the inheritance chain, so the codes are computable from the
`.hal` files:

| interface | methods | codes |
|---|---|---|
| `IRadio@1.0` | 130 | 1-130 |
| `@1.1` | 6 | 131-136 |
| `@1.2` | 6 | 137-142 |
| `@1.3` | 3 | 143-145 |
| `@1.4` | 10 | 146-155 |
| `@1.5` | 17 | 156-172 |
| **`@1.6`** | **29** | **173-201** |

Checked against all eight request codes `libgbinder-radio` actually ships -
`setResponseFunctions` 1, `responseAcknowledgement` 130,
`startNetworkScan_1_2` 137, `setIndicationFilter_1_2` 138,
`setupDataCall_1_2` 141, `deactivateDataCall_1_2` 142,
`setInitialAttachApn_1_4` 147, `setDataProfile_1_4` 148 - and every one
matches. Which gives the two that matter:

    setAllowedNetworkTypesBitmap = 187
    getAllowedNetworkTypesBitmap = 188

Building is possible on the device: `gcc`, `make`, `meson` and
`dpkg-buildpackage` are there, the `-dev` packages are in the FuriOS
repository, and both projects have public sources. The risk is that
`libgbinder-radio` carries the whole modem stack - a bad build is a phone with
no modem until `apt install --reinstall`.

**What such a build could and could not prove here.** It could show whether
the modem accepts `setAllowedNetworkTypesBitmap` where it rejects the 1.4
call - that is a yes or no from the RIL and needs no coverage. It could not
show an NR registration: there is no 5G at this location. Open.

Do **not** reach for `radioInterface = 1.5` on the way there: measured on this
device, oFono then never gets the modem up at all. It stops at five
interfaces, `RadioSettings` and `NetworkRegistration` never appear, and the
log repeats `Power request failed` every 30 seconds.

---

## Diagnosing it by hand

`modemctl status` and `modemctl check` cover the usual questions. These are the
raw commands behind them, for the cases they do not answer.

```bash
# Are the loops back?  (should be empty)
journalctl -u ofono --since "-10min" \
    | grep -E "Error 44|Unexpected data call|Activating context"

# Is the data registration flapping?  (should be empty)
journalctl -u ofono --since "-10min" | grep "data reg changed"

# Is NetworkManager stuck in prepare?
nmcli -t device | grep ril_0

# Is the prefix right?  (must be /24 or similar, never /0)
ip -br addr | grep -E "ccmni[0-9]+ " | grep -v DOWN

# Who is talking to oFono?
# NOTE: without sudo, dbus-monitor shows NOTHING and does not say so - the
# system bus does not allow unprivileged eavesdropping. An empty run is not
# evidence of absence.
sudo dbus-monitor --system "type='method_call',destination='org.ofono'"

# Is the signal bar alive?  ("recent", not "cached", and not 0%)
mmcli -m any | grep "signal quality"

# Is ofono2mm really asking every 30 s?  (sudo required, see above)
sudo timeout 70 dbus-monitor --system \
  "type='method_call',interface='org.ofono.NetworkMonitor'" \
  | grep GetServingCellInformation

# What the radio really receives, cross-checked against AT+CESQ
modemctl signal

# Modem state
mmcli -m any
dbus-send --system --print-reply --dest=org.ofono /ril_0 \
    org.ofono.RadioSettings.GetProperties
```

---

## Upstream

Four reports were written against the **current** upstream tree, not just the
installed version - see [upstream/](upstream/). The signal report
(`ofono2mm-4-signal-quality.md`) has not been re-checked against current
upstream, and its third part belongs to oFono rather than ofono2mm.

Nothing has been filed for numbers 7 and 8 yet. It is not clear which project should
take it: oFono reporting a gateway it does not have, or NetworkManager having
no way to express "default route, no next hop" for a point-to-point link that
Android has handled this way for fifteen years.

Two of the nine are already fixed or half-fixed upstream, which matters here:
an ofono2mm update brings part of this along by itself and overwrites the rest.
That is what `modemctl apply` is for.
