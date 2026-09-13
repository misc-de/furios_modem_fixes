# What we found out

The README says what this does and how to run it. This file says *why*: the
measurements behind each fix, and the things that cost hours because they are
not what the documentation of the parts involved suggests.

Device: FuriPhone FLX1 (radon), MediaTek modem `MOLY.NR15.R3.MP.V189`, SIM
262-23, APN `web.vodafone.de`. Package versions in
[paket-versionen.txt](paket-versionen.txt).

Three symptoms started this, on different days:

- the data connection would only come up reliably after a reboot, and the UI
  said "mobile data unavailable" in between;
- the signal icon sat at the emptiest bar no matter where the phone was;
- switching Wi-Fi off left the phone with no network at all, although mobile
  data was connected and every component called itself healthy.

None was a radio problem. All nine causes are in software, and only one of
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

The modem advertises IRadio 1.0 through **1.6**. Only 1.6 has
`setAllowedNetworkTypesBitmap`, the path this modem expects for NR.

**Fix:** `radioInterface = 1.6`.

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

Not a seventh defect, but the question fault 1 leaves behind: is NR reachable
once the modem stops rejecting it?

`radioInterface = 1.4` made oFono ask for NR through a call this modem refuses,
so it retried every two seconds - 42,714 rejections in one day, and never a 5G
connection. A mobile data toggle then left `TechnologyPreference` on LTE, so
afterwards nothing asked for 5G at all. Both states look identical from the
outside: no 5G, ever.

With `radioInterface = 1.6` the modem accepts `TechnologyPreference = nr`.
Measured after setting it:

| | result |
|---|---|
| 12 min steady state, sampled every 30 s | preference `nr`, no `Error 44`, no registration churn, data connected throughout |
| mobile data off and on again | preference survives - this is the exact event that reset it under 1.4 |
| persisted to `/var/lib/ofono/<IMSI>/radiosetting` | `TechnologyPreference=8` |
| ofonod CPU over 600 s | 0.0717% against 0.0683% on LTE the day before - noise |

The phone still registers on LTE here, at roughly -120 dBm on band 1. Whether
that is coverage, provisioning or the NSA anchor cannot be decided from the
device; it needs a location with known 5G.

**Not verified: a reboot.** The on-disk value is what oFono applies at start,
and under 1.4 that was where the rejection loop began. Under 1.6 it does not
reject, but this has not been watched through an actual boot. `modemctl check`
reports a returning loop, and one command undoes it:

```bash
dbus-send --system --print-reply --dest=org.ofono /ril_0 \
    org.ofono.RadioSettings.SetProperty string:"TechnologyPreference" \
    variant:string:"lte"
```

One more thing oFono does not help with: `AvailableTechnologies` lists only
gsm, umts and lte, and never nr - yet oFono accepts `nr` as the preference
without complaint. So `mmcli` reports `supported: gsm-umts, lte` and offers no
5G modes. That inconsistency is in the binder plugin and is still open. The
display path itself is fine: `mm_modem.py` maps `nr` to
`MM_MODEM_ACCESS_TECHNOLOGY_5GNR` correctly.

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
