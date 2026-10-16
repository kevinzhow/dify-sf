| round | mix | clients | secs | profile | edits issued | committed | conflict notices | lost disjoint | lost same-value | reported lost (crash) | silent overwrites | final divergence | POST rtt p50/p99 ms | ack p50/p99 ms | visible p50/p99 ms (steady p99) | server CPU avg/peak % | RSS MB | faults | result |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| storm-b-100c-baseline | b | 100 | 120 | baseline | 7748 | 7637 | 111 | 0 | 0 | 0 | 0 | 0 | 7/42 | 7/419 | 8/948 (946) | 28/41 | 95 | - | PASS |
| storm-b-100c-latency-200ms | b | 100 | 120 | latency-200ms | 11116 | 9696 | 1420 | 0 | 0 | 0 | 0 | 0 | 207/236 | 207/760 | 208/1334 (1337) | 26/37 | 100 | - | PASS |
| storm-b-100c-latency-800ms | b | 100 | 120 | latency-800ms | 11073 | 8774 | 2299 | 0 | 0 | 0 | 0 | 0 | 807/829 | 807/1976 | 808/2523 (2525) | 25/44 | 98 | - | PASS |
| storm-b-100c-latency-2s | b | 100 | 120 | latency-2s | 11036 | 8313 | 2723 | 0 | 0 | 0 | 0 | 0 | 2012/2214 | 2825/5798 | 2932/6451 (6508) | 17/241 | 105 | - | PASS |
| storm-b-100c-jitter | b | 100 | 120 | jitter | 11113 | 9511 | 1602 | 0 | 0 | 0 | 0 | 0 | 230/388 | 262/863 | 325/1514 (1521) | 26/37 | 105 | - | PASS |
| storm-b-100c-asymmetric | b | 100 | 120 | asymmetric | 11079 | 8738 | 2341 | 0 | 0 | 0 | 0 | 0 | 857/879 | 857/2009 | 858/2626 (2635) | 25/44 | 99 | - | PASS |
| storm-b-100c-loss-1pct | b | 100 | 120 | loss-1pct | 10477 | 9513 | 964 | 0 | 0 | 0 | 0 | 0 | 87/373 | 87/753 | 140/1799 (1821) | 25/36 | 99 | - | PASS |
| storm-b-100c-loss-5pct | b | 100 | 120 | loss-5pct | 11719 | 10536 | 1183 | 0 | 0 | 0 | 0 | 0 | 86/430 | 87/786 | 201/2654 (2697) | 25/34 | 98 | - | PASS |
| storm-b-100c-loss-15pct | b | 100 | 120 | loss-15pct | 17384 | 15201 | 2183 | 0 | 0 | 0 | 0 | 0 | 88/948 | 126/1540 | 887/5406 (5462) | 25/45 | 103 | - | PASS |
| storm-b-100c-reorder-duplicate | b | 100 | 120 | reorder-duplicate | 7923 | 7726 | 197 | 0 | 0 | 0 | 0 | 0 | 7/99 | 7/478 | 63/985 (982) | 29/40 | 96 | - | PASS |
| storm-b-100c-bandwidth-256kbps | b | 100 | 120 | bandwidth-256kbps | 10645 | 10323 | 322 | 0 | 0 | 0 | 0 | 0 | 19/48 | 22/595 | 23/1072 (1078) | 27/38 | 103 | - | PASS |
| storm-b-100c-clean-disconnects | b | 100 | 120 | clean-disconnects | 7772 | 7243 | 529 | 0 | 0 | 0 | 0 | 0 | 6/3362 | 7/3492 | 3805/7205 (7170) | 28/37 | 94 | disconnect=724 | PASS |
| storm-b-100c-half-open-sse | b | 100 | 120 | half-open-sse | 8552 | 6982 | 1570 | 0 | 0 | 0 | 0 | 0 | 5/41 | 786/30086 | 29786/41259 (41279) | 34/52 | 98 | halfOpen=334 | PASS |
| storm-b-100c-flapping | b | 100 | 120 | flapping | 7749 | 6445 | 1304 | 0 | 0 | 0 | 0 | 0 | 7/2593 | 27/2608 | 2812/5792 (5827) | 32/94 | 92 | flap=4290 | PASS |
| storm-b-100c-long-offline | b | 100 | 120 | long-offline | 7775 | 7486 | 289 | 0 | 0 | 0 | 0 | 0 | 7/80 | 7/28630 | 638/44450 (41941) | 27/39 | 96 | longOffline=25 | PASS |
| storm-b-100c-slow-server | b | 100 | 120 | slow-server | 7766 | 5637 | 2129 | 0 | 0 | 0 | 0 | 0 | 1622/1703 | 2187/3297 | 2230/3869 (3899) | 9/23 | 96 | - | PASS |
| storm-b-100c-post-response-lost | b | 100 | 120 | post-response-lost | 9443 | 9219 | 224 | 0 | 0 | 0 | 0 | 0 | 7/38 | 7/7715 | 8/6348 (1473) | 28/40 | 95 | - | PASS |
| storm-b-100c-sse-buffered | b | 100 | 120 | sse-buffered | 9198 | 6744 | 2454 | 0 | 0 | 0 | 0 | 0 | 4/30 | 4652/9230 | 4988/10566 (10576) | 22/73 | 97 | - | PASS |
| storm-b-100c-sse-lifetime-cap | b | 100 | 120 | sse-lifetime-cap | 5363 | 5313 | 50 | 0 | 0 | 0 | 0 | 0 | 6/16 | 6/358 | 63657/160437 (158937) | 14/155 | 95 | - | PASS |

Profiles:
- `asymmetric`: uplink 50 ms, downlink 800 ms (one way)
- `bandwidth-256kbps`: 256 kbit/s per direction (a 500-node snapshot takes many seconds)
- `baseline`: no impairment (through the proxy)
- `clean-disconnects`: connections closed for 2-4 s every 8-20 s
- `flapping`: link up/down every 0.3-2.5 s
- `half-open-sse`: SSE direction silently stalls (socket stays open) for 15-30 s windows
- `jitter`: 100 ms each way with +-100 ms jitter
- `latency-200ms`: fixed latency, RTT +200 ms (100 ms each way)
- `latency-2s`: fixed latency, RTT +2000 ms (1000 ms each way)
- `latency-800ms`: fixed latency, RTT +800 ms (400 ms each way)
- `long-offline`: 25% of clients offline for 20-35 s, then return
- `loss-15pct`: 15% packet loss (netem) + 40 ms delay
- `loss-1pct`: 1% packet loss (netem) + 40 ms delay
- `loss-5pct`: 5% packet loss (netem) + 40 ms delay
- `post-response-lost`: 30% of POST connections swallow the response after the server committed (client times out and resends)
- `reorder-duplicate`: 25% packet reordering + 5% duplication (netem), 20-60 ms delay
- `slow-server`: every commit takes an extra 800 ms
- `sse-buffered`: a buffering proxy delays the SSE stream by 3-5 s
- `sse-lifetime-cap`: SSE connections are reset 8 s after they start (NAT / proxy lifetime cap)
