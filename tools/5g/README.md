# 5G

**Solved 2026-09-29.** `sudo modemctl nr on` allows 5G (NR) and remembers it;
`furios-modem-nr.service` puts it back after every boot and every restart of
oFono. Off after installing, like everything else here.

It takes two things, measured in a 1&1 cell where a phone next to this one
showed 5G:

1. NR in the RIL's allowed-types bitmap, set through IRadio 1.6 on the HAL
   instance `em<slot>` (below). `AT+ERAT=22,128` on its own is not enough,
   and the RIL rewrites ERAT to 6 at every start from oFono's preference.
2. A fresh registration afterwards (oFono `Online` false, then true). The
   network learns what the phone can do when it registers and keeps that:
   with NR allowed after registration, three minutes and 130 MB stayed on
   LTE; registered afresh, oFono said `nr` and ModemManager `5gnr` within a
   download. The NR leg itself only appears under load, and not in every
   sector.

`modemctl` registers afresh only when NR had to be added, so the day FuriOS
allows NR by itself this becomes a no-op. Each fresh registration costs the
data call a few seconds; NetworkManager logs two "missing data port" and
reconnects on its own.

The instance follows the SIM slot oFono uses: the vendor manifest pairs
`em1` with `slot1` and `em2` with `slot2`, and each has its own bitmap.

`nr-test` and `nrprobe` below are the tools this was found with.

```bash
./nr-test status   # changes nothing
./nr-test run      # status, allow NR, watch 180 s, restore - also on Ctrl+C
```

Everything goes to `~/nr-test.log`. `dataRadioTech 20` (or `nr` / `5gnr` in
oFono / ModemManager) means 5G works; `14` is LTE. Still open: why oFono's
own request gets Error 44 - answering that would be the clean fix.

## What is known

- The modem accepts NR through IRadio 1.6 `setAllowedNetworkTypesBitmap`
  (request 187, response 193; get = 188/194) and through 1.4
  `setPreferredNetworkTypeBitmap`, both on the HAL instance `em1`, which
  nobody else uses. oFono's identical 1.4 request on `slot1` gets Error 44.
- The HIDL interface token must name the version that *declares* the method
  (setResponseFunctions @1.0, bitmap @1.4, allowed @1.6), or the HAL drops
  the call and only says `enforceInterface()` in logcat.
- `AT+ERAT=22` (ofono2mm writes it at every start) is GSM/UMTS/LTE/NR; the
  second-to-last field `128` means NR preferred. Boot state: `22,0,0` with an
  RIL bitmap of `0x9ce0e`; NR allowed is `0x19ce0e`.
- oFono only reads the setting back when it starts, so it does not fight the
  test. Each switch drops the data call for a few seconds;
  `furios-mobile-context` restores it.
- **Never use `slot2`** (a probe there reset the modem and crashed oFono) and
  never `slot1` (oFono's). `nrprobe` refuses both.

## What switching off puts back, and what it cannot

- The allowed-types bitmap needs no record: the RIL writes its own at every
  start of oFono, so the shipped one comes back by itself. `modemctl nr off`
  only clears the NR bit it set.
- oFono's `TechnologyPreference` is stored on disk by oFono and outlives a
  reboot and the package. `modemctl nr on` records what it was before the
  first change (`/var/lib/furios-modem-fixes/original/`), and `nr off` - also
  run by `uninstall.sh` and the package's `prerm` - puts exactly that back, as
  long as it is still the `nr` we set.
- **Not reversible: the modem's `nr_ps`** (`AT+EPSCONFIG=0,"nr_ps"`, read by
  `nr-test`; 255 = no SIM may use NR data, 1 = SIM1). The modem answers every
  write to it with `+CME ERROR: 50`, so whatever it holds after 5G was used
  here stays, uninstall or not. Nothing in this repository writes it.

## Building nrprobe

The binary is not in git. Either install `libgbinder-dev libglibutil-dev`, or
clone `mer-hybris/libgbinder` and `sailfishos/libglibutil` side by side and run
`GBINDER_SRC=<parent dir> ./build.sh`.
