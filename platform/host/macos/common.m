// Clock, errors, permissions, displays and pixel buffers for the macOS host backend.
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreVideo/CoreVideo.h>
#include <mach/mach_time.h>
#include <sys/sysctl.h>
#include <math.h>
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

int mh_window_frame(uint32_t id, double *x, double *y, double *w, double *h, double *scale) {
    CGRect r = CGRectNull;
    CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow, (CGWindowID)id);
    if (list) {
        if (CFArrayGetCount(list) > 0) {
            CFDictionaryRef info = (CFDictionaryRef)CFArrayGetValueAtIndex(list, 0);
            CFDictionaryRef bounds = (CFDictionaryRef)CFDictionaryGetValue(info, kCGWindowBounds);
            if (bounds && !CGRectMakeWithDictionaryRepresentation(bounds, &r)) r = CGRectNull;
        }
        CFRelease(list);
    }
    if (CGRectIsNull(r) || r.size.width <= 0 || r.size.height <= 0) return mh_fail(MH_ERR_DEVICE_LOST, "window %u is gone", id);
    *x = r.origin.x;
    *y = r.origin.y;
    *w = r.size.width;
    *h = r.size.height;
    if (scale) {
        // The display under the window's centre (else the main one): its mode's pixels
        // per point.
        CGDirectDisplayID did = CGMainDisplayID();
        uint32_t n = 0;
        CGDirectDisplayID under;
        if (CGGetDisplaysWithPoint(CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r)), 1, &under, &n) == kCGErrorSuccess && n > 0) did = under;
        double s = 1;
        CGDisplayModeRef m = CGDisplayCopyDisplayMode(did);
        CGRect b = CGDisplayBounds(did);
        if (m) {
            if (b.size.width > 0) s = (double)CGDisplayModeGetPixelWidth(m) / b.size.width;
            CGDisplayModeRelease(m);
        }
        *scale = s >= 1 ? s : 1;
    }
    return MH_OK;
}

int mh_window_pixels(uint32_t id, uint32_t *w, uint32_t *h) {
    double x, y, pw, ph, s;
    int rc = mh_window_frame(id, &x, &y, &pw, &ph, &s);
    if (rc != MH_OK) return rc;
    *w = (uint32_t)lround(pw * s) & ~1u;
    *h = (uint32_t)lround(ph * s) & ~1u;
    if (*w < 2) *w = 2;
    if (*h < 2) *h = 2;
    return MH_OK;
}

// The window's owner and frame from the window server.
static int window_owner(uint32_t id, pid_t *pid, CGRect *r) {
    *pid = 0;
    *r = CGRectNull;
    CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow, (CGWindowID)id);
    if (list) {
        if (CFArrayGetCount(list) > 0) {
            CFDictionaryRef info = (CFDictionaryRef)CFArrayGetValueAtIndex(list, 0);
            CFNumberRef owner = (CFNumberRef)CFDictionaryGetValue(info, kCGWindowOwnerPID);
            int p = 0;
            if (owner && CFNumberGetValue(owner, kCFNumberIntType, &p)) *pid = (pid_t)p;
            CFDictionaryRef bounds = (CFDictionaryRef)CFDictionaryGetValue(info, kCGWindowBounds);
            if (bounds && !CGRectMakeWithDictionaryRepresentation(bounds, r)) *r = CGRectNull;
        }
        CFRelease(list);
    }
    return *pid > 0 ? MH_OK : mh_fail(MH_ERR_DEVICE_LOST, "window %u is gone", id);
}

// Raises the AX window of `app` whose frame is `r` (the window server's and AX's frames
// are both points, top-left origin) and makes it main. 1 when one matched.
static int ax_raise(AXUIElementRef app, CGRect r) {
    CFArrayRef wins = NULL;
    if (AXUIElementCopyAttributeValue(app, kAXWindowsAttribute, (CFTypeRef *)&wins) != kAXErrorSuccess || !wins) return 0;
    int raised = 0;
    for (CFIndex i = 0; i < CFArrayGetCount(wins) && !raised; i++) {
        AXUIElementRef w = (AXUIElementRef)CFArrayGetValueAtIndex(wins, i);
        CFTypeRef pos = NULL, size = NULL;
        CGPoint p = CGPointZero;
        CGSize s = CGSizeZero;
        int have = AXUIElementCopyAttributeValue(w, kAXPositionAttribute, &pos) == kAXErrorSuccess && pos &&
                   AXValueGetValue((AXValueRef)pos, (AXValueType)kAXValueCGPointType, &p);
        have = have && AXUIElementCopyAttributeValue(w, kAXSizeAttribute, &size) == kAXErrorSuccess && size &&
               AXValueGetValue((AXValueRef)size, (AXValueType)kAXValueCGSizeType, &s);
        if (pos) CFRelease(pos);
        if (size) CFRelease(size);
        if (!have || fabs(p.x - r.origin.x) > 2 || fabs(p.y - r.origin.y) > 2 || fabs(s.width - r.size.width) > 2 ||
            fabs(s.height - r.size.height) > 2)
            continue;
        AXUIElementSetAttributeValue(w, kAXMainAttribute, kCFBooleanTrue);
        raised = AXUIElementPerformAction(w, kAXRaiseAction) == kAXErrorSuccess;
    }
    CFRelease(wins);
    return raised;
}

int mh_window_focus(uint32_t id) {
    @autoreleasepool {
        pid_t pid;
        CGRect r;
        int rc = window_owner(id, &pid, &r);
        if (rc != MH_OK) return rc;
        int front = 0, raised = 0;
        if (AXIsProcessTrusted()) {
            AXUIElementRef app = AXUIElementCreateApplication(pid);
            if (app) {
                front = AXUIElementSetAttributeValue(app, kAXFrontmostAttribute, kCFBooleanTrue) == kAXErrorSuccess;
                if (!CGRectIsNull(r)) raised = ax_raise(app, r);
                CFRelease(app);
            }
        }
        if (!front) {
            // Without Accessibility: ask AppKit (macOS 14 may decline for a background caller).
            NSRunningApplication *a = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
            front = a && [a activateWithOptions:NSApplicationActivateIgnoringOtherApps];
        }
        if (!front && !raised) return mh_fail(MH_ERR, "window %u (pid %d) could not be brought to the front", id, (int)pid);
        return MH_OK;
    }
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
