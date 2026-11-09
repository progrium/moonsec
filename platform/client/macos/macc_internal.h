// Shared between the Objective-C files of the macOS client backend; not seen by Zig.
#ifndef MACC_INTERNAL_H
#define MACC_INTERNAL_H

#import <Foundation/Foundation.h>

#include "macc.h"

@class CAMetalLayer;

// Runs `block` on the main thread (directly when already there).
void macc_on_main(void (^block)(void));
// Seconds on the mach_absolute_time clock (NSEvent.timestamp, presentedTime) to ns.
uint64_t macc_seconds_to_ns(double s);
// The window view's layer, and whether its size changed since the last call.
CAMetalLayer *macc_window_layer(macc_window *win);
int macc_window_take_size_change(macc_window *win);
// MACC_MATRIX_* from a CVPixelBuffer's YCbCr matrix attachment (BT.709 when none).
uint32_t macc_matrix_of(void *pixel_buffer);

#endif
