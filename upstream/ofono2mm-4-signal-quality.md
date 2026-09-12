# SignalQuality is stuck at 0%, and Modem.Signal reports RSRP/RSRQ swapped and unsigned

**Repo:** furilabs/oFono2MM
**Observed on:** ofono2mm 1.8.0+git20260520152015.3b02630.forky.production,
ofono 1.29+git8-11, ofono-binder-plugin 1.1.22, FuriPhone FLX1 (MTK, `MOLY.NR15.R3.MP.V189`)

## Summary

Three separate defects in the same chain. They mask each other: the first one
makes the signal bar dead, so nobody notices that the third one reports
physically impossible numbers.

### 1. `SignalQuality` can never leave `(0, false)` on drivers that report no strength

`mm_modem.py` feeds `SignalQuality` exclusively from
`org.ofono.NetworkRegistration`'s `Strength` property:

```python
if 'Strength' in self.ofono_interface_props['org.ofono.NetworkRegistration'].props:
    self.props['SignalQuality'] = Variant('(ub)', [... ['Strength'].value, True])
```

`mm_modem_simple.py` does the same in `GetStatus()`.

oFono only ever exposes `NetworkRegistration.Strength` once a driver has
reported a value (`src/network.c`, initial value `-1`), and
`signal_strength_callback` returns silently when the query fails. On this
device the MTK HAL never serves
`RADIO_IND_CURRENT_SIGNAL_STRENGTH_1_4`, so the property does not exist at all:

```
$ dbus-send --system --print-reply --dest=org.ofono /ril_0 \
      org.ofono.NetworkRegistration.GetProperties
   ... Status, Mode, CellId, Technology, MobileCountryCode,
       MobileNetworkCode, Name   -- no Strength
```

75 s of `dbus-monitor` on the interface produced no `PropertyChanged` either.

Result: `mmcli -m any` prints `signal quality: 0% (cached)` forever, and any
shell drawing bars from libmm-glib shows an empty icon regardless of reception.

There is a perfectly good fallback available — `org.ofono.NetworkMonitor`,
which ofono2mm already talks to in `mm_modem_signal.py`, serves the serving
cell's RSRP and an ASU strength on this very modem.

### 2. `Modem.Signal` swaps LTE RSRP and RSRQ

Not ofono2mm's own doing, but ofono2mm is where it becomes visible.
`plugins/cellinfo-netmon.c` publishes the HAL's `lte->rsrp` under
`OFONO_NETMON_INFO_RSRQ` (D-Bus name `ReferenceSignalReceivedQuality`) and
`lte->rsrq` under `OFONO_NETMON_INFO_RSRP` (`ReferenceSignalReceivedPower`):

```c
if (lte->rsrp != OFONO_CELL_INVALID_VALUE) {
        params[n].type = OFONO_NETMON_INFO_RSRQ;
        params[n].value = lte->rsrp;
        ...
if (lte->rsrq != OFONO_CELL_INVALID_VALUE) {
        params[n].type = OFONO_NETMON_INFO_RSRP;
        params[n].value = lte->rsrq;
```

`mm_modem_signal.py:86-89` reads them at face value.

### 3. `Modem.Signal` passes HAL magnitudes through as if they were dBm

The binder HAL reports RSRP and RSRQ as positive magnitudes with the sign
dropped. ModemManager's API is defined in real dBm and dB. Combined with the
swap above, `mmcli -m any --signal-get` reported:

```
  LTE    |    rsrq: 120.00 dB      <- RSRP, unsigned
         |    rsrp: 10.00 dBm      <- RSRQ, unsigned
```

Both are outside the physically possible range (RSRP −140..−44 dBm,
RSRQ −20..−3 dB), so this is detectable without any device knowledge.

Also in the same block, `ChannelQualityIndicator` is assigned to `rssi`. CQI is
a 0–15 modulation-quality index, not a received power. The genuine RSSI is
available: `Strength` is `<rssi>` per 27.007 §8.5, an ASU index 0–31 with 99
meaning unknown, so RSSI dBm = −113 + 2 × ASU.

## Verification against an independent source

`AT+CESQ` through `org.ofono.FuriLabs.AT`, read at the same moment as
`NetworkMonitor` (2026-09-12 20:05):

```
+CESQ: 99,99,255,255,19,21,62,40,57
         rsrq index 19 -> -19.5 + 19*0.5 = -10.0 dB
         rsrp index 21 -> -140 + 21      = -119 dBm
```

| Source | RSRP | RSRQ |
|---|---|---|
| `AT+CESQ` | −119 dBm | −10.0 dB |
| `NetworkMonitor`, read crosswise and negated | −120 dBm | −10 dB |
| `mmcli --signal-get`, as shipped | **+10 dBm** | **+120 dB** |

## Suggested fix

In `mm_modem_signal.py`:

- read `ReferenceSignalReceivedQuality` as RSRP and `ReferenceSignalReceivedPower`
  as RSRQ, negating the magnitude, and range-check the result so the HAL's
  "unknown" placeholders are dropped instead of forwarded;
- take `rssi` from `Strength` (ASU → dBm), not from `ChannelQualityIndicator`;
- zero the access technologies the modem is not camped on, otherwise stale LTE
  numbers keep being served after a fallback to GSM.

In `mm_modem.py`: when `NetworkRegistration` has no `Strength`, derive
`SignalQuality` from those measurements instead of leaving it at 0. A driver
that does report a strength should keep precedence.

Note that `GetServingCellInformation` is on-demand only — the cellinfo netmon
plugin switches RIL cell reporting on, waits for one update and switches it off
again — so a modest poll (we use 30 s) is needed for the bar to move at all,
and costs roughly 2% duty cycle rather than continuous reporting.
