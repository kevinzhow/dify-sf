import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/mcp/workflow_reader.dart';
import 'package:dify_sf_app/src/launch_options.dart';
import 'package:dify_sf_app/src/workflow_editor/header/checklist/use_checklist.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final doc = Document(
    nodes: [
      const Node(id: 'start', type: 'start', title: 'Start'),
      Node(
        id: 'end',
        type: 'end',
        title: 'End',
        config: {
          'outputs': VList([
            VMap({
              'variable': const VString('result'),
              'value_selector': const VList([VString('sys'), VString('workflow_run_id')]),
            }),
          ]),
        },
      ),
    ],
    edges: [const Edge(id: 'e', source: 'start', target: 'end')],
  );
  ReadonlyWorkflowReader reader({List<String> unavailable = const [], int revision = 7}) => ReadonlyWorkflowReader(
    snapshot: (_) async => (seq: revision, doc: doc, mode: 'workflow'),
    context: (_, __, mode) async => (env: ChecklistEnv(appMode: mode), unavailable: unavailable),
  );
  test('native opt-in is absent from browser query and ordinary startup', () {
    expect(LaunchOptions.fromQuery({'mcp-port': '39391'}).mcpPort, isNull);
    expect(LaunchOptions.parse([]).mcpPort, isNull);
    final options = LaunchOptions.parse([
      '--mcp-port',
      '39391',
      '--mcp-token-file',
      '/private/key',
      '--mcp-profile',
      '/private/profile',
    ]);
    expect(options.mcpPort, 39391);
    expect(options.mcpProfile, '/private/profile');
  });
  test('atomic revision accompanies actual graph and variable registers', () async {
    final result = await reader().read('app');
    expect(result['draft_revision'], 7);
    expect((result['nodes'] as List).length, 2);
    expect(result.keys, isNot(contains('access_token')));
  });
  test('mismatched revision cannot produce a valid checklist', () async {
    final result = await reader().read('app', expectedRevision: 6, check: true);
    expect(result['complete'], false);
    expect(result['error'], 'revision_changed');
    expect(result, isNot(contains('items')));
  });
  test('missing catalog never authorizes gate even with no editor warnings', () async {
    final result = await reader(unavailable: ['model_providers']).read('app', check: true);
    expect(result['complete'], false);
    expect(result['gate_passed'], false);
    expect(result['unavailable_context'], ['model_providers']);
    expect(result['warning_count'], isNull);
    expect(result['partial_warning_count'], 0);
  });
  test('items and publish result are the unmodified editor projections', () async {
    final result = await reader().read('app', check: true);
    final env = ChecklistEnv();
    expect(result['items'], [for (final i in computeChecklist(doc, env)) i.toJson()]);
    expect(result['publish_error'], checkBeforePublish(doc, env));
    expect(result['complete'], true);
    expect(result['items'], isEmpty);
    expect(result['gate_passed'], true);
  });
  test('document routing cannot contain paths, query strings or traversal', () async {
    for (final id in ['../x', 'x?secret=1', 'x/y', '']) {
      await expectLater(reader().read(id), throwsFormatException);
    }
  });
}
