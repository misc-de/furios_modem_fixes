# Upstream reports — as of 2026-09-13

Six reports, ready to paste into the respective issue tracker.

| File | Repo | Severity |
|---|---|---|
| `ofono2mm-1-connect-hang.md` | furilabs/oFono2MM | high — the modem stays dead until reboot |
| `ofono2mm-2-duplicate-bearer.md` | furilabs/oFono2MM | medium |
| `ofono2mm-3-ipv6-family.md` | furilabs/oFono2MM | low |
| `ofono2mm-4-signal-quality.md` | furilabs/oFono2MM | medium — the signal display is permanently blind |
| `mmsd4ofono-1-activation-loop.md` | furilabs/mmsd4ofono | high — destabilises the data connection |
| `mobile-broadband-provider-info-1-eu-alert-4372.md` | GNOME/mobile-broadband-provider-info | high — an "extreme" level warning channel is missing, in DE **and** NL |

The first four were checked against the **current** upstream state, not only
against the installed version:

- oFono2MM `forky` @ `2b1d012f3d37722f97151c52f989e239d91ee4bc`
- mmsd4ofono `forky` @ `9b04724b4e68dbcd899b827250eb8e07f57bb796`

## Not reported, because upstream has already fixed it

**The missing bus policy for cell broadcast** (fault 13) is done upstream:
`data/org.freedesktop.ModemManager1.conf.polkit` on `main` has three rules for
`Modem.CellBroadcast` (`List` for everyone, `Delete` and `SetChannels` behind
polkit). In tag `1.24.2` — the version installed here — `CellBroadcast` does
**not appear in the file at all**. So there is nothing to report, only
something a ModemManager update brings along by itself. Our drop-in in
`../dbus/` is deliberately narrower than the upstream rules, because those
rely on a polkit check that ofono2mm does not perform; `modemctl status`
recognises the tag at which it becomes superfluous, and `revert` takes it away
then.

The missing netmask in `Ip4Config` (→ NetworkManager configured the address as
`/0`) is done upstream: `utils.py` now has `netmask_to_prefix()`, used in
`mm_modem.py` and `mm_bearer.py`. The local patch in `../patches/` is
therefore in effect a backport onto the installed version 1.8.0.

## The new one (13.9.)

`mobile-broadband-provider-info-1-eu-alert-4372.md` is not about ofono2mm but
about the database `cellbroadcastd` takes its channel list from. Found while
fixing fault 13: after the fix the phone listened on 25 channels instead of 8
— but **4372 was gone**, although it had been there before.

It is not a national decision but a slip, and the proof is in the entry
itself: **4385 is listed, 4372 is not.** 4385 carries the foreign-language
version of exactly the warning that is sent on 4372 — nobody chooses to
subscribe to the translation of a warning but not to the warning. It fits that
`us` and `il` write the same range as `start="4371" end="4372"` while `de` and
`nl` write `start="4371" end="4371"`. One character of difference.

Checked against upstream `main` (fetched 13.9.2026): the same fault is there,
so this is not something a package update brings along by itself.

## Important for this device

The installed version is **older** than upstream. An `ofono2mm` update
therefore brings the netmask fix and part of the counter fix along by itself —
but overwrites the local patches while doing so. After an update:

```bash
sudo /home/furios/modem-fixes/reapply.sh
```

The script notices when a patch no longer applies (because upstream changed
the place), and says so instead of breaking something.

## Not yet checked against current upstream

`ofono2mm-4-signal-quality.md` (signal display) was written against the
**installed** version. Before reporting it, please check whether
`mm_modem_signal.py` looks different upstream by now. The third part of the
report is not about ofono2mm anyway but about ofono's
`plugins/cellinfo-netmon.c` — which belongs, if reported separately, with
FuriLabs/ofono.
