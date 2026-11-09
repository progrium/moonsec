// The header compiles as C++17 (extern "C", no C-only constructs), and every function
// has its frozen 1.0 signature: a change to a parameter or return type fails to compile.
// Keep it complete: abi/header_test.zig fails when a function is missing here.
#include <moonsec.h>

#include <cstdio>
#include <type_traits>

#define SIG(name, ret, args) \
    static_assert(std::is_same<decltype(&name), ret(*) args>::value, #name " changed signature")

SIG(moonsec_version, uint32_t, (void));
SIG(moonsec_version_string, const char*, (void));
SIG(moonsec_features, uint32_t, (void));
SIG(moonsec_status_string, const char*, (moonsec_status));
SIG(moonsec_last_error, moonsec_status, (char*, size_t, size_t*));
SIG(moonsec_host_create, moonsec_status, (const moonsec_host_config*, moonsec_host**));
SIG(moonsec_host_destroy, void, (moonsec_host*));
SIG(moonsec_host_id, moonsec_status, (moonsec_host*, char*, size_t, size_t*));
SIG(moonsec_host_listen, moonsec_status, (moonsec_host*));
SIG(moonsec_host_ticket, moonsec_status, (moonsec_host*, char*, size_t, size_t*));
SIG(moonsec_host_pair_begin, moonsec_status, (moonsec_host*, const moonsec_pair_config*, moonsec_pair_info*));
SIG(moonsec_host_pair_end, moonsec_status, (moonsec_host*));
SIG(moonsec_host_set_permissions, moonsec_status, (moonsec_host*, const char*, uint32_t));
SIG(moonsec_host_listen_loopback, moonsec_status, (moonsec_host*, moonsec_loopback*, moonsec_session**));
SIG(moonsec_host_give_input, moonsec_status, (moonsec_host*, moonsec_session*));
SIG(moonsec_host_displays, moonsec_status, (moonsec_host*, moonsec_display_info*, size_t, size_t*));
SIG(moonsec_client_create, moonsec_status, (const moonsec_client_config*, moonsec_client**));
SIG(moonsec_client_destroy, void, (moonsec_client*));
SIG(moonsec_client_id, moonsec_status, (moonsec_client*, char*, size_t, size_t*));
SIG(moonsec_client_connect, moonsec_status, (moonsec_client*, const char*, uint32_t, moonsec_session**));
SIG(moonsec_client_pair, moonsec_status, (moonsec_client*, const char*, const char*));
SIG(moonsec_client_connect_loopback, moonsec_status, (moonsec_client*, moonsec_loopback*, moonsec_session**));
SIG(moonsec_session_state, int32_t, (moonsec_session*));
SIG(moonsec_session_close, moonsec_status, (moonsec_session*));
SIG(moonsec_session_release, void, (moonsec_session*));
SIG(moonsec_session_send_input, moonsec_status, (moonsec_session*, const moonsec_input*));
SIG(moonsec_session_request_input, moonsec_status, (moonsec_session*));
SIG(moonsec_session_clipboard_set, moonsec_status, (moonsec_session*, const char*, size_t));
SIG(moonsec_session_clipboard_get, moonsec_status, (moonsec_session*, char*, size_t, size_t*));
SIG(moonsec_session_format, moonsec_status, (moonsec_session*, moonsec_video_format*, uint32_t*, uint32_t*));
SIG(moonsec_session_telemetry, moonsec_status, (moonsec_session*, moonsec_telemetry*));
SIG(moonsec_host_poll_event, int32_t, (moonsec_host*, moonsec_event*, uint32_t));
SIG(moonsec_client_poll_event, int32_t, (moonsec_client*, moonsec_event*, uint32_t));
SIG(moonsec_loopback_create, moonsec_status, (const moonsec_loopback_config*, moonsec_loopback**));
SIG(moonsec_loopback_destroy, void, (moonsec_loopback*));
SIG(moonsec_loopback_advance, moonsec_status, (moonsec_loopback*, int64_t));
SIG(moonsec_loopback_now, int64_t, (moonsec_loopback*));

static_assert(sizeof(moonsec_video_format) == 16, "moonsec_video_format is frozen");
static_assert(sizeof(moonsec_input) == 48, "moonsec_input is frozen");
static_assert(sizeof(moonsec_stage_stats) == 56, "moonsec_stage_stats is frozen");
static_assert(std::is_trivially_copyable<moonsec_event>::value, "events are plain data");

int main() {
    // Linked against the library: the C++ caller can call it.
    moonsec_host_config cfg{};
    cfg.struct_size = sizeof cfg;
    cfg.state_dir = "";
    moonsec_host *h = nullptr;
    if (moonsec_host_create(&cfg, &h) != MOONSEC_OK || moonsec_version() != MOONSEC_ABI_VERSION) {
        std::fprintf(stderr, "abi include check: the library does not work from C++\n");
        return 1;
    }
    moonsec_host_destroy(h);
    std::printf("abi include check: ok (%s)\n", moonsec_version_string());
    return 0;
}
