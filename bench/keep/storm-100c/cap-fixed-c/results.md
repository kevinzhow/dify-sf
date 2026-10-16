| round | mix | clients | secs | profile | edits issued | committed | conflict notices | lost disjoint | lost same-value | reported lost (crash) | silent overwrites | final divergence | POST rtt p50/p99 ms | ack p50/p99 ms | visible p50/p99 ms (steady p99) | server CPU avg/peak % | RSS MB | faults | result |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| storm-c-100c-sse-lifetime-cap | c | 100 | 120 | sse-lifetime-cap | 7715 | 7397 | 318 | 0 | 0 | 0 | 0 | 0 | 6/93 | 7/1503 | 852/3712 (3749) | 34/82 | 96 | clientKill=4 clientPause=3 lifetimeCut=1500 serverKill=3 | PASS |

Profiles:
- `sse-lifetime-cap`: SSE connections are cut every 8 s (NAT / proxy lifetime cap)
