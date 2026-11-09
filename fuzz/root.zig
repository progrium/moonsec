//! Fuzz harnesses for every parser that reads bytes from the network or a file
//! (docs/fuzzing.md lists them). Each `test` here is one harness; see fuzz/build.zig for
//! how to run them and tools/fuzz/run.sh for long runs.
const std = @import("std");

pub const proto = @import("proto.zig");
pub const media = @import("media.zig");
pub const audio = @import("audio.zig");
pub const recovery = @import("recovery.zig");
pub const control = @import("control.zig");
pub const pair = @import("pair.zig");
pub const video = @import("video.zig");

const common = @import("common.zig");

/// Every harness by name: the test name, the corpus directory under fuzz/corpus/, and
/// what `fuzz-repro` takes.
pub const harnesses = .{
    .{ "proto_datagram", proto.datagram },
    .{ "proto_varint", proto.varint },
    .{ "media_receiver", media.receiver },
    .{ "media_retransmit", media.retransmit },
    .{ "audio_messages", audio.messages },
    .{ "audio_receiver", audio.receiver },
    .{ "audio_opus_client", audio.opusClient },
    .{ "recovery_host", recovery.host },
    .{ "recovery_client", recovery.client },
    .{ "input_receiver", control.inputReceiver },
    .{ "input_round_trip", control.inputRoundTrip },
    .{ "clock_sync", control.clockSync },
    .{ "app_session", control.session },
    .{ "pair_ticket", pair.ticketText },
    .{ "pair_text", pair.text },
    .{ "pair_exchange_host", pair.exchangeHost },
    .{ "pair_exchange_client", pair.exchangeClient },
    .{ "video_passthrough_decoder", video.passthroughDecoder },
};

test {
    std.testing.refAllDecls(@This());
}
