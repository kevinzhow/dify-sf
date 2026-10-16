# Storm at 100 clients under every network profile

Server `main` after 2df0c3e (protocol 1.3), 500-node workflow, 100 real client processes, 120 s per round, one round per
network profile (`bench/storm/run.sh sweep c` and `sweep b` with `CLIENTS=100 DURATION=120`). Raw results: `bench/keep/storm-100c/`.

* **mix c** = mix b (40% disjoint edits, 30% same value, 30% different values on shared fields) plus connection drops, client
  kills, client pauses, duplicate and replayed POSTs, and server `kill -9` every 25-40 s.
* **mix b** = the same edit mix without injected process faults.

## Summary

| sweep | rounds | passed | edits issued | committed | conflict notices | reported lost (volatile client killed) | invariant violations |
|---|---|---|---|---|---|---|---|
| mix c | 19 | 19 | 180124 | 156349 | 23629 | 146 | 0 |
| mix b | 19 | 19 | 184931 | 161037 | 23894 | 0 | 0 |

Invariants checked on every round (I1-I5): no acknowledged edit missing from the durable log, no stale write overwriting an
unseen one, every client's view equal to the server at the end, no dangling references (server and every client), and exactly
one outcome per edit. Edits reported lost come only from volatile (unjournaled) clients that were killed before the server
acknowledged them; each one was reported to its user.

Under netem packet loss the editing window ran past 120 s (up to 2x the edits of the baseline round at 15% loss): after the
window the harness restored its 200 proxies through the same lossy link before clearing netem, and the editors kept going
until that finished. That only made those rounds harder; the harness now clears netem first.

## `sse-lifetime-cap` was broken before this run, now fixed

The profile used Toxiproxy's `reset_peer` toxic with `timeout = 8000`. In Toxiproxy 2.12.0 that toxic takes the first chunk
of data, waits for the timeout and resets the connection without forwarding the chunk, so **no event ever reached a client**
while the profile was active. Clients only got their state once the network was restored at the end of the window, which
showed up as visibility p50 65 s / p99 177 s at 100 clients (and as only 53-78 edits per round at 25 clients, including the
earlier preliminary sweep in `bench/keep/storm-prelim/20261017-010009`). The profile now cuts each client's event stream every
8 s by disabling and re-enabling its proxy (random phase per client). The rows below are the reruns with the fix; the sweep
tables keep the broken rows for the record.

| round | mix | clients | secs | profile | edits issued | committed | conflict notices | lost disjoint | lost same-value | reported lost (crash) | silent overwrites | final divergence | POST rtt p50/p99 ms | ack p50/p99 ms | visible p50/p99 ms (steady p99) | server CPU avg/peak % | RSS MB | faults | result |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| storm-b-100c-sse-lifetime-cap | b | 100 | 120 | sse-lifetime-cap | 7785 | 7555 | 230 | 0 | 0 | 0 | 0 | 0 | 6/44 | 7/758 | 806/1028 (1019) | 30/39 | 94 | lifetimeCut=1500 | PASS |
| storm-c-100c-sse-lifetime-cap | c | 100 | 120 | sse-lifetime-cap | 7715 | 7397 | 318 | 0 | 0 | 0 | 0 | 0 | 6/93 | 7/1503 | 852/3712 (3749) | 34/82 | 96 | clientKill=4 clientPause=3 lifetimeCut=1500 serverKill=3 | PASS |

## mix c

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

## mix b

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
