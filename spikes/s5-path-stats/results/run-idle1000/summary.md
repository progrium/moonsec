# S5 run summary

datagrams sent ~2000 pps of 1150 B; host received 30893; sender-side send_datagram errors 0

## A: relay forced
- open paths seen before unblock: {"PathId(0)": true}
- direct UDP packets on the wire before unblock: 0
- relay path RTT (selected): min 0.21 ms, max 0.71 ms, last 0.36 ms

## B: direct allowed
relative to unblock:
- first direct packet on wire (client->host): +109.8 ms
- direct packets both ways: +109.8 ms
- first full-size datagram on direct: +110.0 ms
- client Opened(direct): +110.4 ms  Selected(direct): +110.4 ms
- host   Opened(direct): +110.5 ms  Selected(direct): +110.5 ms
- **event lag: client Opened after first bidirectional direct packet: 0.6 ms**
- **event lag: client Selected vs first data on direct: +0.4 ms** (negative = event before data moved)
- direct path RTT: min 0.046 ms, max 0.388 ms
- relay and direct paths open at the same time with separate stats: true

## C: 1/20 loss on direct
- first lost_packets increment on direct path: +0.2 ms
  (first injected drop happens within ~10 ms of loss_on at this send rate)
- during C: sent 8080, lost 358 => 4.43% (injected 5.00% one way at client egress plus same on acks)
- relay path lost_packets during C: Some(0)..Some(0)

## D: direct broken again
relative to block:
- last direct packet on wire: -2.9 ms
- first full-size packet on relay TCP: +998.7 ms
- client Selected(relay): +998.5 ms  Closed(direct): +998.5 ms
- **event lag: Selected(relay) vs first data on relay: -0.2 ms**
- direct path RTT estimate kept reporting until +998 ms (last 0.09 ms)

## Receiver-side datagram gaps (longest gap in host receive)
- B (relay -> direct switch): 2.3 ms
- D (direct blackholed -> relay): 999.3 ms

## Stats polling cost (Connection::paths() + stats() for all paths)
- p50 5.5 us, p99 99.4 us, max 8687.9 us over 23340 polls
