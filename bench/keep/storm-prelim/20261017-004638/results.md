| round | mix | clients | secs | profile | edits issued | committed | conflict notices | lost disjoint | lost same-value | reported lost (crash) | silent overwrites | final divergence | ack p50/p99 ms | visible p50/p99 ms (steady p99) | server CPU avg/peak % | RSS MB | faults | result |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| storm-c-100c-baseline | c | 100 | 120 | baseline | 7778 | 7488 | 290 | 0 | 0 | 0 | 0 | 0 | 17/1618 | 25/3157 (3178) | 34/66 | 95 | clientKill=4 clientPause=3 serverKill=3 | PASS |

Profiles:
- `baseline`: no impairment (through the proxy)
