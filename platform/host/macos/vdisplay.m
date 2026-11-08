// Virtual displays with CGVirtualDisplay, for a headless host (docs/design.md, Phase 5).
//
// CGVirtualDisplay is private CoreGraphics API (macOS 11+): the classes are looked up
// at run time with NSClassFromString, never linked, so a macOS that drops or renames
// them makes mh_vdisplay_available() return 0 and the host falls back to the physical
// display instead of failing to launch. Build with -Dmac-virtual-display=false to leave
// it out entirely (MH_NO_CGVIRTUALDISPLAY).
//
// Lifecycle: the display exists while the CGVirtualDisplay object is retained; the
// window server removes it when we release it or when this process exits, crash
// included. Creating one needs no TCC permission; capturing it needs Screen Recording,
// like any display.
//
// The declarations below are what the classes have answered to since macOS 11 (as used
// by Chromium's virtual display test utility and others). Tested macOS versions are
// listed in README.md; the design calls for re-testing on every macOS beta.
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#include <unistd.h>
#include "mh_internal.h"

#ifndef MH_NO_CGVIRTUALDISPLAY

@interface CGVirtualDisplayDescriptor : NSObject
@property(retain, nonatomic) dispatch_queue_t queue;
@property(retain, nonatomic) NSString *name;
@property(nonatomic) unsigned int maxPixelsHigh;
@property(nonatomic) unsigned int maxPixelsWide;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) unsigned int serialNum;
@property(nonatomic) unsigned int productID;
@property(nonatomic) unsigned int vendorID;
@property(copy, nonatomic) void (^terminationHandler)(id, id);
@end

@interface CGVirtualDisplayMode : NSObject
@property(readonly, nonatomic) double refreshRate;
@property(readonly, nonatomic) unsigned int height;
@property(readonly, nonatomic) unsigned int width;
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property(retain, nonatomic) NSArray *modes;
@property(nonatomic) unsigned int hiDPI;
@end

@interface CGVirtualDisplay : NSObject
@property(readonly, nonatomic) unsigned int displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

struct mh_vdisplay {
    void *display; // CGVirtualDisplay, retained (CFBridgingRetain)
    uint32_t id;
    uint32_t max_w, max_h;
};

static Class cls(NSString *name) { return NSClassFromString(name); }

int mh_vdisplay_available(void) {
    return cls(@"CGVirtualDisplay") && cls(@"CGVirtualDisplayDescriptor") && cls(@"CGVirtualDisplayMode") &&
                   cls(@"CGVirtualDisplaySettings")
               ? 1
               : 0;
}

static int apply_mode(CGVirtualDisplay *d, uint32_t w, uint32_t h, uint32_t hz) {
    CGVirtualDisplayMode *mode = [[cls(@"CGVirtualDisplayMode") alloc] initWithWidth:w height:h refreshRate:(double)hz];
    CGVirtualDisplaySettings *settings = [[cls(@"CGVirtualDisplaySettings") alloc] init];
    if (!mode || !settings) return mh_fail(MH_ERR_UNSUPPORTED, "CGVirtualDisplayMode/Settings unavailable");
    settings.hiDPI = 0; // pixels = points: the client asked for pixels
    settings.modes = @[ mode ];
    if (![d applySettings:settings]) return mh_fail(MH_ERR, "CGVirtualDisplay applySettings %ux%u@%u refused", w, h, hz);
    return MH_OK;
}

static int index_of(uint32_t id, uint32_t *index) {
    CGDirectDisplayID ids[32];
    uint32_t n = 0;
    if (CGGetActiveDisplayList(32, ids, &n) != kCGErrorSuccess) return mh_fail(MH_ERR, "CGGetActiveDisplayList failed");
    for (uint32_t i = 0; i < n; i++)
        if (ids[i] == id) {
            *index = i;
            return MH_OK;
        }
    return mh_fail(MH_ERR_UNSUPPORTED, "virtual display %u not active", id);
}

static int wait_mode(uint32_t id, uint32_t w, uint32_t h, uint32_t timeout_ms) {
    int64_t deadline = mh_now_us() + (int64_t)timeout_ms * 1000;
    for (;;) {
        uint32_t index;
        if (index_of(id, &index) == MH_OK && CGDisplayPixelsWide(id) == w && CGDisplayPixelsHigh(id) == h) return MH_OK;
        if (mh_now_us() >= deadline)
            return mh_fail(MH_ERR, "virtual display %u not active at %ux%u after %u ms (now %zux%zu)", id, w, h, timeout_ms,
                           CGDisplayPixelsWide(id), CGDisplayPixelsHigh(id));
        usleep(20000);
    }
}

int mh_vdisplay_create(uint32_t width, uint32_t height, uint32_t refresh_hz, uint32_t timeout_ms, mh_vdisplay **out) {
    @autoreleasepool {
        mh_clear_error();
        *out = NULL;
        if (!mh_vdisplay_available()) return mh_fail(MH_ERR_UNSUPPORTED, "CGVirtualDisplay is not available on this macOS");
        (void)CGMainDisplayID(); // window server connection

        CGVirtualDisplayDescriptor *desc = [[cls(@"CGVirtualDisplayDescriptor") alloc] init];
        desc.queue = dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0);
        desc.name = @"moonsec virtual display";
        desc.maxPixelsWide = width;
        desc.maxPixelsHigh = height;
        // A plausible physical size (~96 dpi) so the system picks a sane default scale.
        desc.sizeInMillimeters = CGSizeMake(width * 25.4 / 96.0, height * 25.4 / 96.0);
        desc.vendorID = 0x6d73; // "ms"
        desc.productID = 0x0001;
        desc.serialNum = (unsigned int)getpid();
        desc.terminationHandler = ^(id a, id b) {
          (void)a;
          (void)b;
        };
        CGVirtualDisplay *d = [[cls(@"CGVirtualDisplay") alloc] initWithDescriptor:desc];
        if (!d || d.displayID == 0) return mh_fail(MH_ERR, "CGVirtualDisplay initWithDescriptor failed");
        int rc = apply_mode(d, width, height, refresh_hz);
        if (rc != MH_OK) return rc;
        rc = wait_mode(d.displayID, width, height, timeout_ms);
        if (rc != MH_OK) return rc;

        mh_vdisplay *v = (mh_vdisplay *)calloc(1, sizeof *v);
        if (!v) return mh_fail(MH_ERR_NOMEM, "out of memory");
        v->id = d.displayID;
        v->max_w = width;
        v->max_h = height;
        v->display = (void *)CFBridgingRetain(d);
        *out = v;
        return MH_OK;
    }
}

int mh_vdisplay_set_mode(mh_vdisplay *v, uint32_t width, uint32_t height, uint32_t refresh_hz) {
    @autoreleasepool {
        mh_clear_error();
        if (width > v->max_w || height > v->max_h)
            return mh_fail(MH_ERR_UNSUPPORTED, "%ux%u is larger than the display was made for (%ux%u)", width, height,
                           v->max_w, v->max_h);
        int rc = apply_mode((__bridge CGVirtualDisplay *)v->display, width, height, refresh_hz);
        if (rc != MH_OK) return rc;
        return wait_mode(v->id, width, height, 3000);
    }
}

uint32_t mh_vdisplay_id(const mh_vdisplay *v) { return v->id; }

int mh_vdisplay_index(const mh_vdisplay *v, uint32_t *index) { return index_of(v->id, index); }

int mh_vdisplay_wait_shareable(const mh_vdisplay *v, uint32_t timeout_ms) {
    int64_t deadline = mh_now_us() + (int64_t)timeout_ms * 1000;
    for (;;) {
        @autoreleasepool {
            uint32_t index;
            int rc = index_of(v->id, &index);
            if (rc == MH_OK) {
                if (mh_sc_display(index, &rc)) return MH_OK;
                if (rc == MH_ERR_PERMISSION) return rc;
            }
            if (mh_now_us() >= deadline) return rc;
        }
        usleep(50000);
    }
}

void mh_vdisplay_destroy(mh_vdisplay *v) {
    if (!v) return;
    uint32_t id = v->id;
    if (v->display) CFRelease(v->display); // the window server removes the display
    free(v);
    // Wait briefly for it to leave the active list so the next count is right.
    for (int i = 0; i < 50; i++) {
        uint32_t index;
        if (index_of(id, &index) != MH_OK) break;
        usleep(20000);
    }
}

#else // MH_NO_CGVIRTUALDISPLAY

int mh_vdisplay_available(void) { return 0; }
int mh_vdisplay_create(uint32_t width, uint32_t height, uint32_t refresh_hz, uint32_t timeout_ms, mh_vdisplay **out) {
    *out = NULL;
    return mh_fail(MH_ERR_UNSUPPORTED, "built without CGVirtualDisplay (-Dmac-virtual-display=false)");
}
int mh_vdisplay_set_mode(mh_vdisplay *v, uint32_t width, uint32_t height, uint32_t refresh_hz) {
    return mh_fail(MH_ERR_UNSUPPORTED, "built without CGVirtualDisplay");
}
uint32_t mh_vdisplay_id(const mh_vdisplay *v) { return 0; }
int mh_vdisplay_index(const mh_vdisplay *v, uint32_t *index) { return mh_fail(MH_ERR_UNSUPPORTED, "no virtual display"); }
int mh_vdisplay_wait_shareable(const mh_vdisplay *v, uint32_t timeout_ms) {
    return mh_fail(MH_ERR_UNSUPPORTED, "no virtual display");
}
void mh_vdisplay_destroy(mh_vdisplay *v) {}

#endif

uint32_t mh_display_count(uint32_t exclude) {
    CGDirectDisplayID ids[32];
    uint32_t n = 0, count = 0;
    if (CGGetActiveDisplayList(32, ids, &n) != kCGErrorSuccess) return 0;
    for (uint32_t i = 0; i < n; i++)
        if (ids[i] != exclude) count++;
    return count;
}
