// GameController.framework snapshots for the macOS gamepad source
// (gamecontroller.zig). The Zig side declares the same struct and functions.
#pragma once
#include <stddef.h>
#include <stdint.h>

// One connected controller with an extended gamepad profile. `buttons` uses
// core.input.Gamepad.Button bits; axes are GameController's own floats
// (sticks -1..1, up positive; triggers 0..1).
typedef struct mgc_pad {
    uint64_t id;
    uint32_t buttons;
    float lx, ly, rx, ry;
    float lt, rt;
} mgc_pad;

// Lets the app read controllers while it is not frontmost (macOS 11.3+) and
// starts wireless discovery. Safe to call more than once.
void mgc_init(void);

// Copies up to `cap` connected controllers into `out`; returns how many.
size_t mgc_poll(mgc_pad *out, size_t cap);
