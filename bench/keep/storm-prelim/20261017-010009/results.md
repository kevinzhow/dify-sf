| round | mix | clients | secs | profile | edits issued | committed | conflict notices | lost disjoint | lost same-value | reported lost (crash) | silent overwrites | final divergence | POST rtt p50/p99 ms | ack p50/p99 ms | visible p50/p99 ms (steady p99) | server CPU avg/peak % | RSS MB | faults | result |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| storm-b-25c-baseline | b | 25 | 45 | baseline | 709 | 707 | 2 | 0 | 0 | 0 | 0 | 0 | 6/16 | 6/298 | 7/396 (612) | 5/9 | 68 | - | PASS |
| storm-b-25c-latency-200ms | b | 25 | 45 | latency-200ms | 924 | 881 | 43 | 0 | 0 | 0 | 0 | 0 | 207/216 | 207/584 | 209/731 (936) | 5/11 | 69 | - | PASS |
| storm-b-25c-latency-800ms | b | 25 | 45 | latency-800ms | 914 | 798 | 116 | 0 | 0 | 0 | 0 | 0 | 807/815 | 807/1797 | 808/1997 (2140) | 5/8 | 68 | - | PASS |
| storm-b-25c-latency-2s | b | 25 | 45 | latency-2s | 901 | 737 | 164 | 0 | 0 | 0 | 0 | 0 | 2007/2016 | 2702/4989 | 2713/5115 (5280) | 5/54 | 68 | - | PASS |
| storm-b-25c-jitter | b | 25 | 45 | jitter | 923 | 874 | 49 | 0 | 0 | 0 | 0 | 0 | 235/378 | 238/752 | 320/989 (1059) | 5/8 | 68 | - | PASS |
| storm-b-25c-asymmetric | b | 25 | 45 | asymmetric | 914 | 793 | 121 | 0 | 0 | 0 | 0 | 0 | 857/869 | 857/1891 | 858/2187 (2243) | 5/9 | 67 | - | PASS |
| storm-b-25c-loss-1pct | b | 25 | 45 | loss-1pct | 878 | 852 | 26 | 0 | 0 | 0 | 0 | 0 | 86/369 | 86/684 | 112/1780 (1828) | 5/7 | 70 | - | PASS |
| storm-b-25c-loss-5pct | b | 25 | 45 | loss-5pct | 940 | 911 | 29 | 0 | 0 | 0 | 0 | 0 | 87/619 | 87/909 | 196/1730 (1978) | 5/8 | 69 | - | PASS |
| storm-b-25c-loss-15pct | b | 25 | 45 | loss-15pct | 1184 | 1126 | 58 | 0 | 0 | 0 | 0 | 0 | 91/1232 | 127/1853 | 499/3880 (3944) | 5/12 | 70 | - | PASS |
| storm-b-25c-reorder-duplicate | b | 25 | 45 | reorder-duplicate | 724 | 721 | 3 | 0 | 0 | 0 | 0 | 0 | 8/73 | 8/374 | 53/487 (699) | 5/9 | 68 | - | PASS |
| storm-b-25c-bandwidth-256kbps | b | 25 | 45 | bandwidth-256kbps | 809 | 804 | 5 | 0 | 0 | 0 | 0 | 0 | 22/38 | 24/331 | 25/460 (631) | 5/8 | 69 | - | PASS |
| storm-b-25c-clean-disconnects | b | 25 | 45 | clean-disconnects | 713 | 670 | 43 | 0 | 0 | 0 | 0 | 0 | 5/3346 | 6/3345 | 2938/6399 (5835) | 5/7 | 67 | disconnect=75 | PASS |
| storm-b-25c-half-open-sse | b | 25 | 45 | half-open-sse | 751 | 627 | 124 | 0 | 0 | 0 | 0 | 0 | 6/19 | 25/29579 | 19361/31312 (31465) | 6/9 | 69 | halfOpen=33 | PASS |
| storm-b-25c-flapping | b | 25 | 45 | flapping | 695 | 607 | 88 | 0 | 0 | 0 | 0 | 0 | 9/2613 | 82/2637 | 2462/4835 (4995) | 7/18 | 65 | flap=414 | PASS |
| storm-b-25c-long-offline | b | 25 | 45 | long-offline | 713 | 657 | 56 | 0 | 0 | 0 | 0 | 0 | 6/16 | 7/30642 | 14633/37646 (31358) | 4/8 | 67 | longOffline=7 | PASS |
| storm-b-25c-slow-server | b | 25 | 45 | slow-server | 713 | 506 | 207 | 0 | 0 | 0 | 0 | 0 | 3021/9712 | 90249/114305 | 93905/117247 (110118) | 1/12 | 69 | - | PASS |
| storm-b-25c-post-response-lost | b | 25 | 45 | post-response-lost | 823 | 804 | 19 | 0 | 0 | 0 | 0 | 0 | 9/23 | 10/11298 | 11/8954 (7386) | 5/9 | 69 | - | PASS |
| storm-b-25c-sse-buffered | b | 25 | 45 | sse-buffered | 749 | 584 | 165 | 0 | 0 | 0 | 0 | 0 | 8/21 | 4314/8863 | 4923/10063 (10084) | 4/9 | 67 | - | PASS |
| storm-b-25c-sse-lifetime-cap | b | 25 | 45 | sse-lifetime-cap | 53 | 53 | 0 | 0 | 0 | 0 | 0 | 0 | 9/18 | 10/20 | 14897/20881 (0) | 3/35 | 69 | - | PASS |

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
