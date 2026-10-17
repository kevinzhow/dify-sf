// dify-spec: web/app/components/workflow/operator/__tests__/add-block.spec.tsx
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/workflow_editor/operator/operator.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import 'operator_harness.dart';

const _label = 'common.addBlock';

bool _open(WidgetTester t) => t.widget<OperatorButton>(find.byType(OperatorButton)).active;

Finder _dialog() => find.byWidgetPredicate(
  (w) => w is Semantics && w.properties.role == SemanticsRole.dialog && w.properties.label == _label,
);

void main() {
  group('AddBlock', () {
    late WorkflowStore store;
    setUp(() => store = WorkflowStore());

    testWidgets('opens the real selector and exposes its open state', (t) async {
      await pumpWithStore(t, store, const AddBlock());
      expect(_open(t), isFalse);

      final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: t.getCenter(pressable(_label)));
      await t.pump(const Duration(milliseconds: 400));
      expect(find.descendant(of: find.byType(DifyTipPopupBox), matching: find.text(_label)), findsOneWidget);
      expect(_open(t), isFalse);

      await t.tap(pressable(_label));
      await t.pump();
      await t.pump(const Duration(milliseconds: 200));

      expect(_open(t), isTrue);
      expect(_dialog(), findsOneWidget);
      await mouse.removePointer();
    });

    testWidgets('keeps the disabled trigger focusable without opening the selector', (t) async {
      final semantics = t.ensureSemantics();
      await pumpWithStore(t, store, const AddBlock(disabled: true));

      expect(t.getSemantics(pressable(_label)), isSemantics(isEnabled: false));
      expect(await focusButton(t, _label), isTrue);
      await t.tap(pressable(_label));
      await t.pump();
      await t.pump(const Duration(milliseconds: 200));

      expect(_dialog(), findsNothing);
      semantics.dispose();
    });

    testWidgets('closes the selector through the real trigger and cancels the pane menu', (t) async {
      await pumpWithStore(t, store, const AddBlock());
      store.setContextMenuTarget(WorkflowContextMenuTarget.panel);

      await t.tap(pressable(_label));
      await t.pump();
      await t.pump(const Duration(milliseconds: 200));
      expect(store.contextMenuTarget.value, isNotNull);
      await t.tap(pressable(_label));
      await t.pump();
      await t.pump(const Duration(milliseconds: 200));

      expect(_open(t), isFalse);
      expect(store.contextMenuTarget.value, isNull);
    });
  });
}
