/* Virtual displays through the moonsec IddCx driver (platform/windows/idd), and the
 * display-configuration helpers capture needs to find and size them.
 *
 * msw_vdisp_open finds the driver's device interface. When no device exists yet it
 * creates a software device (SwDeviceCreate) that lives only as long as this process,
 * so a host that dies takes its displays with it; the driver's ping watchdog is the
 * second guard (a thread here pings every MOONSEC_IDD_PING_INTERVAL_MS). */
#include "msw_internal.h"
#include "host_win.h"
#include "idd/moonsec_idd.h"

#include <cfgmgr32.h>
#include <stdio.h>
#include <string.h>
#include <winioctl.h>

/* swdevice.h is not in mingw-w64; the few declarations we need (Windows 8+,
 * cfgmgr32.dll). */
typedef struct HSWDEVICE__ *HSWDEVICE;
typedef struct moonsec_sw_device_create_info {
    ULONG cbSize;
    PCWSTR pszInstanceId;
    PCWSTR pszzHardwareIds;
    PCWSTR pszzCompatibleIds;
    const GUID *pContainerId;
    ULONG CapabilityFlags;
    PCWSTR pszDeviceDescription;
    PCWSTR pszDeviceLocation;
    const SECURITY_DESCRIPTOR *pSecurityDescriptor;
} moonsec_sw_device_create_info;
enum { SW_CAP_REMOVABLE = 1, SW_CAP_SILENT_INSTALL = 2, SW_CAP_DRIVER_REQUIRED = 8 };
typedef VOID(WINAPI *moonsec_sw_device_create_callback)(HSWDEVICE, HRESULT, PVOID, PCWSTR);
DECLSPEC_IMPORT HRESULT WINAPI SwDeviceCreate(PCWSTR, PCWSTR, const moonsec_sw_device_create_info *, ULONG,
                                              const void *, moonsec_sw_device_create_callback, PVOID, HSWDEVICE *);
DECLSPEC_IMPORT void WINAPI SwDeviceClose(HSWDEVICE);

static const GUID kIddInterface = MOONSEC_IDD_INTERFACE_GUID_INIT;

struct msw_vdisp {
    HANDLE dev;
    HSWDEVICE sw;
    HANDLE ping_thread;
    HANDLE ping_stop;
    CRITICAL_SECTION io; /* one DeviceIoControl at a time */
};

static msw_hr last_hr(void) {
    DWORD e = GetLastError();
    return e ? HRESULT_FROM_WIN32(e) : MSW_E_FAIL;
}

/* Opens the first present interface of the driver; MSW_E_NOTFOUND when there is none. */
static msw_hr open_interface(HANDLE *out) {
    *out = INVALID_HANDLE_VALUE;
    GUID g = kIddInterface;
    ULONG len = 0;
    if (CM_Get_Device_Interface_List_SizeW(&len, &g, NULL, CM_GET_DEVICE_INTERFACE_LIST_PRESENT) != CR_SUCCESS ||
        len <= 1)
        return MSW_E_NOTFOUND;
    WCHAR *list = (WCHAR *)calloc(len, sizeof(WCHAR));
    if (!list) return E_OUTOFMEMORY;
    msw_hr hr = MSW_E_NOTFOUND;
    if (CM_Get_Device_Interface_ListW(&g, NULL, list, len, CM_GET_DEVICE_INTERFACE_LIST_PRESENT) == CR_SUCCESS) {
        for (WCHAR *p = list; *p; p += wcslen(p) + 1) {
            HANDLE h = CreateFileW(p, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
                                   OPEN_EXISTING, 0, NULL);
            if (h != INVALID_HANDLE_VALUE) {
                *out = h;
                hr = S_OK;
                break;
            }
            hr = last_hr();
        }
    }
    free(list);
    return hr;
}

typedef struct sw_wait {
    HANDLE done;
    HRESULT result;
} sw_wait;

static VOID WINAPI sw_created(HSWDEVICE h, HRESULT result, PVOID ctx, PCWSTR id) {
    (void)h;
    (void)id;
    sw_wait *w = (sw_wait *)ctx;
    w->result = result;
    SetEvent(w->done);
}

static msw_hr create_sw_device(HSWDEVICE *out) {
    *out = NULL;
    static const WCHAR hwids[] = MOONSEC_IDD_HWID L"\0";
    moonsec_sw_device_create_info info;
    memset(&info, 0, sizeof info);
    info.cbSize = sizeof info;
    info.pszInstanceId = L"0";
    info.pszzHardwareIds = hwids;
    info.pszzCompatibleIds = hwids;
    info.CapabilityFlags = SW_CAP_REMOVABLE | SW_CAP_SILENT_INSTALL | SW_CAP_DRIVER_REQUIRED;
    info.pszDeviceDescription = L"moonsec virtual display";
    sw_wait w = {CreateEventW(NULL, TRUE, FALSE, NULL), E_FAIL};
    if (!w.done) return last_hr();
    HSWDEVICE h = NULL;
    HRESULT hr = SwDeviceCreate(MOONSEC_IDD_SW_ENUMERATOR, L"HTREE\\ROOT\\0", &info, 0, NULL, sw_created, &w, &h);
    if (SUCCEEDED(hr)) {
        if (WaitForSingleObject(w.done, 10000) != WAIT_OBJECT_0) hr = HRESULT_FROM_WIN32(ERROR_TIMEOUT);
        else hr = w.result;
        if (FAILED(hr)) {
            SwDeviceClose(h);
            h = NULL;
        }
    }
    CloseHandle(w.done);
    *out = h;
    return hr;
}

static msw_hr vd_ioctl(msw_vdisp *v, uint32_t code, const void *in, DWORD in_len, void *out, DWORD out_len) {
    DWORD got = 0;
    EnterCriticalSection(&v->io);
    BOOL okay = DeviceIoControl(v->dev, code, (void *)in, in_len, out, out_len, &got, NULL);
    msw_hr hr = okay ? S_OK : last_hr();
    LeaveCriticalSection(&v->io);
    if (SUCCEEDED(hr) && out_len && got < out_len) hr = HRESULT_FROM_WIN32(ERROR_INVALID_DATA);
    return hr;
}

static DWORD WINAPI ping_main(LPVOID p) {
    msw_vdisp *v = (msw_vdisp *)p;
    while (WaitForSingleObject(v->ping_stop, MOONSEC_IDD_PING_INTERVAL_MS) == WAIT_TIMEOUT)
        vd_ioctl(v, MOONSEC_IDD_IOCTL_PING, NULL, 0, NULL, 0);
    return 0;
}

msw_hr msw_vdisp_open(uint32_t create_device, msw_vdisp **out) {
    *out = NULL;
    msw_vdisp *v = (msw_vdisp *)calloc(1, sizeof *v);
    if (!v) return E_OUTOFMEMORY;
    InitializeCriticalSection(&v->io);
    msw_hr hr = open_interface(&v->dev);
    if (hr == MSW_E_NOTFOUND && create_device) {
        hr = create_sw_device(&v->sw);
        if (SUCCEEDED(hr)) {
            /* The interface shows up once the driver started; that takes a moment. */
            hr = MSW_E_NOTFOUND;
            for (int i = 0; i < 100 && hr == MSW_E_NOTFOUND; i++) {
                hr = open_interface(&v->dev);
                if (hr == MSW_E_NOTFOUND) Sleep(50);
            }
        } else if (hr == HRESULT_FROM_WIN32(ERROR_NOT_FOUND) || hr == HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND)) {
            hr = MSW_E_NOTFOUND;
        }
    }
    if (FAILED(hr)) goto fail;

    moonsec_idd_info info;
    /* The adapter finishes initializing asynchronously after the device starts. */
    for (int i = 0; i < 100; i++) {
        hr = vd_ioctl(v, MOONSEC_IDD_IOCTL_INFO, NULL, 0, &info, sizeof info);
        if (FAILED(hr) || info.adapter_ready) break;
        Sleep(50);
    }
    if (FAILED(hr)) goto fail;
    if (info.protocol != MOONSEC_IDD_PROTOCOL) {
        hr = HRESULT_FROM_WIN32(ERROR_REVISION_MISMATCH);
        goto fail;
    }
    if (!info.adapter_ready) {
        hr = HRESULT_FROM_WIN32(ERROR_NOT_READY);
        goto fail;
    }
    v->ping_stop = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (!v->ping_stop) {
        hr = last_hr();
        goto fail;
    }
    v->ping_thread = CreateThread(NULL, 0, ping_main, v, 0, NULL);
    if (!v->ping_thread) {
        hr = last_hr();
        goto fail;
    }
    *out = v;
    return S_OK;
fail:
    msw_vdisp_close(v);
    return hr;
}

void msw_vdisp_close(msw_vdisp *v) {
    if (!v) return;
    msw_vdisp_stop_pinging(v);
    if (v->ping_stop) CloseHandle(v->ping_stop);
    if (v->dev && v->dev != INVALID_HANDLE_VALUE) {
        vd_ioctl(v, MOONSEC_IDD_IOCTL_REMOVE_ALL, NULL, 0, NULL, 0);
        CloseHandle(v->dev);
    }
    if (v->sw) SwDeviceClose(v->sw);
    DeleteCriticalSection(&v->io);
    free(v);
}

void msw_vdisp_stop_pinging(msw_vdisp *v) {
    if (!v->ping_thread) return;
    SetEvent(v->ping_stop);
    WaitForSingleObject(v->ping_thread, INFINITE);
    CloseHandle(v->ping_thread);
    v->ping_thread = NULL;
}

static void monitor_out(const moonsec_idd_monitor *m, msw_vdisp_monitor *out) {
    out->id = m->id;
    out->adapter_luid = ((int64_t)m->adapter_luid_high << 32) | (int64_t)m->adapter_luid_low;
    out->target_id = m->target_id;
    out->width = m->mode.width;
    out->height = m->mode.height;
    out->refresh_hz = m->mode.refresh_hz;
}

msw_hr msw_vdisp_add(msw_vdisp *v, uint32_t width, uint32_t height, uint32_t refresh_hz, int64_t render_luid,
                     msw_vdisp_monitor *out) {
    moonsec_idd_add in;
    memset(&in, 0, sizeof in);
    in.mode.width = width;
    in.mode.height = height;
    in.mode.refresh_hz = refresh_hz;
    in.render_luid_low = (uint32_t)(render_luid & 0xffffffff);
    in.render_luid_high = (int32_t)(render_luid >> 32);
    moonsec_idd_monitor m;
    msw_hr hr = vd_ioctl(v, MOONSEC_IDD_IOCTL_ADD, &in, sizeof in, &m, sizeof m);
    if (SUCCEEDED(hr)) monitor_out(&m, out);
    return hr;
}

msw_hr msw_vdisp_set_mode(msw_vdisp *v, uint32_t id, uint32_t width, uint32_t height, uint32_t refresh_hz,
                          msw_vdisp_monitor *out) {
    moonsec_idd_set_mode in;
    memset(&in, 0, sizeof in);
    in.id = id;
    in.mode.width = width;
    in.mode.height = height;
    in.mode.refresh_hz = refresh_hz;
    moonsec_idd_monitor m;
    msw_hr hr = vd_ioctl(v, MOONSEC_IDD_IOCTL_SET_MODE, &in, sizeof in, &m, sizeof m);
    if (SUCCEEDED(hr)) monitor_out(&m, out);
    return hr;
}

msw_hr msw_vdisp_remove(msw_vdisp *v, uint32_t id) {
    moonsec_idd_id in = {id};
    return vd_ioctl(v, MOONSEC_IDD_IOCTL_REMOVE, &in, sizeof in, NULL, 0);
}

msw_hr msw_vdisp_active(msw_vdisp *v, uint32_t *count) {
    moonsec_idd_info info;
    msw_hr hr = vd_ioctl(v, MOONSEC_IDD_IOCTL_INFO, NULL, 0, &info, sizeof info);
    *count = SUCCEEDED(hr) ? info.active_monitors : 0;
    return hr;
}

/* ---- Display configuration ---------------------------------------------------- */

static int64_t luid64(LUID l) { return ((int64_t)l.HighPart << 32) | (int64_t)l.LowPart; }

/* Active display paths (QDC_ONLY_ACTIVE_PATHS). Caller frees *paths. */
static msw_hr active_paths(DISPLAYCONFIG_PATH_INFO **paths, UINT32 *np, DISPLAYCONFIG_MODE_INFO **modes, UINT32 *nm) {
    *paths = NULL;
    *modes = NULL;
    for (int attempt = 0; attempt < 4; attempt++) {
        UINT32 p = 0, m = 0;
        LONG r = GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &p, &m);
        if (r != ERROR_SUCCESS) return HRESULT_FROM_WIN32(r);
        *paths = (DISPLAYCONFIG_PATH_INFO *)calloc(p ? p : 1, sizeof **paths);
        *modes = (DISPLAYCONFIG_MODE_INFO *)calloc(m ? m : 1, sizeof **modes);
        if (!*paths || !*modes) {
            free(*paths);
            free(*modes);
            return E_OUTOFMEMORY;
        }
        r = QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, &p, *paths, &m, *modes, NULL);
        if (r == ERROR_SUCCESS) {
            *np = p;
            *nm = m;
            return S_OK;
        }
        free(*paths);
        free(*modes);
        *paths = NULL;
        *modes = NULL;
        if (r != ERROR_INSUFFICIENT_BUFFER) return HRESULT_FROM_WIN32(r);
    }
    return HRESULT_FROM_WIN32(ERROR_INSUFFICIENT_BUFFER);
}

uint32_t msw_display_count_active(int64_t exclude_luid) {
    DISPLAYCONFIG_PATH_INFO *paths;
    DISPLAYCONFIG_MODE_INFO *modes;
    UINT32 np = 0, nm = 0;
    if (FAILED(active_paths(&paths, &np, &modes, &nm))) return 0;
    uint32_t n = 0;
    for (UINT32 i = 0; i < np; i++)
        if (exclude_luid == 0 || luid64(paths[i].targetInfo.adapterId) != exclude_luid) n++;
    free(paths);
    free(modes);
    return n;
}

/* The GDI device name (\\.\DISPLAYn) of the active path to (luid, target); S_FALSE when
 * that target is not active. */
static msw_hr source_name(int64_t luid, uint32_t target_id, WCHAR name[32]) {
    DISPLAYCONFIG_PATH_INFO *paths;
    DISPLAYCONFIG_MODE_INFO *modes;
    UINT32 np = 0, nm = 0;
    msw_hr hr = active_paths(&paths, &np, &modes, &nm);
    if (FAILED(hr)) return hr;
    hr = S_FALSE;
    for (UINT32 i = 0; i < np; i++) {
        if (luid64(paths[i].targetInfo.adapterId) != luid || paths[i].targetInfo.id != target_id) continue;
        DISPLAYCONFIG_SOURCE_DEVICE_NAME src;
        memset(&src, 0, sizeof src);
        src.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME;
        src.header.size = sizeof src;
        src.header.adapterId = paths[i].sourceInfo.adapterId;
        src.header.id = paths[i].sourceInfo.id;
        LONG r = DisplayConfigGetDeviceInfo(&src.header);
        if (r != ERROR_SUCCESS) {
            hr = HRESULT_FROM_WIN32(r);
            break;
        }
        memcpy(name, src.viewGdiDeviceName, sizeof src.viewGdiDeviceName);
        name[31] = 0;
        hr = S_OK;
        break;
    }
    free(paths);
    free(modes);
    return hr;
}

msw_hr msw_display_activate(int64_t adapter_luid, uint32_t target_id, uint32_t width, uint32_t height,
                            uint32_t refresh_hz, uint32_t timeout_ms, char gdi_name[32]) {
    gdi_name[0] = 0;
    WCHAR name[32];
    ULONGLONG deadline = GetTickCount64() + timeout_ms;
    int extended = 0;
    msw_hr hr;
    for (;;) {
        hr = source_name(adapter_luid, target_id, name);
        if (hr != S_FALSE) break;
        ULONGLONG now = GetTickCount64();
        if (!extended && now + timeout_ms / 2 >= deadline) {
            /* Windows normally attaches a new monitor to the desktop by itself; if it
             * did not (a topology the user saved), extend the desktop onto it. */
            SetDisplayConfig(0, NULL, 0, NULL, SDC_TOPOLOGY_EXTEND | SDC_APPLY);
            extended = 1;
        }
        if (now >= deadline) return HRESULT_FROM_WIN32(ERROR_TIMEOUT);
        Sleep(50);
    }
    if (FAILED(hr)) return hr;

    DEVMODEW dm;
    memset(&dm, 0, sizeof dm);
    dm.dmSize = sizeof dm;
    if (EnumDisplaySettingsW(name, ENUM_CURRENT_SETTINGS, &dm) && dm.dmPelsWidth == width &&
        dm.dmPelsHeight == height && dm.dmDisplayFrequency == refresh_hz) {
        msw_utf8(name, gdi_name, 32);
        return S_OK;
    }
    /* Windows may restore a mode it remembered for this monitor: set the one asked for. */
    memset(&dm, 0, sizeof dm);
    dm.dmSize = sizeof dm;
    dm.dmPelsWidth = width;
    dm.dmPelsHeight = height;
    dm.dmDisplayFrequency = refresh_hz;
    dm.dmFields = DM_PELSWIDTH | DM_PELSHEIGHT | DM_DISPLAYFREQUENCY;
    LONG r = ChangeDisplaySettingsExW(name, &dm, NULL, CDS_UPDATEREGISTRY, NULL);
    if (r != DISP_CHANGE_SUCCESSFUL) return HRESULT_FROM_WIN32(ERROR_INVALID_PARAMETER);
    msw_utf8(name, gdi_name, 32);
    return S_OK;
}
