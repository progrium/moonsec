/* Client window and Raw Input.
 *
 * The window lives on its own thread, which does nothing but pump messages, so it
 * stays responsive and Raw Input keeps flowing whatever the decode and present threads
 * are doing. The swapchain is created on that HWND from the present thread, which DXGI
 * allows. Raw Input records go into a ring under an SRW lock; any one thread polls it. */
#include "msw_internal.h"
#include "mswc.h"

#include <string.h>

#define RAW_CAP 1024

#define WM_APP_DESTROY (WM_APP + 1)
#define WM_APP_FULLSCREEN (WM_APP + 2)

struct mswc_window {
    HWND hwnd;
    volatile LONG closed;
    volatile LONG w, h;
    uint32_t flags;
    uint32_t init_w, init_h;
    WCHAR title[256];
    HANDLE thread;
    HANDLE ready;
    HRESULT create_hr;
    /* Windowed placement to return to from fullscreen. */
    WINDOWPLACEMENT placement;
    int fullscreen;

    SRWLOCK lock;
    mswc_raw ring[RAW_CAP];
    size_t head, len;
    uint64_t dropped;
};

static const WCHAR kClass[] = L"moonsec-client";

static void push(mswc_window *win, const mswc_raw *r) {
    AcquireSRWLockExclusive(&win->lock);
    if (win->len == RAW_CAP) {
        win->head = (win->head + 1) % RAW_CAP;
        win->len--;
        win->dropped++;
    }
    win->ring[(win->head + win->len) % RAW_CAP] = *r;
    win->len++;
    ReleaseSRWLockExclusive(&win->lock);
}

static void push_quit(mswc_window *win) {
    if (InterlockedExchange(&win->closed, 1)) return;
    mswc_raw r;
    memset(&r, 0, sizeof r);
    r.kind = MSWC_RAW_QUIT;
    r.time_ns = msw_qpc_ns();
    push(win, &r);
}

static void set_fullscreen(mswc_window *win, int on) {
    HWND hwnd = win->hwnd;
    if (on == win->fullscreen) return;
    if (on) {
        MONITORINFO mi;
        memset(&mi, 0, sizeof mi);
        mi.cbSize = sizeof mi;
        win->placement.length = sizeof win->placement;
        if (!GetWindowPlacement(hwnd, &win->placement) ||
            !GetMonitorInfoW(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST), &mi))
            return;
        /* Borderless fullscreen: with a flip-model swapchain covering the monitor the
         * compositor flips our buffers directly, which is what tearing needs. */
        SetWindowLongPtrW(hwnd, GWL_STYLE, WS_POPUP | WS_VISIBLE);
        SetWindowPos(hwnd, HWND_TOP, mi.rcMonitor.left, mi.rcMonitor.top, mi.rcMonitor.right - mi.rcMonitor.left,
                     mi.rcMonitor.bottom - mi.rcMonitor.top, SWP_FRAMECHANGED | SWP_NOOWNERZORDER);
    } else {
        SetWindowLongPtrW(hwnd, GWL_STYLE, WS_OVERLAPPEDWINDOW | WS_VISIBLE);
        SetWindowPlacement(hwnd, &win->placement);
        SetWindowPos(hwnd, NULL, 0, 0, 0, 0,
                     SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
    }
    win->fullscreen = on;
}

static void on_input(mswc_window *win, HRAWINPUT h) {
    /* RAWINPUT is at most a few dozen bytes for keyboards and mice; HID devices are
     * not registered. Align for the 64-bit header. */
    union {
        RAWINPUT ri;
        BYTE bytes[sizeof(RAWINPUT) + 64];
    } buf;
    UINT size = sizeof buf;
    if (GetRawInputData(h, RID_INPUT, &buf, &size, sizeof(RAWINPUTHEADER)) == (UINT)-1) return;
    mswc_raw r;
    memset(&r, 0, sizeof r);
    r.time_ns = msw_qpc_ns();
    if (buf.ri.header.dwType == RIM_TYPEKEYBOARD) {
        r.kind = MSWC_RAW_KEYBOARD;
        r.kb_make_code = buf.ri.data.keyboard.MakeCode;
        r.kb_flags = buf.ri.data.keyboard.Flags;
    } else if (buf.ri.header.dwType == RIM_TYPEMOUSE) {
        r.kind = MSWC_RAW_MOUSE;
        r.mouse_flags = buf.ri.data.mouse.usFlags;
        r.mouse_button_flags = buf.ri.data.mouse.usButtonFlags;
        r.mouse_button_data = buf.ri.data.mouse.usButtonData;
        r.mouse_last_x = buf.ri.data.mouse.lLastX;
        r.mouse_last_y = buf.ri.data.mouse.lLastY;
    } else {
        return;
    }
    push(win, &r);
}

static LRESULT CALLBACK wndproc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    mswc_window *win = (mswc_window *)GetWindowLongPtrW(hwnd, GWLP_USERDATA);
    switch (msg) {
    case WM_NCCREATE: {
        CREATESTRUCTW *cs = (CREATESTRUCTW *)lp;
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, (LONG_PTR)cs->lpCreateParams);
        break;
    }
    case WM_INPUT:
        if (win) on_input(win, (HRAWINPUT)lp);
        /* DefWindowProc does the cleanup for RIM_INPUT. */
        break;
    case WM_SIZE:
        if (win && wp != SIZE_MINIMIZED) {
            InterlockedExchange(&win->w, LOWORD(lp));
            InterlockedExchange(&win->h, HIWORD(lp));
        }
        return 0;
    case WM_CLOSE:
        if (win) push_quit(win);
        return 0; /* the owner destroys the window */
    case WM_APP_FULLSCREEN:
        if (win) set_fullscreen(win, (int)wp);
        return 0;
    case WM_APP_DESTROY:
        DestroyWindow(hwnd);
        return 0;
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    case WM_ERASEBKGND:
        return 1; /* the swapchain covers it */
    case WM_SYSKEYDOWN:
    case WM_SYSKEYUP:
    case WM_SYSCHAR:
        /* Alt combinations belong to the remote; keep Alt+F4 local. */
        if (msg == WM_SYSKEYDOWN && wp == VK_F4) break;
        return 0;
    default:
        break;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

static ATOM register_class(void) {
    static ATOM atom;
    if (atom) return atom;
    WNDCLASSEXW wc;
    memset(&wc, 0, sizeof wc);
    wc.cbSize = sizeof wc;
    wc.style = CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc = wndproc;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.hCursor = LoadCursorW(NULL, (LPCWSTR)IDC_ARROW);
    wc.lpszClassName = kClass;
    atom = RegisterClassExW(&wc);
    return atom;
}

static HRESULT create_on_thread(mswc_window *win) {
    if (!register_class()) return HRESULT_FROM_WIN32(GetLastError());
    DWORD style = WS_OVERLAPPEDWINDOW;
    RECT rc = {0, 0, (LONG)win->init_w, (LONG)win->init_h};
    AdjustWindowRect(&rc, style, FALSE);
    win->hwnd = CreateWindowExW(0, kClass, win->title, style, CW_USEDEFAULT, CW_USEDEFAULT, rc.right - rc.left,
                                rc.bottom - rc.top, NULL, NULL, GetModuleHandleW(NULL), win);
    if (!win->hwnd) return HRESULT_FROM_WIN32(GetLastError());
    RECT cr;
    if (GetClientRect(win->hwnd, &cr)) {
        win->w = cr.right - cr.left;
        win->h = cr.bottom - cr.top;
    }
    if (win->flags & MSWC_WINDOW_RAW_INPUT) {
        RAWINPUTDEVICE rid[2];
        DWORD f = (win->flags & MSWC_WINDOW_INPUT_SINK) ? RIDEV_INPUTSINK : 0;
        rid[0].usUsagePage = 0x01; /* generic desktop */
        rid[0].usUsage = 0x06;     /* keyboard */
        rid[0].dwFlags = f;
        rid[0].hwndTarget = win->hwnd;
        rid[1].usUsagePage = 0x01;
        rid[1].usUsage = 0x02; /* mouse */
        rid[1].dwFlags = f;
        rid[1].hwndTarget = win->hwnd;
        if (!RegisterRawInputDevices(rid, 2, sizeof rid[0])) {
            HRESULT hr = HRESULT_FROM_WIN32(GetLastError());
            DestroyWindow(win->hwnd);
            win->hwnd = NULL;
            return hr;
        }
    }
    if (win->flags & MSWC_WINDOW_VISIBLE) {
        ShowWindow(win->hwnd, SW_SHOW);
        UpdateWindow(win->hwnd);
    }
    return S_OK;
}

static DWORD WINAPI window_thread(LPVOID arg) {
    mswc_window *win = (mswc_window *)arg;
    /* Input before rendering: this thread only moves messages. */
    SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_ABOVE_NORMAL);
    win->create_hr = create_on_thread(win);
    SetEvent(win->ready);
    if (FAILED(win->create_hr)) return 1;
    MSG msg;
    while (GetMessageW(&msg, NULL, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    if (win->flags & MSWC_WINDOW_RAW_INPUT) {
        RAWINPUTDEVICE rid[2];
        rid[0].usUsagePage = 0x01;
        rid[0].usUsage = 0x06;
        rid[0].dwFlags = RIDEV_REMOVE;
        rid[0].hwndTarget = NULL;
        rid[1] = rid[0];
        rid[1].usUsage = 0x02;
        RegisterRawInputDevices(rid, 2, sizeof rid[0]);
    }
    push_quit(win);
    return 0;
}

msw_hr mswc_window_create(uint32_t w, uint32_t h, const char *title_utf8, uint32_t flags, mswc_window **out) {
    *out = NULL;
    mswc_window *win = (mswc_window *)calloc(1, sizeof *win);
    if (!win) return E_OUTOFMEMORY;
    InitializeSRWLock(&win->lock);
    win->flags = flags;
    win->init_w = w ? w : 1280;
    win->init_h = h ? h : 720;
    if (!title_utf8 || MultiByteToWideChar(CP_UTF8, 0, title_utf8, -1, win->title, 256) <= 0) win->title[0] = 0;
    win->title[255] = 0;
    win->ready = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (!win->ready) {
        free(win);
        return HRESULT_FROM_WIN32(GetLastError());
    }
    win->thread = CreateThread(NULL, 0, window_thread, win, 0, NULL);
    if (!win->thread) {
        HRESULT hr = HRESULT_FROM_WIN32(GetLastError());
        CloseHandle(win->ready);
        free(win);
        return hr;
    }
    WaitForSingleObject(win->ready, INFINITE);
    if (FAILED(win->create_hr)) {
        HRESULT hr = win->create_hr;
        WaitForSingleObject(win->thread, INFINITE);
        CloseHandle(win->thread);
        CloseHandle(win->ready);
        free(win);
        return hr;
    }
    *out = win;
    return S_OK;
}

void mswc_window_destroy(mswc_window *win) {
    if (!win) return;
    PostMessageW(win->hwnd, WM_APP_DESTROY, 0, 0);
    WaitForSingleObject(win->thread, INFINITE);
    CloseHandle(win->thread);
    CloseHandle(win->ready);
    free(win);
}

int mswc_window_open(const mswc_window *win) { return !win->closed; }

void mswc_window_set_fullscreen(mswc_window *win, int on) {
    SendMessageW(win->hwnd, WM_APP_FULLSCREEN, (WPARAM)(on != 0), 0);
}

size_t mswc_window_poll_raw(mswc_window *win, mswc_raw *out, size_t max) {
    AcquireSRWLockExclusive(&win->lock);
    size_t n = win->len < max ? win->len : max;
    for (size_t i = 0; i < n; i++) out[i] = win->ring[(win->head + i) % RAW_CAP];
    win->head = (win->head + n) % RAW_CAP;
    win->len -= n;
    ReleaseSRWLockExclusive(&win->lock);
    return n;
}

uint64_t mswc_window_raw_dropped(mswc_window *win) {
    AcquireSRWLockShared(&win->lock);
    uint64_t d = win->dropped;
    ReleaseSRWLockShared(&win->lock);
    return d;
}

void mswc_window_size(const mswc_window *win, uint32_t *w, uint32_t *h) {
    *w = (uint32_t)win->w;
    *h = (uint32_t)win->h;
}

void *mswc_window_hwnd(const mswc_window *win) { return win->hwnd; }

uint32_t mswc_send_key(uint16_t scan_code, int extended, int up) {
    INPUT in;
    memset(&in, 0, sizeof in);
    in.type = INPUT_KEYBOARD;
    in.ki.wScan = scan_code;
    in.ki.dwFlags = KEYEVENTF_SCANCODE | (extended ? KEYEVENTF_EXTENDEDKEY : 0) | (up ? KEYEVENTF_KEYUP : 0);
    return SendInput(1, &in, sizeof in);
}
