// dify-spec: web/app/components/workflow/nodes/knowledge-retrieval/__tests__/integration.spec.tsx
//
// The knowledge retrieval components on their own. Where Dify mocks a child (the Select Dataset dialog, the settings
// modal, ConfigContent, VarReferenceVars, the metadata panel), the real Flutter one runs with the services standing
// for the backend (a dataset page, the settings drawer's result); the ACL check is the services' canEditDataset.
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/cards/bodies/llm_bodies.dart';
import 'package:dify_sf_app/src/cards/card_kit.dart';
import 'package:dify_sf_app/src/workflow/var_types.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/group_host.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/kr_datasets.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/kr_metadata.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/kr_retrieval_config.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/panel_fields.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../dify_test_i18n.dart';
import 'kr_fixtures.dart';

Future<void> _pump(WidgetTester t, Widget child, {LlmGroupServices services = LlmGroupServices.empty}) async {
  t.view.physicalSize = const Size(1400, 1000);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      home: Material(
        child: LlmGroupScope(
          services: services,
          child: Align(
            alignment: Alignment.topCenter,
            child: SizedBox(width: 1200, child: child),
          ),
        ),
      ),
    ),
  );
  await _settle(t);
}

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 5; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _tap(WidgetTester t, Finder f) async {
  await t.tap(f.first);
  await _settle(t);
}

MetadataShape _shape({
  List<Map<String, Object?>> metadataList = const [],
  List<Map<String, Object?>> conditions = const [],
  ValueChanged<String>? onRemove,
  ValueChanged<Map<String, Object?>>? onAdd,
}) => MetadataShape(
  metadataList: metadataList,
  selectedDatasetsLoaded: true,
  conditions: {'logical_operator': 'and', 'conditions': conditions},
  onAddCondition: onAdd ?? (_) {},
  onRemoveCondition: onRemove ?? (_) {},
  onToggleLogicalOperator: () {},
  onUpdateCondition: (_, _) {},
);

void main() {
  setUp(useDifyTestTranslator);

  group('knowledge-retrieval path', () {
    group('Dataset controls', () {
      testWidgets('should open dataset selector and forward selected datasets', (t) async {
        List<Map<String, Object?>>? got;
        await _pump(
          t,
          AddDataset(selectedIds: const ['dataset-1'], onChange: (d) => got = d),
          services: LlmGroupServices(
            fetchDatasetPage: (page) async => (
              data: [
                createDataset({'id': 'dataset-2', 'name': 'Selected Dataset'}),
              ],
              hasMore: false,
            ),
          ),
        );
        await _tap(t, find.bySemanticsLabel('common.operation.add workflow.nodes.knowledgeRetrieval.knowledge'));
        await _tap(t, find.text('Selected Dataset'));
        // dataset-1 (kept selected, not in the page) and the picked one, as Dify's modal hands them over.
        await _tap(t, find.text('common.operation.add'));
        expect([for (final d in got!) d['id']], ['dataset-1', 'dataset-2']);
        expect(got!.last, containsPair('name', 'Selected Dataset'));
      });

      testWidgets('should support editing a dataset item', (t) async {
        Map<String, Object?>? changed;
        await _pump(
          t,
          DatasetItem(
            payload: createDataset({'is_multimodal': true}),
            onChange: (d) => changed = d,
            onRemove: () {},
          ),
          services: LlmGroupServices(editDataset: (d) async => {...d, 'name': 'Updated Dataset'}),
        );
        expect(find.text('Dataset Name'), findsOneWidget);
        await _tap(t, find.text('Dataset Name'));
        await _tap(t, find.bySemanticsLabel('common.operation.edit'));
        expect(changed, containsPair('name', 'Updated Dataset'));
      });

      testWidgets('should support removing a dataset item', (t) async {
        var removed = false;
        await _pump(
          t,
          DatasetItem(
            payload: createDataset({'is_multimodal': true}),
            onChange: (_) {},
            onRemove: () => removed = true,
          ),
        );
        await _tap(t, find.text('Dataset Name'));
        await _tap(t, find.bySemanticsLabel('common.operation.remove'));
        expect(removed, isTrue);
      });

      testWidgets('should render empty and populated dataset lists', (t) async {
        List<Map<String, Object?>>? changed;
        await _pump(t, DatasetList(list: const [], onChange: (d) => changed = d));
        expect(find.text('app-debug.datasetConfig.knowledgeTip'), findsOneWidget);
        await _pump(t, DatasetList(list: [createDataset()], onChange: (d) => changed = d));
        await _tap(t, find.text('Dataset Name'));
        await _tap(t, find.bySemanticsLabel('common.operation.remove'));
        expect(changed, isEmpty);
      });

      testWidgets(
        'should hide dataset settings when ACL does not grant edit even if legacy dataset permission allows it',
        (t) async {
          final dataset = createDataset({
            'permission': 'all_team_members',
            'permission_keys': ['dataset.acl.use'],
          });
          final asked = <Object?>[];
          await _pump(
            t,
            DatasetList(list: [dataset], onChange: (_) {}),
            services: LlmGroupServices(
              editDataset: (d) async => d,
              canEditDataset: (d) {
                asked.add(d['permission_keys']);
                return false;
              },
            ),
          );
          await _tap(t, find.text('Dataset Name'));
          expect(find.bySemanticsLabel('common.operation.edit'), findsNothing);
          expect(asked.first, ['dataset.acl.use']);
        },
      );
    });

    group('Retrieval settings', () {
      testWidgets('should open retrieval config and map config updates back to workflow payload', (t) async {
        final modes = <String>[];
        final configs = <Map<String, Object?>>[];
        await _pump(
          t,
          RetrievalConfig(
            retrievalMode: 'multiple',
            multipleRetrievalConfig: const {'top_k': 3, 'score_threshold': null},
            onRetrievalModeChange: modes.add,
            onMultipleRetrievalConfigChange: configs.add,
            open: true,
            onOpenChange: (_) {},
            selectedDatasets: [createDataset()],
          ),
        );
        final content = t.widget<ConfigRetrievalContent>(find.byType(ConfigRetrievalContent));
        content.onChange({
          'retrieval_model': 'multiple',
          'top_k': 8,
          'score_threshold_enabled': true,
          'score_threshold': 0.4,
          'reranking_model': {'reranking_provider_name': 'cohere', 'reranking_model_name': 'rerank-v3'},
          'reranking_mode': 'weighted_score',
          'weights': {
            'weight_type': 'customized',
            'vector_setting': {
              'vector_weight': 0.7,
              'embedding_provider_name': 'openai',
              'embedding_model_name': 'text-embedding-3',
            },
            'keyword_setting': {'keyword_weight': 0.3},
          },
          'reranking_enable': true,
        }, false);
        content.onChange({'retrieval_model': 'single'}, true);
        expect(configs.single, containsPair('top_k', 8));
        expect(configs.single, containsPair('score_threshold', 0.4));
        expect(configs.single, containsPair('reranking_model', {'provider': 'cohere', 'model': 'rerank-v3'}));
        expect(configs.single, containsPair('reranking_enable', true));
        expect(modes, ['single']);
      });
    });

    group('Metadata controls', () {
      testWidgets('should select metadata filter mode from the dropdown', (t) async {
        final picked = <String>[];
        await _pump(t, MetadataFilterSelector(value: 'disabled', onSelect: picked.add));
        await _tap(t, find.text('workflow.nodes.knowledgeRetrieval.metadata.options.disabled.title'));
        await _tap(t, find.text('workflow.nodes.knowledgeRetrieval.metadata.options.manual.title'));
        expect(picked.first, 'manual');
      });

      testWidgets('should remove stale metadata conditions and open the manual metadata panel', (t) async {
        final removed = <String>[];
        await _pump(
          t,
          MetadataTrigger(
            shape: _shape(
              metadataList: [createMetadata()],
              conditions: [
                createCondition(),
                createCondition({'id': 'condition-stale', 'metadata_id': 'missing', 'name': 'missing'}),
              ],
              onRemove: removed.add,
            ),
          ),
        );
        expect(removed, ['condition-stale']);
        await _tap(t, find.text('workflow.nodes.knowledgeRetrieval.metadata.panel.conditions'));
        expect(find.text('workflow.nodes.knowledgeRetrieval.metadata.panel.title'), findsOneWidget);
      });

      testWidgets(
        'should call handleAddCondition with the correct metadata item when clicking any part of the row',
        (t) async {
          final added = <Map<String, Object?>>[];
          await _pump(
            t,
            AddCondition(
              metadataList: [
                createMetadata({'id': 'meta-perm', 'name': 'permission'}),
                createMetadata({'id': 'meta-topic', 'name': 'topic'}),
              ],
              onAdd: added.add,
            ),
          );
          await _tap(t, find.text('workflow.nodes.knowledgeRetrieval.metadata.panel.add'));
          await _tap(t, find.text('string'));
          expect(added, hasLength(1));
          expect(added.single, allOf(containsPair('id', 'meta-perm'), containsPair('name', 'permission')));
        },
      );

      testWidgets('should render automatic and manual metadata filter states', (t) async {
        final shape = _shape(metadataList: [createMetadata()], conditions: [createCondition()]);
        await _pump(t, MetadataFilter(shape: shape, mode: 'automatic', onModeChange: (_) {}));
        expect(find.text('workflow.nodes.knowledgeRetrieval.metadata.options.automatic.title'), findsOneWidget);
        await _pump(t, MetadataFilter(shape: shape, mode: 'manual', onModeChange: (_) {}));
        await _tap(t, find.text('workflow.nodes.knowledgeRetrieval.metadata.panel.conditions'));
        expect(find.text('workflow.nodes.knowledgeRetrieval.metadata.panel.title'), findsOneWidget);
      });
    });

    group('Condition inputs', () {
      testWidgets('should toggle value method and keep the same option idempotent', (t) async {
        final changes = <String>[];
        await _pump(t, ConditionValueMethod(valueMethod: 'variable', onValueMethodChange: changes.add));
        await _tap(t, find.text('Variable'));
        await _tap(t, find.text('Constant'));
        await _tap(t, find.text('Variable'));
        await _tap(t, find.text('Variable').last);
        expect(changes, ['constant']);
      });

      testWidgets('should select workflow and common variables', (t) async {
        final picked = <List<String>>[];
        final common = <String>[];
        const scope = VarScope(
          vars: [
            VarGroup(nodeId: 'node-1', title: 'Node 1', vars: [PickerVar('field', VarType.string)]),
          ],
        );
        await _pump(t, ConditionVariableSelector(valueSelector: const [], vars: scope, onChange: picked.add));
        await _tap(t, find.text('workflow.nodes.knowledgeRetrieval.metadata.panel.select'));
        await _tap(t, find.text('field'));
        expect(picked, [
          ['node-1', 'field'],
        ]);
        await _pump(
          t,
          ConditionCommonVariableSelector(
            variables: const [(name: 'common', type: 'string', value: 'sys.user_name')],
            onChange: common.add,
          ),
        );
        await _tap(t, find.text('workflow.nodes.knowledgeRetrieval.metadata.panel.select'));
        await _tap(t, find.text('sys.user_name'));
        expect(common, ['sys.user_name']);
      });

      testWidgets('should update operator, clear date values, and remove conditions', (t) async {
        final operators = <String>[];
        final dates = <int?>[];
        final removed = <String>[];
        final updates = <Map<String, Object?>>[];
        await _pump(
          t,
          Column(
            children: [
              ConditionOperator(variableType: 'string', value: 'contains', onSelect: operators.add),
              ConditionDate(value: 1710000000, onChange: dates.add),
              ConditionItem(
                condition: createCondition(),
                shape: MetadataShape(
                  metadataList: [createMetadata()],
                  onAddCondition: (_) {},
                  onRemoveCondition: removed.add,
                  onToggleLogicalOperator: () {},
                  onUpdateCondition: (_, c) => updates.add(c),
                ),
              ),
            ],
          ),
        );
        await _tap(t, find.text('workflow.nodes.ifElse.comparisonOperator.contains'));
        await _tap(t, find.text('workflow.nodes.ifElse.comparisonOperator.is'));
        await _tap(t, find.bySemanticsLabel('common.operation.clear'));
        await t.enterText(find.byType(EditableText).last, 'updated-agent');
        await _settle(t);
        await _tap(t, find.bySemanticsLabel('common.operation.delete'));
        expect(operators.first, 'is');
        expect(dates, [null]);
        expect(updates.last, containsPair('value', 'updated-agent'));
        expect(removed, ['condition-1']);
      });

      testWidgets('should resolve built-in metadata fields by name because their ids are shared', (t) async {
        await _pump(
          t,
          ConditionItem(
            condition: createCondition({'metadata_id': 'built-in', 'name': 'uploader'}),
            shape: _shape(
              metadataList: [
                createMetadata({'id': 'built-in', 'name': 'document_name'}),
                createMetadata({'id': 'built-in', 'name': 'uploader'}),
              ],
            ),
          ),
        );
        expect(find.text('uploader'), findsOneWidget);
        expect(find.text('document_name'), findsNothing);
      });
    });

    group('Node rendering', () {
      testWidgets('should render selected datasets from the detail store and hide when none are selected', (t) async {
        Future<void> card(List<String> ids) => _pump(
          t,
          Builder(
            builder: (c) => const KnowledgeRetrievalBody().build(
              c,
              BodyContext(
                Node(
                  id: 'knowledge-node',
                  type: 'knowledge-retrieval',
                  title: 'Knowledge Retrieval',
                  config: {
                    'dataset_ids': VList([for (final id in ids) VString(id)]),
                  },
                ),
                (_) => null,
                datasets: {'dataset-1': createDataset()},
              ),
            ),
          ),
        );
        await card(['dataset-1']);
        expect(find.text('Dataset Name'), findsOneWidget);
        await card([]);
        expect(find.text('Dataset Name'), findsNothing);
      });
    });
  });
}
