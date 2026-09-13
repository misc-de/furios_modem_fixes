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

None was a radio problem. All twelve causes are in software, and only one of
them is in code anybody here wrote.

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

Woken by oFono's signals, not a clock: the loop blocks on `dbus-monitor` and
only falls back to a timer while a revive is actually in flight. Healthy, one
wakeup an hour.

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

## What it costs, measured

Numbers from the phone, not estimates. The polling is the only thing this adds
to a running system; everything else happens once at boot or after a package
operation.

| | measured | how |
|---|---|---|
| ofono2mm, polling every 30 s | 30 ms CPU in 600 s = **0.005%** | `/proc/<pid>/stat`, 20 polls |
| ofonod, same window | 410 ms = **0.068%** | same, and this is an upper bound |
| `modemctl apply` as a no-op | **41 ms** | what the boot unit and the apt hook run |
| `modemctl status` | 253 ms | the patch checks are ~40 ms of it; the rest is mmcli, dbus-send and nmcli |

ofonod's share is an upper bound because that process also does everything
else oFono does - registration, contexts, SMS. Even attributing all of it to
the poll puts the whole feature under a tenth of a percent of one core.

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

As root, the four `MODEMCTL_*` overrides the tests use are refused outright.
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
