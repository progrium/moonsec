// GameController.framework capture for the macOS client (gamecontroller.zig).
//
// GCController.controllers is kept up to date by the framework on the main
// run loop, which the macOS client app runs (NSApplication). Element values
// can be read from any thread, so mgc_poll is called from the input thread.

#import <Foundation/Foundation.h>
#import <GameController/GameController.h>

#include "gc.h"

// core.input.Gamepad.Button
enum {
    B_DPAD_UP = 0x0001,
    B_DPAD_DOWN = 0x0002,
    B_DPAD_LEFT = 0x0004,
    B_DPAD_RIGHT = 0x0008,
    B_START = 0x0010,
    B_BACK = 0x0020,
    B_LTHUMB = 0x0040,
    B_RTHUMB = 0x0080,
    B_LSHOULDER = 0x0100,
    B_RSHOULDER = 0x0200,
    B_GUIDE = 0x0400,
    B_A = 0x1000,
    B_B = 0x2000,
    B_X = 0x4000,
    B_Y = 0x8000,
};

static uint32_t bit(GCControllerButtonInput *b, uint32_t mask) {
    return (b != nil && b.pressed) ? mask : 0;
}

void mgc_init(void) {
    @autoreleasepool {
        if (@available(macOS 11.3, *)) {
            GCController.shouldMonitorBackgroundEvents = YES;
        }
    }
}

size_t mgc_poll(mgc_pad *out, size_t cap) {
    size_t n = 0;
    @autoreleasepool {
        for (GCController *c in GCController.controllers) {
            if (n >= cap) break;
            GCExtendedGamepad *g = c.extendedGamepad;
            if (g == nil) continue;
            uint32_t b = 0;
            b |= bit(g.buttonA, B_A);
            b |= bit(g.buttonB, B_B);
            b |= bit(g.buttonX, B_X);
            b |= bit(g.buttonY, B_Y);
            b |= bit(g.leftShoulder, B_LSHOULDER);
            b |= bit(g.rightShoulder, B_RSHOULDER);
            b |= bit(g.dpad.up, B_DPAD_UP);
            b |= bit(g.dpad.down, B_DPAD_DOWN);
            b |= bit(g.dpad.left, B_DPAD_LEFT);
            b |= bit(g.dpad.right, B_DPAD_RIGHT);
            b |= bit(g.leftThumbstickButton, B_LTHUMB);
            b |= bit(g.rightThumbstickButton, B_RTHUMB);
            b |= bit(g.buttonMenu, B_START);
            b |= bit(g.buttonOptions, B_BACK);
            if (@available(macOS 11.0, *)) {
                b |= bit(g.buttonHome, B_GUIDE);
            }
            mgc_pad *p = &out[n++];
            p->id = (uint64_t)(uintptr_t)(__bridge void *)c;
            p->buttons = b;
            p->lx = g.leftThumbstick.xAxis.value;
            p->ly = g.leftThumbstick.yAxis.value;
            p->rx = g.rightThumbstick.xAxis.value;
            p->ry = g.rightThumbstick.yAxis.value;
            p->lt = g.leftTrigger.value;
            p->rt = g.rightTrigger.value;
        }
    }
    return n;
}
