/* moonsec virtual display driver: the control interface shared by the driver
 * (driver/Driver.cpp, built with the WDK) and the host (platform/host/windows/vdisp.c,
 * built with zig cc). Plain C, fixed-size little-endian fields, no Windows headers.
 *
 * The host opens the device interface below with CreateFile and sends these
 * METHOD_BUFFERED IOCTLs with DeviceIoControl. Every display it adds stays only while
 * the host keeps sending MOONSEC_IDD_IOCTL_PING: after MOONSEC_IDD_PING_TIMEOUT_MS
 * without one the driver removes all displays, so a host that crashed leaves none behind.
 */
#ifndef MOONSEC_IDD_H
#define MOONSEC_IDD_H

#include <stdint.h>

/* Bump on any incompatible change; MOONSEC_IDD_IOCTL_INFO reports the driver's. */
#define MOONSEC_IDD_PROTOCOL 1

/* Device interface class: {da61943f-aa3c-47cd-9d52-a0d72cc5ffe1} */
#define MOONSEC_IDD_INTERFACE_GUID_INIT \
    { 0xda61943f, 0xaa3c, 0x47cd, { 0x9d, 0x52, 0xa0, 0xd7, 0x2c, 0xc5, 0xff, 0xe1 } }

/* The hardware ID the INF matches. The host creates a software device with it
 * (SwDeviceCreate, enumerator "MoonsecIdd"), or an installer creates a root device
 * (devcon install MoonsecIdd.inf Root\MoonsecIdd). Both are listed in the INF. */
#define MOONSEC_IDD_SW_ENUMERATOR L"MoonsecIdd"
#define MOONSEC_IDD_HWID L"MoonsecIdd"
#define MOONSEC_IDD_ROOT_HWID L"Root\\MoonsecIdd"

#define MOONSEC_IDD_MAX_MONITORS 4
#define MOONSEC_IDD_PING_TIMEOUT_MS 3000
/* The host pings at this interval. */
#define MOONSEC_IDD_PING_INTERVAL_MS 500

/* CTL_CODE(FILE_DEVICE_UNKNOWN, 0x900 + n, METHOD_BUFFERED, FILE_ANY_ACCESS) */
#define MOONSEC_IDD_CTL(n) ((uint32_t)((0x22u << 16) | ((0x900u + (n)) << 2)))

/* out: moonsec_idd_info */
#define MOONSEC_IDD_IOCTL_INFO MOONSEC_IDD_CTL(0)
/* in: moonsec_idd_add; out: moonsec_idd_monitor. Plugs in a display. */
#define MOONSEC_IDD_IOCTL_ADD MOONSEC_IDD_CTL(1)
/* in: moonsec_idd_id. Unplugs one display. */
#define MOONSEC_IDD_IOCTL_REMOVE MOONSEC_IDD_CTL(2)
/* in: moonsec_idd_set_mode; out: moonsec_idd_monitor. Replugs the display with the new
 * mode as its preferred one (the OS sees a new monitor mode list). */
#define MOONSEC_IDD_IOCTL_SET_MODE MOONSEC_IDD_CTL(3)
/* No buffers. Keeps the displays alive. */
#define MOONSEC_IDD_IOCTL_PING MOONSEC_IDD_CTL(4)
/* No buffers. Unplugs every display. */
#define MOONSEC_IDD_IOCTL_REMOVE_ALL MOONSEC_IDD_CTL(5)

typedef struct moonsec_idd_info {
    uint32_t protocol;
    uint32_t max_monitors;
    uint32_t active_monitors;
    uint32_t ping_timeout_ms;
    /* 1 once IddCx finished initializing the adapter; ADD fails before that. */
    uint32_t adapter_ready;
    uint32_t reserved[3];
} moonsec_idd_info;

typedef struct moonsec_idd_mode {
    uint32_t width, height, refresh_hz;
} moonsec_idd_mode;

typedef struct moonsec_idd_add {
    moonsec_idd_mode mode;
    /* Preferred render adapter (the host's encoder GPU), so Desktop Duplication and the
     * encoder share it. 0/0 = let the OS pick. */
    uint32_t render_luid_low;
    int32_t render_luid_high;
    uint32_t reserved[2];
} moonsec_idd_add;

typedef struct moonsec_idd_id {
    uint32_t id;
} moonsec_idd_id;

typedef struct moonsec_idd_set_mode {
    uint32_t id;
    moonsec_idd_mode mode;
} moonsec_idd_set_mode;

typedef struct moonsec_idd_monitor {
    /* Driver slot, 1..MOONSEC_IDD_MAX_MONITORS. */
    uint32_t id;
    /* What IddCxMonitorArrival reported: the display path's adapter LUID and target ID
     * (QueryDisplayConfig's targetInfo.adapterId and targetInfo.id). */
    uint32_t adapter_luid_low;
    int32_t adapter_luid_high;
    uint32_t target_id;
    moonsec_idd_mode mode;
} moonsec_idd_monitor;

#endif
