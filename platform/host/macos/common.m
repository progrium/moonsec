// Clock, errors, permissions, displays and pixel buffers for the macOS host backend.
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreVideo/CoreVideo.h>
#include <mach/mach_time.h>
#include <sys/sysctl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "mh_internal.h"

static mach_timebase_info_data_t g_tb;
static dispatch_once_t g_tb_once;

int64_t mh_ticks_to_us(uint64_t ticks) {
    dispatch_once(&g_tb_once, ^{ mach_timebase_info(&g_tb); });
    return (int64_t)((__uint128_t)ticks * g_tb.numer / g_tb.denom / 1000);
}

int64_t mh_now_us(void) { return mh_ticks_to_us(mach_absolute_time()); }

static _Thread_local char g_err[512];

int mh_fail(int code, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(g_err, sizeof g_err, fmt, ap);
    va_end(ap);
    return code;
}

void mh_clear_error(void) { g_err[0] = 0; }

const char *mh_last_error(void) { return g_err; }

int mh_is_vm(void) {
    int v = 0;
    size_t n = sizeof v;
    if (sysctlbyname("kern.hv_vmm_present", &v, &n, NULL, 0) != 0) return 0;
    return v ? 1 : 0;
}

int mh_screen_capture_allowed(void) { return CGPreflightScreenCaptureAccess() ? 1 : 0; }

int mh_post_event_allowed(void) { return CGPreflightPostEventAccess() ? 1 : 0; }

uint32_t mh_display_id(uint32_t index) {
    CGDirectDisplayID ids[32];
    uint32_t n = 0;
    if (CGGetActiveDisplayList(32, ids, &n) != kCGErrorSuccess || index >= n) return 0;
    return ids[index]; // the first entry is the main display
}

int mh_display_bounds(uint32_t index, double *x, double *y, double *w, double *h) {
    CGDirectDisplayID id = mh_display_id(index);
    if (!id) return mh_fail(MH_ERR_UNSUPPORTED, "no display %u", index);
    CGRect r = CGDisplayBounds(id);
    *x = r.origin.x;
    *y = r.origin.y;
    *w = r.size.width;
    *h = r.size.height;
    return MH_OK;
}

int mh_display_pixels(uint32_t index, uint32_t *w, uint32_t *h) {
    CGDirectDisplayID id = mh_display_id(index);
    if (!id) return mh_fail(MH_ERR_UNSUPPORTED, "no display %u", index);
    CGDisplayModeRef m = CGDisplayCopyDisplayMode(id);
    if (m) {
        *w = (uint32_t)CGDisplayModeGetPixelWidth(m);
        *h = (uint32_t)CGDisplayModeGetPixelHeight(m);
        CGDisplayModeRelease(m);
    } else {
        *w = (uint32_t)CGDisplayPixelsWide(id);
        *h = (uint32_t)CGDisplayPixelsHigh(id);
    }
    return (*w && *h) ? MH_OK : mh_fail(MH_ERR, "display %u has no size", index);
}

static void display_name(CGDirectDisplayID id, char *out, size_t len, double *max_fps) {
    out[0] = 0;
    *max_fps = 0;
    @autoreleasepool {
        for (NSScreen *s in [NSScreen screens]) {
            NSNumber *n = s.deviceDescription[@"NSScreenNumber"];
            if (!n || n.unsignedIntValue != id) continue;
            if (@available(macOS 10.15, *)) {
                NSString *name = s.localizedName;
                if (name.length) snprintf(out, len, "%s", name.UTF8String);
            }
            if (@available(macOS 12.0, *)) *max_fps = (double)s.maximumFramesPerSecond;
            break;
        }
    }
    if (!out[0]) {
        if (CGDisplayIsBuiltin(id)) snprintf(out, len, "Built-in Display");
        else snprintf(out, len, "Display %u", id);
    }
}

uint32_t mh_displays(mh_display_info *out, uint32_t cap) {
    CGDirectDisplayID ids[32];
    uint32_t n = 0;
    if (CGGetActiveDisplayList(32, ids, &n) != kCGErrorSuccess) return 0;
    for (uint32_t i = 0; i < n && i < cap; i++) {
        mh_display_info *d = &out[i];
        memset(d, 0, sizeof *d);
        d->index = i;
        d->id = ids[i];
        CGRect r = CGDisplayBounds(ids[i]);
        d->x = (int32_t)r.origin.x;
        d->y = (int32_t)r.origin.y;
        d->primary = CGDisplayIsMain(ids[i]) ? 1 : 0;
        double hz = 0;
        CGDisplayModeRef m = CGDisplayCopyDisplayMode(ids[i]);
        if (m) {
            d->width = (uint32_t)CGDisplayModeGetPixelWidth(m);
            d->height = (uint32_t)CGDisplayModeGetPixelHeight(m);
            hz = CGDisplayModeGetRefreshRate(m);
            CGDisplayModeRelease(m);
        }
        if (!d->width || !d->height) {
            d->width = (uint32_t)CGDisplayPixelsWide(ids[i]);
            d->height = (uint32_t)CGDisplayPixelsHigh(ids[i]);
        }
        double max_fps = 0;
        display_name(ids[i], d->name, sizeof d->name, &max_fps);
        /* Built-in panels report a mode rate of 0; NSScreen knows theirs. */
        if (hz <= 0) hz = max_fps;
        d->refresh_mhz = hz > 0 ? (uint32_t)(hz * 1000.0 + 0.5) : 0;
    }
    return n;
}

uint32_t mh_fmt_to_cv(uint32_t fmt) {
    return fmt == MH_FMT_NV12 ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange : kCVPixelFormatType_32BGRA;
}

uint32_t mh_cv_to_fmt(uint32_t cv) {
    switch (cv) {
    case kCVPixelFormatType_32BGRA: return MH_FMT_BGRA;
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
    case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: return MH_FMT_NV12;
    default: return 0;
    }
}

void *mh_pixel_buffer_create(uint32_t width, uint32_t height, uint32_t format) {
    NSDictionary *attrs = @{
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
    };
    CVPixelBufferRef pb = NULL;
    CVReturn r = CVPixelBufferCreate(NULL, width, height, mh_fmt_to_cv(format), (__bridge CFDictionaryRef)attrs, &pb);
    if (r != kCVReturnSuccess) {
        mh_fail(MH_ERR_NOMEM, "CVPixelBufferCreate %ux%u: %d", width, height, (int)r);
        return NULL;
    }
    return pb;
}

static uint32_t xorshift(uint32_t *s) {
    uint32_t x = *s;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    return *s = x;
}

int mh_pixel_buffer_fill(void *pixel_buffer, uint32_t frame, int noise) {
    CVPixelBufferRef pb = (CVPixelBufferRef)pixel_buffer;
    if (CVPixelBufferLockBaseAddress(pb, 0) != kCVReturnSuccess) return mh_fail(MH_ERR, "lock failed");
    uint32_t seed = 0x9E3779B9u ^ (frame * 2654435761u);
    size_t planes = CVPixelBufferIsPlanar(pb) ? CVPixelBufferGetPlaneCount(pb) : 1;
    for (size_t p = 0; p < planes; p++) {
        uint8_t *base;
        size_t stride, h, w;
        if (CVPixelBufferIsPlanar(pb)) {
            base = CVPixelBufferGetBaseAddressOfPlane(pb, p);
            stride = CVPixelBufferGetBytesPerRowOfPlane(pb, p);
            h = CVPixelBufferGetHeightOfPlane(pb, p);
            w = CVPixelBufferGetWidthOfPlane(pb, p) * (p ? 2 : 1);
        } else {
            base = CVPixelBufferGetBaseAddress(pb);
            stride = CVPixelBufferGetBytesPerRow(pb);
            h = CVPixelBufferGetHeight(pb);
            w = CVPixelBufferGetWidth(pb) * 4;
        }
        for (size_t y = 0; y < h; y++) {
            uint8_t *row = base + y * stride;
            if (noise) {
                for (size_t x = 0; x < w; x++) row[x] = (uint8_t)xorshift(&seed);
            } else {
                for (size_t x = 0; x < w; x++) row[x] = (uint8_t)(x + y * 2 + frame * 4 + (p ? 64 : 0));
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);
    return MH_OK;
}

void mh_pixel_buffer_size(void *pixel_buffer, uint32_t *width, uint32_t *height, uint32_t *format) {
    CVPixelBufferRef pb = (CVPixelBufferRef)pixel_buffer;
    *width = (uint32_t)CVPixelBufferGetWidth(pb);
    *height = (uint32_t)CVPixelBufferGetHeight(pb);
    *format = mh_cv_to_fmt(CVPixelBufferGetPixelFormatType(pb));
}

void mh_cf_release(void *cf) {
    if (cf) CFRelease((CFTypeRef)cf);
}

void *mh_cf_retain(void *cf) { return cf ? (void *)CFRetain((CFTypeRef)cf) : NULL; }
