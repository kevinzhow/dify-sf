// dify-spec: web/app/components/workflow/nodes/agent/components/__tests__/model-bar.spec.tsx
import 'package:dify_sf_app/src/cards/model_chip.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart' show DifyStatusDot;
import 'package:dify_sf_app/src/workflow/model_catalog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

var mockModelLists = <String, List<ProviderWithModels>>{};

Future<void> render(WidgetTester t, Widget w) => t.pumpWidget(
  MaterialApp(
    home: Material(
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(width: 214, child: w),
      ),
    ),
  ),
);

ModelCatalog get catalog => ModelCatalog(modelLists: mockModelLists);

/// The mocked ModelSelector printed `provider/model:models.length` (or `no-model:…`).
String selector(WidgetTester t) {
  final chip = t.widget<ModelChip>(find.byType(ModelChip));
  final v = chip.value;
  return '${v == null ? 'no-model' : '${v.provider}/${v.model}'}:${chip.models.length}';
}

Finder srOnly(String text) => find.byWidgetPredicate((w) => w is Semantics && w.properties.label == text);

void main() {
  group('agent/model-bar', () {
    setUp(() {
      mockModelLists = {
        ModelTypeEnum.textGeneration: const [
          ProviderWithModels(
            provider: 'openai',
            models: [ModelItem(model: 'gpt-4o')],
          ),
        ],
        ModelTypeEnum.moderation: const [],
        ModelTypeEnum.rerank: const [],
        ModelTypeEnum.speech2text: const [],
        ModelTypeEnum.textEmbedding: const [],
        ModelTypeEnum.tts: const [],
      };
    });

    testWidgets('should render an empty disabled selector with a warning when no model is selected', (t) async {
      await render(t, ModelBar(catalog: catalog));

      expect(selector(t), 'no-model:0');
      expect(t.widget<ModelChip>(find.byType(ModelChip)).disabled, isTrue);
      expect(find.byType(DifyStatusDot), findsOneWidget);
      expect(srOnly(ModelBar.notSelected), findsOneWidget);
    });

    testWidgets('should render the selected model without warning when it is installed', (t) async {
      await render(t, ModelBar(value: (provider: 'openai', model: 'gpt-4o'), catalog: catalog));

      expect(selector(t), 'openai/gpt-4o:1');
      expect(find.byType(DifyStatusDot), findsNothing);
    });

    testWidgets('should show a warning tooltip when the selected model is not installed', (t) async {
      await render(t, ModelBar(value: (provider: 'openai', model: 'gpt-4.1'), catalog: catalog));

      expect(selector(t), 'openai/gpt-4.1:1');
      expect(find.byType(DifyStatusDot), findsOneWidget);
      expect(srOnly(ModelBar.notInstalled), findsOneWidget);
    });
  });
}
