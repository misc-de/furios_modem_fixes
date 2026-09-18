# Upstream reports — as of 2026-09-18

Eleven reports, ready to paste into the respective issue tracker.

| File | Repo | Severity |
|---|---|---|
| `ofono2mm-1-connect-hang.md` | furilabs/oFono2MM | high — the modem stays dead until reboot |
| `ofono2mm-2-duplicate-bearer.md` | furilabs/oFono2MM | medium |
| `ofono2mm-3-ipv6-family.md` | furilabs/oFono2MM | low |
| `ofono2mm-4-signal-quality.md` | furilabs/oFono2MM | medium — the signal display is permanently blind |
| `ofono2mm-5-stale-net-ports.md` | furilabs/oFono2MM | high — DNS fails on mobile data while packets flow |
| `ofono2mm-6-radiosettings-never-reread.md` | furilabs/oFono2MM | medium — no capabilities, no modes, for the whole boot |
| `ofono2mm-7-objectmanager-announces-sims-and-bearers.md` | furilabs/oFono2MM | high — no signal icon at all, on a healthy modem |
| `ofono2mm-8-bearer-without-subscription.md` | furilabs/oFono2MM | high — a whole boot with no mobile data |
| `ofono2mm-9-bus-name-released-on-purpose.md` | furilabs/oFono2MM | high — every restart can cost the clients for good |
| `mmsd4ofono-1-activation-loop.md` | furilabs/mmsd4ofono | high — destabilises the data connection |
| `mobile-broadband-provider-info-1-eu-alert-4372.md` | GNOME/mobile-broadband-provider-info | high — an "extreme" level warning channel is missing, in DE **and** NL |

All nine oFono2MM reports were checked against the **current** upstream state,
not only against the installed version:

- oFono2MM `forky` @ `2b1d012f3d37722f97151c52f989e239d91ee4bc`
  (fetched 18.9.2026 — still HEAD, unchanged since 12.8.2026)
- mmsd4ofono `forky` @ `9b04724b4e68dbcd899b827250eb8e07f57bb796`

Reports 5–9 quote line numbers from that oFono2MM commit. Where upstream has
moved since the version installed here, the report says what that changes —
see "What HEAD already fixes" in report 5 and "What it costs, on HEAD" in
report 8. Nothing in reports 5 to 9 is fixed upstream.

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

Two more of our local fixes have upstream equivalents on HEAD, both from
Jeffrey Clemmons' bearer work of July/August 2026: clearing a bearer's
`Interface` when its context goes down (`de4894c`) and adopting a context that
is already active instead of re-activating it (`713e342`). Neither closes the
defect it touches here — see reports 5 and 8 — but both change the symptom, so
read those two sections before reproducing.

## The provider database

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
but overwrites the local patches while doing so. The apt hook and the boot
unit put them back, and `modemctl status` says whether they are in place; the
hook reports a patch that no longer applies (because upstream changed the
place) instead of breaking something.

## Not yet checked against current upstream

`ofono2mm-4-signal-quality.md` (signal display) was written against the
**installed** version. Before reporting it, please check whether
`mm_modem_signal.py` looks different upstream by now. The third part of the
report is not about ofono2mm anyway but about oFono's
`plugins/cellinfo-netmon.c` — which belongs, if reported separately, with
FuriLabs/ofono.
