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

  test('journal slots: one live instance per slot, the journal survives release, a free slot is reused', () async {
    final dirs = FileJournalDirectory(dir.path);
    final a = await dirs.acquire('doc1');
    final b = await dirs.acquire('doc1');
    expect(a.description, endsWith('doc1.slot-0.json'));
    expect(
      b.description,
      endsWith('doc1.slot-1.json'),
      reason: 'a second instance must not share the first one\'s journal',
    );
    expect((await dirs.acquire('doc2')).description, endsWith('doc2.slot-0.json'), reason: 'slots are per document');
    await a.save(sample);
    await a.release();
    final again = await dirs.acquire('doc1');
    expect(again.description, endsWith('doc1.slot-0.json'));
    expect((await again.load())!.id, 'c1', reason: 'the restarted instance finds the journal of the one that left');
    await again.release();
    await b.release();
  });

  test('platform factory gives a file store on the VM', () async {
    final store = createPlatformStore(name: 'x', directory: dir.path);
    await store.save(sample);
    expect(File('${dir.path}/x.json').existsSync(), isTrue);
  });
}
