import 'package:dify_sf_app/src/demo/demo_backend.dart';
import 'package:dify_sf_app/src/editor/editor_controller.dart';
import 'package:dify_sf_app/src/workflow_editor/header/editor_header_binding.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the binding maps the session onto the header: saved time, syncing, graph, checklist, save barrier', () async {
    final demo = DemoBackend(withBo: false);
    final opened = await demo.openSession('demo', clientId: 'me-abc123', journaled: false);
    await opened.session.start();
    final controller = EditorController(session: opened.session, docId: 'demo', journaled: false);
    final store = WorkflowStore();
    final binding = EditorHeaderBinding(controller: controller, store: store);
    addTearDown(() async {
      binding.dispose();
      store.dispose();
      controller.dispose();
      await opened.close();
      await demo.dispose();
    });

    for (var i = 0; i < 50 && !controller.ready; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(controller.ready, isTrue);
    expect(store.draftUpdatedAt.value, isNot(0));
    expect(binding.graph.value.nodes, isNotEmpty);
    expect(binding.graph.value.nodes.length, controller.doc.nodes.length);
    expect(store.checklistItems.value.length, binding.graph.value.checklist.length);

    // An unconnected, unconfigured node shows up in the checklist; the barrier waits for the server's ack.
    final id = controller.addNode('code', x: 0, y: 0);
    final saved = binding.syncWorkflowDraft();
    expect(await saved, isTrue);
    expect(store.isSyncingWorkflowDraft.value, isFalse);
    expect(binding.graph.value.checklist.map((i) => i.id), contains(id));
  });
}
