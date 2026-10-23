import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver(
  responseDataCallback: (data) async {
    final out = File('build/perf/canvas_perf_${Platform.environment['PERF_NODES'] ?? '500'}.json')..createSync(recursive: true);
    out.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(data));
  },
);
