| round | mix | clients | secs | profile | edits issued | committed | conflict notices | lost disjoint | lost same-value | reported lost (crash) | silent overwrites | final divergence | POST rtt p50/p99 ms | ack p50/p99 ms | visible p50/p99 ms (steady p99) | server CPU avg/peak % | RSS MB | faults | result |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| storm-c-100c-baseline | c | 100 | 120 | baseline | 7707 | 7513 | 194 | 0 | 0 | 0 | 0 | 0 | 7/110 | 7/1407 | 9/3656 (3686) | 32/74 | 97 | clientKill=4 clientPause=3 serverKill=3 | PASS |
| storm-c-100c-latency-200ms | c | 100 | 120 | latency-200ms | 11017 | 9600 | 1417 | 0 | 0 | 0 | 0 | 0 | 207/255 | 207/1623 | 209/3689 (3782) | 29/79 | 99 | clientKill=4 clientPause=3 serverKill=3 | PASS |
| storm-c-100c-latency-800ms | c | 100 | 120 | latency-800ms | 10959 | 8725 | 2229 | 0 | 0 | 5 | 0 | 0 | 806/895 | 807/2834 | 810/4659 (4735) | 28/83 | 104 | clientKill=4 clientPause=3 serverKill=3 | PASS |
| storm-c-100c-latency-2s | c | 100 | 120 | latency-2s | 10819 | 8231 | 2564 | 0 | 0 | 24 | 0 | 0 | 2008/2238 | 2718/5981 | 2920/7900 (7401) | 24/207 | 97 | clientKill=4 clientPause=3 serverKill=3 | PASS |
| storm-c-100c-jitter | c | 100 | 120 | jitter | 11030 | 9449 | 1581 | 0 | 0 | 0 | 0 | 0 | 220/389 | 260/1731 | 330/3772 (3804) | 29/64 | 104 | clientKill=4 clientPause=3 serverKill=3 | PASS |
| storm-c-100c-asymmetric | c | 100 | 120 | asymmetric | 10981 | 8691 | 2286 | 0 | 0 | 4 | 0 | 0 | 856/942 | 857/2492 | 859/4539 (4558) | 27/85 | 99 | clientKill=4 clientPause=3 serverKill=3 | PASS |
| storm-c-100c-loss-1pct | c | 100 | 120 | loss-1pct | 10303 | 9343 | 960 | 0 | 0 | 0 | 0 | 0 | 87/374 | 87/1552 | 142/3806 (3874) | 28/75 | 99 | clientKill=4 clientPause=3 serverKill=3 | PASS |
| storm-c-100c-loss-5pct | c | 100 | 120 | loss-5pct | 11284 | 10152 | 1132 | 0 | 0 | 0 | 0 | 0 | 87/622 | 88/1667 | 216/4177 (4196) | 27/80 | 100 | clientKill=4 clientPause=3 serverKill=3 | PASS |
| storm-c-100c-loss-15pct | c | 100 | 120 | loss-15pct | 16183 | 14182 | 1998 | 0 | 0 | 3 | 0 | 0 | 90/1199 | 127/2198 | 1034/7733 (7768) | 27/63 | 115 | clientKill=4 clientPause=3 serverKill=3 | PASS |
| storm-c-100c-reorder-duplicate | c | 100 | 120 | reorder-duplicate | 7840 | 7578 | 262 | 0 | 0 | 0 | 0 | 0 | 7/111 | 8/1436 | 64/3694 (3708) | 33/77 | 96 | clientKill=4 clientPause=3 serverKill=3 | PASS |
| storm-c-100c-bandwidth-256kbps | c | 100 | 120 | bandwidth-256kbps | 9977 | 9521 | 456 | 0 | 0 | 0 | 0 | 0 | 19/55 | 22/2511 | 41/13671 (13691) | 28/83 | 98 | clientKill=4 clientPause=3 serverKill=3 | PASS |
| storm-c-100c-clean-disconnects | c | 100 | 120 | clean-disconnects | 7678 | 7078 | 597 | 0 | 0 | 3 | 0 | 0 | 7/3364 | 7/3701 | 3888/8261 (7922) | 31/70 | 95 | clientKill=4 clientPause=3 disconnect=723 serverKill=3 | PASS |
| storm-c-100c-half-open-sse | c | 100 | 120 | half-open-sse | 8054 | 6633 | 1395 | 0 | 0 | 26 | 0 | 0 | 2/15 | 632/31966 | 31337/42334 (42462) | 79/166 | 138 | clientKill=4 clientPause=3 halfOpen=334 serverKill=3 | PASS |
| storm-c-100c-flapping | c | 100 | 120 | flapping | 7660 | 6335 | 1313 | 0 | 0 | 12 | 0 | 0 | 7/2595 | 74/3952 | 3221/9690 (9793) | 35/84 | 91 | clientKill=4 clientPause=3 flap=4285 serverKill=3 | PASS |
| storm-c-100c-long-offline | c | 100 | 120 | long-offline | 7626 | 7297 | 315 | 0 | 0 | 14 | 0 | 0 | 7/109 | 7/30664 | 625/45201 (42695) | 30/71 | 96 | clientKill=4 clientPause=3 longOffline=25 serverKill=3 | PASS |
| storm-c-100c-slow-server | c | 100 | 120 | slow-server | 7662 | 5527 | 2110 | 0 | 0 | 25 | 0 | 0 | 1881/2822 | 2761/5929 | 2985/6728 (6602) | 13/67 | 95 | clientKill=4 clientPause=3 serverKill=3 | PASS |
| storm-c-100c-post-response-lost | c | 100 | 120 | post-response-lost | 9372 | 8890 | 463 | 0 | 0 | 19 | 0 | 0 | 7/84 | 7/16932 | 9/11021 (10621) | 30/82 | 100 | clientKill=4 clientPause=3 serverKill=3 | PASS |
| storm-c-100c-sse-buffered | c | 100 | 120 | sse-buffered | 8883 | 6555 | 2317 | 0 | 0 | 11 | 0 | 0 | 4/22 | 4657/9653 | 4999/12564 (12143) | 40/149 | 111 | clientKill=4 clientPause=3 serverKill=3 | PASS |
| storm-c-100c-sse-lifetime-cap | c | 100 | 120 | sse-lifetime-cap | 5089 | 5049 | 40 | 0 | 0 | 0 | 0 | 0 | 5/14 | 6/334 | 65473/176560 (173779) | 15/116 | 99 | clientKill=4 clientPause=3 serverKill=3 | PASS |

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
