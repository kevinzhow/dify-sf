// dify-spec: web/app/components/workflow/panel/env-panel/__tests__/variable-trigger.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:dify_sf_app/src/workflow_editor/variable_panels/env_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../harness.dart';

/// `TriggerHarness`: the trigger with its own open state.
class TriggerHarness extends StatefulWidget {
  const TriggerHarness({super.key, this.env, required this.onClose, required this.onSave});
  final Map<String, Object?>? env;
  final VoidCallback onClose;
  final ValueChanged<Map<String, Object?>> onSave;

  @override
  State<TriggerHarness> createState() => _TriggerHarnessState();
}

class _TriggerHarnessState extends State<TriggerHarness> {
  bool open = false;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 420,
    child: Align(
      alignment: Alignment.topLeft,
      child: Padding(
        padding: const EdgeInsets.only(top: 200),
        child: EnvVariableTrigger(
          open: open,
          setOpen: (v) => setState(() => open = v),
          env: widget.env,
          onClose: widget.onClose,
          onSave: widget.onSave,
        ),
      ),
    ),
  );
}

void main() {
  setUp(useDifyTestTranslator);

  Future<void> render(
    WidgetTester t,
    Widget w, {
    List<Map<String, Object?>> env = const [],
    Map<String, String> secrets = const {},
  }) async {
    final store = WorkflowStore()
      ..setEnvironmentVariables(env)
      ..setEnvSecrets(secrets);
    addTearDown(store.dispose);
    await pumpPanel(t, w, store: store);
  }

  group('VariableTrigger', () {
    testWidgets('opens and closes the variable trigger modal through the real portal flow', (t) async {
      var closed = 0;
      await render(t, TriggerHarness(onClose: () => closed++, onSave: (_) {}));
      final trigger = buttonNamed('workflow.env.envPanelButton');

      await tap(t, trigger);
      expect(find.text('workflow.env.modal.title'), findsOneWidget);

      await tap(t, trigger);
      expect(closed, 1);
      expect(find.text('workflow.env.modal.title'), findsNothing);

      await tap(t, trigger);
      expect(find.text('workflow.env.modal.title'), findsOneWidget);

      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(t);
      expect(closed, 2);
      expect(find.text('workflow.env.modal.title'), findsNothing);
    });

    testWidgets('submits the edited environment variable through the real modal', (t) async {
      var closed = 0;
      final saved = <Map<String, Object?>>[];
      await render(
        t,
        TriggerHarness(
          env: createEnv({'id': 'env-2', 'name': 'counter', 'value': '[__HIDDEN__]', 'description': 'editable'}),
          onClose: () => closed++,
          onSave: saved.add,
        ),
        env: [
          createEnv({'id': 'env-2', 'name': 'counter'}),
        ],
        secrets: {'env-2': '123'},
      );

      await tap(t, buttonNamed('workflow.env.envPanelButton'));
      await type(t, byPlaceholder('workflow.env.modal.valuePlaceholder'), '456');
      await tap(t, buttonNamed('common.operation.save'));

      expect(saved, [
        {'id': 'env-2', 'name': 'counter', 'value': '456', 'value_type': 'secret', 'description': 'editable'},
      ]);
      expect(closed, 1);
      expect(find.text('workflow.env.modal.editTitle'), findsNothing);
    });
  });
}
