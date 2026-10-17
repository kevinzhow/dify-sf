// Top Dart functions by CPU samples, from a running profile-mode app's VM service.
// Usage: dart vmprof.dart <app log with "VM service is listening on http://..."> <delay s> <window s> [marker]
import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final log = File(args[0]);
  final delay = double.parse(args[1]), window = double.parse(args[2]);
  String? uri;
  for (var i = 0; i < 300 && uri == null; i++) {
    if (log.existsSync()) {
      uri = RegExp(r'listening on (http://\S+)').firstMatch(log.readAsStringSync())?.group(1);
    }
    if (uri == null) await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  final ws = await WebSocket.connect('${uri!.replaceFirst('http', 'ws')}ws');
  var id = 0;
  final pending = <int, Completer<Map<String, dynamic>>>{};
  ws.listen((m) {
    final j = jsonDecode(m as String) as Map<String, dynamic>;
    pending.remove(j['id'] is int ? j['id'] : int.tryParse('${j['id']}'))?.complete(j);
  });
  Future<Map<String, dynamic>> call(String method, [Map<String, Object?> params = const {}]) {
    final c = Completer<Map<String, dynamic>>();
    pending[++id] = c;
    ws.add(jsonEncode({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params}));
    return c.future.then((r) => (r['result'] ?? r) as Map<String, dynamic>);
  }

  final vm = await call('getVM');
  if (vm['isolates'] == null) { stdout.writeln('getVM: $vm'); await stdout.flush(); exit(1); }
  final iso = (vm['isolates'] as List).first['id'];
  stdout.writeln('setFlag profiler: ${jsonEncode(await call('setFlag', {'name': 'profiler', 'value': 'true'}))}');
  // Optional 4th argument: wait until this line appears in the log before the delay.
  if (args.length > 3) {
    for (var i = 0; i < 600 && !log.readAsStringSync().contains(args[3]); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }
  await Future<void>.delayed(Duration(milliseconds: (delay * 1000).round()));
  await call('clearCpuSamples', {'isolateId': iso});
  await Future<void>.delayed(Duration(milliseconds: (window * 1000).round()));
  final s = await call('getCpuSamples', {'isolateId': iso, 'timeOriginMicros': 0, 'timeExtentMicros': 1 << 62});
  if (s['functions'] == null) { stdout.writeln('getCpuSamples: ${jsonEncode(s)}'); await stdout.flush(); exit(1); }
  final fns = (s['functions'] as List).cast<Map<String, dynamic>>();
  final total = (s['sampleCount'] as int?) ?? 1;
  String name(Map<String, dynamic> f) {
    final fn = f['function'] as Map<String, dynamic>;
    final owner = fn['owner'] is Map ? '${(fn['owner'] as Map)['name']}.' : '';
    return '$owner${fn['name']}  (${(f['resolvedUrl'] as String? ?? '').split('/').last})';
  }

  stdout.writeln('samples $total');
  for (final key in ['exclusiveTicks', 'inclusiveTicks']) {
    stdout.writeln('-- top by $key');
    fns.sort((a, b) => (b[key] as int).compareTo(a[key] as int));
    for (final f in fns.take(25)) {
      stdout.writeln('${(100 * (f[key] as int) / total).toStringAsFixed(1).padLeft(5)}%  ${name(f)}');
    }
  }
  await ws.close();
}
