/*
 * SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
 * SPDX-License-Identifier: MIT
 *
 * nrprobe - ask the radio HAL about network types on an instance oFono
 * does not use (em1 by default), and read the modem's own answers.
 *
 * Every IRadio request is oneway; the answer arrives as a transaction on the
 * IRadioResponse object registered with setResponseFunctions. oFono owns
 * slot1's response object, so a probe on slot1 would steal or lose answers.
 * em1 reaches the same modem through its own channel.
 *
 * HIDL checks the interface token against the interface that DECLARES a
 * method, not the newest one the service implements: setResponseFunctions
 * wants @1.0, getPreferredNetworkTypeBitmap @1.4, the Allowed pair @1.6.
 *
 * NEVER point it at slot2: a probe there reset the modem on 2026-09-28 and
 * took oFono down with it (rild dropped slot1 two seconds after the probe's
 * client went away). slot1 belongs to oFono. em1 is the only safe instance.
 *
 * Usage: nrprobe get | setlegacy N | setbitmap RAF | setallowed RAF
 */
#include <gbinder.h>
#include <glib.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define SERIAL_BASE 0x4e520001   /* "NR" */

/* IRadio request codes (libgbinder-radio radio_types.h; 187/188 derived) */
#define REQ_SET_RESPONSE_FUNCTIONS          1
#define REQ_SET_PREFERRED_NETWORK_TYPE      65
#define REQ_GET_PREFERRED_NETWORK_TYPE      66
#define REQ_GET_PREF_NET_TYPE_BITMAP        151
#define REQ_SET_PREF_NET_TYPE_BITMAP        152
#define REQ_SET_ALLOWED_NET_TYPES_BITMAP    187
#define REQ_GET_ALLOWED_NET_TYPES_BITMAP    188
#define REQ_GET_RADIO_CAPABILITY            119
#define RESP_GET_RADIO_CAPABILITY           118

typedef struct { gint32 type, serial, error; } RadioResponseInfo;

static GMainLoop* loop;
static int pending;
static int failures;

static const char* errname(int e)
{
    switch (e) {
    case 0: return "NONE";
    case 1: return "RADIO_NOT_AVAILABLE";
    case 2: return "GENERIC_FAILURE";
    case 6: return "REQUEST_NOT_SUPPORTED";
    case 44: return "INVALID_ARGUMENTS";
    case 38: return "INTERNAL_ERR";
    case 40: return "MODEM_ERR";
    default: return "?";
    }
}

static GBinderLocalReply* on_response(GBinderLocalObject* obj,
    GBinderRemoteRequest* req, guint code, guint flags, int* status,
    void* user_data)
{
    GBinderReader reader;
    const RadioResponseInfo* info;

    gbinder_remote_request_init_reader(req, &reader);
    info = gbinder_reader_read_hidl_struct(&reader, RadioResponseInfo);
    if (info && (info->serial & 0xffff0000) == (SERIAL_BASE & 0xffff0000)) {
        gint32 value;

        printf("  <- response %u serial %#x error %d (%s)", code,
            info->serial, info->error, errname(info->error));
        if (code == RESP_GET_RADIO_CAPABILITY) {
            /* RadioCapability: session, phase, raf, uuid (hidl_string), status */
            const gint32* rc = gbinder_reader_read_hidl_struct1(&reader, 40);

            if (rc) printf(" session %d phase %d raf %d (%#x) status %d",
                rc[0], rc[1], rc[2], rc[2], rc[8]);
        } else if (gbinder_reader_read_int32(&reader, &value)) {
            printf(" value %d (%#x)", value, value);
        }
        printf("\n");
        fflush(stdout);
        if (info->error) failures++;
        if (--pending <= 0) g_main_loop_quit(loop);
    }
    *status = GBINDER_STATUS_OK;
    return NULL;
}

static GBinderLocalReply* on_indication(GBinderLocalObject* obj,
    GBinderRemoteRequest* req, guint code, guint flags, int* status,
    void* user_data)
{
    *status = GBINDER_STATUS_OK;
    return NULL;
}

static GBinderClient* clients[3];   /* @1.0, @1.4, @1.6 */
static gint32 serial = SERIAL_BASE;

static void send(const char* name, guint code, int nargs, gint32 arg)
{
    GBinderClient* c = clients[code >= 187 ? 2 : code >= 146 ? 1 : 0];
    GBinderLocalRequest* r = gbinder_client_new_request(c);
    GBinderWriter w;
    int st;

    gbinder_local_request_init_writer(r, &w);
    gbinder_writer_append_int32(&w, serial);
    if (nargs) gbinder_writer_append_int32(&w, arg);
    st = gbinder_client_transact_sync_oneway(c, code, r);
    gbinder_local_request_unref(r);
    if (nargs) {
        printf("-> %s(%d / %#x) serial %#x, status %d\n", name, arg, arg,
            serial, st);
    } else {
        printf("-> %s() serial %#x, status %d\n", name, serial, st);
    }
    serial++;
    if (!st) pending++;
}

static gboolean on_timeout(gpointer data)
{
    printf("  (%d request(s) unanswered after 5 s)\n", pending);
    g_main_loop_quit(loop);
    return G_SOURCE_REMOVE;
}

int main(int argc, char* argv[])
{
    static const char* resp_ifaces[] = {
        "android.hardware.radio@1.6::IRadioResponse",
        "android.hardware.radio@1.5::IRadioResponse",
        "android.hardware.radio@1.4::IRadioResponse",
        "android.hardware.radio@1.3::IRadioResponse",
        "android.hardware.radio@1.2::IRadioResponse",
        "android.hardware.radio@1.1::IRadioResponse",
        "android.hardware.radio@1.0::IRadioResponse", NULL };
    static const char* ind_ifaces[] = {
        "android.hardware.radio@1.6::IRadioIndication",
        "android.hardware.radio@1.5::IRadioIndication",
        "android.hardware.radio@1.4::IRadioIndication",
        "android.hardware.radio@1.3::IRadioIndication",
        "android.hardware.radio@1.2::IRadioIndication",
        "android.hardware.radio@1.1::IRadioIndication",
        "android.hardware.radio@1.0::IRadioIndication", NULL };
    const char* inst = g_getenv("NRPROBE_INSTANCE");
    GBinderServiceManager* sm;
    GBinderRemoteObject* remote;
    GBinderLocalObject *resp, *ind;
    GBinderLocalRequest* r;
    GBinderWriter w;
    char* fqname;
    int st;

    if (argc < 2 || (strcmp(argv[1], "get") && argc < 3)) {
        fprintf(stderr, "usage: %s get | setlegacy N | setbitmap RAF | "
            "setallowed RAF\n", argv[0]);
        return 2;
    }
    if (!inst) inst = "em1";
    if (!strncmp(inst, "slot", 4)) {
        fprintf(stderr, "refusing %s: slot1 is oFono's, slot2 resets the "
            "modem\n", inst);
        return 2;
    }

    sm = gbinder_servicemanager_new("/dev/hwbinder");
    fqname = g_strconcat("android.hardware.radio@1.6::IRadio/", inst, NULL);
    remote = gbinder_servicemanager_get_service_sync(sm, fqname, &st);
    if (!remote) {
        fprintf(stderr, "%s not available (%d)\n", fqname, st);
        return 1;
    }
    gbinder_remote_object_ref(remote);
    clients[0] = gbinder_client_new(remote, "android.hardware.radio@1.0::IRadio");
    clients[1] = gbinder_client_new(remote, "android.hardware.radio@1.4::IRadio");
    clients[2] = gbinder_client_new(remote, "android.hardware.radio@1.6::IRadio");

    resp = gbinder_servicemanager_new_local_object2(sm, resp_ifaces,
        on_response, NULL);
    ind = gbinder_servicemanager_new_local_object2(sm, ind_ifaces,
        on_indication, NULL);

    r = gbinder_client_new_request(clients[0]);
    gbinder_local_request_init_writer(r, &w);
    gbinder_writer_append_local_object(&w, resp);
    gbinder_writer_append_local_object(&w, ind);
    st = gbinder_client_transact_sync_oneway(clients[0],
        REQ_SET_RESPONSE_FUNCTIONS, r);
    gbinder_local_request_unref(r);
    printf("setResponseFunctions on %s: %d\n", inst, st);

    if (!strcmp(argv[1], "get")) {
        send("getPreferredNetworkType", REQ_GET_PREFERRED_NETWORK_TYPE, 0, 0);
        send("getPreferredNetworkTypeBitmap", REQ_GET_PREF_NET_TYPE_BITMAP, 0, 0);
        send("getAllowedNetworkTypesBitmap", REQ_GET_ALLOWED_NET_TYPES_BITMAP, 0, 0);
        send("getRadioCapability", REQ_GET_RADIO_CAPABILITY, 0, 0);
    } else {
        gint32 v = (gint32) strtol(argv[2], NULL, 0);

        if (!strcmp(argv[1], "setlegacy")) {
            send("setPreferredNetworkType", REQ_SET_PREFERRED_NETWORK_TYPE, 1, v);
            send("getPreferredNetworkType", REQ_GET_PREFERRED_NETWORK_TYPE, 0, 0);
        } else if (!strcmp(argv[1], "setbitmap")) {
            send("setPreferredNetworkTypeBitmap", REQ_SET_PREF_NET_TYPE_BITMAP, 1, v);
            send("getPreferredNetworkTypeBitmap", REQ_GET_PREF_NET_TYPE_BITMAP, 0, 0);
        } else if (!strcmp(argv[1], "setallowed")) {
            send("setAllowedNetworkTypesBitmap", REQ_SET_ALLOWED_NET_TYPES_BITMAP, 1, v);
            send("getAllowedNetworkTypesBitmap", REQ_GET_ALLOWED_NET_TYPES_BITMAP, 0, 0);
        } else {
            fprintf(stderr, "unknown command %s\n", argv[1]);
            return 2;
        }
    }

    loop = g_main_loop_new(NULL, FALSE);
    g_timeout_add_seconds(5, on_timeout, NULL);
    g_main_loop_run(loop);
    return (pending || failures) ? 1 : 0;
}
