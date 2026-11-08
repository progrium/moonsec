/* WASAPI loopback capture of the default render endpoint, shared mode, event driven.
 * The engine converts to 48 kHz float with the requested channel count
 * (AUTOCONVERTPCM), so the Opus stage always gets the format it wants. */
#include <initguid.h>
#include "msw_internal.h"
#include "host_win.h"

#include <audioclient.h>
#include <mmdeviceapi.h>
#include <string.h>

#ifndef AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM
#define AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM 0x80000000
#endif
#ifndef AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY
#define AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY 0x08000000
#endif

/* KSDATAFORMAT_SUBTYPE_IEEE_FLOAT */
DEFINE_GUID(kSubtypeFloat, 0x00000003, 0x0000, 0x0010, 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71);

struct msw_loopback {
    IMMDevice *device;
    IAudioClient *client;
    IAudioCaptureClient *capture;
    HANDLE event;
    uint32_t channels;
    int started;
    /* Leftover of a packet that did not fit the caller's buffer. */
    float *pending;
    uint32_t pending_frames, pending_off, pending_cap;
    uint64_t pending_time_ns;
};

void msw_loopback_destroy(msw_loopback *l) {
    if (!l) return;
    if (l->started && l->client) IAudioClient_Stop(l->client);
    MSW_RELEASE(l->capture);
    MSW_RELEASE(l->client);
    MSW_RELEASE(l->device);
    if (l->event) CloseHandle(l->event);
    free(l->pending);
    free(l);
}

msw_hr msw_loopback_create(uint32_t channels, msw_loopback **out) {
    *out = NULL;
    if (channels == 0 || channels > 8) return E_INVALIDARG;
    msw_loopback *l = (msw_loopback *)calloc(1, sizeof *l);
    if (!l) return E_OUTOFMEMORY;
    l->channels = channels;
    HRESULT hr;
    IMMDeviceEnumerator *en = NULL;
    MSW_TRY(CoCreateInstance(&CLSID_MMDeviceEnumerator, NULL, CLSCTX_ALL, &IID_IMMDeviceEnumerator, (void **)&en), fail);
    hr = IMMDeviceEnumerator_GetDefaultAudioEndpoint(en, eRender, eConsole, &l->device);
    if (hr == HRESULT_FROM_WIN32(ERROR_NOT_FOUND) || hr == E_NOTFOUND) hr = MSW_E_NOTFOUND;
    if (FAILED(hr)) goto fail;
    MSW_TRY(IMMDevice_Activate(l->device, &IID_IAudioClient, CLSCTX_ALL, NULL, (void **)&l->client), fail);

    WAVEFORMATEXTENSIBLE wf = {0};
    wf.Format.wFormatTag = WAVE_FORMAT_EXTENSIBLE;
    wf.Format.nChannels = (WORD)channels;
    wf.Format.nSamplesPerSec = 48000;
    wf.Format.wBitsPerSample = 32;
    wf.Format.nBlockAlign = (WORD)(4 * channels);
    wf.Format.nAvgBytesPerSec = 48000 * wf.Format.nBlockAlign;
    wf.Format.cbSize = sizeof wf - sizeof wf.Format;
    wf.Samples.wValidBitsPerSample = 32;
    wf.dwChannelMask = channels == 1 ? SPEAKER_FRONT_CENTER : channels == 2 ? (SPEAKER_FRONT_LEFT | SPEAKER_FRONT_RIGHT) : 0;
    wf.SubFormat = kSubtypeFloat;

    /* 20 ms engine buffer; event-driven loopback needs Windows 10 1703 or later. */
    const REFERENCE_TIME buffer = 20 * 10000;
    MSW_TRY(IAudioClient_Initialize(l->client, AUDCLNT_SHAREMODE_SHARED,
                                    AUDCLNT_STREAMFLAGS_LOOPBACK | AUDCLNT_STREAMFLAGS_EVENTCALLBACK |
                                        AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
                                    buffer, 0, (WAVEFORMATEX *)&wf, NULL),
            fail);
    l->event = CreateEventW(NULL, FALSE, FALSE, NULL);
    if (!l->event) {
        hr = HRESULT_FROM_WIN32(GetLastError());
        goto fail;
    }
    MSW_TRY(IAudioClient_SetEventHandle(l->client, l->event), fail);
    MSW_TRY(IAudioClient_GetService(l->client, &IID_IAudioCaptureClient, (void **)&l->capture), fail);
    MSW_RELEASE(en);
    *out = l;
    return S_OK;
fail:
    MSW_RELEASE(en);
    msw_loopback_destroy(l);
    return hr;
}

msw_hr msw_loopback_start(msw_loopback *l) {
    if (l->started) return S_OK;
    HRESULT hr = IAudioClient_Start(l->client);
    if (SUCCEEDED(hr)) l->started = 1;
    return hr;
}

void msw_loopback_stop(msw_loopback *l) {
    if (l->started) IAudioClient_Stop(l->client);
    l->started = 0;
    l->pending_frames = l->pending_off = 0;
}

static uint64_t qpc100_to_ns(UINT64 t) { return t * 100; }

/* Copies out of the pending leftover. */
static uint32_t take_pending(msw_loopback *l, float *out, uint32_t max_frames, uint64_t *time_ns) {
    uint32_t n = l->pending_frames - l->pending_off;
    if (n > max_frames) n = max_frames;
    memcpy(out, l->pending + (size_t)l->pending_off * l->channels, (size_t)n * l->channels * sizeof(float));
    *time_ns = l->pending_time_ns + (uint64_t)l->pending_off * 1000000000ull / 48000;
    l->pending_off += n;
    if (l->pending_off == l->pending_frames) l->pending_frames = l->pending_off = 0;
    return n;
}

msw_hr msw_loopback_read(msw_loopback *l, float *out, uint32_t max_frames, uint32_t timeout_ms, uint32_t *frames,
                         uint64_t *time_ns) {
    *frames = 0;
    *time_ns = 0;
    if (!l->started) return E_UNEXPECTED;
    if (l->pending_frames) {
        *frames = take_pending(l, out, max_frames, time_ns);
        return S_OK;
    }
    const ULONGLONG deadline = GetTickCount64() + timeout_ms;
    for (;;) {
        UINT32 packet = 0;
        HRESULT hr = IAudioCaptureClient_GetNextPacketSize(l->capture, &packet);
        if (FAILED(hr)) return hr;
        if (packet == 0) {
            ULONGLONG now = GetTickCount64();
            if (now >= deadline) return S_OK;
            DWORD w = WaitForSingleObject(l->event, (DWORD)(deadline - now));
            if (w == WAIT_TIMEOUT) return S_OK;
            continue;
        }
        BYTE *data = NULL;
        UINT32 n = 0;
        DWORD flags = 0;
        UINT64 qpc = 0;
        hr = IAudioCaptureClient_GetBuffer(l->capture, &data, &n, &flags, NULL, &qpc);
        if (hr == AUDCLNT_S_BUFFER_EMPTY) continue;
        if (FAILED(hr)) return hr;
        const size_t ch = l->channels;
        const int silent = (flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0;
        uint32_t direct = n < max_frames ? n : max_frames;
        if (silent) memset(out, 0, (size_t)direct * ch * sizeof(float));
        else memcpy(out, data, (size_t)direct * ch * sizeof(float));
        *frames = direct;
        *time_ns = qpc100_to_ns(qpc);
        if (direct < n) {
            uint32_t rest = n - direct;
            if (rest > l->pending_cap) {
                float *p = (float *)realloc(l->pending, (size_t)rest * ch * sizeof(float));
                if (!p) {
                    IAudioCaptureClient_ReleaseBuffer(l->capture, n);
                    return E_OUTOFMEMORY;
                }
                l->pending = p;
                l->pending_cap = rest;
            }
            if (silent) memset(l->pending, 0, (size_t)rest * ch * sizeof(float));
            else memcpy(l->pending, data + (size_t)direct * ch * sizeof(float), (size_t)rest * ch * sizeof(float));
            l->pending_frames = rest;
            l->pending_off = 0;
            l->pending_time_ns = *time_ns + (uint64_t)direct * 1000000000ull / 48000;
        }
        IAudioCaptureClient_ReleaseBuffer(l->capture, n);
        return S_OK;
    }
}
