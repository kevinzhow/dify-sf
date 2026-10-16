| round | mix | clients | secs | profile | edits issued | committed | conflict notices | lost disjoint | lost same-value | reported lost (crash) | silent overwrites | final divergence | ack p50/p99 ms | visible p50/p99 ms (steady p99) | server CPU avg/peak % | RSS MB | faults | result |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| storm-b-10c-baseline | b | 10 | 120 | baseline | 785 | 784 | 1 | 0 | 0 | 0 | 0 | 0 | 9/491 | 10/708 (708) | 2/5 | 67 | - | PASS |
| storm-b-25c-baseline | b | 25 | 120 | baseline | 1957 | 1952 | 5 | 0 | 0 | 0 | 0 | 0 | 9/480 | 11/899 (907) | 5/9 | 71 | - | PASS |
| storm-b-50c-baseline | b | 50 | 120 | baseline | 3916 | 3888 | 28 | 0 | 0 | 0 | 0 | 0 | 10/410 | 12/915 (930) | 12/21 | 79 | - | PASS |
| storm-b-100c-baseline | b | 100 | 120 | baseline | 7852 | 7688 | 164 | 0 | 0 | 0 | 0 | 0 | 13/384 | 16/965 (969) | 32/47 | 95 | - | PASS |

Profiles:
- `baseline`: no impairment (through the proxy)
