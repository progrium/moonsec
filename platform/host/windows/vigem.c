/* Virtual Xbox 360 pads through the ViGEmBus driver (https://github.com/nefarius/ViGEmBus).
 *
 * ViGEmBus is a signed kernel bus driver the user installs once; it is not shipped with
 * moonsec. This file speaks its IOCTL protocol directly (the XUSB subset) instead of
 * linking the C++ ViGEmClient library. The IOCTL codes and request layouts follow
 * ViGEmClient's include/ViGEm/km/BusShared.h and Common.h:
 *   MIT License, Copyright (c) 2016-2019 Nefarius Software Solutions e.U. and Contributors.
 *
 * Every pad shows up as a wired Xbox 360 controller (045E:028E), which XInput,
 * DirectInput, Windows.Gaming.Input and SDL all read. */
#include "msw_internal.h"
#include "host_win.h"

#include <setupapi.h>
#include <winioctl.h>

/* {96E42B22-F5E9-42F8-B043-ED0F932F014F} */
static const GUID kVigemBusInterface = {0x96E42B22, 0xF5E9, 0x42F8, {0xB0, 0x43, 0xED, 0x0F, 0x93, 0x2F, 0x01, 0x4F}};

#define VIGEM_COMMON_VERSION 0x0001
#define VIGEM_IOCTL_BASE 0x801
#define VIGEM_W(i) CTL_CODE(FILE_DEVICE_BUS_EXTENDER, VIGEM_IOCTL_BASE + (i), METHOD_BUFFERED, FILE_WRITE_DATA)
#define IOCTL_VIGEM_PLUGIN_TARGET VIGEM_W(0x000)
#define IOCTL_VIGEM_UNPLUG_TARGET VIGEM_W(0x001)
#define IOCTL_VIGEM_CHECK_VERSION VIGEM_W(0x002)
#define IOCTL_VIGEM_WAIT_DEVICE_READY VIGEM_W(0x003)
#define IOCTL_XUSB_SUBMIT_REPORT VIGEM_W(0x201)

/* The bus numbers its children 1..VIGEM_TARGETS_MAX; a free number is found by trying. */
#define VIGEM_TARGETS_MAX 16

typedef struct {
    ULONG Size, SerialNo;
    ULONG TargetType; /* VIGEM_TARGET_TYPE: 0 = Xbox 360 wired */
    USHORT VendorId, ProductId;
} vigem_plugin;

typedef struct {
    ULONG Size, SerialNo;
} vigem_serial; /* VIGEM_UNPLUG_TARGET, VIGEM_WAIT_DEVICE_READY */

typedef struct {
    ULONG Size, Version;
} vigem_check_version;

typedef struct {
    USHORT wButtons;
    BYTE bLeftTrigger, bRightTrigger;
    SHORT sThumbLX, sThumbLY, sThumbRX, sThumbRY;
} xusb_report;

typedef struct {
    ULONG Size, SerialNo;
    xusb_report Report;
} xusb_submit_report;

_Static_assert(sizeof(vigem_plugin) == 16, "VIGEM_PLUGIN_TARGET layout");
_Static_assert(sizeof(xusb_submit_report) == 20, "XUSB_SUBMIT_REPORT layout");

struct msw_vigem {
    HANDLE bus;
    HANDLE event; /* for the overlapped IOCTLs; the bus handle is opened overlapped */
};

/* One IOCTL, waited for. FALSE with GetLastError() set on failure. */
static BOOL vigem_ioctl(msw_vigem *v, DWORD code, void *in, DWORD in_len) {
    OVERLAPPED ov = {0};
    ov.hEvent = v->event;
    DWORD n = 0;
    if (!DeviceIoControl(v->bus, code, in, in_len, NULL, 0, &n, &ov) && GetLastError() != ERROR_IO_PENDING) return FALSE;
    return GetOverlappedResult(v->bus, &ov, &n, TRUE);
}

static HRESULT last_hr(void) {
    DWORD e = GetLastError();
    return e ? HRESULT_FROM_WIN32(e) : E_FAIL;
}

msw_hr msw_vigem_open(msw_vigem **out) {
    *out = NULL;
    HDEVINFO set = SetupDiGetClassDevsW(&kVigemBusInterface, NULL, NULL, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
    if (set == INVALID_HANDLE_VALUE) return last_hr();
    msw_vigem *v = calloc(1, sizeof(*v));
    if (!v) {
        SetupDiDestroyDeviceInfoList(set);
        return E_OUTOFMEMORY;
    }
    v->bus = INVALID_HANDLE_VALUE;
    v->event = CreateEventW(NULL, FALSE, FALSE, NULL);
    HRESULT hr = v->event ? MSW_E_VIGEM_NOT_INSTALLED : last_hr();
    SP_DEVICE_INTERFACE_DATA iface = {.cbSize = sizeof(iface)};
    for (DWORD i = 0; v->event && SetupDiEnumDeviceInterfaces(set, NULL, &kVigemBusInterface, i, &iface); i++) {
        DWORD need = 0;
        SetupDiGetDeviceInterfaceDetailW(set, &iface, NULL, 0, &need, NULL);
        SP_DEVICE_INTERFACE_DETAIL_DATA_W *detail = need ? malloc(need) : NULL;
        if (!detail) continue;
        detail->cbSize = sizeof(*detail);
        if (SetupDiGetDeviceInterfaceDetailW(set, &iface, detail, need, &need, NULL)) {
            v->bus = CreateFileW(detail->DevicePath, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
                                 OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_NO_BUFFERING | FILE_FLAG_WRITE_THROUGH | FILE_FLAG_OVERLAPPED,
                                 NULL);
        }
        free(detail);
        if (v->bus == INVALID_HANDLE_VALUE) {
            hr = last_hr();
            continue;
        }
        vigem_check_version cv = {.Size = sizeof(cv), .Version = VIGEM_COMMON_VERSION};
        if (vigem_ioctl(v, IOCTL_VIGEM_CHECK_VERSION, &cv, sizeof(cv))) {
            hr = S_OK;
            break;
        }
        hr = MSW_E_VIGEM_VERSION;
        CloseHandle(v->bus);
        v->bus = INVALID_HANDLE_VALUE;
    }
    SetupDiDestroyDeviceInfoList(set);
    if (FAILED(hr)) {
        msw_vigem_close(v);
        return hr;
    }
    *out = v;
    return S_OK;
}

void msw_vigem_close(msw_vigem *v) {
    if (!v) return;
    /* Closing the bus handle unplugs every pad this handle plugged in. */
    if (v->bus != INVALID_HANDLE_VALUE) CloseHandle(v->bus);
    if (v->event) CloseHandle(v->event);
    free(v);
}

msw_hr msw_vigem_plug(msw_vigem *v, uint32_t *serial) {
    *serial = 0;
    HRESULT hr = HRESULT_FROM_WIN32(ERROR_NO_MORE_ITEMS);
    for (ULONG s = 1; s <= VIGEM_TARGETS_MAX; s++) {
        vigem_plugin p = {.Size = sizeof(p), .SerialNo = s, .TargetType = 0, .VendorId = 0x045E, .ProductId = 0x028E};
        if (!vigem_ioctl(v, IOCTL_VIGEM_PLUGIN_TARGET, &p, sizeof(p))) continue; /* serial taken: try the next */
        /* Bus v1.17+ holds this until the pad accepts reports; older buses reject it. */
        vigem_serial w = {.Size = sizeof(w), .SerialNo = s};
        if (vigem_ioctl(v, IOCTL_VIGEM_WAIT_DEVICE_READY, &w, sizeof(w)) || GetLastError() == ERROR_INVALID_PARAMETER) {
            *serial = s;
            return S_OK;
        }
        hr = last_hr();
        msw_vigem_unplug(v, s);
        break;
    }
    return hr;
}

msw_hr msw_vigem_unplug(msw_vigem *v, uint32_t serial) {
    vigem_serial u = {.Size = sizeof(u), .SerialNo = serial};
    return vigem_ioctl(v, IOCTL_VIGEM_UNPLUG_TARGET, &u, sizeof(u)) ? S_OK : last_hr();
}

msw_hr msw_vigem_update(msw_vigem *v, uint32_t serial, const msw_xusb_report *r) {
    xusb_submit_report x = {.Size = sizeof(x), .SerialNo = serial};
    x.Report.wButtons = r->buttons;
    x.Report.bLeftTrigger = r->left_trigger;
    x.Report.bRightTrigger = r->right_trigger;
    x.Report.sThumbLX = r->lx;
    x.Report.sThumbLY = r->ly;
    x.Report.sThumbRX = r->rx;
    x.Report.sThumbRY = r->ry;
    return vigem_ioctl(v, IOCTL_XUSB_SUBMIT_REPORT, &x, sizeof(x)) ? S_OK : last_hr();
}
