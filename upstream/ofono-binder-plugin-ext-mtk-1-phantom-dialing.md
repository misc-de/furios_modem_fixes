# ofono-binder-plugin-ext-mtk: a refused VoLTE call stays "dialing" for ever

Package: ofono-binder-plugin-ext-mtk 1.2.1+git20250826014945.837f943 (FuriOS, FLX1)

## What happens

An outgoing VoLTE call that the network refuses at once never ends. oFono
keeps it in `dialing`, ModemManager (ofono2mm) in `ringing-out`, GNOME Calls
shows "hanging up" after the user hangs up, and neither `Hangup` nor
`HangupAll` sends anything to the modem. Only restarting ofono clears it.

Radio log, all in the same second:

    RmcCCReqHandler: onHandleRequest: RFX_MSG_REQUEST_IMS_DIAL
    RmcCCReqHandler: AT> ATD+49*****84930
    AT< +ECPI: 1, 130, 0, 0, 0, 0, +49*****84930, 145, **
    AT< +ECPI: 1, 133, 0, 0, 0, 0, +49*****84930, 145, **, 63
    RtcCC: Remove ImsCall in slot: 0, callId: 1

Cause 63 (service or option not available) while LTE data registration was
flapping between registered and searching.

## Why

`mtk_ims_call_msg_type_to_state()` maps `CALL_INFO_MSG_TYPE_MO_CALL_ID_ASSIGN`
(130) to INVALID, so an outgoing call is unknown to the plugin until ALERT
(2). The 133 that follows disconnects an id the binder plugin never had
(`binder_voicecall_ext_call_disconnected`: "ignoring ext call 1 hangup").
The dial request then completes OK and the oFono core synthesizes a
`dialing` call for it (`dial_handle_result`), which no later event refers to.

## Fix

- 130 -> `BINDER_EXT_CALL_STATE_DIALING`, without the INCOMING flag (MTK IMS
  calls were all reported as incoming).
- A disconnect of the dialing call while the dial request is still pending
  makes that dial fail, so the core does not synthesize a call.

Patch: `patches/ofono-binder-plugin-ext-mtk-phantom-dialing.patch`.
Building 837f943 also needs `-std=gnu17` (gcc 15: `mtk_radio_ext_new_req_id()`
is declared without a prototype) and a space before `-I$(BINDER_PLUGIN_INCLUDE_PATH)`
in the Makefile.
