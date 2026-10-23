// dify-spec: web/app/components/workflow/__tests__/panel-contextmenu.spec.tsx
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/workflow_editor/context_menu/context_menu.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

const _pane = Offset(500, 150);

void main() {
  setUp(() => DifyI18n.current = KeyEchoTranslator());

  group('PanelContextmenu', () {
    var addNote = 0, run = 0, exported = 0, added = <Offset>[];
    WorkflowMenuOptions options({
      bool chat = false,
      bool canEdit = true,
      bool snippet = false,
      bool comments = false,
    }) => WorkflowMenuOptions(
      isChatMode: chat,
      canEdit: canEdit,
      isSnippetCanvas: snippet,
      commentModeAvailable: comments,
      onAddBlock: added.add,
      onAddNote: () => addNote++,
      onRun: () => run++,
      onExportDsl: () => exported++,
    );
    setUp(() {
      addNote = run = exported = 0;
      added = [];
    });

    Future<Harness> start(WidgetTester t, {WorkflowMenuOptions? o}) async {
      final h = await Harness.start(t, [node('n1', type: 'answer')]);
      await t.pumpWidget(h.app(options: o ?? options()));
      return h;
    }

    testWidgets('should stay hidden when the panel menu is absent', (t) async {
      final h = await start(t);
      expect(find.text('common.addBlock'), findsNothing);
      await h.dispose(t);
    });

    testWidgets('should keep paste disabled when the clipboard is empty', (t) async {
      final h = await start(t);
      await h.rightClick(t, _pane);
      await h.tapText(t, 'common.pasteHere');
      expect(h.doc.nodes, hasLength(1));
      expect(h.menuOpen, isTrue);
      await h.dispose(t);
    });

    testWidgets('should render actions and execute enabled actions', (t) async {
      final h = await start(t);
      h.store.setClipboardData(nodes: [difyNodeOf(node('copied-node'))], edges: const []);
      await h.rightClick(t, _pane);
      expect(find.text('common.addBlock'), findsOneWidget);
      expect(find.text('common.run'), findsOneWidget);
      expect(find.text('common.pasteHere'), findsOneWidget);
      for (final item in [
        'common.addBlock',
        'nodes.note.addNote',
        'common.run',
        'common.pasteHere',
        'export',
        'importApp',
      ]) {
        if (!h.menuOpen) await h.rightClick(t, _pane);
        await h.tapText(t, item);
      }
      expect(added, [_pane]);
      expect(addNote, 1);
      expect(run, 1);
      expect(h.doc.nodes, hasLength(2), reason: 'pasted');
      expect(exported, 1);
      expect(h.store.showImportDSLModal.value, isTrue);
      await h.dispose(t);
    });

    testWidgets('should hide import app on snippet canvases', (t) async {
      final h = await start(t, o: options(snippet: true));
      await h.rightClick(t, _pane);
      expect(find.text('export'), findsOneWidget);
      expect(find.text('importApp'), findsNothing);
      await h.dispose(t);
    });

    testWidgets('should render preview action in chat mode', (t) async {
      final h = await start(t, o: options(chat: true));
      await h.rightClick(t, _pane);
      expect(find.text('common.debugAndPreview'), findsOneWidget);
      expect(find.text('common.run'), findsNothing);
      await h.tapText(t, 'common.debugAndPreview');
      expect(run, 1);
      expect(h.menuOpen, isFalse);
      await h.dispose(t);
    });

    testWidgets('should hide add note but keep comments available when editing is denied', (t) async {
      final h = await start(t, o: options(canEdit: false, comments: true));
      await h.rightClick(t, _pane);
      expect(find.text('comments.actions.addComment'), findsOneWidget);
      expect(find.text('nodes.note.addNote'), findsNothing);
      await h.tapText(t, 'comments.actions.addComment');
      expect(h.store.isCommentPlacing.value && h.store.isCommentQuickAdd.value, isTrue);
      await h.dispose(t);
    });
  });
}
