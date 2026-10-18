/// Protocol 1.8: a `POST /ops` refused with `403 forbidden` (a read-only role, e.g. after a role change mid-session) is
/// final for the outstanding ops: they are finished as rejected with the local reason `forbidden` (not saved, gone from
/// the journal), nothing is retried, new edits are refused locally, and sending resumes only after `allowEdits`.
library;

import 'dart:convert';

import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart';
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';

import 'support/helpers.dart';

/// A machine with the document at seq 0 and a live stream.
ClientMachine _synced({String id = 'c'}) {
  final m = ClientMachine(id: id);
  final open = (m.tick(0).single as OpenStreamAction).open;
  m.receiveStream(SnapshotEvent(seq: 0, doc: baseDoc()), open.generation, 0);
  m.receiveStream(const ReadyEvent(0), open.generation, 0);
  return m;
}

SubmitRequest _submit(List<ClientRequest> rs) => rs.whereType<SubmitRequestAction>().single.request;

StreamOpen _reopen(List<ClientRequest> rs) => rs.whereType<OpenStreamAction>().single.open;

/// A transport that counts the POSTs the session sends (refused ones too).
class _CountingTransport extends FakeTransport {
  _CountingTransport(super.server, {super.auth});
  int submits = 0;
  @override
  Future<SubmitResponse> submit(SubmitRequest request, {required Duration timeout}) {
    submits++;
    return super.submit(request, timeout: timeout);
  }
}

void main() {
  test('forbidden is a local reason: distinct, not stale-based, round-trips', () {
    final r = RejectReason.fromJson(jsonDecode('{"type":"forbidden"}'));
    expect(r, const Forbidden());
    expect(r.name, 'forbidden');
    expect(r.isStaleBased, isFalse);
    expect(RejectReason.fromJson(r.toJson()), r);
  });

  group('machine', () {
    test('a 403 rejects the outstanding ops once (after the reopened stream is ready), sends nothing more, '
        'clears the journal; allowEdits resumes with a floor', () {
      final m = _synced();
      final first = _submit(m.edit(setPrompt('a', 'one'), 1).requests);
      expect(first.ops.map((o) => o.cseq), [1]);
      expect(m.edit(setPrompt('b', 'two'), 2).requests, isEmpty, reason: 'one POST at a time');
      expect(cfg(m.view, 'a', 'prompt'), 'one');

      final reopen = _reopen(m.submitForbidden(3));
      expect(m.drainEvents(), [isA<EditingForbidden>()], reason: 'announced at once; the verdicts wait for the stream');
      expect(m.editsForbidden, isTrue);
      // No retry loop: however much time passes, no POST.
      for (var t = 4; t < 120000; t += 500) {
        expect(m.tick(t).whereType<SubmitRequestAction>(), isEmpty);
      }
      expect(m.networkAvailable(120000).whereType<SubmitRequestAction>(), isEmpty);
      // New edits are refused locally.
      final refused = m.edit(setPrompt('a', 'three'), 120001);
      expect((refused.cseq, refused.refusal), (null, const Forbidden()));
      expect(m.drainEvents().single, isA<LocalInvalid>().having((e) => e.reason, 'reason', const Forbidden()));

      // The stream opened after the refusal (networkAvailable reopened it once more) catches up: nothing of ours was
      // committed, so both ops are finished as rejected(forbidden), in cseq order, once.
      final gen = m.generation;
      expect(gen, greaterThan(reopen.generation));
      m.receiveStream(const ReadyEvent(0), gen, 120002);
      final events = m.drainEvents();
      expect(events, hasLength(2));
      expect(
        events.map((e) => (e as OpRejected).cseq),
        [1, 2],
      );
      expect(events.map((e) => (e as OpRejected).reason), everyElement(const Forbidden()));
      expect(m.unresolvedCount, 0);
      expect(m.durable.journal, isEmpty, reason: 'a restart must not resend them');
      expect(m.durable.unresolvedFrom, 3);
      expect(cfg(m.view, 'a', 'prompt'), isNull, reason: 'not saved: gone from the view');
      m.receiveStream(const ReadyEvent(0), gen, 120003);
      expect(m.drainEvents(), isEmpty, reason: 'reported once');

      // Allowed again: a floor goes out at once (the server never handled cseqs 1 and 2), then edits flow.
      final floor = _submit(m.allowEdits(130000));
      expect((floor.floor, floor.ops.length, floor.resolveFrom), (3, 0, null));
      expect(m.editsForbidden, isFalse);
      m.receiveResponse(const SubmitResponse(head: 0, high: 2, results: []), 130001);
      final next = _submit(m.edit(setPrompt('a', 'four'), 130002).requests);
      expect((next.floor, next.ops.single.cseq), (null, 3));
    });

    test('an op whose earlier copy was committed before the refusal is reported committed, not rejected', () {
      final m = _synced();
      m.edit(setPrompt('a', 'one'), 1);
      m.submitFailed(2); // timed out: the server may have committed it
      expect(_submit(m.tick(5000)).ops.single.cseq, 1, reason: 'resent');
      final open = _reopen(m.submitForbidden(5001));
      m.receiveStream(
        CommitEvent(LogEntry(seq: 1, client: 'c', cseq: 1, base: 0, op: setPrompt('a', 'one'))),
        open.generation,
        5002,
      );
      m.receiveStream(const ReadyEvent(1), open.generation, 5003);
      final events = m.drainEvents();
      expect(events.whereType<OpRejected>(), isEmpty);
      expect(events.whereType<OpCommitted>().single.seq, 1);
      expect(m.durable.journal, isEmpty);
    });

    test('allowEdits before the stream caught up simply sends the ops again', () {
      final m = _synced();
      m.edit(setPrompt('a', 'one'), 1);
      m.submitForbidden(2);
      m.drainEvents();
      final again = _submit(m.allowEdits(3));
      expect((again.floor, again.ops.single.cseq), (null, 1), reason: 'nothing was finished locally: no floor');
      m.receiveStream(const ReadyEvent(0), m.generation, 4);
      expect(m.drainEvents(), isEmpty, reason: 'no late forbidden verdict');
    });

    test('a restart before the floor got through: the server answers gap, the next POST carries the floor', () {
      // The journal after the refusal: cseqs 1 and 2 finished locally, never handled by the server.
      final m = ClientMachine.restore(const ClientDurable(id: 'c', nextCseq: 3, unresolvedFrom: 3, journal: []));
      final open = (m.tick(0).single as OpenStreamAction).open;
      m.receiveStream(SnapshotEvent(seq: 0, doc: baseDoc()), open.generation, 0);
      m.receiveStream(const ReadyEvent(0), open.generation, 0);
      final first = _submit(m.edit(setPrompt('a', 'x'), 1).requests);
      expect((first.floor, first.ops.single.cseq), (null, 3));
      final healed = _submit(
        m.receiveResponse(const SubmitResponse(head: 0, high: 0, results: [GapResult(3, 1)]), 2),
      );
      expect((healed.floor, healed.ops.single.cseq), (3, 3));
      // Against the in-memory server: the floor makes it skip 1 and 2 and commit 3.
      final server = FakeServer(initial: baseDoc());
      expect(server.submit(first).results.single, isA<GapResult>());
      final r = server.submit(healed);
      expect(r.results.single, isA<AckResult>());
      m.receiveResponse(r, 3);
      expect(m.debug.last, contains('floor=null'));
    });
  });

  group('session against the in-memory server with accounts', () {
    test('role downgraded mid-session: one refusal, no retries, rejected(forbidden), journal cleared; '
        'promoted back: allowEdits resumes', () {
      fakeAsync((async) {
        final accounts = FakeAccounts();
        accounts
          ..addMember(email: 'o@example.com', name: 'Olivia')
          ..addMember(email: 'e@example.com', name: 'Ed', role: AccountRole.editor);
        final server = FakeServer(initial: baseDoc(), accounts: accounts);
        final ed = AuthSession(api: FakeAuthApi(accounts));
        ed.login(email: 'e@example.com', password: 'password-1');
        async.flushMicrotasks();
        final transport = _CountingTransport(server, auth: ed);
        final store = MemoryStore();
        final session = CollabSession(transport: transport, store: store, clock: () => async.elapsed.inMilliseconds);
        final events = <ClientEvent>[];
        session.events.listen(events.add);
        session.start();
        async.elapse(const Duration(seconds: 2));
        session.edit(setPrompt('a', 'saved'));
        async.elapse(const Duration(seconds: 2));
        expect(server.head, 1);
        expect(events.whereType<OpCommitted>(), hasLength(1));

        // An admin makes Ed a normal member; Ed keeps typing.
        accounts.byEmail('e@example.com')!.role = AccountRole.normal;
        final posts = transport.submits;
        session.edit(setPrompt('a', 'mine 1'));
        session.edit(setPrompt('b', 'mine 2'));
        async.elapse(const Duration(seconds: 3));
        expect(events.whereType<EditingForbidden>(), hasLength(1));
        final rejected = events.whereType<OpRejected>().toList();
        expect(rejected.map((e) => (e.cseq, e.reason)), [(2, const Forbidden()), (3, const Forbidden())]);
        expect(session.editsForbidden, isTrue);
        expect(session.pending, isEmpty);
        expect(cfg(session.view, 'a', 'prompt'), 'saved');
        expect(store.saved!.journal, isEmpty);
        expect(store.saved!.unresolvedFrom, 4);
        expect(session.status.lastError, contains('403'));
        final refusedPosts = transport.submits - posts;
        expect(refusedPosts, inInclusiveRange(1, 2), reason: 'the refused batch (or the two ops, sent one by one)');
        // Minutes later: still no retry, and an edit is refused locally.
        async.elapse(const Duration(minutes: 3));
        expect(transport.submits - posts, refusedPosts);
        expect(session.edit(setPrompt('a', 'more')).refusal, const Forbidden());
        expect(events.whereType<EditingForbidden>(), hasLength(1));
        expect(server.head, 1);

        // Promoted back: the app re-read the account and allows edits again.
        accounts.byEmail('e@example.com')!.role = AccountRole.editor;
        session.allowEdits();
        async.elapse(const Duration(seconds: 2));
        final t = session.edit(setPrompt('a', 'back'));
        expect(t.cseq, 4);
        async.elapse(const Duration(seconds: 2));
        expect(server.head, 2);
        expect(server.log.last.cseq, 4);
        expect(cfg(server.doc, 'a', 'prompt'), 'back');
        expect(events.whereType<OpCommitted>().last.cseq, 4);
        session.stop();
        async.flushMicrotasks();
      });
    });
  });
}
