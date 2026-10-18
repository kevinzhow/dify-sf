@TestOn('vm')
library;

import 'dart:convert';

import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart';
import 'package:collab_client/testing_io.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

const _fast = ClientConfig(streamSilence: 900, reconnectBase: 40, reconnectMax: 300, retransmitAfter: 3000);

Future<void> until(bool Function() cond, {Duration timeout = const Duration(seconds: 10), String? what}) async {
  final end = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(end)) fail('timed out waiting for ${what ?? 'condition'}');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// A small Dify workflow: start -> code -> llm -> end, with references, keyed lists, declared outputs and a secret.
const workflowYaml = r'''
app: {name: Replaced, mode: workflow, icon: x}
kind: app
version: 0.3.1
workflow:
  environment_variables:
  - {id: e1, name: api_key, value: sk-fake-secret-1, value_type: secret}
  - {id: e2, name: region, value: eu, value_type: string}
  conversation_variables: []
  features: {opening_statement: hi}
  graph:
    nodes:
    - id: start
      data: {type: start, title: Start, variables: [{variable: q, type: text-input, label: q}]}
      position: {x: 0, y: 0}
    - id: code
      data:
        type: code
        title: Code
        code: 'def main(q): return {"result": q}'
        outputs: {result: {type: string}}
        variables: [{variable: q, value_selector: [start, q]}]
      position: {x: 300, y: 0}
    - id: llm
      data:
        type: llm
        title: LLM
        prompt_template: [{id: p1, role: user, text: 'Say {{#code.result#}}'}]
        context: {enabled: true, variable_selector: [code, result]}
      position: {x: 600.5, y: 0}
    - id: end
      data: {type: end, title: End, outputs: [{variable: out, value_selector: [llm, text]}]}
      position: {x: 900, y: 0}
    edges:
    - {id: start-source-code-target, source: start, target: code, sourceHandle: source, targetHandle: target}
    - {id: code-source-llm-target, source: code, target: llm, sourceHandle: source, targetHandle: target}
    - {id: llm-source-end-target, source: llm, target: end, sourceHandle: source, targetHandle: target}
''';

Matcher _status(int status, [String? code]) => isA<TransportException>()
    .having((e) => e.statusCode, 'statusCode', status)
    .having((e) => e.code, 'code', code ?? anything);

void main() {
  late HttpFakeServer srv;
  late FakeAccounts accounts;
  final sessions = <CollabSession>[];

  setUp(() async {
    accounts = FakeAccounts();
    srv = await HttpFakeServer.start(pingInterval: const Duration(milliseconds: 300), accounts: accounts);
    srv.doc('d', template: 'empty');
  });
  tearDown(() async {
    for (final s in sessions) {
      await s.stop();
    }
    sessions.clear();
    await srv.close();
  });

  Future<AuthSession> signIn(String email, {String role = AccountRole.editor, String name = 'User'}) async {
    if (accounts.byEmail(email) == null) accounts.addMember(email: email, name: name, role: role);
    final auth = AuthSession(api: HttpAuthApi(srv.url), store: MemoryTokenStore(), server: '${srv.url}');
    await auth.login(email: email, password: 'password-1');
    return auth;
  }

  Future<CollabSession> connect(AuthSession auth) async {
    final s = CollabSession(
      transport: HttpTransport(baseUrl: srv.url, docId: 'd', auth: auth),
      journaled: false,
      config: _fast,
      tickInterval: const Duration(milliseconds: 25),
      postTimeout: const Duration(milliseconds: 500),
    );
    sessions.add(s);
    await s.start();
    await s.settled().timeout(const Duration(seconds: 10));
    return s;
  }

  test('DocsApi.replaceDocument: ops of the caller, the file imported, retries replayed, the cseq contract', () async {
    final owner = await signIn('o@example.com', role: AccountRole.owner, name: 'Olivia');
    final docs = DocsApi(srv.url, auth: owner);
    addTearDown(docs.close);
    final client = await docs.issueClientId('d');

    final r = await docs.replaceDocument('d', workflowYaml, client, cseq: 1);
    expect(r.ops, greaterThan(4));
    expect((r.head, r.nextCseq, r.nodes, r.edges, r.replayed), (r.ops, r.ops + 1, 4, 3, false));
    expect(
      (r.status, r.hasWarnings, r.importedDslVersion, r.currentDslVersion),
      (
        'completed-with-warnings',
        true,
        '0.3.1',
        '0.7.0',
      ),
    );
    expect(r.renamedNodes, isEmpty);
    final fake = srv.doc('d');
    expect(fake.log.map((e) => e.client).toSet(), {client});
    expect(fake.log.map((e) => e.cseq), [for (var c = 1; c <= r.ops; c++) c]);
    // The document is the file, as the reference server imports it.
    final snap = await docs.snapshot('d');
    final d = snap.doc;
    expect(d.nodes.keys.toSet(), {'start', 'code', 'llm', 'end'});
    expect(d.nodes['start']!.x, 0); // the template's start node was kept and moved
    expect(
      d.nodes['llm']!.config['context'],
      const VMap({'enabled': VBool(true), 'variable_selector': VRef(OutputRef('code', 'result'))}),
    );
    expect(
      d.nodes['llm']!.config['_dify_node'],
      const VMap({
        'position': VMap({'x': VDouble(600.5), 'y': VInt(0)}),
      }),
    );
    expect((d.nodes['code']!.config['outputs']! as VItems).items.single.id, 'result');
    expect((d.nodes['end']!.config['outputs']! as VItems).items.single.id, 'out');
    expect(d.edges.keys.toSet(), {'start-source-code-target', 'code-source-llm-target', 'llm-source-end-target'});
    final env = AppRegisters.variables(d, AppRegisters.environmentVariables);
    expect(env.first['value'], AppRegisters.maskSecret('sk-fake-secret-1'));
    expect(fake.secrets[env.first[AppRegisters.secretRef]], 'sk-fake-secret-1');
    expect(jsonEncode(d.toJson()), isNot(contains('sk-fake-secret-1')));
    expect(AppRegisters.featuresOf(d), {'opening_statement': 'hi'});
    expect((await docs.meta('d')).appName, 'Replaced');

    // A retry is the earlier success; the same file again writes nothing; a cseq ahead is refused.
    final again = await docs.replaceDocument('d', workflowYaml, client, cseq: 1);
    expect((again.replayed, again.ops, again.nextCseq, again.head), (true, r.ops, r.nextCseq, r.head));
    final same = await docs.replaceDocument('d', workflowYaml, client, cseq: r.nextCseq);
    expect((same.ops, same.nextCseq, fake.head), (0, r.nextCseq, r.head));
    await expectLater(
      docs.replaceDocument('d', workflowYaml, client, cseq: r.nextCseq + 2),
      throwsA(_status(409, 'outstanding_ops')),
    );

    // Someone deletes the LLM node; the file brings it back under a fresh id, references and edges follow.
    fake.submit(
      SubmitRequest(
        client: 'other',
        ops: [OutgoingOp(cseq: 1, base: fake.head, op: const RemoveNode('llm'))],
      ),
    );
    final back = await docs.replaceDocument('d', workflowYaml, client, cseq: r.nextCseq);
    final fresh = back.renamedNodes['llm']!;
    expect(int.tryParse(fresh), isNotNull);
    expect(back.renamedEdges, {
      'code-source-llm-target': 'code-source-$fresh-target',
      'llm-source-end-target': '$fresh-source-end-target',
    });
    final after = (await docs.snapshot('d')).doc;
    expect(after.nodes[fresh]!.type, 'llm');
    final out = (after.nodes['end']!.config['outputs']! as VItems).items.single.value as VMap;
    expect(out.entries['value_selector'], VRef(OutputRef(fresh, 'text')));
    expect(after.integrityProblems, isEmpty);
  });

  test('refusals: Dify messages, the version confirmation, the mode, accounts', () async {
    final owner = await signIn('o@example.com', role: AccountRole.owner, name: 'Olivia');
    final bob = await signIn('b@example.com', name: 'Bob');
    final nora = await signIn('n@example.com', role: AccountRole.normal, name: 'Nora');
    final docs = DocsApi(srv.url, auth: owner);
    addTearDown(docs.close);
    final client = await docs.issueClientId('d');
    await expectLater(docs.replaceDocument('d', '- a', client, cseq: 1), throwsA(_status(400, 'bad_request')));
    await expectLater(
      docs.replaceDocument('d', 'version: 0.3.1\nworkflow: {}', client, cseq: 1),
      throwsA(isA<TransportException>().having((e) => e.message, 'message', 'Missing app data in YAML content')),
    );
    // The app keeps its mode: a chatflow's answer node does not fit this workflow.
    final chat = workflowYaml
        .replaceFirst('mode: workflow', 'mode: advanced-chat')
        .replaceFirst('type: end', 'type: answer');
    await expectLater(
      docs.replaceDocument('d', chat, client, cseq: 1),
      throwsA(isA<TransportException>().having((e) => e.message, 'message', startsWith('Import Failed'))),
    );
    // A newer DSL version needs the user's confirmation.
    final newer = workflowYaml.replaceFirst('version: 0.3.1', 'version: 0.9.0');
    await expectLater(
      docs.replaceDocument('d', newer, client, cseq: 1),
      throwsA(
        isA<DslVersionUnconfirmed>()
            .having((e) => e.importedVersion, 'imported', '0.9.0')
            .having((e) => e.currentVersion, 'current', '0.7.0'),
      ),
    );
    expect((await docs.replaceDocument('d', newer, client, cseq: 1, confirm: true)).status, 'pending');
    // Accounts: someone else's client id is 403, a read-only member is 403, no token is 401.
    final bobDocs = DocsApi(srv.url, auth: bob);
    final noraDocs = DocsApi(srv.url, auth: nora);
    final anonymous = DocsApi(srv.url);
    addTearDown(bobDocs.close);
    addTearDown(noraDocs.close);
    addTearDown(anonymous.close);
    await expectLater(bobDocs.replaceDocument('d', workflowYaml, client, cseq: 1), throwsA(_status(403, 'forbidden')));
    await expectLater(noraDocs.replaceDocument('d', workflowYaml, 'n-1', cseq: 1), throwsA(_status(403, 'forbidden')));
    await expectLater(anonymous.replaceDocument('d', workflowYaml, 'x', cseq: 1), throwsA(_status(401)));
    final res = await http.post(srv.url.replace(path: '/v1/docs/d/replace'), body: workflowYaml);
    expect(res.statusCode, 401);
  });

  test('CollabSession.replaceDocument: waits for local ops, reserves the cseqs, others conflict with it', () async {
    final olivia = await signIn('o@example.com', role: AccountRole.owner, name: 'Olivia');
    final bob = await signIn('b@example.com', name: 'Bob');
    final docs = DocsApi(srv.url, auth: olivia);
    addTearDown(docs.close);
    final a = await connect(olivia);
    final b = await connect(bob);
    final seenByBob = b.lastSeq;

    // An edit still in flight: the replacement waits for it; edits made meanwhile are refused locally.
    a.edit(const SetField('start', TitleKey(), VString('Mine')));
    final replacing = a.replaceDocument((id, cseq) => docs.replaceDocument('d', workflowYaml, id, cseq: cseq));
    expect(a.edit(const SetField('start', TitleKey(), VString('Again'))).refusal, isA<Invalid>());
    final r = await replacing;
    expect(r.ops, greaterThan(4));
    expect(a.lastSeq, r.head); // the stream has delivered it
    expect(a.view.nodes.keys.toSet(), {'start', 'code', 'llm', 'end'});
    expect(a.view.nodes['start']!.title, 'Start'); // the file's title won over the earlier edit
    expect(a.machine.nextCseq, r.nextCseq);
    final committed = srv.doc('d').log.where((e) => e.client == a.clientId).map((e) => e.cseq).toList();
    expect(committed, [for (var c = 1; c < r.nextCseq; c++) c]);

    // The session goes on with the next cseq (no clientIdInUse, the same id).
    final id = a.clientId;
    a.edit(const SetField('llm', TitleKey(), VString('Answer')));
    await a.settled();
    expect(a.clientId, id);
    expect(srv.doc('d').log.last.cseq, r.nextCseq);

    // Bob sees the replacement as ordinary commits; a write based on what he saw before it conflicts, naming Olivia.
    await until(() => b.lastSeq == srv.doc('d').head, what: 'bob catches up');
    expect(b.view.nodes['llm']!.title, 'Answer');
    final stale = b.edit(const SetField('start', TitleKey(), VString('Bob')), base: seenByBob);
    expect(stale.refusal, isA<Conflict>().having((c) => c.by, 'by', id));
  });

  test('the in-memory server: FakeServer.replace and FakeDifyDsl', () {
    final server = FakeServer(initial: Templates.empty());
    final r = server.replace(client: 'c', cseq: 1, root: FakeDifyDsl.parseYaml(workflowYaml));
    expect(r['nodes'], 4);
    expect(server.head, r['ops']);
    expect(server.appMode, 'workflow');
    expect(server.difyApp!['name'], 'Replaced');
    // The plan reaches the file exactly; replaying it on the old state with the same base is valid op by op.
    final plan = FakeDifyDsl.planReplacement(
      FakeDifyDsl.parseYaml(workflowYaml),
      current: Templates.empty(),
      storedSecrets: const {},
      client: 'c',
      base: 0,
      newSecretRef: () => 'sec-x',
    );
    final d = Templates.empty();
    for (final (i, op) in plan.ops.indexed) {
      expect(d.validate(op, base: 0, client: 'c'), isNull, reason: '$op');
      d.apply(op, Stamp(i + 1, 'c'));
    }
    expect(FakeReplacement.difference(d, plan.document), isNull);
    expect(FakeDifyDsl.versionStatus('0.7.0'), 'completed');
    expect(FakeDifyDsl.versionStatus('1.0.0'), 'pending');
    expect(FakeDifyDsl.versionStatus('x'), 'failed');
    expect(server.replace(client: 'c', cseq: 1, root: FakeDifyDsl.parseYaml(workflowYaml))['replayed'], isTrue);
    expect(
      () => server.replace(client: 'c', cseq: 99, root: FakeDifyDsl.parseYaml(workflowYaml)),
      throwsA(isA<FakeReplaceError>().having((e) => e.code, 'code', 'outstanding_ops')),
    );
    expect(
      () => server.replace(client: 'c', cseq: 1, root: FakeDifyDsl.parseYaml('app: {name: x}')),
      throwsA(isA<FakeReplaceError>().having((e) => e.message, 'message', 'loss app mode')),
    );
  });
}
