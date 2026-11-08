# app: the Phase 2 session spine

The host and client apps: a platform backend bundle ([platform/api.zig](../platform/api.zig)),
a session, and a `PacketPipe`, wired into the pipeline.

| File | What |
| --- | --- |
| [host_session.zig](host_session.zig) | Host network stage: config, packetizer + retransmit history, NACKs, transport feedback into the rate controller (pacing), frame acks into `core/recovery`, clock pongs, input actions, host-side telemetry (capture, encode, input). Fixed encoder bitrate. |
| [client_session.zig](client_session.zig) | Client network stage: hello, reassembly + NACKs, transport feedback, recovery (freeze on gap, LTR refresh requests), clock ping/estimate, input sender, per-frame stage times into telemetry, the freeze detector, the overlay. |
| [apps.zig](apps.zig) | `HostApp`/`ClientApp`: `tick()` runs every stage on one thread without blocking (virtual time); `runThreaded()` gives capture+encode or decode+present its own thread next to the network thread. |
| [wire.zig](wire.zig) | Session messages (spec/wire-v0.md, "session"). |
| [simrun.zig](simrun.zig) | Both apps with the synthetic backend over the in-process sim, in virtual time. |
| [pathsim.zig](pathsim.zig) | Scripted path flaps (direct <-> relay) and connection drops over the sim, for the session tests. |
| [pathlog.zig](pathlog.zig) | The sessions' path log. |
| [main.zig](main.zig) | The `moonsec` tool. |
| [pairing.zig](pairing.zig) | Pairing on a device: the state directory, and the pairing exchange and session admission over any reliable stream ([spec/pairing-v0.md](../spec/pairing-v0.md)). |
| [keystore.zig](keystore.zig) | `KeyStore` interface for the device key; file-backed store (0600) and an in-memory one. |
| [pair_cmd.zig](pair_cmd.zig) | `moonsec id`, `pair host`, `pair client`, `paired`, `unpair`, `run pair`, and admission for `peer iroh --state-dir`. |

## The synthetic backend and the test pattern

[platform/synthetic](../platform/synthetic/root.zig) implements the platform interface with
no OS behind it. Capture renders the test pattern ([platform/pattern.zig](../platform/pattern.zig)),
stamped with the capture clock and frame number. The passthrough codec carries the stamp, a
CRC-32 of the pixels, reference bookkeeping (IDR, P, LTR, LTR refresh) and filler sized to the
bitrate; its decoder fails a P frame after a gap like a real one, re-renders the picture and
checks the CRC. The presenter reads the stamp back from the pixels, so every presented frame is
checked end to end.

The pattern is also the measurement tool for real backends: a barcode and seven-segment digits
with the capture time in ms, and a flash square that is white for the first 100 ms of every
second of the capture clock. Put a photodiode (or a camera) on the host's screen and the
client's; the delay between the two flashes is glass-to-glass. `moonsec pattern --out p.ppm`
writes one; `pattern.read` decodes a screenshot or camera crop and `pattern.readDigits` reads the
digits when the barcode does not survive. [tools/latency](../tools/latency/README.md) turns photodiode
logs and camera or screenshot frames into the host×client latency matrix for the Phase 4 gate.

## Commands

```sh
zig build test-app                       # both apps over the in-process sim (part of `zig build test`)
zig build moonsec-sim -- sim --profile wan --seconds 60
zig build soak                           # one hour of simulated LAN in virtual time (~5 min)
zig build moonsec-sim -- run sim         # two processes over the sim hub, wall clock, threads
zig build moonsec -- run all             # ...and over iroh on loopback (builds the shim)
zig build install-moonsec                # then, on two machines:
zig-out/bin/moonsec peer iroh host --ticket-file t --relay --seconds 60
zig-out/bin/moonsec peer iroh client --ticket-file t --relay --seconds 60   # copy t over first
```

## Pairing

```sh
zig build test-pair                      # pair by QR ticket and by PIN, then admission, over iroh
moonsec pair host --relay                # shows a QR code, the ticket text and a PIN for 120 s
moonsec pair client --ticket MOONSEC1:...          # QR ticket: pairs with no PIN
moonsec pair client --ticket MOONSEC1:... --pin 123456   # address ticket plus the PIN
moonsec paired                           # this device's ID and both paired-device lists
moonsec unpair a1b2c3d4                  # remove a device by ID prefix
moonsec peer iroh host --state-dir D ... # device key; admits only paired clients
```

Each device keeps its key and lists in a state directory (`--state-dir`, else
`$MOONSEC_STATE_DIR`, else the per-user config directory). `peer iroh` without
`--state-dir` keeps the old behaviour (fresh key, no admission) for the gate tooling.

The freeze detector ([core/telemetry/freeze.zig](../core/telemetry/freeze.zig)) counts a freeze
whenever no new picture reaches the screen for 200 ms (nothing presented, or old content
repeated), and counts 50 ms and 100 ms stalls separately. Every run prints per-stage telemetry
(capture, encode, network, decode, present, glass-to-glass, input).

Audio rides along on stream 2 whenever the backend has an audio source (host) or sink
(client): the apps feed 10 ms frames through the Opus stage ([codec/opus/stage.zig](../codec/opus/stage.zig))
from the network stage, and the client renders from the jitter buffer into the sink, keeping
about one frame queued. The synthetic backend plays a 440/660 Hz stereo tone; runs report what
the buffer did (decoded, FEC, RS rebuilt, concealed, late) and sink underruns, and the sim runs
fail if under 95% of the audio frames play, the sink runs dry, or it plays mostly silence.

## Path changes and drops

The pipe reports the selected path (`PathStats.path_epoch`, `relayed`), whether it is
`stalled` (the shim's no-ack-progress signal) and, for a reconnecting pipe, `conn_epoch`.
Over iroh, `IrohLink` ([transport/iroh_pipe.zig](../transport/iroh_pipe.zig)) is that pipe:
the client redials when its connection closes or when the session asks, keeping the old
connection until the new one is up; the host accepts in the background and moves to a new
connection once it delivers.

- **Stall**: the host stops sending video (the frames would only be lost, or wait behind the
  dead path), and when acks resume or the path changes, the next frame is a recovery frame
  (LTR refresh, else IDR). A stall within 250 ms of a path change is ignored.
- **Path change**: the rate controller restarts its delay and capacity estimates for the new
  path (`Controller.onPathChange`); the shim has already moved the pacing target.
- **New connection**: the host sets the pacing rate again and sends a recovery frame; the
  client says hello until it hears from the host.
- **Drop**: with a pipe that can reconnect, the client asks for a new connection after 2 s
  without a datagram (`reconnect_after_us`, again every 2 s), and both sides wait up to 60 s
  (`reconnect_timeout_us`) instead of the 5 s peer timeout.

Each session keeps a short path log (stalls, path changes, reconnects) and prints it with
its report. `moonsec sim --flaps 2000:1500 --idle-ms 300` and `--drops 2000:1000` script the
same events over the simulated network ([pathsim.zig](pathsim.zig)); the netns lab
([tools/netlab](../tools/netlab/README.md)) runs them over iroh through two NATs.

A host process that restarts is a new session; the client does not detect that yet.

## Not yet

- Rate adaptation: Phase 2 is fixed bitrate; the controller only sets pacing (at least
  4× the bitrate, or the measured capacity when higher).
- The pipes have no wakeup handle, so the network thread polls at 1 ms.
