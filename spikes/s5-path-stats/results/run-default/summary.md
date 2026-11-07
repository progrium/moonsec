# S5 run summary

datagrams sent ~2000 pps of 1150 B; host received 30981; sender-side send_datagram errors 0

## A: relay forced
- open paths seen before unblock: {"PathId(0)": true}
- direct UDP packets on the wire before unblock: 0
- relay path RTT (selected): min 0.21 ms, max 0.97 ms, last 0.28 ms

## B: direct allowed
relative to unblock:
- first direct packet on wire (client->host): +113.9 ms
- direct packets both ways: +113.9 ms
- first full-size datagram on direct: +114.1 ms
- client Opened(direct): +114.5 ms  Selected(direct): +114.5 ms
- host   Opened(direct): +114.6 ms  Selected(direct): +114.6 ms
- **event lag: client Opened after first bidirectional direct packet: 0.5 ms**
- **event lag: client Selected vs first data on direct: +0.3 ms** (negative = event before data moved)
- direct path RTT: min 0.042 ms, max 0.244 ms
- relay and direct paths open at the same time with separate stats: true

## C: 1/20 loss on direct
- first lost_packets increment on direct path: +0.4 ms
  (first injected drop happens within ~10 ms of loss_on at this send rate)
- during C: sent 8063, lost 291 => 3.61% (injected 5.00% one way at client egress plus same on acks)
- relay path lost_packets during C: Some(0)..Some(0)

## D: direct broken again
relative to block:
- last direct packet on wire: -2.7 ms
- first full-size packet on relay TCP: +14999.3 ms
- client Selected(relay): +14999.0 ms  Closed(direct): +14999.0 ms
- **event lag: Selected(relay) vs first data on relay: -0.3 ms**
- direct path RTT estimate kept reporting until +14998 ms (last 0.09 ms)

## Stats polling cost (Connection::paths() + stats() for all paths)
- p50 5.8 us, p99 75.8 us, max 2013.4 us over 48065 polls
