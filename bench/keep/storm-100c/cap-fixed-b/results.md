| round | mix | clients | secs | profile | edits issued | committed | conflict notices | lost disjoint | lost same-value | reported lost (crash) | silent overwrites | final divergence | POST rtt p50/p99 ms | ack p50/p99 ms | visible p50/p99 ms (steady p99) | server CPU avg/peak % | RSS MB | faults | result |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| storm-b-100c-sse-lifetime-cap | b | 100 | 120 | sse-lifetime-cap | 7785 | 7555 | 230 | 0 | 0 | 0 | 0 | 0 | 6/44 | 7/758 | 806/1028 (1019) | 30/39 | 94 | lifetimeCut=1500 | PASS |

Profiles:
- `sse-lifetime-cap`: SSE connections are cut every 8 s (NAT / proxy lifetime cap)
