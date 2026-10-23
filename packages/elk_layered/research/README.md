# Existing Dart ELK evaluation

This is a comparison harness, not an implementation or an editor integration.
It evaluates the published `elk` **0.2.0** against real **elkjs 0.11.1**, using the root and child option sets from
Dify **1.17.1** `web/app/components/workflow/utils/elk-layout.ts`.

## Result

Measured on 2026-10-18. All 126 inputs completed in both engines. After independently subtracting each layout's
minimum node x/y, as Dify does, **0 of 126** layouts matched all node coordinates and dimensions within `1e-9`.
The comparison removes whole-graph translation, so different root padding is not the explanation.

| Corpus | Layouts | Nodes | Matching layouts | Mean node displacement | Maximum coordinate delta |
| --- | ---: | ---: | ---: | ---: | ---: |
| Dify examples, including container interiors | 16 | 72 | 0 | 33.57 | 176.67 |
| Simple chain/diamond/cycle/disconnected/multiport, root and child | 10 | 40 | 0 | 22.96 | 55.00 |
| Seeded random graphs | 100 | 960 | 0 | 160.27 | 968.96 |

Neither result contained overlapping node rectangles in this corpus. This is evidence of coordinate differences,
not evidence that the existing package produces unusable layouts. These tests do not measure frame rate, visual
rendering, arbitrary nested compound hierarchies, or every possible graph. Dify lays out container interiors as
separate flat graphs; those are included. The fixtures retain source sample node sizes, falling back to Dify's
244 by 100 defaults when absent; they do not measure live rendered node sizes.

For the four-node root diamond, after normalization:

| Node | elkjs (x, y) | elk (x, y) |
| --- | --- | --- |
| n0 | 0, 70 | 0, 100 |
| n1 | 364, 0 | 344, 0 |
| n2 | 364, 180 | 344, 180 |
| n3 | 728, 106.66666666666667 | 688, 85 |

The resulting node bounds are **972 × 280** versus **932 × 280**.

## Source findings and reuse boundaries

The published package is pure Dart, runs without Flutter or JavaScript, and already contains actual layered
phases: depth-first cycle breaking, network-simplex layering, layer-sweep crossing minimization, Brandes–Köpf
placement, ports and hierarchy handling. Its current engine does not use the older bundled Dagre implementation.
These are useful building blocks; dismissing it from the README alone would miss them.

The current public API/pipeline does not implement the whole Dify configuration:

| Dify requirement | Published elk 0.2.0 source | Consequence for customization |
| --- | --- | --- |
| `FIXED_ORDER` ports and distributed spacing | Node JSON does not retain `portConstraints`/port indices; engine marks declared sides `FIXED_SIDE`; E/W placement centers a group at fixed gaps | Extend graph/options plumbing and port processing, preserving existing callers |
| Model-order processing and TWO_SIDED greedy switch | Model-order heuristics exist; greedy-switch is listed as omitted; RNG sequence is not promised identical | Compare phase outputs; extend crossing minimization and exact ordering/tie behavior |
| Dify thoroughness 10 | Layerer defaults to 7; crossing minimizer hardcodes 7; public options do not expose it | Carry the effective option through every relevant phase |
| `SPLINES`, conservative routing | Engine always runs `OrthogonalRoutingGenerator` | Add the spline router's spacing computation even if curve geometry is discarded |
| Final `EDGE_LENGTH` post-compaction | Pipeline ends with edge restoration; no horizontal graph compactor | Add post-compaction and its route-derived constraints |
| Precise matching against elkjs 0.11.1 | Package documents structural comparisons against 0.9.3, not exact coordinates | Retain the 0.11.1 oracle and add exact regression tests for customizations |

The baseline alone cannot establish which changes are sufficient for complete equality or their total effort.
A small exploratory fixed-order/distributed-port patch did **not** solve the comparison (0/126; sample mean
displacement rose to 48.00). It was not retained as a proposed fix. Coordinated pipeline work is required if
exact coordinates remain a requirement; a wrapper and configuration changes alone are insufficient.

## Reproduce

`graphs.json` contains only layout data (IDs, sizes, ports, edges, options). `elkjs.json` and `dart.json` are retained
outputs; `comparison.json` records per-graph metrics. The random corpus uses Python's `random.Random(seed)` with
seeds 0 through 99, 4–16 nodes, varied sizes, and periodic back edges. The sample corpus has 13 root layouts and
3 loop/iteration interior layouts.

From this directory:

```sh
dart pub get
dart run evaluate.dart graphs.json dart.json
ELK_MODULE=/path/to/elkjs-0.11.1/lib/elk.bundled.js node reference.cjs graphs.json elkjs.json
python3 compare.py
```

Run Node/Dart under the machine's resource limits. Oracle generation is separate from comparison and must not
silently overwrite reference output during an ordinary regression test. The script assumes that the supplied
`ELK_MODULE` is the intended 0.11.1 release; `sources.json` records the evaluated archive checksums.

To recreate the input corpus from a local Dify 1.17.1 source checkout and the client's visual samples, install
PyYAML, then run:

```sh
python3 make_corpus.py --dify-source "$DIFY_SOURCE" --fixtures "$DIFY_SAMPLES" --output graphs.json
```

The optional builder audit runs the **original TypeScript** helper extracted from the Dify checkout under Bun,
then compares its serialized children/edges with the Python builder's output. All 126 inputs passed this audit:

```sh
python3 make_corpus.py --dify-source "$DIFY_SOURCE" --fixtures "$DIFY_SAMPLES" --output graphs.json --audit inputs.json
bun audit_builder.mjs "$DIFY_SOURCE/web/app/components/workflow/utils/elk-layout.ts" inputs.json graphs.json
```

The builder preserves Dify's sourcePort field rather than changing endpoints to port IDs: elkjs ignores that
legacy field when `sources` is supplied. Dify's unused explicit ports still affect layout. Branch sorting, DFS
child/edge order, source handle naming, and internal-edge filters follow the Dify helper.

`builder_cases.json` retains the paired pre-builder inputs for all 126 graphs, with only fields read by the
builder (IDs, types, sizes, branch/class/action IDs, and edge handles). Match its `id` to `graphs.json` to obtain
the expected `graph.children` and `graph.edges`. These pairs test `buildPortAwareGraph`; node/edge filtering
around that helper remains a separate editor integration responsibility. The three real child graphs use
their actual parent IDs as the graph ID.

## Sources

- [Published elk 0.2.0](https://pub.dev/packages/elk/versions/0.2.0), including README, `lib/src/api/`,
  `lib/src/layered/elk_layered_engine.dart`, `PORTING.md`, and the phase implementations in its release archive.
- [elk upstream](https://github.com/orestesgaolin/mermaid), package MIT with a separately attributed Apache-2.0
  Dagre derivative. This harness depends on the published package and does not vendor its code.
- [elkjs 0.11.1](https://www.npmjs.com/package/elkjs/v/0.11.1), used as the independent oracle.
- [Dify 1.17.1 layout builder](https://github.com/langgenius/dify/blob/1.17.1/web/app/components/workflow/utils/elk-layout.ts).
