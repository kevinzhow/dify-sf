// dify-spec: web/app/components/workflow/__tests__/node-contextmenu.spec.tsx
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  setUp(() => DifyI18n.current = NsKeyTranslator());

  group('NodeContextmenu', () {
    Future<Harness> start(WidgetTester t) async {
      final h = await Harness.start(t, [node('node-1', title: 'Node 1'), node('note', x: 300, rfType: 'custom-note')]);
      await t.pumpWidget(h.app());
      return h;
    }

    testWidgets('should stay hidden when the node menu is absent', (t) async {
      final h = await start(t);
      // Notes have no node menu (handleNodeContextMenu stops there).
      await h.rightClick(t, h.nodePoint('note'));
      expect(h.menuOpen, isFalse);
      expect(h.store.contextMenuTarget.value, isNull);
      await h.dispose(t);
    });

    testWidgets('should stay hidden when the referenced node cannot be found', (t) async {
      final h = await start(t);
      await h.rightClick(t, h.nodePoint('node-1'));
      expect(h.menuOpen, isTrue);
      h.controller.deleteNode('node-1');
      await Harness.settle(t);
      expect(h.menuOpen, isFalse);
      await h.dispose(t);
    });

    testWidgets('should render the node actions and close from content actions', (t) async {
      final h = await start(t);
      await h.rightClick(t, h.nodePoint('node-1'));
      expect(find.text('WORKFLOW.PANEL.ABOUT'), findsOneWidget);
      expect(h.store.contextMenuTarget.value, const NodeContextMenuTarget('node-1'));
      expect(h.controller.selectedNodeId, 'node-1', reason: 'right-clicking a node selects it');
      await h.tapText(t, 'workflow.common.copy');
      expect(h.menuOpen, isFalse);
      expect(h.store.contextMenuTarget.value, isNull);
      expect(h.store.clipboardElements.value.single['id'], 'node-1');
      await h.dispose(t);
    });
  });
}
