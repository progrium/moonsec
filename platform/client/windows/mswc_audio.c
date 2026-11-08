/* WASAPI shared-mode output, polled (the audio thread writes what fits, never waits). */
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#include "msw_internal.h"
#include "mswc.h"

#include <initguid.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <mmreg.h>
#include <ks.h>
#include <ksmedia.h>
#include <string.h>

struct mswc_audio {
    IAudioClient *client;
    IAudioRenderClient *render;
    UINT32 buffer_frames;
    UINT32 channels;
    REFERENCE_TIME period;
    int low_latency;
};

static int is_float(const WAVEFORMATEX *f) {
    if (f->wFormatTag == WAVE_FORMAT_IEEE_FLOAT) return f->wBitsPerSample == 32;
    if (f->wFormatTag == WAVE_FORMAT_EXTENSIBLE && f->cbSize >= 22) {
        const WAVEFORMATEXTENSIBLE *x = (const WAVEFORMATEXTENSIBLE *)f;
        return IsEqualGUID(&x->SubFormat, &KSDATAFORMAT_SUBTYPE_IEEE_FLOAT) && f->wBitsPerSample == 32;
    }
    return 0;
}

msw_hr mswc_audio_open(uint32_t rate, uint32_t channels, mswc_audio **out) {
    *out = NULL;
    if (channels == 0 || channels > 8 || rate == 0) return E_INVALIDARG;
    mswc_audio *a = (mswc_audio *)calloc(1, sizeof *a);
    if (!a) return E_OUTOFMEMORY;
    a->channels = channels;
    HRESULT hr;
    IMMDeviceEnumerator *en = NULL;
    IMMDevice *dev = NULL;
    IAudioClient3 *c3 = NULL;
    WAVEFORMATEX *mix = NULL;

    MSW_TRY(CoCreateInstance(&CLSID_MMDeviceEnumerator, NULL, CLSCTX_ALL, &IID_IMMDeviceEnumerator, (void **)&en),
            fail);
    MSW_TRY(IMMDeviceEnumerator_GetDefaultAudioEndpoint(en, eRender, eConsole, &dev), fail);

    if (SUCCEEDED(IMMDevice_Activate(dev, &IID_IAudioClient3, CLSCTX_ALL, NULL, (void **)&c3))) {
        if (SUCCEEDED(IAudioClient3_GetMixFormat(c3, &mix)) && is_float(mix) && mix->nSamplesPerSec == rate &&
            mix->nChannels == channels) {
            UINT32 def = 0, fund = 0, min = 0, max = 0;
            if (SUCCEEDED(IAudioClient3_GetSharedModeEnginePeriod(c3, mix, &def, &fund, &min, &max)) && min > 0 &&
                SUCCEEDED(IAudioClient3_InitializeSharedAudioStream(c3, 0, min, mix, NULL))) {
                a->low_latency = 1;
                a->period = (REFERENCE_TIME)min * 10000000 / rate;
                a->client = (IAudioClient *)c3;
                c3 = NULL;
            }
        }
        MSW_RELEASE(c3);
    }
    if (!a->client) {
        MSW_TRY(IMMDevice_Activate(dev, &IID_IAudioClient, CLSCTX_ALL, NULL, (void **)&a->client), fail);
        WAVEFORMATEXTENSIBLE f;
        memset(&f, 0, sizeof f);
        f.Format.wFormatTag = WAVE_FORMAT_EXTENSIBLE;
        f.Format.nChannels = (WORD)channels;
        f.Format.nSamplesPerSec = rate;
        f.Format.wBitsPerSample = 32;
        f.Format.nBlockAlign = (WORD)(channels * 4);
        f.Format.nAvgBytesPerSec = rate * channels * 4;
        f.Format.cbSize = sizeof f - sizeof f.Format;
        f.Samples.wValidBitsPerSample = 32;
        f.dwChannelMask = channels == 1 ? SPEAKER_FRONT_CENTER
                          : channels == 2 ? (SPEAKER_FRONT_LEFT | SPEAKER_FRONT_RIGHT)
                                          : 0;
        f.SubFormat = KSDATAFORMAT_SUBTYPE_IEEE_FLOAT;
        a->period = 200000; /* 20 ms buffer */
        MSW_TRY(IAudioClient_Initialize(a->client, AUDCLNT_SHAREMODE_SHARED,
                                        AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
                                        a->period, 0, (WAVEFORMATEX *)&f, NULL),
                fail);
    }
    MSW_TRY(IAudioClient_GetBufferSize(a->client, &a->buffer_frames), fail);
    MSW_TRY(IAudioClient_GetService(a->client, &IID_IAudioRenderClient, (void **)&a->render), fail);
    MSW_TRY(IAudioClient_Start(a->client), fail);

    if (mix) CoTaskMemFree(mix);
    MSW_RELEASE(dev);
    MSW_RELEASE(en);
    *out = a;
    return S_OK;
fail:
    if (mix) CoTaskMemFree(mix);
    MSW_RELEASE(c3);
    MSW_RELEASE(dev);
    MSW_RELEASE(en);
    mswc_audio_close(a);
    return hr;
}

void mswc_audio_close(mswc_audio *a) {
    if (!a) return;
    if (a->client) IAudioClient_Stop(a->client);
    MSW_RELEASE(a->render);
    MSW_RELEASE(a->client);
    free(a);
}

msw_hr mswc_audio_queued(mswc_audio *a, uint32_t *frames) {
    UINT32 pad = 0;
    HRESULT hr = IAudioClient_GetCurrentPadding(a->client, &pad);
    *frames = SUCCEEDED(hr) ? pad : 0;
    return hr;
}

msw_hr mswc_audio_write(mswc_audio *a, const float *pcm, uint32_t frames, uint32_t *written) {
    *written = 0;
    UINT32 pad = 0;
    HRESULT hr = IAudioClient_GetCurrentPadding(a->client, &pad);
    if (FAILED(hr)) return hr;
    UINT32 room = a->buffer_frames > pad ? a->buffer_frames - pad : 0;
    UINT32 n = frames < room ? frames : room;
    if (n == 0) return S_OK;
    BYTE *dst = NULL;
    hr = IAudioRenderClient_GetBuffer(a->render, n, &dst);
    if (FAILED(hr)) return hr;
    memcpy(dst, pcm, (size_t)n * a->channels * sizeof(float));
    hr = IAudioRenderClient_ReleaseBuffer(a->render, n, 0);
    if (FAILED(hr)) return hr;
    *written = n;
    return S_OK;
}

void mswc_audio_info(const mswc_audio *a, uint32_t *buffer_frames, int64_t *period_hns, int *low_latency) {
    *buffer_frames = a->buffer_frames;
    *period_hns = a->period;
    *low_latency = a->low_latency;
}
