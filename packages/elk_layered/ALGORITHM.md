# Phase scope

Reference: elkjs 0.11.1's actual processor execution with the Dify 1.17.1 root/child options, checked against the
ELK Java v0.11.0 sources. The effective Dart engine is about 4,800 lines including the public importer/API;
the initial estimate was 5,500–6,500. Tests, tools, retained JSON, and the separate candidate evaluation are not
algorithm code.

| Actual ELK phase/processor | This package |
| --- | --- |
| EdgeAndLayerConstraintEdgeReverser | No effect under these options |
| PortSideProcessor | `elk_layering.dart` |
| DepthFirstCycleBreaker | `elk_layering.dart` |
| LayerConstraintPreprocessor | No effect under these options |
| NetworkSimplexLayerer | `elk_layering.dart`, `network_simplex.dart` |
| LayerConstraintPostprocessor | No effect under these options |
| LongEdgeSplitter | `elk_layering.dart` |
| InvertedPortProcessor | `elk_layering.dart` |
| PortListSorter | `elk_layering.dart` |
| SortByInputModelProcessor and model-order comparators | `elk_layering.dart` |
| LayerSweepCrossingMinimizer / ModelOrderBarycenterHeuristic | `elk_crossmin.dart` |
| Hierarchical TWO_SIDED greedy switch | `elk_crossmin.dart`, root only |
| InLayerConstraintProcessor | No effect under these options |
| LabelAndNodeSizeProcessor | Zero-size E/W distributed-port placement in `elk_placement.dart` |
| InnermostNodeMarginCalculator | `elk_placement.dart` |
| BKNodePlacer, alignment, compaction, straightening | `elk_placement.dart` |
| LayerSizeAndGraphHeightCalculator | `elk_routing.dart` |
| SplineEdgeRouter | Channel/slot ranking and node x positions in `elk_routing.dart`; no curve output |
| LongEdgeJoiner | `elk_routing.dart` |
| HorizontalGraphCompactor | EDGE_LENGTH network-simplex compaction and scanline constraints in `elk_routing.dart` |
| FinalSplineBendpointsCalculator, EndLabelSorter, ReversedEdgeRestorer | Edge geometry only; not returned |
| HierarchicalNodeResizingProcessor | No nested graph nodes in these flat calls |

## Exactness details

- Dify's declared EAST ports are not connected by its legacy `sourcePort` field when the edge also has a
  `sources` array. The JSON importer creates a new implicit source/target port per edge. Keeping the unused
  ports is necessary to reproduce the port distribution and node positions.
- `INCLUDE_CHILDREN` selects ELK's compound pipeline even for a flat input. In particular, the graph is not
  split and repacked as independent connected components. Container interiors are separate calls.
- Spline channel ranking and horizontal post-compaction affect node x coordinates even though Dify discards
  ELK's returned edge geometry. Removing those phases is not equivalent.
- Dify's root `compaction.postCompaction.constraints=EDGE_LENGTH` is not a recognized constraint value in this
  elkjs release and resolves to SCANLINE. The implemented compactor follows that effective behavior.
- GWT treats Java floats as doubles. Perturbation constants, random state updates, `nextLong` seed handling,
  sorting stability, traversal order, and intermediate reassignment of node/port IDs are retained.
- Two initial-order flags use an identical property identifier in upstream `InternalProperties.java` and
  elkjs's generated worker. Their alias is intentional here to match execution, rather than the apparent
  intent of their distinct Java constant names.
- The scanline predecessor/successor set is represented by a `SplayTreeMap` to keep ordered lookups logarithmic.

The equivalence claim is limited to the tested Dify subset and oracle corpora. It does not prove equivalence
for arbitrary ELK options, arbitrary nesting, or graphs beyond that supported contract.
