// dify-spec: web/app/components/workflow/nodes/llm/__tests__/node.spec.tsx
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/cards/bodies/llm_bodies.dart';
import 'package:dify_sf_app/src/cards/card_kit.dart';
import 'package:dify_sf_app/src/cards/model_chip.dart';
import 'package:dify_sf_app/src/workflow/model_catalog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const textGenerationModelList = [
  ProviderWithModels(
    provider: 'openai',
    models: [ModelItem(model: 'gpt-4o')],
  ),
];

Node createData({String provider = 'openai', String name = 'gpt-4o', Map<String, Value> extra = const {}}) => Node(
  id: 'llm-node',
  type: 'llm',
  title: 'LLM',
  config: {
    'model': VMap({'provider': VString(provider), 'name': VString(name), 'mode': const VString('chat')}),
    ...extra,
  },
);

Future<void> render(WidgetTester t, Node node) {
  final ctx = BodyContext(
    node,
    (_) => null,
    models: const ModelCatalog(modelLists: {ModelTypeEnum.textGeneration: textGenerationModelList}),
  );
  return t.pumpWidget(
    MaterialApp(
      home: Material(
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: 238, child: Builder(builder: (c) => const LlmBody().build(c, ctx))),
        ),
      ),
    ),
  );
}

/// The mocked ModelSelector printed `provider:model`.
Finder selector(String text) => find.byWidgetPredicate(
  (w) => w is ModelChip && w.disabled && w.value != null && '${w.value!.provider}:${w.value!.model}' == text,
);

void main() {
  group('llm/node', () {
    testWidgets('renders the disabled model selector when a model is configured', (t) async {
      await render(t, createData());

      expect(selector('openai:gpt-4o'), findsOneWidget);
    });

    testWidgets('renders nothing when the node has no configured model', (t) async {
      await render(t, createData(provider: '', name: ''));

      expect(selector('openai:gpt-4o'), findsNothing);
      expect(find.byType(ModelChip), findsNothing);
    });

    testWidgets('renders a cached environment model without requiring workflow context', (t) async {
      await render(
        t,
        createData(
          provider: 'anthropic',
          name: 'claude-sonnet',
          extra: {
            'model_selector': const VList([VString('env'), VString('for_summarize')]),
          },
        ),
      );

      expect(selector('anthropic:claude-sonnet'), findsOneWidget);
    });
  });
}
