# moonsec multi-user sessions v0

Status: draft, Nov 2026. Reference implementation: [`core/multi`](../core/multi) (roster,
input policy, messages, LTR ack intersection, shared rate) and
[`app/multi_host.zig`](../app/multi_host.zig) (the host fan-out), tested end to end over
the sim in [`app/multi_test.zig`](../app/multi_test.zig).
Builds on the control channel ([control-v0.md](control-v0.md)): message types
`0x0300`–`0x03ff`, feature bits 16–23.

A multi-user session is one host streaming to several clients at once. Each client is an
ordinary session on its own connection ([wire-v0.md](wire-v0.md) datagrams, its own control
channel); the host captures and encodes once and sends the same encoded frames to every
client. The user at the host stays in charge: who may join, who may type.

## Membership

- **Who may join.** The host's allowlist ([pairing-v0.md](pairing-v0.md)) admits a client
  as for a single-user session. The host app decides per member whether it **may
  control** (hold input); in v0 that is a host setting, and a per-device permission in the
  allowlist is a follow-up. The host caps the number of members (8 by default, at most
  32).
- **Member ids.** The host gives each member a `u16` id when it joins, unique for the
  life of the host session (a client that leaves and comes back gets a new one). Id 0
  means the host's own user.
- **Joining.** A member that joins after the stream started has no reference frame, so
  its `hello` makes the host send an IDR (to everyone: there is one encoder). A member
  whose control channel does not advertise feature bit 16 (an older client) still gets
  video and audio; it gets no roster, and its input is governed like anyone else's.
- **Leaving.** A member leaves with `bye`, by timing out, or when its connection drops
  for longer than the reconnect timeout (as for one client). The host removes it from the
  roster and from the ack intersection (below).

## Input policy

The host runs one of three policies, a byte in the roster:

| Value | Policy | Whose input is injected |
| ---: | --- | --- |
| 0 | `owner` (default) | One member at a time, the **input owner**. |
| 1 | `everyone` | Every member that may control. |
| 2 | `view_only` | Nobody's; only the user at the host types. |

Under `owner`:

- When nobody remote holds input, the first member that may control gets it without
  asking (`auto_owner`, on by default; off, input stays with the host's user until a
  member asks and the host's user gives it).
- A member asks with `input_request`; the roster marks it `requesting`, so the owner
  (and the host's user) can see it. If nobody remote holds input it is granted at once.
- The owner hands input on with `input_give`. Only the owner may, and only to a member
  that may control; anything else is refused (and counted) without a reply, since the
  roster shows the result either way.
- The host's user can give input to any member that may control, or take it back, at
  any time.
- When the owner leaves, a member that is requesting gets input, else (with
  `auto_owner`) the oldest member that may control, else the host's user.
- **On a handoff the host releases every key and mouse button the previous owner left
  down**, so a key held across the handoff does not stay stuck. Input the previous
  owner sent but the host had not injected yet is dropped.

A member's input that the policy does not apply is still received and acked on the
datagram input stream (so the client stops resending it) and then dropped. Clients may
stop sending input when the roster says they do not hold it.

## Messages

All are sent on the control channel with `required` clear and `version` 0, and only to a
peer that advertised feature bit 16 (`multi_user`). Integers are little-endian.

### `0x0300` roster (host → client)

The whole membership, sent to each member when its channel comes up and after every
change (join, leave, request, handoff, policy, a member's path moving to or from a
relay). Each member gets its own copy (`you` differs).

| Offset | Size | Field | Meaning |
| ---: | ---: | --- | --- |
| 0 | 4 | `epoch` | Bumped on every change. A receiver ignores a roster older than the one it has (serial-number comparison). |
| 4 | 2 | `you` | The receiver's member id. |
| 6 | 2 | `owner` | Who holds input under `owner` policy; 0 = the host's user. |
| 8 | 1 | `policy` | 0 `owner`, 1 `everyone`, 2 `view_only`. |
| 9 | 1 | `count` | Entries that follow, at most 32. |
| 10 | 2 | reserved | 0. |
| 12 | | entries | `count` entries. |

Entry:

| Offset | Size | Field | Meaning |
| ---: | ---: | --- | --- |
| 0 | 2 | `id` | Member id. |
| 2 | 1 | `flags` | Bit 0 `may_control`, bit 1 `requesting`, bit 2 `relayed`; bits 3–7 reserved, ignored on receive. |
| 3 | 1 | `name_len` | At most 64. |
| 4 | | `name` | UTF-8, the allowlist name (already sanitized there). |

A roster whose `count` is over 32, or whose entries run past the end of the body, is
dropped (and counted). Trailing bytes after the last entry are ignored (room to extend).

### `0x0301` input_request (client → host)

| Offset | Size | Field | Meaning |
| ---: | ---: | --- | --- |
| 0 | 1 | `want` | Bit 0: 1 ask for input, 0 withdraw the request. |

### `0x0302` input_give (client → host)

| Offset | Size | Field | Meaning |
| ---: | ---: | --- | --- |
| 0 | 2 | `to` | The member to hand input to; 0 = back to the host's user. |
| 2 | 2 | reserved | 0. |

Sent by the owner. The host checks it is still the owner when it arrives.

### Feature bits

| Bit | Feature |
| ---: | --- |
| 16 | `multi_user`: the messages above. |
| 17–23 | reserved. |

## One encode, N clients

Everything about delivery stays per client: pacing and the rate estimate from that
client's transport feedback, NACKs answered from that client's history, the loss policy
(NACK, FEC or relay mode) for that client's path, stall holds, clock sync, audio. What is
shared is what the encoder decides:

- **Frame ids** are the encoder's, the same for every client. A client that joins sees
  ids starting wherever the stream is.
- **Recovery.** A recovery request from any client makes the next frame a recovery frame
  (an LTR refresh, or an IDR) for everyone. Requests from different clients for the same
  frame are copies: the host's retry window is the longest of the members' (about the
  farthest member's RTT in frames).
- **LTR acks are intersected.** The encoder is told a long-term reference is acked only
  once every member that was receiving when the frame was sent has acked it. A refresh
  then references a frame every member decoded. Without this, a refresh against a frame
  that a lossy member lost would be undecodable for it (the sim shows exactly that with
  the intersection off). A member that leaves stops counting, which can release frames
  only it held back. A frozen or lossy member holds back new common references, so
  refreshes reference an older frame (still fine for everyone) or, past `max_ltr_age`,
  fall back to an IDR.
- **Bitrate.** With rate control, the encoder runs at a rate combined from the members'
  estimates: the lowest by default (every path stays uncongested), or the median, with an
  optional floor so one bad path cannot drag everyone down; a member below the shared rate
  then relies on its pacer, FEC and recovery. One ladder applies it, bounded by the
  strictest member's loss-policy caps (relay mode) and the largest FEC share.

- **Codec and format.** One encode has one codec and format (chroma, bit depth, HDR10):
  the best one every member's decoder and display take (`format.negotiateCommon`: the
  members' hello capabilities intersected, then the usual `format.negotiate` ranking). The
  host holds each `hello` until it has picked, so a joiner's first `config` already names
  the common format. When a join, a leave or a member's new `hello` changes the pick,
  every member gets a new `config`, the encoder is reconfigured and the next frame is an
  IDR for everyone; members keep decoding the old stream until their new `config`, then
  drop frames until that IDR (spec/wire-v0.md, "Session"). Members already streaming
  count first: a joiner whose decoder has no codec and format in common with them (and the
  encoder) is turned away, and the others keep their format.

## Presence

Clients show the roster in the overlay as one line: how many are here and who has input,
for example `3 here  input: Alice (you)`, `3 here  input: host`, `3 here  view only`
(`core.multi.View.presence`).

## Known limits and follow-ups

- An IDR goes to everyone: a member joining, or one that cannot decode a refresh, costs
  every member a keyframe. A member whose path cannot carry an IDR at all (the sim's
  120 ms RTT, 5% loss path with the loss policy off) asks for one again and again, and
  every member pays for each. With the loss policy on (FEC for that path) it does not
  happen; a per-member IDR budget is a follow-up.
- Per-device "may control" in the allowlist, and host UI for the roster and handoff.
- The common format is only as good as the weakest member's decoder: a phone without
  4:4:4 joining a desktop session drops everyone to 4:2:0 until it leaves.
- Sending each member a different encode (simulcast, or a second encoder for a slow
  member) is out of scope for v0.

## Changes

- v0 (Nov 2026): first draft: membership, input policies and handoff, roster,
  `input_request`, `input_give`, ack intersection, shared rate.
- v0 (Nov 2026): one codec and format for every member, re-picked on joins and leaves.
