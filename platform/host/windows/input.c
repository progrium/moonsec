/* Input injection with SendInput: keys by scan code (layout-independent), mouse buttons,
 * wheel, relative and absolute motion. */
#include "msw_internal.h"
#include "host_win.h"

/* USB HID keyboard usages 0x04..0xE7 to set-1 scan codes; 0x100 marks E0 extended keys. */
static const uint16_t kHidToScan[256] = {
    [0x04] = 0x1E, [0x05] = 0x30, [0x06] = 0x2E, [0x07] = 0x20, [0x08] = 0x12, [0x09] = 0x21, [0x0A] = 0x22,
    [0x0B] = 0x23, [0x0C] = 0x17, [0x0D] = 0x24, [0x0E] = 0x25, [0x0F] = 0x26, [0x10] = 0x32, [0x11] = 0x31,
    [0x12] = 0x18, [0x13] = 0x19, [0x14] = 0x10, [0x15] = 0x13, [0x16] = 0x1F, [0x17] = 0x14, [0x18] = 0x16,
    [0x19] = 0x2F, [0x1A] = 0x11, [0x1B] = 0x2D, [0x1C] = 0x15, [0x1D] = 0x2C, /* a..z */
    [0x1E] = 0x02, [0x1F] = 0x03, [0x20] = 0x04, [0x21] = 0x05, [0x22] = 0x06, [0x23] = 0x07, [0x24] = 0x08,
    [0x25] = 0x09, [0x26] = 0x0A, [0x27] = 0x0B, /* 1..0 */
    [0x28] = 0x1C, [0x29] = 0x01, [0x2A] = 0x0E, [0x2B] = 0x0F, [0x2C] = 0x39, /* enter esc bksp tab space */
    [0x2D] = 0x0C, [0x2E] = 0x0D, [0x2F] = 0x1A, [0x30] = 0x1B, [0x31] = 0x2B, [0x32] = 0x2B, [0x33] = 0x27,
    [0x34] = 0x28, [0x35] = 0x29, [0x36] = 0x33, [0x37] = 0x34, [0x38] = 0x35, [0x39] = 0x3A, /* - = [ ] \ # ; ' ` , . / caps */
    [0x3A] = 0x3B, [0x3B] = 0x3C, [0x3C] = 0x3D, [0x3D] = 0x3E, [0x3E] = 0x3F, [0x3F] = 0x40, [0x40] = 0x41,
    [0x41] = 0x42, [0x42] = 0x43, [0x43] = 0x44, [0x44] = 0x57, [0x45] = 0x58, /* F1..F12 */
    [0x46] = 0x137, [0x47] = 0x46, [0x48] = 0x45, /* print screen, scroll lock, pause (see below) */
    [0x49] = 0x152, [0x4A] = 0x147, [0x4B] = 0x149, [0x4C] = 0x153, [0x4D] = 0x14F, [0x4E] = 0x151,
    [0x4F] = 0x14D, [0x50] = 0x14B, [0x51] = 0x150, [0x52] = 0x148, /* ins home pgup del end pgdn right left down up */
    [0x53] = 0x45, [0x54] = 0x135, [0x55] = 0x37, [0x56] = 0x4A, [0x57] = 0x4E, [0x58] = 0x11C, /* numlock kp/ * - + enter */
    [0x59] = 0x4F, [0x5A] = 0x50, [0x5B] = 0x51, [0x5C] = 0x4B, [0x5D] = 0x4C, [0x5E] = 0x4D, [0x5F] = 0x47,
    [0x60] = 0x48, [0x61] = 0x49, [0x62] = 0x52, [0x63] = 0x53, /* kp1..kp9 kp0 kp. */
    [0x64] = 0x56, [0x65] = 0x15D, [0x67] = 0x59, /* non-US \, application, kp= */
    [0x68] = 0x64, [0x69] = 0x65, [0x6A] = 0x66, [0x6B] = 0x67, [0x6C] = 0x68, [0x6D] = 0x69, [0x6E] = 0x6A,
    [0x6F] = 0x6B, [0x70] = 0x6C, [0x71] = 0x6D, [0x72] = 0x6E, [0x73] = 0x76, /* F13..F24 */
    [0x85] = 0x7E, [0x87] = 0x73, [0x88] = 0x70, [0x89] = 0x7D, [0x8A] = 0x79, [0x8B] = 0x7B, /* intl */
    [0x90] = 0x72, [0x91] = 0x71, /* lang1/2 */
    [0xE0] = 0x1D, [0xE1] = 0x2A, [0xE2] = 0x38, [0xE3] = 0x15B, /* lctrl lshift lalt lgui */
    [0xE4] = 0x11D, [0xE5] = 0x36, [0xE6] = 0x138, [0xE7] = 0x15C, /* rctrl rshift ralt rgui */
};

uint32_t msw_hid_to_scancode(uint16_t usage) { return usage < 256 ? kHidToScan[usage] : 0; }

static HRESULT send(INPUT *in, UINT n) {
    UINT sent = SendInput(n, in, sizeof(INPUT));
    if (sent == n) return S_OK;
    DWORD e = GetLastError();
    return e ? HRESULT_FROM_WIN32(e) : E_ACCESSDENIED; /* UIPI blocks without an error code */
}

msw_hr msw_input_key(uint16_t hid_usage, uint32_t down) {
    INPUT in[2] = {0};
    if (hid_usage == 0x48) {
        /* Pause has no scan code of its own: inject it as a virtual key. */
        in[0].type = INPUT_KEYBOARD;
        in[0].ki.wVk = VK_PAUSE;
        in[0].ki.dwFlags = down ? 0 : KEYEVENTF_KEYUP;
        return send(in, 1);
    }
    uint32_t sc = msw_hid_to_scancode(hid_usage);
    if (!sc) return E_INVALIDARG;
    in[0].type = INPUT_KEYBOARD;
    in[0].ki.wScan = (WORD)(sc & 0xFF);
    in[0].ki.dwFlags = KEYEVENTF_SCANCODE | (down ? 0 : KEYEVENTF_KEYUP) | ((sc & 0x100) ? KEYEVENTF_EXTENDEDKEY : 0);
    return send(in, 1);
}

msw_hr msw_input_button(uint32_t button, uint32_t down) {
    INPUT in = {0};
    in.type = INPUT_MOUSE;
    switch (button) {
    case 1: in.mi.dwFlags = down ? MOUSEEVENTF_LEFTDOWN : MOUSEEVENTF_LEFTUP; break;
    case 2: in.mi.dwFlags = down ? MOUSEEVENTF_RIGHTDOWN : MOUSEEVENTF_RIGHTUP; break;
    case 3: in.mi.dwFlags = down ? MOUSEEVENTF_MIDDLEDOWN : MOUSEEVENTF_MIDDLEUP; break;
    case 4:
    case 5:
        in.mi.dwFlags = down ? MOUSEEVENTF_XDOWN : MOUSEEVENTF_XUP;
        in.mi.mouseData = button == 4 ? XBUTTON1 : XBUTTON2;
        break;
    default: return E_INVALIDARG;
    }
    return send(&in, 1);
}

msw_hr msw_input_scroll(int32_t dx, int32_t dy) {
    INPUT in[2] = {0};
    UINT n = 0;
    if (dy) {
        in[n].type = INPUT_MOUSE;
        in[n].mi.dwFlags = MOUSEEVENTF_WHEEL;
        in[n].mi.mouseData = (DWORD)dy;
        n++;
    }
    if (dx) {
        in[n].type = INPUT_MOUSE;
        in[n].mi.dwFlags = MOUSEEVENTF_HWHEEL;
        in[n].mi.mouseData = (DWORD)dx;
        n++;
    }
    return n ? send(in, n) : S_OK;
}

msw_hr msw_input_move_rel(int32_t dx, int32_t dy) {
    if (!dx && !dy) return S_OK;
    INPUT in = {0};
    in.type = INPUT_MOUSE;
    in.mi.dx = dx;
    in.mi.dy = dy;
    /* Relative motion goes through pointer acceleration; games reading raw input see the
     * raw delta either way. */
    in.mi.dwFlags = MOUSEEVENTF_MOVE;
    return send(&in, 1);
}

void msw_input_primary_rect(int32_t *left, int32_t *top, int32_t *width, int32_t *height) {
    *left = 0;
    *top = 0;
    *width = GetSystemMetrics(SM_CXSCREEN);
    *height = GetSystemMetrics(SM_CYSCREEN);
}

msw_hr msw_input_move_abs(uint16_t x, uint16_t y, int32_t left, int32_t top, int32_t width, int32_t height) {
    if (width <= 0 || height <= 0) return E_INVALIDARG;
    /* Display pixel, then normalized 0..65535 over the virtual desktop. */
    const int32_t px = left + (int32_t)(((int64_t)x * (width - 1) + 32767) / 65535);
    const int32_t py = top + (int32_t)(((int64_t)y * (height - 1) + 32767) / 65535);
    const int32_t vx = GetSystemMetrics(SM_XVIRTUALSCREEN), vy = GetSystemMetrics(SM_YVIRTUALSCREEN);
    const int32_t vw = GetSystemMetrics(SM_CXVIRTUALSCREEN), vh = GetSystemMetrics(SM_CYVIRTUALSCREEN);
    if (vw <= 1 || vh <= 1) return E_UNEXPECTED;
    INPUT in = {0};
    in.type = INPUT_MOUSE;
    in.mi.dx = (LONG)(((int64_t)(px - vx) * 65535 + (vw - 1) / 2) / (vw - 1));
    in.mi.dy = (LONG)(((int64_t)(py - vy) * 65535 + (vh - 1) / 2) / (vh - 1));
    in.mi.dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK;
    return send(&in, 1);
}
