// Input injection with CGEvent (needs the Accessibility / "post events" permission).
//
// Keys arrive as macOS virtual key codes (host.zig maps HID usages). Modifier keys are
// posted as kCGEventFlagsChanged, and every event carries the modifier flags we hold,
// so a shifted click or key is seen as shifted by every app. Mouse buttons held turn
// motion into drag events, and repeated clicks in place within the double-click interval
// get an increasing click count. Relative motion sets the delta fields games read and
// moves the cursor, clamped to the displays.
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#include <math.h>
#include <stdlib.h>
#include "mh_internal.h"

struct mh_input {
    CGEventSourceRef src;
    uint32_t display;
    CGEventFlags flags;
    uint32_t buttons; // bit (b - 1) for button b
    // Click counting.
    uint32_t last_button;
    int64_t last_click_us;
    CGPoint last_click_at;
    int64_t click_count;
    // Scroll remainders (120 per notch).
    int32_t rem_x, rem_y;
};

int mh_input_create(mh_input **out) {
    struct mh_input *in = calloc(1, sizeof *in);
    if (!in) return mh_fail(MH_ERR_NOMEM, "out of memory");
    in->src = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    if (!in->src) {
        free(in);
        return mh_fail(MH_ERR, "CGEventSourceCreate failed");
    }
    *out = in;
    return MH_OK;
}

void mh_input_set_display(mh_input *in, uint32_t display) { in->display = display; }

void mh_input_cursor(double *x, double *y) {
    CGEventRef e = CGEventCreate(NULL);
    CGPoint p = e ? CGEventGetLocation(e) : CGPointZero;
    if (e) CFRelease(e);
    *x = p.x;
    *y = p.y;
}

static int post(CGEventRef e) {
    if (!e) return mh_fail(MH_ERR, "CGEvent creation failed");
    CGEventPost(kCGHIDEventTap, e);
    CFRelease(e);
    return MH_OK;
}

static CGEventFlags modifier_flag(uint16_t kc) {
    switch (kc) {
    case kVK_Shift:
    case kVK_RightShift: return kCGEventFlagMaskShift;
    case kVK_Control:
    case kVK_RightControl: return kCGEventFlagMaskControl;
    case kVK_Option:
    case kVK_RightOption: return kCGEventFlagMaskAlternate;
    case kVK_Command:
    case kVK_RightCommand: return kCGEventFlagMaskCommand;
    case kVK_CapsLock: return kCGEventFlagMaskAlphaShift;
    case kVK_Function: return kCGEventFlagMaskSecondaryFn;
    default: return 0;
    }
}

int mh_input_key(mh_input *in, uint16_t keycode, int down) {
    CGEventFlags mod = modifier_flag(keycode);
    if (mod) {
        if (keycode == kVK_CapsLock) {
            if (down) in->flags ^= mod; // caps lock toggles on press
        } else if (down) {
            in->flags |= mod;
        } else {
            in->flags &= ~mod;
        }
    }
    CGEventRef e = CGEventCreateKeyboardEvent(in->src, (CGKeyCode)keycode, down ? true : false);
    if (!e) return mh_fail(MH_ERR, "CGEventCreateKeyboardEvent failed");
    if (mod) CGEventSetType(e, kCGEventFlagsChanged);
    CGEventSetFlags(e, in->flags);
    return post(e);
}

static CGRect desktop_bounds(void) {
    CGDirectDisplayID ids[32];
    uint32_t n = 0;
    CGRect r = CGRectNull;
    if (CGGetActiveDisplayList(32, ids, &n) == kCGErrorSuccess)
        for (uint32_t i = 0; i < n; i++) r = CGRectUnion(r, CGDisplayBounds(ids[i]));
    return CGRectIsNull(r) ? CGDisplayBounds(CGMainDisplayID()) : r;
}

static CGPoint clamp_point(CGPoint p) {
    // Keep the point on some display: clamp to the union, then to the display under it.
    CGRect u = desktop_bounds();
    p.x = fmin(fmax(p.x, CGRectGetMinX(u)), CGRectGetMaxX(u) - 1);
    p.y = fmin(fmax(p.y, CGRectGetMinY(u)), CGRectGetMaxY(u) - 1);
    CGDirectDisplayID id;
    uint32_t n = 0;
    if (CGGetDisplaysWithPoint(p, 1, &id, &n) == kCGErrorSuccess && n > 0) return p;
    CGRect m = CGDisplayBounds(CGMainDisplayID());
    p.x = fmin(fmax(p.x, CGRectGetMinX(m)), CGRectGetMaxX(m) - 1);
    p.y = fmin(fmax(p.y, CGRectGetMinY(m)), CGRectGetMaxY(m) - 1);
    return p;
}

static void button_types(uint32_t button, CGEventType *down, CGEventType *up, CGEventType *drag, CGMouseButton *mb) {
    switch (button) {
    case 1:
        *down = kCGEventLeftMouseDown, *up = kCGEventLeftMouseUp, *drag = kCGEventLeftMouseDragged, *mb = kCGMouseButtonLeft;
        break;
    case 2:
        *down = kCGEventRightMouseDown, *up = kCGEventRightMouseUp, *drag = kCGEventRightMouseDragged, *mb = kCGMouseButtonRight;
        break;
    default:
        // Middle is button 2 in CG terms; back/forward are 3 and 4.
        *down = kCGEventOtherMouseDown, *up = kCGEventOtherMouseUp, *drag = kCGEventOtherMouseDragged;
        *mb = (CGMouseButton)(button == 3 ? kCGMouseButtonCenter : button - 1);
        break;
    }
}

// The event type for motion with the buttons held now.
static CGEventType move_type(const struct mh_input *in, CGMouseButton *mb) {
    CGEventType d, u, drag;
    for (uint32_t b = 1; b <= 5; b++)
        if (in->buttons & (1u << (b - 1))) {
            button_types(b, &d, &u, &drag, mb);
            return drag;
        }
    *mb = kCGMouseButtonLeft;
    return kCGEventMouseMoved;
}

static int post_move(mh_input *in, CGPoint to, int32_t dx, int32_t dy) {
    CGMouseButton mb;
    CGEventType t = move_type(in, &mb);
    CGEventRef e = CGEventCreateMouseEvent(in->src, t, to, mb);
    if (!e) return mh_fail(MH_ERR, "CGEventCreateMouseEvent failed");
    CGEventSetIntegerValueField(e, kCGMouseEventDeltaX, dx);
    CGEventSetIntegerValueField(e, kCGMouseEventDeltaY, dy);
    CGEventSetFlags(e, in->flags);
    return post(e);
}

int mh_input_button(mh_input *in, uint32_t button, int down) {
    if (button < 1 || button > 5) return mh_fail(MH_ERR_UNSUPPORTED, "button %u", button);
    double x, y;
    mh_input_cursor(&x, &y);
    CGPoint at = CGPointMake(x, y);
    CGEventType dt, ut, drag;
    CGMouseButton mb;
    button_types(button, &dt, &ut, &drag, &mb);
    if (down) {
        int64_t now = mh_now_us();
        int64_t interval = (int64_t)(NSEvent.doubleClickInterval * 1e6);
        if (button == in->last_button && now - in->last_click_us <= interval && fabs(at.x - in->last_click_at.x) < 4 &&
            fabs(at.y - in->last_click_at.y) < 4)
            in->click_count++;
        else
            in->click_count = 1;
        in->last_button = button;
        in->last_click_us = now;
        in->last_click_at = at;
        in->buttons |= 1u << (button - 1);
    } else {
        in->buttons &= ~(1u << (button - 1));
    }
    CGEventRef e = CGEventCreateMouseEvent(in->src, down ? dt : ut, at, mb);
    if (!e) return mh_fail(MH_ERR, "CGEventCreateMouseEvent failed");
    CGEventSetIntegerValueField(e, kCGMouseEventClickState, in->click_count ? in->click_count : 1);
    if (button > 2) CGEventSetIntegerValueField(e, kCGMouseEventButtonNumber, mb);
    CGEventSetFlags(e, in->flags);
    return post(e);
}

int mh_input_scroll(mh_input *in, int32_t dx, int32_t dy) {
    if (!dx && !dy) return MH_OK;
    // Whole lines for line-based apps, pixels (at about 10 px per notch's 120) for the rest.
    in->rem_x += dx;
    in->rem_y += dy;
    int32_t lx = in->rem_x / 120, ly = in->rem_y / 120;
    in->rem_x -= lx * 120;
    in->rem_y -= ly * 120;
    // CGEvent wheel 2 is positive to the left; ours is positive to the right.
    CGEventRef e = CGEventCreateScrollWheelEvent2(in->src, kCGScrollEventUnitPixel, 2, dy / 12, -dx / 12, 0);
    if (!e) return mh_fail(MH_ERR, "CGEventCreateScrollWheelEvent2 failed");
    CGEventSetIntegerValueField(e, kCGScrollWheelEventDeltaAxis1, ly);
    CGEventSetIntegerValueField(e, kCGScrollWheelEventDeltaAxis2, -lx);
    CGEventSetFlags(e, in->flags);
    return post(e);
}

int mh_input_move_rel(mh_input *in, int32_t dx, int32_t dy) {
    if (!dx && !dy) return MH_OK;
    double x, y;
    mh_input_cursor(&x, &y);
    return post_move(in, clamp_point(CGPointMake(x + dx, y + dy)), dx, dy);
}

int mh_input_move_abs(mh_input *in, uint16_t x, uint16_t y) {
    double bx, by, bw, bh;
    int rc = mh_display_bounds(in->display, &bx, &by, &bw, &bh);
    if (rc != MH_OK) return rc;
    CGPoint p = CGPointMake(bx + (double)x * (bw - 1) / 65535.0, by + (double)y * (bh - 1) / 65535.0);
    double cx, cy;
    mh_input_cursor(&cx, &cy);
    return post_move(in, p, (int32_t)lround(p.x - cx), (int32_t)lround(p.y - cy));
}

void mh_input_destroy(mh_input *in) {
    if (!in) return;
    if (in->src) CFRelease(in->src);
    free(in);
}
