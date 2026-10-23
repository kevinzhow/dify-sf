// Generate a browser/Node-compatible check from retained, independent elkjs output.
import 'dart:convert';
import 'dart:io';

void main() {
  final inputs = jsonDecode(File('research/graphs.json').readAsStringSync());
  final expected = jsonDecode(File('research/elkjs.json').readAsStringSync());
  String literal(Object? value) => jsonEncode(jsonEncode(value)).replaceAll(r'$', r'\$');
  final source =
      """
import 'dart:convert';
import 'package:elk_layered/elk_layered.dart';
void main() {
  final inputs = jsonDecode(${literal(inputs)}) as List;
  final reference = {for(final r in jsonDecode(${literal(expected)}) as List) r['id']:r['nodes'] as List};
  for(final record in inputs) {
    final result = layoutGraph(record['graph'] as Map<String,dynamic>);
    final nodes = reference[record['id']]!;
    final minX = nodes.map((n)=>n['x'] as num).reduce((a,b)=>a<b?a:b);
    final minY = nodes.map((n)=>n['y'] as num).reduce((a,b)=>a<b?a:b);
    for(final node in nodes) {
      final actual = result.nodes[node['id']]!;
      final deltas = [(actual.x-(node['x']-minX)).abs(),(actual.y-(node['y']-minY)).abs(),
        (actual.width-node['width']).abs(),(actual.height-node['height']).abs()];
      if(deltas.any((d)=>!d.isFinite||d>1e-9))throw StateError('Web coordinates differ: '+record['id']+'/'+node['id']);
    }
  }
  print('Web backend matched all '+inputs.length.toString()+' retained elkjs layouts within 1e-9');
}
""";
  Directory('.dart_tool').createSync(recursive: true);
  File('.dart_tool/web_check.dart').writeAsStringSync(source);
  print('Generated .dart_tool/web_check.dart');
}
