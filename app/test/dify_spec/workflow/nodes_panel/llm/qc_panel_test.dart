// dify-spec: web/app/components/workflow/nodes/question-classifier/components/__tests__/advanced-setting.spec.tsx
// dify-spec: web/app/components/workflow/nodes/question-classifier/components/__tests__/class-item.spec.tsx
// dify-spec: web/app/components/workflow/nodes/question-classifier/components/__tests__/class-list.spec.tsx
// dify-spec: web/app/components/workflow/nodes/question-classifier/__tests__/panel.spec.tsx
// dify-spec: web/app/components/workflow/nodes/question-classifier/__tests__/use-config.spec.ts
// dify-spec: web/app/components/workflow/nodes/question-classifier/__tests__/integration.spec.tsx
//
// The Question Classifier's panel over a document in an in-memory session, and its components alone. Where Dify
// mocks a child (the prompt editor, memory config, the model modal), the cases drive the real one through its
// callbacks and read the node's data.
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/cards/bodies/llm_bodies.dart';
import 'package:dify_sf_app/src/cards/card_kit.dart';
import 'package:dify_sf_app/src/cards/model_chip.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/workflow/model_catalog.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/group_host.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/model_parameter_modal.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/qc_class_list.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/question_classifier_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/panel_fields.dart';
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/config_prompt.dart' show PromptEditorEnv;
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:dify_sf_app/src/cards/class_name_popover.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';
import 'qc_pe_test_kit.dart';

Map<String, Object?> topic({String id = 'topic-1', String name = 'Billing questions', String? label}) => {
  'id': id,
  'name': name,
  'label': ?label,
};

Map<String, Object?> qcData([Map<String, Object?> overrides = const {}]) => {
  'model': {'provider': 'openai', 'name': 'gpt-4o', 'mode': 'chat', 'completion_params': <String, Object?>{}},
  'classes': [topic()],
  'query_variable_selector': ['start', 'query'],
  'instruction': 'Route by topic',
  'vision': {'enabled': false},
  ...overrides,
};

const _visionModels = ModelCatalog(
  providers: [
    ModelProvider(provider: 'openai', label: {'en_US': 'OpenAI'}),
  ],
  modelLists: {
    ModelTypeEnum.textGeneration: [
      ProviderWithModels(
        provider: 'openai',
        label: {'en_US': 'OpenAI'},
        models: [
          ModelItem(model: 'gpt-4o', label: {'en_US': 'gpt-4o'}, features: [ModelFeatureEnum.vision]),
        ],
      ),
    ],
  },
);

Map<String, Object?> _qc(Harness h) => dataOf(h, 'qc');
List<Object?> _classes(Harness h) => _qc(h)['classes']! as List;

/// The class list alone, holding its list (Dify's onChange spy plus state), with the removals reported.
class _ListFixture extends StatefulWidget {
  const _ListFixture({
    required this.initial,
    this.readonly = false,
    required this.changes,
    required this.removed,
    this.sorts,
  });
  final List<Map<String, Object?>> initial;
  final bool readonly;
  final List<List<Map<String, Object?>>> changes;
  final List<int> removed;
  final List<List<Map<String, Object?>>>? sorts;

  @override
  State<_ListFixture> createState() => _ListFixtureState();
}

class _ListFixtureState extends State<_ListFixture> {
  late var _list = widget.initial;

  @override
  Widget build(BuildContext context) => ClassList(
    list: _list,
    readonly: widget.readonly,
    env: const PromptEditorEnv(),
    onChange: widget.changes.add,
    onRemove: widget.removed.add,
    onSort: widget.sorts == null
        ? null
        : (l) {
            widget.sorts!.add(l);
            setState(() => _list = l);
          },
  );
}

Finder _addClass() => find.text('workflow.nodes.questionClassifiers.addClass');
Finder _handles() => find.byWidgetPredicate(
  (w) =>
      w is DifyIconButton &&
      w.key is ValueKey<String> &&
      (w.key! as ValueKey<String>).value.startsWith('class-sort-handle'),
);

void main() {
  setUp(() {
    useShortVisionTranslator();
    inlineLabelHintDismissed.value = false;
  });

  Future<Harness> renderPanel(
    WidgetTester t, {
    Map<String, Object?> data = const {},
    LlmGroupServices services = const LlmGroupServices(models: _visionModels),
    bool chatMode = true,
  }) => startPanel(
    t,
    [
      ('start', 'start', {'variables': <Object?>[]}),
      ('qc', 'question-classifier', qcData(data)),
    ],
    services: services,
    chatMode: chatMode,
  );

  group('question-classifier/advanced-setting', () {
    testWidgets('updates the instruction and exposes memory config when memory is enabled', (t) async {
      final instructions = <String>[];
      final memories = <Map<String, Object?>?>[];
      await pumpComponent(
        t,
        QcAdvancedSetting(
          instruction: 'Route by topic',
          onInstructionChange: instructions.add,
          hideMemorySetting: false,
          onMemoryChange: memories.add,
          isChatModel: true,
          isChatApp: true,
          env: const PromptEditorEnv(),
        ),
      );
      editors(t).single.onChange('Route by topic!');
      await t.tap(find.bySemanticsLabel('workflow.nodes.common.memory.memory'));
      await settleShort(t);
      expect(instructions, ['Route by topic!']);
      expect(memories.single, memoryDefault);
    });

    testWidgets('hides the memory setting when the section is disabled', (t) async {
      await pumpComponent(
        t,
        QcAdvancedSetting(
          instruction: 'Route by topic',
          onInstructionChange: (_) {},
          hideMemorySetting: true,
          onMemoryChange: (_) {},
          isChatModel: true,
          isChatApp: true,
          env: const PromptEditorEnv(),
        ),
      );
      expect(find.byType(MemoryConfig), findsNothing);
    });
  });

  group('question-classifier/class-item', () {
    testWidgets('forwards editor updates and remove actions', (t) async {
      final changes = <Map<String, Object?>>[];
      var removed = 0;
      await pumpComponent(
        t,
        ClassItem(
          payload: topic(),
          index: 1,
          env: const PromptEditorEnv(),
          onChange: changes.add,
          onRemove: () => removed++,
        ),
      );
      editors(t).single.onChange('Billing questions updated');
      await t.tap(find.bySemanticsLabel('common.operation.remove'));
      expect(changes.single, {'id': 'topic-1', 'name': 'Billing questions updated'});
      expect(removed, 1);
      expect(find.bySemanticsLabel('CLASS 1'), findsOneWidget);
    });

    testWidgets('preserves a custom label when editing the classifier name', (t) async {
      final changes = <Map<String, Object?>>[];
      await pumpComponent(
        t,
        ClassItem(
          payload: topic(label: 'Billing'),
          index: 1,
          env: const PromptEditorEnv(),
          onChange: changes.add,
          onRemove: () {},
        ),
      );
      editors(t).single.onChange('Billing questions updated');
      expect(changes.single, {'id': 'topic-1', 'name': 'Billing questions updated', 'label': 'Billing'});
      expect(find.bySemanticsLabel('Billing'), findsOneWidget);
    });
  });

  group('question-classifier/class-list', () {
    testWidgets('adds, updates, collapses, and removes classes through the list actions', (t) async {
      final changes = <List<Map<String, Object?>>>[];
      final removed = <int>[];
      await pumpComponent(
        t,
        _ListFixture(
          initial: [
            topic(),
            topic(id: 'topic-2', name: 'Refunds'),
          ],
          changes: changes,
          removed: removed,
        ),
      );
      editors(t).first.onChange('Billing questions updated');
      expect(changes.last.first['name'], 'Billing questions updated');

      await t.tap(find.bySemanticsLabel('common.operation.remove').first);
      expect(removed, [0]);

      await t.tap(find.bySemanticsLabel('workflow.nodes.questionClassifiers.class'));
      await settleShort(t);
      expect(_addClass(), findsNothing);

      await t.tap(find.bySemanticsLabel('workflow.nodes.questionClassifiers.class'));
      await settleShort(t);
      await t.tap(_addClass());
      expect(changes.last.last, allOf(containsPair('name', ''), containsPair('label', 'CLASS 3')));
    });

    testWidgets('confirms keyboard sorting through the branch-aware sort callback', (t) async {
      final changes = <List<Map<String, Object?>>>[];
      final sorts = <List<Map<String, Object?>>>[];
      final topics = [topic(), topic(id: 'topic-2', name: 'Refunds')];
      await pumpComponent(
        t,
        _ListFixture(initial: topics, changes: changes, removed: [], sorts: sorts),
      );
      t.widget<DifyIconButton>(_handles().first).focusNode!.requestFocus();
      await t.pump();
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await settleShort(t);
      expect(editors(t).first.value, 'Refunds');
      expect(sorts, isEmpty);
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await settleShort(t);
      expect(sorts.single, [topics[1], topics[0]]);
      expect(changes, isEmpty);
    });

    testWidgets('hides drag and add affordances when readonly', (t) async {
      await pumpComponent(
        t,
        _ListFixture(
          initial: [
            topic(),
            topic(id: 'topic-2', name: 'Refunds'),
          ],
          readonly: true,
          changes: [],
          removed: [],
        ),
      );
      expect(_addClass(), findsNothing);
      expect(_handles(), findsNothing);
    });
  });

  group('question-classifier/panel', () {
    testWidgets('wires panel actions and renders output variables', (t) async {
      final h = await renderPanel(t);
      t.widget<ModelParameterModal>(find.byType(ModelParameterModal)).onModelChange((
        provider: 'openai',
        modelId: 'gpt-4o',
        mode: 'chat',
        features: const [],
      ));
      await settle(t);
      t.widget<ModelParameterModal>(find.byType(ModelParameterModal)).onCompletionParamsChange({'temperature': 0.2});
      await settle(t);
      t.widget<VarReferencePicker>(find.byType(VarReferencePicker).first).onChange(['start', 'query2'], null);
      await settle(t);
      await t.tap(find.bySemanticsLabel('workflow.nodes.llm.vision'));
      await settle(t);
      t.widget<ConfigVision>(find.byType(ConfigVision)).onConfigChange({
        'detail': 'low',
        'variable_selector': <String>[],
      });
      await settle(t);

      final d = _qc(h);
      expect(d['model'], {
        'provider': 'openai',
        'name': 'gpt-4o',
        'mode': 'chat',
        'completion_params': {'temperature': 0.2},
      });
      expect(d['query_variable_selector'], ['start', 'query2']);
      expect(d['vision'], {
        'enabled': true,
        'configs': {'detail': 'low', 'variable_selector': <String>[]},
      });
      await t.tap(find.text('WORKFLOW.NODES.COMMON.OUTPUTVARS'));
      await settle(t);
      for (final s in ['class_name', 'class_label', 'usage']) {
        expect(find.text(s), findsOneWidget);
      }
      await h.dispose(t);
    });
  });

  group('question-classifier/use-config', () {
    testWidgets('preserves the selected model when the vision follow-up updates after model selection', (t) async {
      final h = await renderPanel(
        t,
        data: {
          'model': {'provider': '', 'name': '', 'mode': 'chat', 'completion_params': <String, Object?>{}},
          'classes': [topic(label: 'CLASS 1')],
          'vision': {'enabled': true},
        },
        services: const LlmGroupServices(),
      );
      t.widget<ModelParameterModal>(find.byType(ModelParameterModal)).onModelChange((
        provider: 'openai',
        modelId: 'gpt-4o',
        mode: 'chat',
        features: const [],
      ));
      await settle(t);
      final d = _qc(h);
      expect(d['model'], containsPair('provider', 'openai'));
      expect(d['model'], containsPair('name', 'gpt-4o'));
      expect(d['model'], containsPair('mode', 'chat'));
      // Not a vision model: the follow-up turns vision off.
      expect(d['vision'], {'enabled': false});
      await h.dispose(t);
    });

    testWidgets('does not default the query selector to sys.query in snippet flows', (t) async {
      const defaults = {
        'question-classifier': {
          'model': {'provider': '', 'name': '', 'mode': 'chat', 'completion_params': <String, Object?>{}},
          'classes': [
            {'id': 'topic-1', 'name': 'Billing questions', 'label': 'CLASS 1'},
          ],
          'vision': {'enabled': false},
        },
      };
      final h = await renderPanel(
        t,
        data: {'query_variable_selector': <String>[]},
        services: const LlmGroupServices(flowType: 'snippet', nodesDefaultConfigs: defaults),
      );
      expect(_qc(h)['query_variable_selector'], <String>[]);
      await h.dispose(t);

      // Outside snippets the chatflow default applies.
      final h2 = await renderPanel(
        t,
        data: {'query_variable_selector': <String>[]},
        services: const LlmGroupServices(nodesDefaultConfigs: defaults),
      );
      expect(_qc(h2)['query_variable_selector'], ['start', 'sys.query']);
      await h2.dispose(t);
    });
  });

  group('question-classifier path', () {
    group('Path Integration', () {
      testWidgets(
        'should render the node when only classes are set and return null when both model and classes are missing',
        (t) async {
          const fullName = 'A long classification rule whose full name needs more than fifty characters to display';
          final data = difyNode('qc', 'question-classifier', {
            'classes': [topic(name: fullName)],
          });
          final ctx = BodyContext(data, (_) => null);
          const body = QuestionClassifierBody();
          await pumpComponent(t, Builder(builder: (context) => SizedBox(width: 238, child: body.build(context, ctx))));
          expect(find.byType(ModelChip), findsNothing);
          expect(body.sources(ctx).keys, ['topic-1']);
          final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
          await mouse.addPointer(location: Offset.zero);
          await mouse.moveTo(t.getCenter(find.byType(ClassNamePopover)));
          await t.pumpAndSettle();
          expect(
            find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText().replaceAll('\u200B', '') == fullName),
            findsNWidgets(2),
          );
          await mouse.removePointer();
          final empty = BodyContext(difyNode('empty', 'question-classifier', {}), (_) => null);
          await pumpComponent(t, Builder(builder: (context) => body.build(context, empty)));
          expect(body.height(empty), 0);
          expect(find.byType(ClassNamePopover), findsNothing);
        },
      );

      testWidgets('should render advanced settings and memory config', (t) async {
        final instructions = <String>[];
        final memories = <Map<String, Object?>?>[];
        await pumpComponent(
          t,
          QcAdvancedSetting(
            instruction: 'Route by topic',
            onInstructionChange: instructions.add,
            hideMemorySetting: false,
            onMemoryChange: memories.add,
            isChatModel: true,
            isChatApp: true,
            env: const PromptEditorEnv(),
          ),
        );
        expect(editors(t).single.value, 'Route by topic');
        editors(t).single.onChange('Route by topic!');
        await t.tap(find.bySemanticsLabel('workflow.nodes.common.memory.memory'));
        expect(instructions, isNotEmpty);
        expect(memories.single, memoryDefault);
      });

      testWidgets('should edit and remove a single class item', (t) async {
        final changes = <Map<String, Object?>>[];
        var removed = 0;
        await pumpComponent(
          t,
          ClassItem(
            payload: topic(),
            index: 1,
            env: const PromptEditorEnv(),
            onChange: changes.add,
            onRemove: () => removed++,
          ),
        );
        editors(t).single.onChange('Billing questions updated');
        await t.tap(find.bySemanticsLabel('common.operation.remove'));
        expect(changes, isNotEmpty);
        expect(removed, 1);
      });

      testWidgets('should add classes and collapse the class list', (t) async {
        final changes = <List<Map<String, Object?>>>[];
        await pumpComponent(
          t,
          _ListFixture(
            initial: [
              topic(),
              topic(id: 'topic-2', name: 'Refunds'),
            ],
            changes: changes,
            removed: [],
          ),
        );
        await t.tap(_addClass());
        await t.tap(find.bySemanticsLabel('workflow.nodes.questionClassifiers.class'));
        await settleShort(t);
        expect(_addClass(), findsNothing);
        await t.tap(find.bySemanticsLabel('workflow.nodes.questionClassifiers.class'));
        await settleShort(t);
        expect(_addClass(), findsOneWidget);
        expect(_handles(), findsNWidgets(2));
        expect(changes, isNotEmpty);
      });

      testWidgets('should update and remove classes from the class list and delete the related edge branch', (
        t,
      ) async {
        final g = difyChain([
          ('start', 'start', {'variables': <Object?>[]}),
          (
            'qc',
            'question-classifier',
            qcData({
              'classes': [topic(), topic(id: 'topic-2', name: 'Refunds')],
            }),
          ),
        ]);
        final end = difyNode('end', 'end', {'outputs': <Object?>[]});
        final h = await Harness.start(
          t,
          [...g.nodes, end],
          edges: [
            ...g.edges,
            const Edge(id: 'branch', source: 'qc', sourceHandle: 'topic-1', target: 'end'),
          ],
        );
        t.view.physicalSize = const Size(1400, 1000);
        h.store
          ..setWorkflowCanvasWidth(1400)
          ..setNodePanelWidth(400);
        await t.pumpWidget(llmPanel(h, 'qc', chatMode: true));
        await settle(t);

        editors(t).first.onChange('Updated billing');
        await settle(t);
        expect((_classes(h).first! as Map)['name'], 'Updated billing');
        await t.tap(find.bySemanticsLabel('common.operation.remove').first);
        await settle(t);
        expect(h.doc.edges.containsKey('branch'), isFalse);
        expect([for (final c in _classes(h)) (c! as Map)['id']], ['topic-2']);
        await h.dispose(t);
      });

      testWidgets('should disable dragging and hide the add button when the class list is readonly', (t) async {
        await pumpComponent(
          t,
          _ListFixture(
            initial: [
              topic(),
              topic(id: 'topic-2', name: 'Refunds'),
            ],
            readonly: true,
            changes: [],
            removed: [],
          ),
        );
        expect(_addClass(), findsNothing);
        expect(_handles(), findsNothing);
      });

      testWidgets('should render the node model and output handles for each class', (t) async {
        final node = Node(
          id: 'node-1',
          type: 'question-classifier',
          title: 'Question Classifier',
          config: {
            'model': const VMap({'provider': VString('openai'), 'name': VString('gpt-4o'), 'mode': VString('chat')}),
            'classes': VList([
              Value.of(topic()),
              Value.of(topic(id: 'topic-2', name: 'Refunds')),
            ]),
          },
        );
        final ctx = BodyContext(
          node,
          (_) => null,
          models: const ModelCatalog(
            modelLists: {
              ModelTypeEnum.textGeneration: [
                ProviderWithModels(
                  provider: 'openai',
                  models: [ModelItem(model: 'gpt-4o')],
                ),
              ],
            },
          ),
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
        expect(find.textContaining('Billing questions', findRichText: true), findsWidgets);
        expect(const QuestionClassifierBody().sources(ctx).keys, ['topic-1', 'topic-2']);
      });

      testWidgets('should render the panel controls and output variables', (t) async {
        final h = await renderPanel(t);
        t.widget<ModelParameterModal>(find.byType(ModelParameterModal)).onModelChange((
          provider: 'openai',
          modelId: 'gpt-4o',
          mode: 'chat',
          features: const [],
        ));
        t.widget<ModelParameterModal>(find.byType(ModelParameterModal)).onCompletionParamsChange({'temperature': 0.2});
        await settle(t);
        t.widget<VarReferencePicker>(find.byType(VarReferencePicker).first).onChange(['start', 'query'], null);
        await t.tap(find.bySemanticsLabel('workflow.nodes.llm.vision'));
        await settle(t);
        await t.tap(find.text('WORKFLOW.NODES.COMMON.OUTPUTVARS'));
        await settle(t);
        expect(find.text('class_name'), findsOneWidget);
        expect(find.text('usage'), findsOneWidget);
        await h.dispose(t);
      });
    });
  });
}
