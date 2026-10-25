import 'dart:async';
import 'dart:convert';

import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/agents/inline_composer.dart';
import 'package:flutter_test/flutter_test.dart';

const binding = {'binding_type': 'inline_agent', 'agent_id': 'private-agent', 'current_snapshot_id': 's1'};
const soul = {
  'schema_version': 1,
  'prompt': {'system_prompt': 'Original private prompt'},
};
Map<String, Object?> composerReply({int seq = 3, Object? selected = binding}) => {
  'document_seq': seq,
  'binding': selected,
  'agent_soul': soul,
  'node_job': {'workflow_prompt': 'Old task', 'declared_outputs': []},
};
Document document({String task = 'Current collaborator task', Object? selected = binding}) => Document(
  nodes: [
    Node(
      id: 'node',
      type: 'agent',
      title: 'Agent',
      config: {
        'agent_binding': Value.fromJson(selected),
        'agent_task': VString(task),
        'agent_declared_outputs': const VList([]),
      },
    ),
  ],
);

class ComposerApi implements AgentComposerApi {
  Map<String, Object?> response = composerReply();
  Future<Map<String, Object?>> Function(Map<String, Object?>)? write;
  final requests = <String>[];
  @override
  Future<Map<String, Object?>> readInlineAgent(String app, String node, {String? snapshotId, String? agentId}) async =>
      response;
  @override
  Future<Map<String, Object?>> saveInlineAgent(String app, String node, Map<String, Object?> body) async {
    requests.add(jsonEncode(body));
    return await write!(body);
  }
}

class Fixture {
  final api = ComposerApi();
  final changes = StreamController<void>.broadcast(sync: true);
  AgentDocumentState current = (document: document(), seq: 3, ready: true);
  late final client = InlineAgentComposer(
    api: api,
    appId: 'app',
    state: () => current,
    changes: changes.stream,
    waitTimeout: const Duration(milliseconds: 30),
  );
  void change(AgentDocumentState value) {
    current = value;
    changes.add(null);
  }
}

void main() {
  test('private save preserves the latest shared task and declares an immutable receipt', () async {
    final f = Fixture();
    addTearDown(f.changes.close);
    final loaded = await f.client.load('node');
    f.change((document: document(task: 'Changed by another member'), seq: 7, ready: true));
    final mutable = <String, Object?>{...soul};
    final payload = await f.client.prepare('node', loaded, mutable);
    mutable['prompt'] = {'system_prompt': 'Typed later'};
    expect((payload['node_job'] as Map)['workflow_prompt'], 'Changed by another member');
    expect(payload['expected_seq'], 7);
    expect((payload['expected_node'] as Map)['agent_task'], 'Changed by another member');
    expect((payload['agent_soul'] as Map)['prompt'], soul['prompt']);
    expect(
      payload['idempotency_key'],
      matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')),
    );
  });
  test('another private binding change is rejected before sending', () async {
    final f = Fixture();
    addTearDown(f.changes.close);
    final loaded = await f.client.load('node');
    f.change((document: document(selected: {...binding, 'current_snapshot_id': 'other-member'}), seq: 6, ready: true));
    await expectLater(f.client.prepare('node', loaded, soul), throwsA(isA<AgentComposerConflict>()));
    expect(f.api.requests, isEmpty);
  });
  test('save waits for actual collaborative delivery and does not submit graph operations', () async {
    final f = Fixture();
    addTearDown(f.changes.close);
    final loaded = await f.client.load('node');
    final next = {...binding, 'current_snapshot_id': 's2'};
    f.api.write = (_) async => composerReply(seq: 6, selected: next);
    var finished = false;
    final pending = f.client.save('node', await f.client.prepare('node', loaded, soul)).then((v) {
      finished = true;
      return v;
    });
    await Future<void>.delayed(Duration.zero);
    expect(finished, false);
    f.change((document: document(selected: next), seq: 6, ready: true));
    expect((await pending)['binding'], next);
    expect(f.changes.hasListener, false);
  });
  test('timed out stream wait releases its subscription', () async {
    final f = Fixture();
    addTearDown(f.changes.close);
    f.api.response = composerReply(seq: 9);
    await expectLater(f.client.load('node'), throwsA(isA<TimeoutException>()));
    expect(f.changes.hasListener, false);
  });
  test('lost create response retries the identical payload even when the committed binding is now visible', () async {
    final f = Fixture();
    addTearDown(f.changes.close);
    f.current = (document: document(selected: null), seq: 0, ready: true);
    f.api.response = composerReply(seq: 0, selected: null);
    var count = 0;
    f.api.write = (_) async {
      f.change((document: document(), seq: 3, ready: true));
      if (count++ == 0) throw const TransportException('outcome unknown', timeout: true);
      return composerReply();
    };
    await expectLater(f.client.create('node'), throwsA(isA<TransportException>()));
    expect((await f.client.create('node'))['binding'], binding);
    expect(f.api.requests, hasLength(2));
    expect(f.api.requests[0], f.api.requests[1]);
  });
  test('pending local edits must be confirmed before CAS takes its head', () async {
    final f = Fixture();
    addTearDown(f.changes.close);
    f.current = (document: document(), seq: 3, ready: false);
    var finished = false;
    final prepared = f.client.prepare('node', composerReply(), soul).then((v) {
      finished = true;
      return v;
    });
    await Future<void>.delayed(Duration.zero);
    expect(finished, false);
    f.change((document: document(task: 'Confirmed local task'), seq: 4, ready: true));
    final payload = await prepared;
    expect(payload['expected_seq'], 4);
    expect((payload['node_job'] as Map)['workflow_prompt'], 'Confirmed local task');
  });
}
