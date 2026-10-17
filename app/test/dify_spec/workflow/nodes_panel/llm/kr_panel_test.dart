// dify-spec: web/app/components/workflow/nodes/knowledge-retrieval/__tests__/panel.spec.tsx
//
// The panel over a document: instead of mocking use-config and the children, the children's callbacks are driven
// (as Dify's mocks' buttons do) and the node's data is read; datasets come from the services' fetchDatasets.
import 'package:dify_sf_app/src/workflow/dify_json.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/group_host.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/kr_datasets.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/kr_metadata.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/kr_retrieval_config.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/panel_edit.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/panel_fields.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';
import 'kr_fixtures.dart';

final _services = LlmGroupServices(
  fetchDatasets: (ids) async => [
    createDataset({
      'is_multimodal': true,
      'doc_metadata': [
        createMetadata(),
        createMetadata({'id': 'meta-2', 'name': 'shared'}),
      ],
    }),
    createDataset({
      'id': 'dataset-2',
      'doc_metadata': [
        createMetadata({'id': 'meta-3', 'name': 'shared'}),
        createMetadata({'id': 'meta-4', 'name': 'language'}),
      ],
    }),
  ],
);

void main() {
  setUp(useDifyTestTranslator);

  group('knowledge-retrieval/panel', () {
    testWidgets('wires panel actions and passes the intersected metadata list to metadata filters', (t) async {
      final h = await startKrPanel(
        t,
        createKrData({
          'dataset_ids': ['dataset-1', 'dataset-2'],
        }),
        services: _services,
      );
      // The Output Variables collapse (closed at first) holds `result: Array[Object]`.
      await t.tap(find.text('WORKFLOW.NODES.COMMON.OUTPUTVARS'));
      await settle(t);
      expect(
        find.byWidgetPredicate((w) => w is VarItem && w.name == 'result' && w.type == 'Array[Object]'),
        findsOneWidget,
      );
      MetadataFilter filter() => t.widget<MetadataFilter>(find.byType(MetadataFilter));
      expect([for (final m in filter().shape.metadataList) m['name']], ['shared']);

      Future<void> act(void Function() f) async {
        f();
        await settle(t);
      }

      List<VarReferencePicker> pickers() => t.widgetList<VarReferencePicker>(find.byType(VarReferencePicker)).toList();
      RetrievalConfig retrieval() => t.widget<RetrievalConfig>(find.byType(RetrievalConfig));
      await act(() => pickers()[0].onChange(['start', 'query'], null));
      await act(() => pickers()[1].onChange(['start', 'query'], null));
      var d = dataOf(h, 'kr');
      expect(d['query_variable_selector'], ['start', 'query']);
      expect(d['query_attachment_selector'], ['start', 'query']);

      await act(() => retrieval().onRetrievalModeChange('single'));
      expect(dataOf(h, 'kr')['retrieval_mode'], 'single');
      await act(
        () => retrieval().onSingleRetrievalModelChange!((
          provider: 'openai',
          modelId: 'gpt-4o-mini',
          mode: 'chat',
          features: const [],
        )),
      );
      await act(() => retrieval().onSingleRetrievalModelParamsChange!({'temperature': 0.2}));
      expect(jsGet(dataOf(h, 'kr')['single_retrieval_config'], 'model'), {
        'provider': 'openai',
        'name': 'gpt-4o-mini',
        'mode': 'chat',
        'completion_params': {'temperature': 0.2},
      });
      await act(() => retrieval().onRetrievalModeChange('multiple'));
      await act(() => retrieval().onMultipleRetrievalConfigChange({'top_k': 8, 'score_threshold': 0.4}));
      expect(dataOf(h, 'kr')['multiple_retrieval_config'], containsPair('top_k', 8));

      await act(() => filter().onModeChange('manual'));
      expect(dataOf(h, 'kr')['metadata_filtering_mode'], 'manual');
      // condition-1 (topic) is not in every dataset's metadata: manual mode prunes it; `shared` stays.
      await act(() => filter().shape.onAddCondition(createMetadata({'id': 'meta-2', 'name': 'shared'})));
      expect(jsList(jsGet(dataOf(h, 'kr')['metadata_filtering_conditions'], 'conditions')), hasLength(1));
      await act(() => filter().shape.onRemoveCondition('condition-1'));
      await act(filter().shape.onToggleLogicalOperator);
      final added = jsMap(jsList(jsGet(dataOf(h, 'kr')['metadata_filtering_conditions'], 'conditions')).single);
      await act(() => filter().shape.onUpdateCondition('${added['id']}', {...added, 'comparison_operator': 'is'}));
      d = dataOf(h, 'kr');
      expect(jsGet(d['metadata_filtering_conditions'], 'logical_operator'), 'or');
      expect(
        jsList(jsGet(d['metadata_filtering_conditions'], 'conditions')).single,
        containsPair('comparison_operator', 'is'),
      );
      await act(
        () => filter().onModelChange!((provider: 'openai', modelId: 'gpt-4.1-mini', mode: 'chat', features: const [])),
      );
      await act(() => filter().onCompletionParamsChange!({'temperature': 0.3}));
      expect(dataOf(h, 'kr')['metadata_model_config'], {
        'provider': 'openai',
        'name': 'gpt-4.1-mini',
        'mode': 'chat',
        'completion_params': {'temperature': 0.3},
      });
      // Last: the new datasets lack the conditions' metadata, so the manual conditions are pruned after this.
      await act(
        () => t.widget<DatasetList>(find.byType(DatasetList)).onChange([
          createDataset({'id': 'dataset-2', 'name': 'Updated Dataset'}),
        ]),
      );
      expect(dataOf(h, 'kr')['dataset_ids'], ['dataset-2']);
      await act(
        () => t.widget<AddDataset>(find.byType(AddDataset)).onChange([
          createDataset({'id': 'dataset-3', 'name': 'Added Dataset'}),
        ]),
      );
      expect(dataOf(h, 'kr')['dataset_ids'], ['dataset-3']);

      await h.dispose(t);
    });

    testWidgets('hides readonly-only controls and the attachment selector when image queries are unavailable', (
      t,
    ) async {
      final h = await startKrPanel(
        t,
        createKrData(),
        readOnly: true,
        services: LlmGroupServices(fetchDatasets: (ids) async => [createDataset()]),
      );
      expect(find.byType(VarReferencePicker), findsOneWidget);
      expect(find.byType(AddDataset), findsNothing);
      await h.dispose(t);
    });
  });
}
