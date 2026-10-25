import 'dart:convert';
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/workflow_editor/context_menu/context_menu.dart';
import 'package:flutter_test/flutter_test.dart';
import '../dify_spec/workflow/context_menu/harness.dart';

void main() {
  testWidgets('duplicate sends private source identities only to the atomic endpoint and records one undo', (t) async {
    final source = node('source', type: 'agent', config: {
      'version': const VString('2'), 'agent_node_kind': const VString('dify_agent'),
      'agent_binding': Value.fromJson({'binding_type': 'inline_agent', 'agent_id': 'private-source', 'current_snapshot_id': 'private-snapshot'}),
    });
    final h = await Harness.start(t, [source]);
    var calls = 0;
    Map<String,Object?>? submitted;
    final packages = {'agent_1': {'schema_version': 1, 'soul': {'prompt': {'system_prompt': 'portable prompt'}}}};
    final options = WorkflowMenuOptions(
      exportAgentClipboard: (_) async => {'nodes': [{...difyNodeOf(source), 'data': {'type': 'agent', 'version': '2', 'agent_node_kind': 'dify_agent', 'agent_binding': {'binding_type': 'inline_agent', 'package_ref': 'agent_1'}}}], 'edges': [], 'agent_packages': packages},
      pasteAgentClipboard: (body) async {
        calls++;
        submitted = body;
        final raw = (body['nodes'] as List).single as Map<String,Object?>;
        final n = nodeFromDify({...raw, 'data': {...(raw['data'] as Map), 'agent_binding': {'binding_type': 'inline_agent', 'agent_id': 'new-owned-agent', 'current_snapshot_id': 'new-owned-snapshot'}}}, h.doc, id: raw['id']! as String);
        h.controller.session.edit(AddNode(n));
        return {'node_ids': [n.id], 'edge_ids': <String>[]};
      },
    );
    await h.actions(options).duplicateNodes('source');
    expect(calls, 1);
    expect(h.doc.nodes, hasLength(2));
    expect(h.controller.undo.past, hasLength(1));
    expect(jsonEncode(submitted!['local_sources']), contains('private-snapshot'));
    expect(h.clipboard, isNot(contains('private-snapshot')));
    expect(h.clipboard, contains('agent_packages'));
    h.controller.undo.undo();
    expect(h.doc.nodes, hasLength(1));
    expect(h.doc.nodes.containsKey('source'), true);
    await h.dispose(t);
  });
}
