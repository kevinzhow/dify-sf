import 'dart:convert';
import 'dart:io';
import 'package:elk/elk.dart';

void main(List<String> args) {
  final input = jsonDecode(File(args[0]).readAsStringSync()) as List;
  final output = <Object>[];
  for (final item in input) {
    final record = item as Map<String, dynamic>;
    final watch = Stopwatch()..start();
    try {
      final result = const ElkLayered().layout(ElkGraph.fromJson(record['graph']));
      output.add({
        'id': record['id'],
        'micros': watch.elapsedMicroseconds,
        'nodes': [
          for (final n in result.children) {'id': n.id, 'x': n.x, 'y': n.y, 'width': n.width, 'height': n.height},
        ],
      });
    } catch (e, stack) {
      output.add({'id': record['id'], 'error': '$e', 'stack': '$stack'});
    }
  }
  File(args[1]).writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(output)}\n');
}
