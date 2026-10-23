# Dify layered node layout

A pure Dart implementation of the node-coordinate-relevant portion of **elkjs 0.11.1**, for the flat graphs
constructed by **Dify 1.17.1** `elk-layout.ts`. There are no runtime dependencies, JavaScript engine, Flutter
imports, or native bindings. Root and iteration/loop interior graphs are separate calls, as in Dify.

```dart
import 'package:elk_layered/elk_layered.dart';

// The same children, edges and layoutOptions passed to elkjs by elk-layout.ts.
final result = layoutGraph(elkGraphJson);
for (final entry in result.nodes.entries) {
  final position = entry.value;
  // Apply x/y as collaborative node moves; the editor owns history and saving.
}
```

`layoutGraph(Map<String, dynamic>, {bool normalize = true})` returns an `ElkLayoutResult` with immutable
`nodes` keyed by input ID, plus `bounds`. Each node has `x`, `y`, `width`, and `height`. Default coordinates
subtract the minimum x/y, matching Dify's final normalization. `normalize: false` returns raw elkjs node
coordinates including its padding. The function does not mutate its input.

The editor retains ownership of node/edge filtering, branch sorting, DFS ordering, container selection, applying
moves, read-only checks, and undo/redo. Node layer indices are not returned: the Dify option sets do not request
them from elkjs either.

## Supported contract

- Dify's rightward layered root and child option sets: DFS cycle breaking, network-simplex layering, model-order
  layer sweep, balanced Brandes–Köpf placement with straightening, conservative spline spacing, horizontal
  EDGE_LENGTH post-compaction, and the root-only TWO_SIDED hierarchical greedy switch.
- Simple directed graphs, including cycles and disconnected components; varying fixed node sizes; fixed-order
  zero-size EAST ports. Missing dimensions use Dify's 244 × 100 defaults.
- Input edges name nodes in single-element `sources`/`targets`. Legacy `sourcePort` is ignored in the presence
  of `sources`, as in elkjs. Unused explicit ports are retained because they affect spacing.

Unsupported features fail explicitly: nested compound JSON, self-loops, input labels, nonzero-size or other-side
ports, and port-to-port/hyperedge input. The editor's container-interior calls remain supported because Dify
already flattens each such call. Curve geometry is not returned; its effect on node coordinates is implemented.
This package is not a general replacement for every ELK algorithm or option. Unrecognized legacy option names
from Dify have their actual elkjs behavior; the package does not invent support for them.

## Verification

The retained oracle is real elkjs 0.11.1, independent of this implementation. `research/graphs.json` contains
126 ELK inputs: 13 real workflow roots, 3 container interiors, 10 simple graphs, and 100 seeded random graphs.
`research/elkjs.json` retains their raw node outputs. The Python input builder was separately checked against
the original Dify TypeScript `buildPortAwareGraph`: all 126 serialized children/edge arrays match.

- **256 VM tests pass**, including all 126 raw layouts and all 126 normalized layouts, input immutability,
  empty/single-node cases, unused-port behavior, and explicit rejection of unsupported input.
- The **Dart JavaScript backend matches all 126** retained layouts within `1e-9` under Node.
- A separate stress run matches **1,026/1,026 layouts, 14,105 nodes**, including 1,000 new seeded random graphs
  with up to 24 nodes, against fresh elkjs 0.11.1 raw output. Maximum coordinate delta: `4.55e-13`.
- Dart static analysis is clean. Production plus test/tool Dart code is below the 8,000-line scope threshold.

From the package directory:

```sh
dart pub get
dart analyze
dart test
bash tool/check_web.sh
```

The Web check compiles the engine and retained fixtures to JavaScript. It uses host Node if available; otherwise
it runs a disposable, CPU/memory-limited Docker Node container. Pass an existing image with Node as the first
argument to avoid fetching the default `node:22-alpine` image. Run compilation and bulk checks under the host's
resource controls.

For an additional independently generated oracle corpus:

```sh
python3 research/make_corpus.py --dify-source "$DIFY_SOURCE" --fixtures "$DIFY_SAMPLES" \
  --random-count 1000 --random-offset 100 --max-nodes 24 --output .dart_tool/stress-input.json
python3 tool/reference_batches.py .dart_tool/stress-input.json .dart_tool/stress-elkjs.json \
  --elkjs "$ELKJS_PACKAGE" --image node:22-alpine
dart run tool/check_corpus.dart .dart_tool/stress-input.json .dart_tool/stress-elkjs.json
```

The reference script verifies the package version. Oracle containers are limited to 512MB/one CPU and removed
after each batch. Bulk generation is separate from normal tests so tests cannot silently bless changed output.

## Implementation and reuse investigation

The published Dart [`elk` 0.2.0](https://pub.dev/packages/elk/versions/0.2.0) was evaluated before completing this
port. It handles all 126 inputs without node overlap, but 0/126 node layouts meet the exact-coordinate criterion.
Its layering and placement are useful existing implementations, but its public options/pipeline omit Dify's
spline spacing, final compaction, and parts of its exact model-order processing. The full retained comparison,
configuration analysis and reproduction scripts are in [research/README.md](research/README.md).

The handed-off partial ELK port already matched 116/126 layouts once compiled and connected to the oracle.
The remaining ten were explained by a single upstream property alias: both `FIRST_TRY_WITH_INITIAL_ORDER` and
`SECOND_TRY_WITH_INITIAL_ORDER` use the key `firstTryWithInitialOrder`. Treating these as independent booleans
changes sweep order and long-edge dummy ordering. This implementation preserves their alias, with oracle
regressions covering the affected graphs. It also preserves GWT's random arithmetic and stable sort behavior.

The implementation adapts the relevant ELK Java 0.11.0 phases and processors, including network simplex,
ordering, port sizing, BK placement, spline channel spacing and scanline compaction. Edge curve construction,
unused label processing, and hierarchy machinery are omitted. See [ALGORITHM.md](ALGORITHM.md) for phase scope.
The Java sources and this adaptation use EPL-2.0; see LICENSE and NOTICE.
