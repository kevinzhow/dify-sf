/// Dify's DataSet / metadata fixtures of the knowledge-retrieval specs (createDataset, createMetadata,
/// createCondition).
library;

import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/group_host.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

Map<String, Object?> createDataset([Map<String, Object?> overrides = const {}]) => {
  'id': 'dataset-1',
  'name': 'Dataset Name',
  'indexing_status': 'completed',
  'icon_info': {'icon': '📙', 'icon_background': '#FFF4ED', 'icon_type': 'emoji', 'icon_url': ''},
  'description': 'Dataset description',
  'permission': 'only_me',
  'indexing_technique': 'high_quality',
  'created_by': 'user-1',
  'maintainer': 'user-1',
  'provider': 'internal',
  'embedding_model': 'text-embedding-3',
  'embedding_model_provider': 'openai',
  'embedding_available': true,
  'retrieval_model_dict': {
    'search_method': 'semantic_search',
    'reranking_enable': false,
    'reranking_model': {'reranking_provider_name': '', 'reranking_model_name': ''},
    'top_k': 5,
    'score_threshold_enabled': false,
    'score_threshold': 0,
  },
  'is_multimodal': false,
  ...overrides,
};

Map<String, Object?> createMetadata([Map<String, Object?> overrides = const {}]) => {
  'id': 'meta-1',
  'name': 'topic',
  'type': 'string',
  'value': 'topic',
  ...overrides,
};

Map<String, Object?> createCondition([Map<String, Object?> overrides = const {}]) => {
  'id': 'condition-1',
  'name': 'topic',
  'metadata_id': 'meta-1',
  'comparison_operator': 'contains',
  'value': 'agent',
  ...overrides,
};

/// The knowledge retrieval node data of panel.spec (createData).
Map<String, Object?> createKrData([Map<String, Object?> overrides = const {}]) => {
  'query_variable_selector': ['start', 'sys.query'],
  'query_attachment_selector': <String>[],
  'dataset_ids': ['dataset-1'],
  'retrieval_mode': 'multiple',
  'multiple_retrieval_config': {'top_k': 5, 'score_threshold': 0.5},
  'metadata_filtering_mode': 'disabled',
  'metadata_filtering_conditions': {
    'logical_operator': 'and',
    'conditions': [createCondition()],
  },
  'metadata_model_config': {'provider': 'openai', 'name': 'gpt-4.1-mini', 'mode': 'chat', 'completion_params': {}},
  ...overrides,
};

/// Starts the knowledge retrieval panel [id] after [upstream] (Dify's test keys are long: the panel is 480 wide).
Future<Harness> startKrPanel(
  WidgetTester t,
  Map<String, Object?> data, {
  LlmGroupServices services = LlmGroupServices.empty,
  bool chatMode = false,
  bool readOnly = false,
  bool withStart = true,
}) async {
  final h = await startPanel(
    t,
    [
      if (withStart) ('start', 'start', {'variables': <Object?>[]}),
      ('kr', 'knowledge-retrieval', data),
    ],
    services: services,
    chatMode: chatMode,
    readOnly: readOnly,
    pump: false,
  );
  h.store.setNodePanelWidth(520);
  await t.pumpWidget(llmPanel(h, 'kr', services: services, chatMode: chatMode, readOnly: readOnly));
  await settle(t);
  return h;
}
