// dify-spec: web/app/components/workflow/nodes/human-input/hooks/__tests__/use-config.spec.ts
//
// useConfig over a document: the edits land in the node's data; branch edges are deleted or moved for real. The
// form content helpers and `editorKey` live in the form content editor (human_input_use_form_content_test.dart).
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/human_input/human_input_config.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/node_panel.dart';
import 'package:flutter_test/flutter_test.dart';

import 'human_input_test_kit.dart';

const approve = {'id': 'approve', 'title': 'Approve', 'button_style': 'primary'};

void main() {
  late Harness h;

  HumanInputConfig config() =>
      HumanInputConfig(NodePanelProps(node: h['hi']!, controller: h.controller, actions: h.actions()));

  Future<void> start(WidgetTester t) async {
    final end = difyNode('end', {'type': 'end', 'outputs': <Object?>[]}, x: 800);
    h = await Harness.start(
      t,
      [
        hiNode({
          'user_actions': [approve],
        }),
        end,
      ],
      edges: [edge('hi', 'end', sourceHandle: 'approve')],
    );
  }

  group('human-input/hooks/use-config', () {
    testWidgets('should expose form-content helpers and update delivery methods, timeout, and collapsed state', (
      t,
    ) async {
      await start(t);
      final methods = [
        {'id': 'email', 'type': 'email', 'enabled': true},
      ];
      expect(config().readOnly, isFalse);

      config().deliveryMethodChange(methods);
      await Harness.settle(t);
      config().timeoutChange(12, 'hour');
      await Harness.settle(t);

      expect(dataOf(h, 'hi')['delivery_methods'], methods);
      expect(dataOf(h, 'hi')['timeout'], 12);
      expect(dataOf(h, 'hi')['timeout_unit'], 'hour');
      await h.dispose(t);
    });

    testWidgets('should append and delete user actions while syncing branch-edge cleanup', (t) async {
      await start(t);
      const reject = {'id': 'reject', 'title': 'Reject', 'button_style': 'default'};

      config().userActionAdd(reject);
      await Harness.settle(t);
      expect(dataOf(h, 'hi')['user_actions'], [approve, reject]);

      config().userActionDelete('approve');
      await Harness.settle(t);
      expect(dataOf(h, 'hi')['user_actions'], [reject]);
      expect(h.doc.edges.values.where((e) => e.sourceHandle == 'approve'), isEmpty);
      await h.dispose(t);
    });

    testWidgets('should update user action ids and refresh source handles when the branch key changes', (t) async {
      await start(t);
      const renamed = {'id': 'approved', 'title': 'Approve', 'button_style': 'primary'};

      config().userActionChange(0, renamed);
      await Harness.settle(t);

      expect(dataOf(h, 'hi')['user_actions'], [renamed]);
      final Edge e = h.doc.edges.values.single;
      expect((e.source, e.sourceHandle, e.target), ('hi', 'approved', 'end'));
      await h.dispose(t);
    });
  });
}
