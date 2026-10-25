import 'dart:async';
import 'dart:convert';
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/agents/inline_composer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'inline_composer_test.dart' show ComposerApi, document;

class ClipboardApi extends ComposerApi implements AgentClipboardApi {
  final sent = <String>[];
  int writes = 0;
  void Function()? committed;
  @override
  Future<Map<String, Object?>> exportAgentClipboard(String app, Map<String, Object?> body) async => {'agent_packages': <String,Object?>{}, 'nodes': [], 'edges': []};
  @override
  Future<Map<String, Object?>> pasteAgentClipboard(String app, Map<String, Object?> body) async {
    sent.add(jsonEncode(body));
    committed?.call();
    if (writes++ == 0) throw const TransportException('reply lost', timeout: true);
    return {'document_seq': 9, 'node_ids': ['confirmed-node'], 'edge_ids': <String>[]};
  }
}
void main() {
  test('uncertain atomic paste retries the same IDs and receipt without submitting duplicate graph ops', () async {
    final api = ClipboardApi();
    final changes = StreamController<void>.broadcast(sync: true);
    addTearDown(changes.close);
    AgentDocumentState current = (document: document(), seq: 3, ready: true);
    final composer = InlineAgentComposer(api: api, appId: 'app', state: () => current, changes: changes.stream,
      waitTimeout: const Duration(milliseconds: 50));
    api.committed = () { current = (document: document(), seq: 9, ready: true); changes.add(null); };
    final graph = {'nodes': [{'id': 'confirmed-node'}], 'edges': [], 'agent_packages': {}, 'id_mapping': {}};
    await expectLater(composer.pasteClipboard(graph), throwsA(isA<TransportException>()));
    await expectLater(composer.pasteClipboard({...graph, 'nodes': [{'id': 'must-not-be-submitted'}]}),
      throwsA(isA<AgentComposerConflict>()));
    expect(api.sent, hasLength(1));
    final saved = await composer.pasteClipboard(graph);
    expect(saved['node_ids'], ['confirmed-node']);
    expect(api.sent, hasLength(2));
    expect(api.sent[0], api.sent[1]);
    expect(api.sent[1], isNot(contains('must-not-be-submitted')));
    expect(changes.hasListener, false);
  });
}
