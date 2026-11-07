# S5 run summary

datagrams sent ~2000 pps of 1150 B; host received 30620; sender-side send_datagram errors 0

## A: relay forced
- open paths seen before unblock: {"PathId(0)": true}
- direct UDP packets on the wire before unblock: 0
- relay path RTT (selected): min 0.21 ms, max 1.19 ms, last 0.31 ms

## B: direct allowed
relative to unblock:
- first direct packet on wire (client->host): +112.1 ms
- direct packets both ways: +112.1 ms
- first full-size datagram on direct: +112.1 ms
- client Opened(direct): +112.7 ms  Selected(direct): +112.7 ms
- host   Opened(direct): +112.9 ms  Selected(direct): +112.9 ms
- **event lag: client Opened after first bidirectional direct packet: 0.6 ms**
- **event lag: client Selected vs first data on direct: +0.6 ms** (negative = event before data moved)
- direct path RTT: min 0.050 ms, max 0.240 ms
- relay and direct paths open at the same time with separate stats: true

## C: 1/20 loss on direct
- first lost_packets increment on direct path: +0.9 ms
  (first injected drop happens within ~10 ms of loss_on at this send rate)
- during C: sent 8097, lost 357 => 4.41% (injected 5.00% one way at client egress plus same on acks)
- relay path lost_packets during C: Some(0)..Some(0)

## D: direct broken again
relative to block:
- last direct packet on wire: -2.3 ms
- first full-size packet on relay TCP: +299.8 ms
- client Selected(relay): +299.6 ms  Closed(direct): +299.5 ms
- **event lag: Selected(relay) vs first data on relay: -0.3 ms**
- direct path RTT estimate kept reporting until +299 ms (last 0.10 ms)

## Receiver-side datagram gaps (longest gap in host receive)
- B (relay -> direct switch): 2.5 ms
- D (direct blackholed -> relay): 300.4 ms

## Stats polling cost (Connection::paths() + stats() for all paths)
- p50 6.3 us, p99 108.6 us, max 17986.3 us over 21978 polls
