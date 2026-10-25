import 'dart:io';

import 'package:test/test.dart';

import '../tool/gen_fixtures.dart';
import 'support.dart';

void main() {
  test('the committed fixtures are what the generator produces', () async {
    final out = Directory('${newDataDir().path}/fixtures');
    addTearDown(() => out.parent.deleteSync(recursive: true));
    writeFixtures(out, await generateFixtures());

    Map<String, String> read(Directory d) => {
      for (final f in d.listSync().whereType<File>())
        if (f.path.endsWith('.json'))
          f.uri.pathSegments.last: f.readAsStringSync(),
    };
    final generated = read(out);
    final committed = read(Directory(fixturesPath));
    const hint = 'regenerate with: dart run tool/gen_fixtures.dart';
    expect(committed.keys.toSet(), generated.keys.toSet(), reason: hint);
    for (final name in generated.keys) {
      final a = committed[name]!.split('\n');
      final b = generated[name]!.split('\n');
      for (var i = 0; i < a.length && i < b.length; i++) {
        if (a[i] != b[i]) {
          fail(
            '$name drifted at line ${i + 1}:\n'
            '  committed: ${a[i]}\n  generated: ${b[i]}\n$hint',
          );
        }
      }
      expect(a.length, b.length, reason: '$name drifted; $hint');
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
