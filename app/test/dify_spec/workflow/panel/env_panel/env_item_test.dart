// dify-spec: web/app/components/workflow/panel/env-panel/__tests__/env-item.spec.tsx
import 'package:dify_sf_app/src/design/dify_tokens.g.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:dify_sf_app/src/workflow_editor/variable_panels/env_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';

import '../harness.dart';

/// The card's border colour (`border-state-destructive-border` while delete is hovered).
Color cardBorder(WidgetTester t) {
  final box = t.widget<Container>(
    find.descendant(of: find.byType(EnvItem), matching: find.byType(Container)).first,
  );
  return ((box.decoration! as BoxDecoration).border! as Border).top.color;
}

Future<TestGesture> hover(WidgetTester t, Finder f) async {
  final g = await t.createGesture(kind: PointerDeviceKind.mouse);
  await g.addPointer(location: t.getCenter(f));
  addTearDown(g.removePointer);
  await t.pump();
  return g;
}

void main() {
  setUp(useDifyTestTranslator);

  Future<WorkflowStore> render(WidgetTester t, Widget w, {Map<String, String> envSecrets = const {}}) async {
    final store = WorkflowStore()..setEnvSecrets(envSecrets);
    addTearDown(store.dispose);
    await pumpPanel(t, SizedBox(width: 388, child: w), store: store);
    return store;
  }

  group('EnvItem', () {
    testWidgets('renders secret env items and triggers edit and delete actions', (t) async {
      final edited = <Object?>[], deleted = <Object?>[];
      final env = createEnv();
      await render(
        t,
        EnvItem(env: env, onEdit: edited.add, onDelete: deleted.add),
        envSecrets: {'env-1': 'masked-value'},
      );

      expect(find.text('api_key'), findsOneWidget);
      expect(find.text('Secret'), findsOneWidget);
      expect(find.text('masked-value'), findsOneWidget);
      expect(find.text('secret description'), findsOneWidget);

      final g = await hover(t, buttonNamed('common.operation.delete'));
      expect(cardBorder(t), DifyColors.stateDestructiveBorder);
      await g.moveTo(Offset.zero);

      await t.tap(buttonNamed('common.operation.edit'));
      await t.tap(buttonNamed('common.operation.delete'));
      expect(edited, [env]);
      expect(deleted, [env]);
    });

    testWidgets('renders non-secret env values and clears destructive styling on mouse out', (t) async {
      final env = createEnv({
        'id': 'env-plain',
        'name': 'public_value',
        'value': 'plain-text',
        'value_type': 'string',
        'description': '',
      });
      await render(t, EnvItem(env: env, onEdit: (_) {}, onDelete: (_) {}));

      expect(find.text('public_value'), findsOneWidget);
      expect(find.text('String'), findsOneWidget);
      expect(find.text('plain-text'), findsOneWidget);
      expect(find.text('secret description'), findsNothing);

      final g = await hover(t, buttonNamed('common.operation.delete'));
      expect(cardBorder(t), DifyColors.stateDestructiveBorder);
      await g.moveTo(Offset.zero);
      await t.pump();
      expect(cardBorder(t), isNot(DifyColors.stateDestructiveBorder));
    });

    testWidgets('renders an LLM environment variable without exposing its object value', (t) async {
      final env = createEnv({
        'id': 'env-llm',
        'name': 'for_summarize',
        'value': {'provider': 'openai', 'name': 'gpt-4o', 'mode': 'chat'},
        'value_type': 'llm',
        'description': '',
      });
      await render(t, EnvItem(env: env, onEdit: (_) {}, onDelete: (_) {}));

      expect(find.text('for_summarize'), findsOneWidget);
      expect(find.text('workflow.blocks.llm'), findsOneWidget);
      expect(find.text('gpt-4o'), findsOneWidget);
    });
  });
}
