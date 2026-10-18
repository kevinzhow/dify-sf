// dify-spec: web/app/components/workflow/variable-inspect/__tests__/index.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/node_panel/resize_handle.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:dify_sf_app/src/workflow_editor/variable_inspect/panel.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'inspect_harness.dart';

const _key = 'workflow-variable-inpsect-panel-height';

void main() {
  setUp(() {
    useDifyTestTranslator();
    SharedPreferences.setMockInitialValues({});
  });

  group('variable inspect index', () {
    late InspectHarness h;
    late WorkflowPreferences preferences;

    Future<void> render(WidgetTester t) async {
      h = InspectHarness();
      h.store
        ..setShowVariableInspectPanel(true)
        ..setVariableInspectPanelHeight(200)
        ..setWorkflowCanvasHeight(500);
      preferences = WorkflowPreferences();
      addTearDown(preferences.dispose);
      await h.pump(t, const VariableInspectPanel(), height: 700, preferences: preferences);
      await t.runAsync(() => preferences.loaded);
    }

    ResizeHandle handle(WidgetTester t) => t.widget<ResizeHandle>(find.byType(ResizeHandle));
    FocusNode handleFocus(WidgetTester t) =>
        t.widget<Focus>(find.descendant(of: find.byType(ResizeHandle), matching: find.byType(Focus)).first).focusNode!;
    Future<void> key(WidgetTester t, LogicalKeyboardKey k) async {
      await t.sendKeyEvent(k);
      await t.pump();
    }

    Future<void> tabToHandle(WidgetTester t) async {
      await key(t, LogicalKeyboardKey.tab);
      expect(handleFocus(t).hasPrimaryFocus, isTrue);
    }

    Future<String?> stored(WidgetTester t) async {
      await t.pump();
      return (await t.runAsync(SharedPreferences.getInstance))!.getString(_key);
    }

    testWidgets('grows upward with the keyboard and persists its height', (t) async {
      await render(t);
      await tabToHandle(t);

      await key(t, LogicalKeyboardKey.arrowUp);
      await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await key(t, LogicalKeyboardKey.arrowUp);
      await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      expect(handle(t).value, 240);
      expect(await stored(t), '240');

      await key(t, LogicalKeyboardKey.end);
      await key(t, LogicalKeyboardKey.arrowUp);
      expect(handle(t).value, 440);

      await key(t, LogicalKeyboardKey.home);
      await key(t, LogicalKeyboardKey.arrowDown);
      expect(handle(t).value, 120);
    });

    testWidgets('constrains its height after the canvas shrinks without replacing the saved preference', (t) async {
      await render(t);
      await tabToHandle(t);
      await key(t, LogicalKeyboardKey.end);
      expect(handle(t).value, 440);
      expect(await stored(t), '440');

      h.store.setWorkflowCanvasHeight(300);
      await t.pump();
      await t.pump();

      expect(handle(t).value, 240);
      expect(handle(t).max, 240);
      expect(
        t.getSize(find.ancestor(of: find.byType(InspectPanel), matching: find.byType(Container)).first).height,
        240,
      );
      expect(await stored(t), '440');
      expect(handleFocus(t).hasPrimaryFocus, isTrue);

      await key(t, LogicalKeyboardKey.arrowUp);
      expect(handle(t).value, 240);
      await key(t, LogicalKeyboardKey.arrowDown);
      expect(handle(t).value, 232);
    });

    testWidgets('renders nothing when the inspect panel is hidden', (t) async {
      final h = InspectHarness()..store.setShowVariableInspectPanel(false);
      await h.pump(t, const VariableInspectPanel());

      expect(find.byType(ResizeHandle), findsNothing);
      expect(find.byType(InspectPanel), findsNothing);
    });
  });
}
