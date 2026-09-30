# Wi-Fi calling (VoWiFi) on the FLX1 - plan

Status 30.9.2026: **not started.** VoWiFi does not work on FuriOS today. This
is what was measured, what is known from outside, and how to get there.

## What was measured

| Question | Answer |
|---|---|
| Does the firmware support it? | Yes: `persist.vendor.mtk_wfc_support=1`, `persist.vendor.mtk.wfc.enable=1`, the RIL logs `RFX_STATUS_KEY_CONFIG_DEVICE_WFC_AVAILABLE ... new value = 1` |
| Does FuriOS switch it on? | Partly: FuriLabs' `ofono-binder-plugin-ext-mtk` sends `setImsCfgFeatureValue(VOICE_OVER_WIFI, IWLAN)`, `setWifiEnabled` and `setWifiIpAddress` (because `wifi.interface=wlan0`) |
| Does it register? | No: `wfcRegState 0` in all 67 `updateImsCallRat` lines, including those without LTE data |
| Is a tunnel attempted? | No: not one line about ePDG, IKE or IPsec in logcat |
| Mode | `ro.telephony.iwlan_operation_mode=AP-assisted` - the application processor is expected to provide the tunnel |
| Vendor pieces for that | None: `/vendor/bin` holds 51 programs, no `wfca`, `epdg_wod`, `charon` or `volte_*`; VoLTE runs entirely in the modem |
| Carrier | 1&1 (262-23) offers Wi-Fi calling on its own network; `epdg.epc.mnc023.mcc262.pub.3gppnetwork.org` resolves to four addresses |
| SIM authentication | oFono exposes `USimApplication.UmtsAuthenticate(RAND, AUTN)` and `ISimApplication.ImsAuthenticate` - EAP-AKA and IMS-AKA without a card reader |
| IKE software | strongSwan 6.0.7 in the archive; it cannot use a real USIM for EAP-AKA (`eap-aka-3gpp` needs Ki/OPc, `eap-sim-pcsc` only does EAP-SIM) |

## What is known from outside

- MT6877 has an IKEv2 client in the modem firmware: CVE-2024-20069 (DH
  downgrade in VoWiFi IKE) names "Modem NR15" and MT6877, fixed by a MOLY
  (modem) patch.
  <https://www.usenix.org/system/files/usenixsecurity24-gegenhuber.pdf>,
  <https://nvd.nist.gov/vuln/detail/cve-2024-20069>
- On Android 12 MediaTek folded the old `vendor.mediatek.hardware.wfo` HAL
  into `IMtkRadioEx`. The request codes are already in FuriLabs'
  `mtk_radio_ext_types.h`: 137 `setWifiEnabled`, 138 `setWifiAssociated`,
  139 `setWifiSignalLevel`, 140 `setWifiIpAddress`, 141/142 `set/getWfcConfig`,
  144 `setLocationInfo`, 146 `setNattKeepAliveStatus`, 147 `setWifiPingResult`,
  164 `notifyEPDGScreenState`, 240 `getIWlanRegistrationState`. The plugin
  sends three of them.
- An MT6789 device (Android 14 GSI) registered VoWiFi only once Google's
  `com.google.android.iwlan` built an `ipsec1` tunnel on the AP - so a
  MediaTek modem can use a tunnel the AP built. How the tunnel is handed
  over is not public. <https://github.com/nalbe/shark8-volte-vowifi-gsi-patch>
- Free IMS clients that make real VoWiFi calls with a SIM: sysmocom's
  foss-ims-client (Asterisk + modified strongSwan, GPL-2)
  <https://osmocom.org/projects/foss-ims-client>, and
  <https://github.com/selvakn/gsm-sip-bridge> (strongSwan ePDG, IMS-AKA,
  sec-agree, AMR-WB, GPL-3).
- FuriLabs has no public plan for VoWiFi; Ubuntu Touch has none either.

## Phases

Every phase ends at a check. A failed check stops the project there, having
cost only that phase. Nothing is tested during a call, and emergency calls
never take this path.

### Phase 0 - ask, change nothing (about an hour)

- Send the ePDG only an `IKE_SA_INIT` and see whether it answers.
- The owner checks in the 1&1 customer account that WLAN-Call is enabled.

**Check:** the ePDG answers.

### Phase 1 - let the modem build the tunnel (about a day)

The modem has an IKE client, and it has only been told three of the roughly
eight things MediaTek's Android side tells it.

- A probe on a HAL instance oFono does not use - the way `tools/5g/nrprobe`
  reaches IRadio 1.6 on `em1` - sends the missing ones: Wi-Fi associated,
  signal level, location, WFC config with the ePDG FQDN; then asks
  `getIWlanRegistrationState`.
- Watch logcat for IKE activity and `wfcRegState`.

**Check:** the modem starts IKE on its own. If it does, the rest is teaching
the oFono plugin to send those calls, and VoWiFi lives in the existing call
UI - the best outcome by far.

### Phase 2 - build the tunnel on Linux (several days)

The foundation for everything after this, if phase 1 fails.

- A small strongSwan `simaka_card` plugin (`get_quintuplet`, `resync`) that
  calls oFono's `UmtsAuthenticate`.
- Identity `0<IMSI>@nai.epc.mnc023.mcc262.3gppnetwork.org`, APN `ims`,
  P-CSCF addresses through the configuration payload.

**Check:** `IKE_AUTH` succeeds and we get an inner address plus P-CSCF
addresses. If 1&1 refuses the device here (for example on the IMEI sent as
`DEVICE_IDENTITY`), the project ends.

### Phase 3 - calls over the tunnel (weeks)

Handing our tunnel to the modem's IMS stack would need the undocumented
hand-over reverse engineered on a reference device; not planned. Instead:

- Register with 1&1's IMS ourselves, based on sysmocom's foss-ims-client:
  IMS-AKA through oFono's `ImsAuthenticate`, sec-agree IPsec through XFRM.
- Asterisk runs locally as a back-to-back agent; GNOME Calls talks to it as
  a plain SIP account, audio goes through PipeWire, AMR-WB is transcoded.

**Checks:** REGISTER answered with 200 OK; an incoming call rings; a call
works in both directions.

### Phase 4 - make it livable

- The network delivers calls to the latest registration. So VoWiFi may only
  be registered while there is no usable cellular - otherwise calls to LTE
  are lost. Handover between Wi-Fi and LTE during a call is out of reach.
- SMS over IMS on Wi-Fi.
- An app switch, off until switched on.
- Battery: the tunnel needs a NAT-T keepalive about every 20 s; measure it.

## Risks

- 1&1 may accept only whitelisted devices. Phase 2 finds out.
- Phase 3 is a second telephony stack next to the modem - the big part.
- Two IMS registrations for one SIM (modem over LTE, ours over Wi-Fi) must
  never overlap; phase 4 exists for that.
