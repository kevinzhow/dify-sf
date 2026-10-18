// Compare an external stress corpus against real elkjs output without replacing retained fixtures.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:elk_layered/elk_layered.dart';

void main(List<String> args) {
  if (args.length != 2) throw ArgumentError('Usage: dart run tool/check_corpus.dart INPUT.json ELKJS.json');
  final input = jsonDecode(File(args[0]).readAsStringSync()) as List;
  final reference = {for (final record in jsonDecode(File(args[1]).readAsStringSync()) as List) record['id']: record};
  var nodesChecked = 0, matched = 0;
  var maxDelta = 0.0;
  final mismatches = <String>[];
  for (final record in input) {
    final expected = reference[record['id']];
    if (expected == null || expected['error'] != null) {
      throw StateError('Oracle failed for ${record['id']}: ${expected?['error']}');
    }
    final output = layoutGraph(record['graph'] as Map<String, dynamic>, normalize: false);
    final nodes = expected['nodes'] as List;
    var graphDelta = 0.0;
    if (nodes.length != output.nodes.length) throw StateError('Different node count in ${record['id']}');
    for (final node in nodes) {
      final actual = output.nodes[node['id']]!;
      for (final delta in [
        (actual.x - node['x']).abs() as num,
        (actual.y - node['y']).abs() as num,
        (actual.width - node['width']).abs() as num,
        (actual.height - node['height']).abs() as num,
      ]) {
        if (!delta.isFinite) throw StateError('Nonfinite coordinate in ${record['id']}');
        graphDelta = math.max(graphDelta, delta.toDouble());
      }
      nodesChecked++;
    }
    maxDelta = math.max(maxDelta, graphDelta);
    if (graphDelta <= 1e-9) {
      matched++;
    } else {
      mismatches.add('${record['id']}: $graphDelta');
    }
  }
  print('Matched $matched/${input.length} graphs ($nodesChecked nodes); max coordinate delta $maxDelta');
  if (mismatches.isNotEmpty) throw StateError('Coordinate mismatches: ${mismatches.join(', ')}');
}
