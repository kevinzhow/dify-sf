// dify-spec: web/app/components/workflow/nodes/_base/components/__tests__/remove-effect-var-confirm.spec.tsx
// dify-spec: web/app/components/workflow/nodes/_base/hooks/__tests__/use-toggle-expend.spec.ts
//
// RemoveEffectVarConfirm is showRemoveEffectVarConfirm (core_kit.dart). useToggleExpend is the code editor's expand
// (CodeEditorBase): fixed beside the node panel in a node, filling the overlay elsewhere, the body height from
// toggleExpendEditorHeight.
import 'package:dify_sf_app/src/design/dify_tokens.g.dart';
import 'package:dify_sf_app/src/workflow_editor/code_editor/code_editor.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/core/core_kit.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../dify_test_i18n.dart';

/// A button opening the confirm with the recorded callbacks.
Future<void> _openConfirm(WidgetTester t, {VoidCallback? onConfirm, VoidCallback? onCancel}) async {
  useDifyTestTranslator();
  await t.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showRemoveEffectVarConfirm(context, onConfirm: onConfirm ?? () {}, onCancel: onCancel),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await t.tap(find.text('open'));
  await t.pump();
  await t.pump(const Duration(milliseconds: 300));
}

/// The code editor at the top left, in a node or not, in a window of [size].
Future<void> _renderEditor(WidgetTester t, {required bool isInNode, Size size = const Size(800, 606)}) async {
  useDifyTestTranslator();
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final store = WorkflowStore()..panelWidth.value = 420;
  addTearDown(store.dispose);
  await t.pumpWidget(
    MaterialApp(
      home: Material(
        child: WorkflowStoreScope(
          store: store,
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 300,
              child: CodeEditorBase(
                title: 'Code',
                value: 'x = 1',
                isFocus: false,
                isInNode: isInNode,
                child: const SizedBox.expand(key: Key('editor-body')),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await t.tap(find.bySemanticsLabel('share.chat.expand'));
  await t.pump();
}

/// The expanded editor's frame (`bg-components-panel-bg` with the expanded shadow).
Finder _expandedFrame() => find.byWidgetPredicate(
  (w) =>
      w is Container &&
      w.decoration is BoxDecoration &&
      (w.decoration! as BoxDecoration).color == DifyColors.componentsPanelBg &&
      (w.decoration! as BoxDecoration).boxShadow != null,
);

void main() {
  group('RemoveEffectVarConfirm', () {
    testWidgets('should render title and content when open', (t) async {
      await _openConfirm(t);
      expect(find.text('workflow.common.effectVarConfirm.title'), findsOneWidget);
      expect(find.text('workflow.common.effectVarConfirm.content'), findsOneWidget);
    });

    testWidgets('should call onConfirm when confirm is clicked', (t) async {
      var confirms = 0;
      await _openConfirm(t, onConfirm: () => confirms++);
      await t.tap(find.text('common.operation.confirm'));
      await t.pump();
      expect(confirms, 1);
    });

    testWidgets('should call onCancel when cancel is clicked', (t) async {
      var cancels = 0;
      await _openConfirm(t, onCancel: () => cancels++);
      await t.tap(find.text('common.operation.cancel'));
      await t.pump();
      expect(cancels, 1);
    });
  });

  group('useToggleExpend', () {
    group('expanded state (node context)', () {
      testWidgets('uses fixed positioning inside a workflow node panel', (t) async {
        await _renderEditor(t, isInNode: true);
        // `fixed right-[9px] top-[166px] bottom-[8px] p-4 rounded-xl` with the expanded shadow.
        final frame = t.getRect(_expandedFrame());
        expect(frame.right, 800 - 9);
        expect(frame.top, 166);
        expect(frame.bottom, 606 - 8);
        final box = t.widget<Container>(_expandedFrame()).decoration! as BoxDecoration;
        expect(box.borderRadius, BorderRadius.circular(DifyRadius.xl));
        expect(box.boxShadow, isNotEmpty);
      });
    });

    group('expanded state (execution-log / webapp context)', () {
      testWidgets('fills its positioned ancestor edge-to-edge without hardcoded offsets', (t) async {
        await _renderEditor(t, isInNode: false);
        // `absolute inset-0 pb-4`: the whole overlay it is in.
        expect(t.getRect(_expandedFrame()), const Rect.fromLTWH(0, 0, 800, 606));
      });
    });

    group('expanded state height math', () {
      testWidgets('subtracts the 29px chrome when hasFooter is false', (t) async {
        expect(toggleExpendEditorHeight(400, hasFooter: false), 371);
        // In a node: 606 - 166 - 8 leaves a 400 px wrapper inside the frame's padding; the body (its own 8 px bottom
        // padding included) is 400 - 29.
        await _renderEditor(t, isInNode: true);
        expect(t.getSize(find.byKey(const Key('editor-body'))).height + 8, 371);
      });

      test('subtracts the 56px chrome when hasFooter is true', () {
        expect(toggleExpendEditorHeight(400), 344);
      });

      test('never returns a negative height even if chrome exceeds wrap', () {
        expect(toggleExpendEditorHeight(20), 0);
        expect(toggleExpendEditorHeight(20, hasFooter: false), 0);
      });
    });
  });
}
