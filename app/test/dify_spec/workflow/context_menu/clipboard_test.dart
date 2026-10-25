// dify-spec: web/app/components/workflow/utils/__tests__/clipboard.spec.ts
import 'dart:convert';

import 'package:dify_sf_app/src/workflow_editor/context_menu/clipboard.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _version = '0.6.0';
final _nodes = [
  {
    'id': 'node-1',
    'type': 'custom',
    'position': {'x': 0, 'y': 0},
    'data': {'title': 'Node node-1', 'desc': '', 'type': 'code'},
  },
];
final _edges = [
  {'id': 'edge-1', 'source': 'node-1', 'target': 'node-2', 'sourceHandle': 'source', 'targetHandle': 'target'},
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  String? text;
  var fails = false;
  setUp(() {
    text = null;
    fails = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (fails) throw PlatformException(code: 'clipboard denied');
        if (call.method == 'Clipboard.setData') text = (call.arguments as Map)['text'] as String?;
        if (call.method == 'Clipboard.getData') return {'text': text};
        return null;
      },
    );
  });

  void expectEmpty(WorkflowClipboardReadResult r) {
    expect(r.nodes, isEmpty);
    expect(r.edges, isEmpty);
    expect(r.sourceVersion, isNull);
    expect(r.isVersionMismatch, isFalse);
  }

  test('portable Agent packages survive the system clipboard envelope', () async {
    final packages = {'agent_1': {'schema_version': 1, 'soul': {'config_files': [{'name': 'missing.txt', 'is_missing': true}]}}};
    await writeWorkflowClipboard((nodes: _nodes, edges: _edges), _version, agentPackages: packages);
    expect((await readWorkflowClipboard(_version)).agentPackages, packages);
    expect(text, isNot(contains('local_sources')));
  });

  group('workflow clipboard storage', () {
    test('should return empty clipboard data when clipboard text is empty', () async {
      text = '';
      expectEmpty(await readWorkflowClipboard(_version));
    });

    test('should write and read clipboard data', () async {
      final serialized = stringifyWorkflowClipboardData((nodes: _nodes, edges: _edges), _version);
      await writeWorkflowClipboard((nodes: _nodes, edges: _edges), _version);
      expect(text, serialized);
      final r = await readWorkflowClipboard(_version);
      expect(r.nodes, _nodes);
      expect(r.edges, _edges);
      expect(r.sourceVersion, _version);
      expect(r.isVersionMismatch, isFalse);
    });

    test('should allow reading clipboard data with different version', () async {
      text = jsonEncode({'kind': 'dify-workflow-clipboard', 'version': '0.5.0', 'nodes': _nodes, 'edges': _edges});
      final r = await readWorkflowClipboard(_version);
      expect(r.nodes, _nodes);
      expect(r.edges, _edges);
      expect(r.sourceVersion, '0.5.0');
      expect(r.isVersionMismatch, isTrue);
    });

    test('should return empty clipboard data for invalid JSON', () {
      expectEmpty(parseWorkflowClipboardText('{invalid-json', _version));
    });

    test('should return empty clipboard data for invalid structure', () {
      expectEmpty(
        parseWorkflowClipboardText(jsonEncode({'kind': 'unknown', 'version': 1, 'nodes': [], 'edges': []}), _version),
      );
    });

    test('should return empty clipboard data when clipboard read fails', () async {
      fails = true;
      expectEmpty(await readWorkflowClipboard(_version));
    });
  });
}
