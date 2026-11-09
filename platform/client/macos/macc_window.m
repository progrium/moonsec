// moonsec macOS client: window, CAMetalLayer-backed view and NSEvent input (macc.h).
//
// AppKit is main-thread only. Calls from other threads hop to the main queue with
// dispatch_sync, so an app that calls in from its present or input thread must keep
// the main thread in its run loop ([NSApp run]) or pumping (macc_pump_events).
// The event queue is filled on the main thread and drained from any thread under a
// lock; size readings are atomics the view updates when it resizes.

#import <AppKit/AppKit.h>
#import <QuartzCore/CAMetalLayer.h>
#include <mach/mach_time.h>
#include <os/lock.h>
#include <stdatomic.h>

#include "macc.h"
#include "macc_internal.h"

uint64_t macc_now_ns(void) {
    static mach_timebase_info_data_t tb;
    if (tb.denom == 0) mach_timebase_info(&tb);
    uint64_t t = mach_absolute_time();
    if (tb.numer == tb.denom) return t;
    return (uint64_t)((__uint128_t)t * tb.numer / tb.denom);
}

uint64_t macc_seconds_to_ns(double s) {
    // NSEvent.timestamp and CAMetalDrawable.presentedTime are seconds on the
    // mach_absolute_time clock (CACurrentMediaTime), so this is the same clock.
    return s <= 0 ? 0 : (uint64_t)(s * 1e9);
}

void macc_on_main(void (^block)(void)) {
    if ([NSThread isMainThread])
        block();
    else
        dispatch_sync(dispatch_get_main_queue(), block);
}

// ---------------------------------------------------------------------------
// Event queue

enum { QUEUE_CAP = 1024 };

@interface MaccView : NSView
@end

@interface MaccWindowObj : NSObject <NSWindowDelegate> {
  @public
    NSWindow *window;
    MaccView *view;
    CAMetalLayer *layer;
    os_unfair_lock lock;
    macc_event queue[QUEUE_CAP];
    size_t head, count;
    uint64_t dropped;
    _Atomic uint32_t width_px, height_px;
    _Atomic int open;
    _Atomic int size_changed;
}
- (void)push:(const macc_event *)ev;
@end

@implementation MaccWindowObj
- (void)push:(const macc_event *)ev {
    os_unfair_lock_lock(&lock);
    if (count == QUEUE_CAP) {
        head = (head + 1) % QUEUE_CAP;
        count--;
        dropped++;
    }
    queue[(head + count) % QUEUE_CAP] = *ev;
    count++;
    os_unfair_lock_unlock(&lock);
}

- (BOOL)windowShouldClose:(NSWindow *)sender {
    atomic_store(&open, 0);
    macc_event ev = {.kind = MACC_EV_QUIT, .time_ns = macc_now_ns()};
    [self push:&ev];
    return YES;
}
@end

@implementation MaccView {
  @public
    __weak MaccWindowObj *owner;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.wantsLayer = YES;
        self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawNever;
    }
    return self;
}

- (CALayer *)makeBackingLayer {
    CAMetalLayer *l = [CAMetalLayer layer];
    l.pixelFormat = MTLPixelFormatBGRA8Unorm;
    l.opaque = YES;
    return l;
}

- (BOOL)wantsUpdateLayer {
    return YES;
}
- (BOOL)acceptsFirstResponder {
    return YES;
}
- (BOOL)acceptsFirstMouse:(NSEvent *)event {
    return YES;
}

- (void)updateSize {
    MaccWindowObj *o = owner;
    if (!o) return;
    CGFloat scale = self.window ? self.window.backingScaleFactor : 1.0;
    NSSize s = self.bounds.size;
    uint32_t w = (uint32_t)(s.width * scale + 0.5), h = (uint32_t)(s.height * scale + 0.5);
    if (w == 0) w = 1;
    if (h == 0) h = 1;
    if (w != atomic_load(&o->width_px) || h != atomic_load(&o->height_px)) {
        atomic_store(&o->width_px, w);
        atomic_store(&o->height_px, h);
        atomic_store(&o->size_changed, 1);
    }
    ((CAMetalLayer *)self.layer).contentsScale = scale;
}

- (void)setFrameSize:(NSSize)size {
    [super setFrameSize:size];
    [self updateSize];
}
- (void)viewDidChangeBackingProperties {
    [super viewDidChangeBackingProperties];
    [self updateSize];
}

static void record(MaccView *v, NSEvent *e, uint32_t kind) {
    MaccWindowObj *o = v->owner;
    if (!o) return;
    macc_event ev = {0};
    ev.kind = kind;
    ev.time_ns = macc_seconds_to_ns(e.timestamp);
    if (ev.time_ns == 0) ev.time_ns = macc_now_ns();
    ev.modifier_flags = (uint64_t)e.modifierFlags;
    switch (kind) {
    case MACC_EV_KEY_DOWN:
    case MACC_EV_KEY_UP:
        ev.key_code = e.keyCode;
        ev.repeat = kind == MACC_EV_KEY_DOWN && e.isARepeat;
        break;
    case MACC_EV_FLAGS_CHANGED:
        ev.key_code = e.keyCode;
        break;
    case MACC_EV_MOUSE_DOWN:
    case MACC_EV_MOUSE_UP:
        ev.button = (uint16_t)e.buttonNumber;
        break;
    case MACC_EV_MOUSE_MOVE:
        ev.dx = e.deltaX;
        ev.dy = e.deltaY;
        break;
    case MACC_EV_SCROLL:
        ev.dx = e.scrollingDeltaX;
        ev.dy = e.scrollingDeltaY;
        ev.precise = e.hasPreciseScrollingDeltas;
        ev.inverted = e.isDirectionInvertedFromDevice;
        break;
    }
    [o push:&ev];
}

- (void)keyDown:(NSEvent *)e {
    record(self, e, MACC_EV_KEY_DOWN);
}
- (void)keyUp:(NSEvent *)e {
    record(self, e, MACC_EV_KEY_UP);
}
- (void)flagsChanged:(NSEvent *)e {
    record(self, e, MACC_EV_FLAGS_CHANGED);
}
// Command-key combinations come here first; take them all so none reach a menu.
- (BOOL)performKeyEquivalent:(NSEvent *)e {
    if (e.type == NSEventTypeKeyDown) record(self, e, MACC_EV_KEY_DOWN);
    return YES;
}
- (void)mouseDown:(NSEvent *)e {
    record(self, e, MACC_EV_MOUSE_DOWN);
}
- (void)mouseUp:(NSEvent *)e {
    record(self, e, MACC_EV_MOUSE_UP);
}
- (void)rightMouseDown:(NSEvent *)e {
    record(self, e, MACC_EV_MOUSE_DOWN);
}
- (void)rightMouseUp:(NSEvent *)e {
    record(self, e, MACC_EV_MOUSE_UP);
}
- (void)otherMouseDown:(NSEvent *)e {
    record(self, e, MACC_EV_MOUSE_DOWN);
}
- (void)otherMouseUp:(NSEvent *)e {
    record(self, e, MACC_EV_MOUSE_UP);
}
- (void)mouseMoved:(NSEvent *)e {
    record(self, e, MACC_EV_MOUSE_MOVE);
}
- (void)mouseDragged:(NSEvent *)e {
    record(self, e, MACC_EV_MOUSE_MOVE);
}
- (void)rightMouseDragged:(NSEvent *)e {
    record(self, e, MACC_EV_MOUSE_MOVE);
}
- (void)otherMouseDragged:(NSEvent *)e {
    record(self, e, MACC_EV_MOUSE_MOVE);
}
- (void)scrollWheel:(NSEvent *)e {
    record(self, e, MACC_EV_SCROLL);
}
@end

// ---------------------------------------------------------------------------
// C API

static MaccWindowObj *W(macc_window *w) {
    return (__bridge MaccWindowObj *)(void *)w;
}

static int ensure_app(void) {
    __block int ok = 1;
    macc_on_main(^{
      // Without a window server NSApplication can't connect; CGMainDisplayID is 0
      // (kCGNullDirectDisplay) in a session without one.
      if (CGMainDisplayID() == kCGNullDirectDisplay) {
          ok = 0;
          return;
      }
      NSApplication *app = [NSApplication sharedApplication];
      if (app.activationPolicy != NSApplicationActivationPolicyRegular) {
          [app setActivationPolicy:NSApplicationActivationPolicyRegular];
          [app finishLaunching];
      }
    });
    return ok;
}

macc_status macc_window_create(uint32_t w, uint32_t h, const char *title_utf8, uint32_t flags, macc_window **out) {
    *out = NULL;
    if (!ensure_app()) return MACC_E_NO_WINDOW;
    if (w == 0 || h == 0) {
        w = 1280;
        h = 720;
    }
    NSString *title = title_utf8 ? [NSString stringWithUTF8String:title_utf8] : @"moonsec";
    __block MaccWindowObj *o = nil;
    macc_on_main(^{
      o = [MaccWindowObj new];
      o->lock = OS_UNFAIR_LOCK_INIT;
      atomic_store(&o->open, 1);
      NSRect r = NSMakeRect(0, 0, w, h);
      NSWindowStyleMask style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable |
                                NSWindowStyleMaskResizable;
      NSWindow *win = [[NSWindow alloc] initWithContentRect:r
                                                  styleMask:style
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
      if (!win) {
          o = nil;
          return;
      }
      win.releasedWhenClosed = NO;
      win.title = title;
      win.delegate = o;
      win.acceptsMouseMovedEvents = YES;
      win.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
      MaccView *v = [[MaccView alloc] initWithFrame:r];
      v->owner = o;
      win.contentView = v;
      [win makeFirstResponder:v];
      o->window = win;
      o->view = v;
      o->layer = (CAMetalLayer *)v.layer;
      [v updateSize];
      if (flags & MACC_WINDOW_VISIBLE) {
          [win center];
          [win makeKeyAndOrderFront:nil];
          [NSApp activateIgnoringOtherApps:YES];
      }
    });
    if (!o) return MACC_E_NO_WINDOW;
    *out = (__bridge_retained macc_window *)o;
    return MACC_OK;
}

void macc_window_destroy(macc_window *win) {
    if (!win) return;
    MaccWindowObj *o = (__bridge_transfer MaccWindowObj *)(void *)win;
    macc_on_main(^{
      o->view->owner = nil;
      o->window.delegate = nil;
      [o->window orderOut:nil];
      [o->window close];
    });
    o = nil;
}

int macc_window_open(macc_window *win) {
    return atomic_load(&W(win)->open);
}

void macc_window_set_fullscreen(macc_window *win, int on) {
    MaccWindowObj *o = W(win);
    macc_on_main(^{
      BOOL is = (o->window.styleMask & NSWindowStyleMaskFullScreen) != 0;
      if ((on != 0) != is) [o->window toggleFullScreen:nil];
    });
}

void macc_window_set_mouse_captured(macc_window *win, int on) {
    (void)win;
    macc_on_main(^{
      CGAssociateMouseAndMouseCursorPosition(on ? false : true);
      if (on)
          [NSCursor hide];
      else
          [NSCursor unhide];
    });
}

size_t macc_window_poll(macc_window *win, macc_event *out, size_t max) {
    MaccWindowObj *o = W(win);
    macc_pump_events();
    os_unfair_lock_lock(&o->lock);
    size_t n = o->count < max ? o->count : max;
    for (size_t i = 0; i < n; i++) out[i] = o->queue[(o->head + i) % QUEUE_CAP];
    o->head = (o->head + n) % QUEUE_CAP;
    o->count -= n;
    os_unfair_lock_unlock(&o->lock);
    return n;
}

uint64_t macc_window_dropped(macc_window *win) {
    MaccWindowObj *o = W(win);
    os_unfair_lock_lock(&o->lock);
    uint64_t d = o->dropped;
    os_unfair_lock_unlock(&o->lock);
    return d;
}

void macc_window_size(macc_window *win, uint32_t *w, uint32_t *h) {
    MaccWindowObj *o = W(win);
    *w = atomic_load(&o->width_px);
    *h = atomic_load(&o->height_px);
}

void macc_pump_events(void) {
    if (![NSThread isMainThread] || NSApp == nil) return;
    @autoreleasepool {
        for (;;) {
            NSEvent *e = [NSApp nextEventMatchingMask:NSEventMaskAny
                                            untilDate:[NSDate distantPast]
                                               inMode:NSDefaultRunLoopMode
                                              dequeue:YES];
            if (!e) break;
            [NSApp sendEvent:e];
        }
    }
}

int macc_window_inject(macc_window *win, uint32_t kind, uint16_t key_code, uint64_t modifier_flags, double dx,
                       double dy) {
    MaccWindowObj *o = W(win);
    __block int queued = 0;
    macc_on_main(^{
      @autoreleasepool {
          CGEventRef cg = NULL;
          switch (kind) {
          case MACC_EV_KEY_DOWN:
          case MACC_EV_KEY_UP:
          case MACC_EV_FLAGS_CHANGED:
              cg = CGEventCreateKeyboardEvent(NULL, key_code, kind != MACC_EV_KEY_UP);
              if (cg) {
                  if (kind == MACC_EV_FLAGS_CHANGED) CGEventSetType(cg, kCGEventFlagsChanged);
                  CGEventSetFlags(cg, (CGEventFlags)modifier_flags);
              }
              break;
          case MACC_EV_MOUSE_MOVE:
              cg = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved, CGPointMake(10, 10), kCGMouseButtonLeft);
              if (cg) {
                  CGEventSetIntegerValueField(cg, kCGMouseEventDeltaX, (int64_t)dx);
                  CGEventSetIntegerValueField(cg, kCGMouseEventDeltaY, (int64_t)dy);
              }
              break;
          default:
              return;
          }
          if (!cg) return;
          NSEvent *e = [NSEvent eventWithCGEvent:cg];
          CFRelease(cg);
          if (!e) return;
          os_unfair_lock_lock(&o->lock);
          size_t before = o->count;
          os_unfair_lock_unlock(&o->lock);
          switch (kind) {
          case MACC_EV_KEY_DOWN:
              [o->view keyDown:e];
              break;
          case MACC_EV_KEY_UP:
              [o->view keyUp:e];
              break;
          case MACC_EV_FLAGS_CHANGED:
              [o->view flagsChanged:e];
              break;
          case MACC_EV_MOUSE_MOVE:
              [o->view mouseMoved:e];
              break;
          }
          os_unfair_lock_lock(&o->lock);
          queued = o->count > before;
          os_unfair_lock_unlock(&o->lock);
      }
    });
    return queued;
}

// ---------------------------------------------------------------------------
// For the presenter (macc_internal.h)

CAMetalLayer *macc_window_layer(macc_window *win) {
    return W(win)->layer;
}

int macc_window_take_size_change(macc_window *win) {
    return atomic_exchange(&W(win)->size_changed, 0);
}
