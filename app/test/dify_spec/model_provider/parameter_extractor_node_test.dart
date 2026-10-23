// dify-spec: web/app/components/workflow/nodes/parameter-extractor/__tests__/node.spec.tsx
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

Node createData({String provider = 'openai', String name = 'gpt-4o'}) => Node(
  id: 'node-1',
  type: 'parameter-extractor',
  title: 'Parameter Extractor',
  config: {
    'model': VMap({'provider': VString(provider), 'name': VString(name), 'mode': const VString('chat')}),
    'query': const VList([VString('node-1'), VString('query')]),
    'reasoning_mode': const VString('prompt'),
    'instruction': const VString('Extract city and budget'),
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
          child: SizedBox(width: 238, child: Builder(builder: (c) => const ParameterExtractorBody().build(c, ctx))),
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
  group('parameter-extractor/node', () {
    testWidgets('renders the disabled model selector when a model is configured', (t) async {
      await render(t, createData());

      expect(selector('openai:gpt-4o'), findsOneWidget);
    });

    testWidgets('renders no model badge when the node has no configured model', (t) async {
      await render(t, createData(provider: '', name: ''));

      expect(selector('openai:gpt-4o'), findsNothing);
      expect(find.byType(ModelChip), findsNothing);
    });
  });
}
