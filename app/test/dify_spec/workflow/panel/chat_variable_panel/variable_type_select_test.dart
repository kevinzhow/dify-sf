// dify-spec: web/app/components/workflow/panel/chat-variable-panel/components/__tests__/variable-type-select.spec.tsx
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:dify_sf_app/src/workflow_editor/variable_panels/chat_variable_values.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../harness.dart';

void main() {
  setUp(useDifyTestTranslator);

  Future<void> render(WidgetTester t, Widget w) async {
    final store = WorkflowStore();
    addTearDown(store.dispose);
    await pumpPanel(
      t,
      SizedBox(
        width: 327,
        child: Align(alignment: Alignment.topCenter, child: w),
      ),
      store: store,
    );
  }

  group('VariableTypeSelector', () {
    testWidgets('opens the selector and applies a new type', (t) async {
      final selected = <String>[];
      await render(
        t,
        VariableTypeSelector(value: 'string', list: const ['string', 'number', 'boolean'], onSelect: selected.add),
      );

      await tap(t, find.text('string'));
      await tap(t, find.text('number'));

      expect(selected, ['number']);
    });

    testWidgets('dismisses the popup through the real portal flow', (t) async {
      await render(t, VariableTypeSelector(value: 'string', list: const ['string', 'number'], onSelect: (_) {}));

      await tap(t, find.text('string'));
      expect(find.text('number'), findsOneWidget);

      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(t);

      expect(find.text('number'), findsNothing);
      expect(find.byType(DifyMenuPopup), findsNothing);
    });

    testWidgets('keeps the custom popup class in in-cell mode', (t) async {
      await render(
        t,
        SizedBox(
          width: 96,
          child: VariableTypeSelector(
            inCell: true,
            value: 'string',
            list: const ['string', 'number'],
            popupWidth: 120,
            onSelect: (_) {},
          ),
        ),
      );

      await tap(t, find.text('string').first);

      expect(t.widget<DifyMenuPopup>(find.byType(DifyMenuPopup)).width, 120);
    });
  });
}
