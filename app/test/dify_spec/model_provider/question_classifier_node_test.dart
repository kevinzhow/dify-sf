// dify-spec: web/app/components/workflow/nodes/question-classifier/__tests__/node.spec.tsx
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

VMap createTopic({String id = 'topic-1', String name = 'Billing questions', String? label}) =>
    VMap({'id': VString(id), 'name': VString(name), 'label': ?(label == null ? null : VString(label))});

Node createData({List<VMap>? classes}) => Node(
  id: 'node-1',
  type: 'question-classifier',
  title: 'Question Classifier',
  config: {
    'model': const VMap({'provider': VString('openai'), 'name': VString('gpt-4o'), 'mode': VString('chat')}),
    'classes': VList(classes ?? [createTopic()]),
    'query_variable_selector': const VList([VString('node-1'), VString('query')]),
    'instruction': const VString('Route by topic'),
  },
);

void main() {
  group('question-classifier/node', () {
    testWidgets('renders the selected model and output handles for each class', (t) async {
      final node = createData(
        classes: [
          createTopic(label: 'Billing'),
          createTopic(id: 'topic-2', name: 'Refunds', label: 'Refund desk'),
        ],
      );
      final ctx = BodyContext(
        node,
        (_) => null,
        models: const ModelCatalog(modelLists: {ModelTypeEnum.textGeneration: textGenerationModelList}),
      );
      await t.pumpWidget(
        MaterialApp(
          home: Material(
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 238,
                child: Builder(builder: (c) => const QuestionClassifierBody().build(c, ctx)),
              ),
            ),
          ),
        ),
      );

      final chip = t.widget<ModelChip>(find.byType(ModelChip));
      expect('${chip.value!.provider}:${chip.value!.model}', 'openai:gpt-4o');
      expect(find.text('Billing'), findsOneWidget);
      expect(find.text('Refund desk'), findsOneWidget);
      // NodeSourceHandle per class: the body reports a source handle for each class id.
      expect(const QuestionClassifierBody().sources(ctx).keys, ['topic-1', 'topic-2']);
    });
  });
}
