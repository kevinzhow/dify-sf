import 'package:dify_sf_app/src/demo/demo_backend.dart';
import 'package:dify_sf_app/src/editor/editor_controller.dart';
import 'package:dify_sf_app/src/workflow_editor/header/editor_header_binding.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter_test/flutter_test.dart';

Future<
  ({
    DemoBackend demo,
    EditorController controller,
    WorkflowStore store,
    EditorHeaderBinding binding,
    Future<void> Function() close,
  })
>
open(WidgetTester t) async {
  final demo = DemoBackend(withBo: false);
  final opened = await demo.openSession('demo', clientId: 'sync-feedback', journaled: false);
  final start = opened.session.start();
  for (var i = 0; i < 50 && !opened.session.hasState; i++) {
    await t.pump(const Duration(milliseconds: 20));
  }
  await start;
  final controller = EditorController(session: opened.session, docId: 'demo', journaled: false);
  final store = WorkflowStore();
  final binding = EditorHeaderBinding(controller: controller, store: store);
  Future<void> close() async {
    binding.dispose();
    store.dispose();
    controller.dispose();
    await opened.close();
    await demo.dispose();
  }

  return (demo: demo, controller: controller, store: store, binding: binding, close: close);
}

void main() {
  testWidgets('repeated quick moves are saved without flashing sync feedback', (t) async {
    final f = await open(t);
    try {
      final node = f.controller.addNode('code', x: 0, y: 0);
      await t.pump(const Duration(milliseconds: 300));
      final transitions = <bool>[];
      f.store.isSyncingWorkflowDraft.addListener(() => transitions.add(f.store.isSyncingWorkflowDraft.value));
      for (var i = 1; i <= 10; i++) {
        f.controller.moveNode(node, i * 10, i * 20);
        await t.pump(const Duration(milliseconds: 300));
        expect(f.controller.status.pending, 0);
      }
      expect(transitions, isEmpty);
      expect(f.controller.doc.nodes[node]!.x, 100);
      expect(f.controller.doc.nodes[node]!.y, 200);
      expect(f.demo.server.doc.nodes[node]!.x, 100);
    } finally {
      await f.close();
    }
  });

  testWidgets('slow saves show stable feedback without weakening the save barrier', (t) async {
    final f = await open(t);
    try {
      f.demo.net.minLatency = f.demo.net.maxLatency = const Duration(milliseconds: 800);
      f.controller.addNode('code', x: 0, y: 0);
      var saved = false;
      final barrier = f.binding.syncWorkflowDraft().then((ok) => saved = ok);
      await t.pump(const Duration(milliseconds: 499));
      expect(f.controller.status.pending, greaterThan(0));
      expect(f.store.isSyncingWorkflowDraft.value, isFalse);
      expect(saved, isFalse);
      await t.pump(const Duration(milliseconds: 1));
      expect(f.store.isSyncingWorkflowDraft.value, isTrue);
      expect(saved, isFalse);
      await t.pump(const Duration(seconds: 3));
      await barrier;
      expect(f.controller.status.pending, 0);
      expect(saved, isTrue);
      await t.pump(const Duration(milliseconds: 250));
      expect(f.store.isSyncingWorkflowDraft.value, isFalse);
    } finally {
      await f.close();
    }
  });
}
