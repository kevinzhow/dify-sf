@TestOn('vm')
library;

import 'dart:io';

import 'package:collab_client/collab_client.dart';
import 'package:collab_client/io.dart';
import 'package:test/test.dart';

import 'support/helpers.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('collab_store_test'));
  tearDown(() => dir.deleteSync(recursive: true));

  final sample = ClientDurable(
    id: 'c1',
    nextCseq: 5,
    unresolvedFrom: 3,
    journal: [
      JournalEntry(cseq: 3, base: 7, op: setPrompt('a', 'x')),
      const JournalEntry(cseq: 4, base: 7, op: MoveNode('b', 1, 2)),
    ],
  );

  test('round trips and overwrites atomically', () async {
    final store = FileStore('${dir.path}/c1.json');
    expect(await store.load(), isNull);
    await store.save(sample);
    final back = (await store.load())!;
    expect((back.id, back.nextCseq, back.unresolvedFrom), ('c1', 5, 3));
    expect(back.journal.map((e) => e.op), [setPrompt('a', 'x'), const MoveNode('b', 1, 2)]);
    await store.save(const ClientDurable(id: 'c1', nextCseq: 6, unresolvedFrom: 6));
    expect((await store.load())!.journal, isEmpty);
    expect(File('${dir.path}/c1.json.tmp').existsSync(), isFalse, reason: 'temp file is renamed away');
  });

  test('a corrupt journal is an error, not an empty outbox', () async {
    File('${dir.path}/c1.json').writeAsStringSync('{"v":1,"id":"c1"');
    await expectLater(FileStore('${dir.path}/c1.json').load(), throwsFormatException);
  });

  test('a stale temp file from a crash mid-write is ignored', () async {
    final store = FileStore('${dir.path}/c1.json');
    await store.save(sample);
    File('${dir.path}/c1.json.tmp').writeAsStringSync('{"torn');
    expect((await store.load())!.nextCseq, 5);
    await store.save(sample); // and overwritten by the next save
    expect((await store.load())!.nextCseq, 5);
  });

  test('platform factory gives a file store on the VM', () async {
    final store = createPlatformStore(name: 'x', directory: dir.path);
    await store.save(sample);
    expect(File('${dir.path}/x.json').existsSync(), isTrue);
  });
}
