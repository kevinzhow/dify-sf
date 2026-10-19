// dify-spec: web/app/components/workflow/nodes/question-classifier/__tests__/node.spec.tsx
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/cards/bodies/llm_bodies.dart';
import 'package:dify_sf_app/src/cards/card_kit.dart';
import 'package:dify_sf_app/src/cards/model_chip.dart';
import 'package:dify_sf_app/src/workflow/model_catalog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:dify_sf_app/src/cards/class_name_popover.dart';
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
    testWidgets('returns nothing when neither model nor classes are configured and truncates long class names', (
      t,
    ) async {
      const body = QuestionClassifierBody();
      final empty = BodyContext(const Node(id: 'empty', type: 'question-classifier', title: ''), (_) => null);
      expect(body.height(empty), 0);
      expect(body.sources(empty), isEmpty);
      const title = 'A very long question topic that must be truncated but fully readable when hovered';
      final ctx = BodyContext(createData(classes: [createTopic(name: title)]), (_) => null);
      await t.pumpWidget(
        MaterialApp(
          home: Material(
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(width: 238, child: Builder(builder: (c) => body.build(c, ctx))),
            ),
          ),
        ),
      );
      final full = find.byWidgetPredicate(
        (w) => w is RichText && w.text.toPlainText().replaceAll('\u200B', '') == title,
      );
      expect(full, findsNothing);
      final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(t.getCenter(find.byType(ClassNamePopover)));
      await t.pumpAndSettle();
      expect(full, findsNWidgets(2));
      await mouse.removePointer();
      await t.pumpWidget(const SizedBox());
    });

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
