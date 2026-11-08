/* Virtual Xbox 360 controllers through the ViGEmBus driver (docs/virtual-gamepad.md).
 *
 * This speaks ViGEmBus's IOCTL protocol directly instead of linking ViGEmClient (a C++
 * static library with its own threads): open the bus's device interface, check the
 * protocol version, plug a target by serial number, submit XUSB reports, unplug. The
 * IOCTL codes and request layouts follow ViGEmClient's include/ViGEm/km/BusShared.h
 * (MIT, Copyright (c) 2016-2019 Nefarius Software Solutions e.U. and Contributors).
 *
 * Every request is overlapped with a bounded wait, so a wedged driver costs the network
 * thread at most kTimeoutMs instead of hanging it. */
#include "msw_internal.h"
#include "host_win.h"

#include <setupapi.h>
#include <stdlib.h>
#include <wchar.h>
#include <winioctl.h>

/* GUID_DEVINTERFACE_BUSENUM_VIGEM {96E42B22-F5E9-42F8-B043-ED0F932F014F} */
static const GUID kVigemBus = {0x96E42B22, 0xF5E9, 0x42F8, {0xB0, 0x43, 0xED, 0x0F, 0x93, 0x2F, 0x01, 0x4F}};

#define VIGEM_IOCTL_W(i) CTL_CODE(FILE_DEVICE_BUS_EXTENDER, (i), METHOD_BUFFERED, FILE_WRITE_DATA)
#define VIGEM_IOCTL_RW(i) CTL_CODE(FILE_DEVICE_BUS_EXTENDER, (i), METHOD_BUFFERED, FILE_WRITE_DATA | FILE_READ_DATA)
#define IOCTL_VIGEM_PLUGIN_TARGET VIGEM_IOCTL_W(0x801)
#define IOCTL_VIGEM_UNPLUG_TARGET VIGEM_IOCTL_W(0x802)
#define IOCTL_VIGEM_CHECK_VERSION VIGEM_IOCTL_W(0x803)
#define IOCTL_VIGEM_WAIT_DEVICE_READY VIGEM_IOCTL_W(0x804)
#define IOCTL_XUSB_SUBMIT_REPORT VIGEM_IOCTL_W(0xA02)
#define IOCTL_XUSB_GET_USER_INDEX VIGEM_IOCTL_RW(0xA07)

#define VIGEM_COMMON_VERSION 0x0001
#define VIGEM_TARGET_X360_WIRED 0
/* Serial numbers are bus-wide; other apps (DS4Windows, Sunshine) may hold some. */
#define VIGEM_MAX_SERIAL 256

static const DWORD kTimeoutMs = 2000;

typedef struct {
    ULONG Size;
    ULONG SerialNo;
} vigem_serial_req; /* UNPLUG_TARGET and WAIT_DEVICE_READY */

typedef struct {
    ULONG Size;
    ULONG SerialNo;
    ULONG TargetType;
    USHORT VendorId; /* 0: the driver's default (045E:028E for Xbox 360) */
    USHORT ProductId;
} vigem_plugin_req;

typedef struct {
    ULONG Size;
    ULONG Version;
} vigem_version_req;

typedef struct {
    ULONG Size;
    ULONG SerialNo;
    msw_xusb_report Report;
} vigem_xusb_submit_req;

typedef struct {
    ULONG Size;
    ULONG SerialNo;
    ULONG UserIndex;
} vigem_user_index_req;

_Static_assert(sizeof(msw_xusb_report) == 12, "XUSB_REPORT layout");
_Static_assert(sizeof(vigem_plugin_req) == 16, "VIGEM_PLUGIN_TARGET layout");
_Static_assert(sizeof(vigem_xusb_submit_req) == 20, "XUSB_SUBMIT_REPORT layout");

struct msw_vigem {
    HANDLE bus;
    HANDLE event;
};

/* One overlapped DeviceIoControl, waited for up to kTimeoutMs. */
static HRESULT ioctl(msw_vigem *v, DWORD code, void *in, DWORD in_len, void *out, DWORD out_len) {
    OVERLAPPED ov = {0};
    ov.hEvent = v->event;
    ResetEvent(v->event);
    DWORD n = 0;
    if (!DeviceIoControl(v->bus, code, in, in_len, out, out_len, &n, &ov)) {
        DWORD e = GetLastError();
        if (e != ERROR_IO_PENDING) return HRESULT_FROM_WIN32(e);
        if (WaitForSingleObject(v->event, kTimeoutMs) != WAIT_OBJECT_0) {
            CancelIoEx(v->bus, &ov);
            GetOverlappedResult(v->bus, &ov, &n, TRUE);
            return HRESULT_FROM_WIN32(ERROR_TIMEOUT);
        }
    }
    if (!GetOverlappedResult(v->bus, &ov, &n, FALSE)) return HRESULT_FROM_WIN32(GetLastError());
    return S_OK;
}

msw_hr msw_vigem_open(msw_vigem **out) {
    *out = NULL;
    HDEVINFO set = SetupDiGetClassDevsW(&kVigemBus, NULL, NULL, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
    if (set == INVALID_HANDLE_VALUE) return HRESULT_FROM_WIN32(GetLastError());
    HRESULT hr = HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND); /* no bus device: driver not installed */
    SP_DEVICE_INTERFACE_DATA ifd = {.cbSize = sizeof(ifd)};
    for (DWORD i = 0; SetupDiEnumDeviceInterfaces(set, NULL, &kVigemBus, i, &ifd); i++) {
        DWORD need = 0;
        SetupDiGetDeviceInterfaceDetailW(set, &ifd, NULL, 0, &need, NULL);
        SP_DEVICE_INTERFACE_DETAIL_DATA_W *detail = malloc(need);
        if (!detail) {
            hr = E_OUTOFMEMORY;
            break;
        }
        detail->cbSize = sizeof(*detail);
        if (!SetupDiGetDeviceInterfaceDetailW(set, &ifd, detail, need, &need, NULL)) {
            free(detail);
            continue;
        }
        HANDLE bus = CreateFileW(detail->DevicePath, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
                                 NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OVERLAPPED, NULL);
        free(detail);
        if (bus == INVALID_HANDLE_VALUE) {
            hr = HRESULT_FROM_WIN32(GetLastError());
            continue;
        }
        msw_vigem *v = calloc(1, sizeof(*v));
        HANDLE ev = CreateEventW(NULL, TRUE, FALSE, NULL);
        if (!v || !ev) {
            free(v);
            if (ev) CloseHandle(ev);
            CloseHandle(bus);
            hr = E_OUTOFMEMORY;
            break;
        }
        v->bus = bus;
        v->event = ev;
        vigem_version_req ver = {.Size = sizeof(ver), .Version = VIGEM_COMMON_VERSION};
        hr = ioctl(v, IOCTL_VIGEM_CHECK_VERSION, &ver, sizeof(ver), NULL, 0);
        if (SUCCEEDED(hr)) {
            *out = v;
            break;
        }
        msw_vigem_close(v);
    }
    SetupDiDestroyDeviceInfoList(set);
    return hr;
}

void msw_vigem_close(msw_vigem *v) {
    if (!v) return;
    /* The bus unplugs whatever this handle plugged when it closes. */
    CloseHandle(v->bus);
    CloseHandle(v->event);
    free(v);
}

msw_hr msw_vigem_plug_x360(msw_vigem *v, uint32_t *serial) {
    *serial = 0;
    HRESULT hr = E_FAIL;
    for (ULONG s = 1; s <= VIGEM_MAX_SERIAL; s++) {
        vigem_plugin_req p = {.Size = sizeof(p), .SerialNo = s, .TargetType = VIGEM_TARGET_X360_WIRED};
        hr = ioctl(v, IOCTL_VIGEM_PLUGIN_TARGET, &p, sizeof(p), NULL, 0);
        if (hr == HRESULT_FROM_WIN32(ERROR_TIMEOUT)) return hr;
        if (FAILED(hr)) continue; /* serial in use */
        /* Plug-in returns at once (v1.17+); this one stays pending until PnP has started
         * the child and it accepts reports. */
        vigem_serial_req w = {.Size = sizeof(w), .SerialNo = s};
        hr = ioctl(v, IOCTL_VIGEM_WAIT_DEVICE_READY, &w, sizeof(w), NULL, 0);
        if (FAILED(hr)) {
            msw_vigem_unplug(v, s);
            return hr;
        }
        *serial = s;
        return S_OK;
    }
    return hr;
}

msw_hr msw_vigem_update_x360(msw_vigem *v, uint32_t serial, const msw_xusb_report *report) {
    vigem_xusb_submit_req r = {.Size = sizeof(r), .SerialNo = serial, .Report = *report};
    return ioctl(v, IOCTL_XUSB_SUBMIT_REPORT, &r, sizeof(r), NULL, 0);
}

msw_hr msw_vigem_unplug(msw_vigem *v, uint32_t serial) {
    vigem_serial_req u = {.Size = sizeof(u), .SerialNo = serial};
    return ioctl(v, IOCTL_VIGEM_UNPLUG_TARGET, &u, sizeof(u), NULL, 0);
}

msw_hr msw_vigem_user_index(msw_vigem *v, uint32_t serial, uint32_t *index) {
    vigem_user_index_req r = {.Size = sizeof(r), .SerialNo = serial};
    HRESULT hr = ioctl(v, IOCTL_XUSB_GET_USER_INDEX, &r, sizeof(r), &r, sizeof(r));
    *index = r.UserIndex;
    return hr;
}

uint32_t msw_xusb_driver_present(void) {
    wchar_t path[MAX_PATH];
    UINT n = GetSystemDirectoryW(path, MAX_PATH);
    if (n == 0 || n + 24 >= MAX_PATH) return 0;
    wcscat(path, L"\\drivers\\xusb22.sys");
    return GetFileAttributesW(path) != INVALID_FILE_ATTRIBUTES;
}

/* XInputGetState from xinput1_4.dll, loaded at run time (tests only). */
typedef struct {
    DWORD packet;
    msw_xusb_report pad;
} xinput_state;
typedef DWORD(WINAPI *xinput_get_state_fn)(DWORD, xinput_state *);

msw_hr msw_xinput_state(uint32_t user, msw_xusb_report *out, uint32_t *packet) {
    static xinput_get_state_fn get;
    if (!get) {
        HMODULE m = LoadLibraryW(L"xinput1_4.dll");
        if (!m) return HRESULT_FROM_WIN32(GetLastError());
        get = (xinput_get_state_fn)(void *)GetProcAddress(m, "XInputGetState");
        if (!get) return HRESULT_FROM_WIN32(GetLastError());
    }
    xinput_state s = {0};
    DWORD e = get(user, &s);
    if (e != ERROR_SUCCESS) return HRESULT_FROM_WIN32(e);
    *out = s.pad;
    *packet = s.packet;
    return S_OK;
}
