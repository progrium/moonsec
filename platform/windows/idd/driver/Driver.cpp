// moonsec virtual display driver: an IddCx (UMDF 2) indirect display driver that plugs
// in up to MOONSEC_IDD_MAX_MONITORS displays on request from the moonsec host, so a
// machine with no monitor attached still has a desktop to capture.
//
// Structure follows Microsoft's IddSampleDriver:
//   - DriverEntry / DeviceAdd set up IddCx and a device interface for the host.
//   - D0Entry starts the adapter (IddCxAdapterInitAsync).
//   - The host's IOCTLs (moonsec_idd.h) create and remove monitors. Monitors carry no
//     EDID; the OS asks for their modes (GetDefaultDescriptionModes, QueryTargetModes),
//     and the requested mode is the preferred one.
//   - AssignSwapChain starts a thread per monitor that takes each frame DWM composes and
//     hands it straight back. The host never sees these frames: it captures the display
//     through Desktop Duplication like any other, so the driver does no copies.
//   - A periodic timer removes every monitor when the host stops pinging, so a host
//     that crashed leaves no display behind.
#define NOMINMAX
#include <windows.h>
#include <bugcodes.h>
#include <wudfwdm.h>
#include <wdf.h>
#include <iddcx.h>
#include <dxgi1_5.h>
#include <d3d11_2.h>
#include <avrt.h>
#include <wrl.h>

#include <new>

#include "../moonsec_idd.h"

using Microsoft::WRL::ComPtr;

namespace {

const GUID kInterfaceGuid = MOONSEC_IDD_INTERFACE_GUID_INIT;
// Container IDs: this base with the slot number in the last byte, so each slot is the
// same "monitor" to Windows across plug and unplug.
const GUID kContainerBase = {0x225bf4b0, 0x2421, 0x4f0a, {0xb1, 0x09, 0x32, 0xe8, 0xaa, 0xac, 0x06, 0x00}};

const UINT kMaxModes = 8;

class SwapChainProcessor;

struct MonitorSlot {
    IDDCX_MONITOR object; // null when free
    moonsec_idd_monitor info;
};

struct DeviceContext {
    WDFDEVICE device;
    IDDCX_ADAPTER adapter;
    volatile LONG adapter_ready;
    SRWLOCK lock;
    MonitorSlot slots[MOONSEC_IDD_MAX_MONITORS];
    ULONGLONG last_ping_ms;
    LUID render_luid;
    bool render_luid_set;
    WDFTIMER watchdog;
};
WDF_DECLARE_CONTEXT_TYPE_WITH_NAME(DeviceContext, GetDeviceContext);

struct AdapterContext {
    DeviceContext *dev;
};
WDF_DECLARE_CONTEXT_TYPE_WITH_NAME(AdapterContext, GetAdapterContext);

struct MonitorContext {
    DeviceContext *dev;
    UINT slot;
    moonsec_idd_mode mode;
    SwapChainProcessor *processor;
};
WDF_DECLARE_CONTEXT_TYPE_WITH_NAME(MonitorContext, GetMonitorContext);

// ---------------------------------------------------------------------------
// Modes

void FillSignalInfo(DISPLAYCONFIG_VIDEO_SIGNAL_INFO &m, DWORD w, DWORD h, DWORD hz, bool monitor_mode) {
    m.totalSize.cx = m.activeSize.cx = w;
    m.totalSize.cy = m.activeSize.cy = h;
    m.AdditionalSignalInfo.vSyncFreqDivider = monitor_mode ? 0 : 1;
    m.AdditionalSignalInfo.videoStandard = 255;
    m.vSyncFreq.Numerator = hz;
    m.vSyncFreq.Denominator = 1;
    m.hSyncFreq.Numerator = hz * h;
    m.hSyncFreq.Denominator = 1;
    m.scanLineOrdering = DISPLAYCONFIG_SCANLINE_ORDERING_PROGRESSIVE;
    m.pixelRate = (UINT64)hz * (UINT64)w * (UINT64)h;
}

// The requested mode first (the preferred one), then common sizes at the same rate so
// Display Settings offers something sensible.
UINT ModeList(const moonsec_idd_mode &pref, moonsec_idd_mode out[kMaxModes]) {
    static const UINT32 common[][2] = {{3840, 2160}, {2560, 1440}, {1920, 1080}, {1600, 900}, {1280, 720}};
    UINT n = 0;
    out[n++] = pref;
    for (auto &c : common) {
        if (n >= kMaxModes) break;
        if (c[0] == pref.width && c[1] == pref.height) continue;
        out[n++] = {c[0], c[1], pref.refresh_hz};
    }
    return n;
}

bool ModeValid(const moonsec_idd_mode &m) {
    return m.width >= 640 && m.width <= 7680 && m.height >= 360 && m.height <= 4320 && m.refresh_hz >= 24 &&
           m.refresh_hz <= 240;
}

// ---------------------------------------------------------------------------
// Swap chain: take every frame and give it back

class SwapChainProcessor {
  public:
    SwapChainProcessor(IDDCX_SWAPCHAIN swapchain, ComPtr<ID3D11Device> device, HANDLE available)
        : swapchain_(swapchain), device_(device), available_(available) {
        terminate_ = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        thread_ = CreateThread(nullptr, 0, RunThread, this, 0, nullptr);
    }

    ~SwapChainProcessor() {
        if (terminate_) SetEvent(terminate_);
        if (thread_) {
            WaitForSingleObject(thread_, INFINITE);
            CloseHandle(thread_);
        }
        if (terminate_) CloseHandle(terminate_);
    }

    bool ok() const { return terminate_ && thread_; }

  private:
    static DWORD CALLBACK RunThread(LPVOID p) {
        reinterpret_cast<SwapChainProcessor *>(p)->Run();
        return 0;
    }

    void Run() {
        DWORD task = 0;
        HANDLE av = AvSetMmThreadCharacteristicsW(L"Distribution", &task);
        RunCore();
        // Deleting the swap chain tells the OS we're done with it.
        WdfObjectDelete((WDFOBJECT)swapchain_);
        swapchain_ = nullptr;
        if (av) AvRevertMmThreadCharacteristics(av);
    }

    void RunCore() {
        ComPtr<IDXGIDevice> dxgi;
        if (FAILED(device_.As(&dxgi))) return;
        IDARG_IN_SWAPCHAINSETDEVICE set = {};
        set.pDevice = dxgi.Get();
        if (FAILED(IddCxSwapChainSetDevice(swapchain_, &set))) return;
        for (;;) {
            IDARG_OUT_RELEASEANDACQUIREBUFFER buf = {};
            HRESULT hr = IddCxSwapChainReleaseAndAcquireBuffer(swapchain_, &buf);
            if (hr == E_PENDING) {
                HANDLE waits[] = {available_, terminate_};
                DWORD w = WaitForMultipleObjects(ARRAYSIZE(waits), waits, FALSE, 16);
                if (w == WAIT_OBJECT_0 || w == WAIT_TIMEOUT) continue;
                break; // terminate, or the wait failed
            }
            if (FAILED(hr)) break; // swap chain lost; the OS assigns a new one
            {
                ComPtr<IDXGIResource> surface;
                surface.Attach(buf.MetaData.pSurface);
            }
            if (FAILED(IddCxSwapChainFinishedProcessingFrame(swapchain_))) break;
        }
    }

    IDDCX_SWAPCHAIN swapchain_;
    ComPtr<ID3D11Device> device_;
    HANDLE available_;
    HANDLE terminate_ = nullptr;
    HANDLE thread_ = nullptr;
};

HRESULT CreateRenderDevice(LUID luid, ComPtr<ID3D11Device> &out) {
    ComPtr<IDXGIFactory5> factory;
    HRESULT hr = CreateDXGIFactory2(0, IID_PPV_ARGS(&factory));
    if (FAILED(hr)) return hr;
    ComPtr<IDXGIAdapter1> adapter;
    hr = factory->EnumAdapterByLuid(luid, IID_PPV_ARGS(&adapter));
    if (FAILED(hr)) return hr;
    return D3D11CreateDevice(adapter.Get(), D3D_DRIVER_TYPE_UNKNOWN, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                             nullptr, 0, D3D11_SDK_VERSION, &out, nullptr, nullptr);
}

// ---------------------------------------------------------------------------
// Monitors (called with dev->lock held exclusively)

NTSTATUS PlugIn(DeviceContext *dev, UINT slot, const moonsec_idd_mode &mode, moonsec_idd_monitor *out) {
    WDF_OBJECT_ATTRIBUTES attr;
    WDF_OBJECT_ATTRIBUTES_INIT_CONTEXT_TYPE(&attr, MonitorContext);

    IDDCX_MONITOR_INFO info = {};
    info.Size = sizeof(info);
    info.MonitorType = DISPLAYCONFIG_OUTPUT_TECHNOLOGY_INDIRECT_WIRED;
    info.ConnectorIndex = slot;
    info.MonitorDescription.Size = sizeof(info.MonitorDescription);
    info.MonitorDescription.Type = IDDCX_MONITOR_DESCRIPTION_TYPE_EDID;
    info.MonitorDescription.DataSize = 0; // no EDID: the OS asks us for modes
    info.MonitorDescription.pData = nullptr;
    info.MonitorContainerId = kContainerBase;
    info.MonitorContainerId.Data4[7] = (UCHAR)(slot + 1);

    IDARG_IN_MONITORCREATE create = {};
    create.ObjectAttributes = &attr;
    create.pMonitorInfo = &info;
    IDARG_OUT_MONITORCREATE created = {};
    NTSTATUS st = IddCxMonitorCreate(dev->adapter, &create, &created);
    if (!NT_SUCCESS(st)) return st;

    MonitorContext *mc = GetMonitorContext(created.MonitorObject);
    mc->dev = dev;
    mc->slot = slot;
    mc->mode = mode;
    mc->processor = nullptr;

    IDARG_OUT_MONITORARRIVAL arrival = {};
    st = IddCxMonitorArrival(created.MonitorObject, &arrival);
    if (!NT_SUCCESS(st)) {
        WdfObjectDelete((WDFOBJECT)created.MonitorObject);
        return st;
    }
    MonitorSlot &s = dev->slots[slot];
    s.object = created.MonitorObject;
    s.info.id = slot + 1;
    s.info.adapter_luid_low = arrival.OsAdapterLuid.LowPart;
    s.info.adapter_luid_high = arrival.OsAdapterLuid.HighPart;
    s.info.target_id = arrival.OsTargetId;
    s.info.mode = mode;
    if (out) *out = s.info;
    return STATUS_SUCCESS;
}

void Unplug(DeviceContext *dev, UINT slot) {
    MonitorSlot &s = dev->slots[slot];
    if (!s.object) return;
    IddCxMonitorDeparture(s.object);
    s.object = nullptr;
    s.info = {};
}

void UnplugAll(DeviceContext *dev) {
    for (UINT i = 0; i < MOONSEC_IDD_MAX_MONITORS; i++) Unplug(dev, i);
}

UINT ActiveCount(DeviceContext *dev) {
    UINT n = 0;
    for (auto &s : dev->slots)
        if (s.object) n++;
    return n;
}

bool SlotFromId(DeviceContext *dev, UINT32 id, UINT *slot) {
    if (id == 0 || id > MOONSEC_IDD_MAX_MONITORS || !dev->slots[id - 1].object) return false;
    *slot = id - 1;
    return true;
}

// ---------------------------------------------------------------------------
// IddCx callbacks

NTSTATUS AdapterInit(DeviceContext *dev) {
    IDDCX_ADAPTER_CAPS caps = {};
    caps.Size = sizeof(caps);
    caps.MaxMonitorsSupported = MOONSEC_IDD_MAX_MONITORS;
    caps.EndPointDiagnostics.Size = sizeof(caps.EndPointDiagnostics);
    caps.EndPointDiagnostics.GammaSupport = IDDCX_FEATURE_IMPLEMENTATION_NONE;
    caps.EndPointDiagnostics.TransmissionType = IDDCX_TRANSMISSION_TYPE_WIRED_OTHER;
    caps.EndPointDiagnostics.pEndPointFriendlyName = L"moonsec virtual display";
    caps.EndPointDiagnostics.pEndPointManufacturerName = L"moonsec";
    caps.EndPointDiagnostics.pEndPointModelName = L"Virtual Display";
    IDDCX_ENDPOINT_VERSION version = {};
    version.Size = sizeof(version);
    version.MajorVer = MOONSEC_IDD_PROTOCOL;
    caps.EndPointDiagnostics.pFirmwareVersion = &version;
    caps.EndPointDiagnostics.pHardwareVersion = &version;

    WDF_OBJECT_ATTRIBUTES attr;
    WDF_OBJECT_ATTRIBUTES_INIT_CONTEXT_TYPE(&attr, AdapterContext);
    IDARG_IN_ADAPTER_INIT init = {};
    init.WdfDevice = dev->device;
    init.pCaps = &caps;
    init.ObjectAttributes = &attr;
    IDARG_OUT_ADAPTER_INIT out = {};
    NTSTATUS st = IddCxAdapterInitAsync(&init, &out);
    if (NT_SUCCESS(st)) {
        dev->adapter = out.AdapterObject;
        GetAdapterContext(out.AdapterObject)->dev = dev;
    }
    return st;
}

NTSTATUS DeviceD0Entry(WDFDEVICE device, WDF_POWER_DEVICE_STATE previous) {
    UNREFERENCED_PARAMETER(previous);
    DeviceContext *dev = GetDeviceContext(device);
    if (dev->adapter) return STATUS_SUCCESS;
    return AdapterInit(dev);
}

NTSTATUS AdapterInitFinished(IDDCX_ADAPTER adapter, const IDARG_IN_ADAPTER_INIT_FINISHED *in) {
    DeviceContext *dev = GetAdapterContext(adapter)->dev;
    if (NT_SUCCESS(in->AdapterInitStatus)) InterlockedExchange(&dev->adapter_ready, 1);
    return STATUS_SUCCESS;
}

NTSTATUS AdapterCommitModes(IDDCX_ADAPTER adapter, const IDARG_IN_COMMITMODES *in) {
    UNREFERENCED_PARAMETER(adapter);
    UNREFERENCED_PARAMETER(in);
    // Nothing to program: there is no hardware behind the paths.
    return STATUS_SUCCESS;
}

NTSTATUS ParseMonitorDescription(const IDARG_IN_PARSEMONITORDESCRIPTION *in, IDARG_OUT_PARSEMONITORDESCRIPTION *out) {
    UNREFERENCED_PARAMETER(in);
    // Only called for monitors with an EDID; ours have none.
    out->MonitorModeBufferOutputCount = 0;
    return STATUS_INVALID_PARAMETER;
}

NTSTATUS MonitorGetDefaultModes(IDDCX_MONITOR monitor, const IDARG_IN_GETDEFAULTDESCRIPTIONMODES *in,
                                IDARG_OUT_GETDEFAULTDESCRIPTIONMODES *out) {
    moonsec_idd_mode modes[kMaxModes];
    UINT n = ModeList(GetMonitorContext(monitor)->mode, modes);
    out->DefaultMonitorModeBufferOutputCount = n;
    if (in->DefaultMonitorModeBufferInputCount == 0) return STATUS_SUCCESS;
    if (in->DefaultMonitorModeBufferInputCount < n) return STATUS_BUFFER_TOO_SMALL;
    for (UINT i = 0; i < n; i++) {
        IDDCX_MONITOR_MODE &m = in->pDefaultMonitorModes[i];
        m = {};
        m.Size = sizeof(m);
        m.Origin = IDDCX_MONITOR_MODE_ORIGIN_DRIVER;
        FillSignalInfo(m.MonitorVideoSignalInfo, modes[i].width, modes[i].height, modes[i].refresh_hz, true);
    }
    out->PreferredMonitorModeIdx = 0;
    return STATUS_SUCCESS;
}

NTSTATUS MonitorQueryTargetModes(IDDCX_MONITOR monitor, const IDARG_IN_QUERYTARGETMODES *in,
                                 IDARG_OUT_QUERYTARGETMODES *out) {
    moonsec_idd_mode modes[kMaxModes];
    UINT n = ModeList(GetMonitorContext(monitor)->mode, modes);
    out->TargetModeBufferOutputCount = n;
    if (in->TargetModeBufferInputCount == 0) return STATUS_SUCCESS;
    if (in->TargetModeBufferInputCount < n) return STATUS_BUFFER_TOO_SMALL;
    for (UINT i = 0; i < n; i++) {
        IDDCX_TARGET_MODE &m = in->pTargetModes[i];
        m = {};
        m.Size = sizeof(m);
        FillSignalInfo(m.TargetVideoSignalInfo.targetVideoSignalInfo, modes[i].width, modes[i].height,
                       modes[i].refresh_hz, false);
    }
    return STATUS_SUCCESS;
}

NTSTATUS MonitorAssignSwapChain(IDDCX_MONITOR monitor, const IDARG_IN_SETSWAPCHAIN *in) {
    MonitorContext *mc = GetMonitorContext(monitor);
    delete mc->processor;
    mc->processor = nullptr;
    ComPtr<ID3D11Device> device;
    if (SUCCEEDED(CreateRenderDevice(in->RenderAdapterLuid, device))) {
        auto *p = new (std::nothrow) SwapChainProcessor(in->hSwapChain, device, in->hNextSurfaceAvailable);
        if (p && p->ok()) {
            mc->processor = p;
            return STATUS_SUCCESS;
        }
        delete p;
    }
    // Hand the swap chain back; the OS tries again.
    WdfObjectDelete((WDFOBJECT)in->hSwapChain);
    return STATUS_SUCCESS;
}

NTSTATUS MonitorUnassignSwapChain(IDDCX_MONITOR monitor) {
    MonitorContext *mc = GetMonitorContext(monitor);
    delete mc->processor;
    mc->processor = nullptr;
    return STATUS_SUCCESS;
}

// ---------------------------------------------------------------------------
// Control interface

template <typename T> NTSTATUS Input(WDFREQUEST req, T **p) {
    return WdfRequestRetrieveInputBuffer(req, sizeof(T), reinterpret_cast<PVOID *>(p), nullptr);
}

template <typename T> NTSTATUS Output(WDFREQUEST req, T **p) {
    return WdfRequestRetrieveOutputBuffer(req, sizeof(T), reinterpret_cast<PVOID *>(p), nullptr);
}

NTSTATUS SetRenderAdapter(DeviceContext *dev, LUID luid) {
    if (luid.LowPart == 0 && luid.HighPart == 0) return STATUS_SUCCESS;
    if (dev->render_luid_set && dev->render_luid.LowPart == luid.LowPart && dev->render_luid.HighPart == luid.HighPart)
        return STATUS_SUCCESS;
    IDARG_IN_ADAPTERSETRENDERADAPTER in = {};
    in.PreferredRenderAdapter = luid;
    IddCxAdapterSetRenderAdapter(dev->adapter, &in);
    dev->render_luid = luid;
    dev->render_luid_set = true;
    return STATUS_SUCCESS;
}

void DeviceIoControl(WDFDEVICE device, WDFREQUEST req, size_t out_len, size_t in_len, ULONG code) {
    UNREFERENCED_PARAMETER(out_len);
    UNREFERENCED_PARAMETER(in_len);
    DeviceContext *dev = GetDeviceContext(device);
    NTSTATUS st = STATUS_SUCCESS;
    ULONG_PTR written = 0;

    AcquireSRWLockExclusive(&dev->lock);
    dev->last_ping_ms = GetTickCount64(); // any request counts as a ping
    const bool ready = dev->adapter_ready != 0;
    switch (code) {
    case MOONSEC_IDD_IOCTL_INFO: {
        moonsec_idd_info *o;
        st = Output(req, &o);
        if (!NT_SUCCESS(st)) break;
        *o = {};
        o->protocol = MOONSEC_IDD_PROTOCOL;
        o->max_monitors = MOONSEC_IDD_MAX_MONITORS;
        o->active_monitors = ActiveCount(dev);
        o->ping_timeout_ms = MOONSEC_IDD_PING_TIMEOUT_MS;
        o->adapter_ready = ready ? 1 : 0;
        written = sizeof(*o);
        break;
    }
    case MOONSEC_IDD_IOCTL_ADD: {
        moonsec_idd_add *i;
        moonsec_idd_monitor *o;
        if (!NT_SUCCESS(st = Input(req, &i)) || !NT_SUCCESS(st = Output(req, &o))) break;
        if (!ready) {
            st = STATUS_DEVICE_NOT_READY;
            break;
        }
        if (!ModeValid(i->mode)) {
            st = STATUS_INVALID_PARAMETER;
            break;
        }
        UINT slot = MOONSEC_IDD_MAX_MONITORS;
        for (UINT k = 0; k < MOONSEC_IDD_MAX_MONITORS; k++)
            if (!dev->slots[k].object) {
                slot = k;
                break;
            }
        if (slot == MOONSEC_IDD_MAX_MONITORS) {
            st = STATUS_TOO_MANY_NODES;
            break;
        }
        LUID luid;
        luid.LowPart = i->render_luid_low;
        luid.HighPart = i->render_luid_high;
        SetRenderAdapter(dev, luid);
        st = PlugIn(dev, slot, i->mode, o);
        if (NT_SUCCESS(st)) written = sizeof(*o);
        break;
    }
    case MOONSEC_IDD_IOCTL_REMOVE: {
        moonsec_idd_id *i;
        UINT slot;
        if (!NT_SUCCESS(st = Input(req, &i))) break;
        if (!SlotFromId(dev, i->id, &slot)) {
            st = STATUS_NOT_FOUND;
            break;
        }
        Unplug(dev, slot);
        break;
    }
    case MOONSEC_IDD_IOCTL_SET_MODE: {
        moonsec_idd_set_mode *i;
        moonsec_idd_monitor *o;
        UINT slot;
        if (!NT_SUCCESS(st = Input(req, &i)) || !NT_SUCCESS(st = Output(req, &o))) break;
        if (!SlotFromId(dev, i->id, &slot)) {
            st = STATUS_NOT_FOUND;
            break;
        }
        if (!ModeValid(i->mode)) {
            st = STATUS_INVALID_PARAMETER;
            break;
        }
        // Replug with the new preferred mode: the OS reads the mode list again.
        Unplug(dev, slot);
        st = PlugIn(dev, slot, i->mode, o);
        if (NT_SUCCESS(st)) written = sizeof(*o);
        break;
    }
    case MOONSEC_IDD_IOCTL_PING:
        break;
    case MOONSEC_IDD_IOCTL_REMOVE_ALL:
        UnplugAll(dev);
        break;
    default:
        st = STATUS_INVALID_DEVICE_REQUEST;
        break;
    }
    ReleaseSRWLockExclusive(&dev->lock);
    WdfRequestCompleteWithInformation(req, st, written);
}

void WatchdogTick(WDFTIMER timer) {
    DeviceContext *dev = GetDeviceContext((WDFDEVICE)WdfTimerGetParentObject(timer));
    AcquireSRWLockExclusive(&dev->lock);
    if (ActiveCount(dev) > 0 && GetTickCount64() - dev->last_ping_ms > MOONSEC_IDD_PING_TIMEOUT_MS) UnplugAll(dev);
    ReleaseSRWLockExclusive(&dev->lock);
}

NTSTATUS DeviceAdd(WDFDRIVER driver, PWDFDEVICE_INIT init) {
    UNREFERENCED_PARAMETER(driver);
    WDF_PNPPOWER_EVENT_CALLBACKS pnp;
    WDF_PNPPOWER_EVENT_CALLBACKS_INIT(&pnp);
    pnp.EvtDeviceD0Entry = DeviceD0Entry;
    WdfDeviceInitSetPnpPowerEventCallbacks(init, &pnp);

    IDD_CX_CLIENT_CONFIG cfg;
    IDD_CX_CLIENT_CONFIG_INIT(&cfg);
    cfg.EvtIddCxDeviceIoControl = DeviceIoControl;
    cfg.EvtIddCxAdapterInitFinished = AdapterInitFinished;
    cfg.EvtIddCxParseMonitorDescription = ParseMonitorDescription;
    cfg.EvtIddCxMonitorGetDefaultDescriptionModes = MonitorGetDefaultModes;
    cfg.EvtIddCxMonitorQueryTargetModes = MonitorQueryTargetModes;
    cfg.EvtIddCxAdapterCommitModes = AdapterCommitModes;
    cfg.EvtIddCxMonitorAssignSwapChain = MonitorAssignSwapChain;
    cfg.EvtIddCxMonitorUnassignSwapChain = MonitorUnassignSwapChain;
    NTSTATUS st = IddCxDeviceInitConfig(init, &cfg);
    if (!NT_SUCCESS(st)) return st;

    WDF_OBJECT_ATTRIBUTES attr;
    WDF_OBJECT_ATTRIBUTES_INIT_CONTEXT_TYPE(&attr, DeviceContext);
    WDFDEVICE device = nullptr;
    st = WdfDeviceCreate(&init, &attr, &device);
    if (!NT_SUCCESS(st)) return st;
    DeviceContext *dev = GetDeviceContext(device);
    dev->device = device;
    InitializeSRWLock(&dev->lock);
    dev->last_ping_ms = GetTickCount64();

    st = WdfDeviceCreateDeviceInterface(device, &kInterfaceGuid, nullptr);
    if (!NT_SUCCESS(st)) return st;

    WDF_TIMER_CONFIG tc;
    WDF_TIMER_CONFIG_INIT_PERIODIC(&tc, WatchdogTick, MOONSEC_IDD_PING_INTERVAL_MS);
    WDF_OBJECT_ATTRIBUTES ta;
    WDF_OBJECT_ATTRIBUTES_INIT(&ta);
    ta.ParentObject = device;
    st = WdfTimerCreate(&tc, &ta, &dev->watchdog);
    if (!NT_SUCCESS(st)) return st;
    WdfTimerStart(dev->watchdog, WDF_REL_TIMEOUT_IN_MS(MOONSEC_IDD_PING_INTERVAL_MS));

    return IddCxDeviceInitialize(device);
}

} // namespace

extern "C" DRIVER_INITIALIZE DriverEntry;

extern "C" NTSTATUS DriverEntry(PDRIVER_OBJECT driver_object, PUNICODE_STRING registry_path) {
    WDF_DRIVER_CONFIG cfg;
    WDF_DRIVER_CONFIG_INIT(&cfg, DeviceAdd);
    WDF_OBJECT_ATTRIBUTES attr;
    WDF_OBJECT_ATTRIBUTES_INIT(&attr);
    return WdfDriverCreate(driver_object, registry_path, &attr, &cfg, WDF_NO_HANDLE);
}
