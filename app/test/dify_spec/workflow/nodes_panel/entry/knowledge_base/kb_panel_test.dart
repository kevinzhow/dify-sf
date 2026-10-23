// dify-spec: web/app/components/workflow/nodes/knowledge-base/__tests__/panel.spec.tsx
//
// The panel on a document in an in-memory session (Dify mocks the sub-components and queries; here the host's model
// lists stand for the queries and the real sub-components render).
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/workflow/model_catalog.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/entry/knowledge_base/knowledge_base_logic.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/entry/knowledge_base/knowledge_base_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/node_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/panel_fields.dart' hide Json;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../context_menu/harness.dart';
import 'kb_harness.dart';

Map<String, Object?> createData([Map<String, Object?> overrides = const {}]) => {
  'index_chunk_variable_selector': ['chunks', 'results'],
  'chunk_structure': ChunkStructure.general,
  'indexing_technique': IndexMethod.qualified,
  'embedding_model': 'text-embedding-3-large',
  'embedding_model_provider': 'openai',
  'keyword_number': 10,
  'retrieval_model': {
    'search_method': SearchMethod.semantic,
    'reranking_enable': false,
    'top_k': 3,
    'score_threshold_enabled': false,
    'score_threshold': 0.5,
  },
  ...overrides,
};

Node kbNode(Map<String, Object?> data) => node(
  'knowledge-base-1',
  type: 'knowledge-index',
  title: 'Knowledge Base',
  config: {
    for (final e in data.entries)
      if (e.value != null) e.key: Value.of(e.value),
  },
);

/// The embedding list of the spec's model-list mock, the model in [status].
ModelCatalog catalogWith({String status = ModelStatusEnum.active}) => ModelCatalog(
  providers: const [ModelProvider(provider: 'openai')],
  modelLists: {
    ModelTypeEnum.textEmbedding: [
      createModel({
        'models': [
          createModelItemJson({'status': status}),
        ],
      }),
    ],
  },
);

void main() {
  setUp(useKbTestTranslator);

  late Harness h;
  late List<String> providerQueries;

  Future<void> render(WidgetTester t, Map<String, Object?> data, {ModelCatalog? catalog}) async {
    providerQueries = [];
    h = await Harness.start(t, [kbNode(data)]);
    await t.pumpWidget(
      kbApp(
        ListenableBuilder(
          listenable: h.controller,
          builder: (context, _) => knowledgeBasePanelBody(
            context,
            NodePanelProps(node: h['knowledge-base-1']!, controller: h.controller, actions: h.actions()),
          ),
        ),
        catalog: catalog ?? catalogWith(),
        providerModels: (p) {
          providerQueries.add(p);
          return null;
        },
      ),
    );
    await t.pump();
  }

  Finder warningDotIn(Type type) =>
      find.descendant(of: find.byType(type), matching: find.byKey(const Key('warning-dot')));

  group('KnowledgeBasePanel', () {
    testWidgets(
      'should show a warning dot on chunk structure and skip nested sections when chunk structure is missing',
      (t) async {
        await render(t, createData({'chunk_structure': null}));
        expect(warningDotIn(KbChunkStructure), findsOneWidget);
        expect(find.byType(BoxGroupField), findsNothing);
        expect(providerQueries, contains('openai'));
        await h.dispose(t);
      },
    );

    testWidgets(
      'should pass warning dots and render summary settings when the qualified configuration needs attention',
      (
        t,
      ) async {
        await render(
          t,
          createData({'index_chunk_variable_selector': <Object?>[]}),
          catalog: catalogWith(status: ModelStatusEnum.disabled),
        );
        expect(warningDotIn(BoxGroupField), findsOneWidget);
        expect(warningDotIn(KbEmbeddingModel), findsOneWidget);
        expect(t.widget<KbEmbeddingModel>(find.byType(KbEmbeddingModel)).warningDot, isTrue);
        expect(providerQueries, contains('openai'));
        expect(find.byType(KbSummaryIndexSetting), findsOneWidget);
        await h.dispose(t);
      },
    );

    testWidgets('should hide embedding and summary settings for non-qualified index methods', (t) async {
      await render(t, createData({'indexing_technique': IndexMethod.economical}));
      expect(find.byType(KbEmbeddingModel), findsNothing);
      expect(find.byType(KbSummaryIndexSetting), findsNothing);
      expect(providerQueries, isEmpty);
      await h.dispose(t);
    });
  });

  group('KnowledgeBasePanel on the document', () {
    testWidgets('choosing a chunk structure and an index method writes the node data', (t) async {
      await render(t, {...knowledgeBaseDefaultValue});
      await t.tap(find.text('workflow.nodes.knowledgeBase.chooseChunkStructure'));
      await t.pump(const Duration(milliseconds: 300));
      await t.tap(find.text('datasetCreation.stepTwo.parentChild'));
      await t.pump(const Duration(milliseconds: 300));
      Map<String, Object?> data() => NodePanelProps(
        node: h['knowledge-base-1']!,
        controller: h.controller,
        actions: h.actions(),
      ).data;
      expect(data()['chunk_structure'], ChunkStructure.parentChild);
      expect(data()['indexing_technique'], IndexMethod.qualified);
      expect((data()['retrieval_model']! as Map)['search_method'], SearchMethod.keywordSearch);
      expect(find.byType(KbIndexMethod), findsOneWidget);
      await t.ensureVisible(find.text('dataset.retrieval.hybrid_search.title'));
      await t.pump();
      await t.tap(find.text('dataset.retrieval.hybrid_search.title'));
      await t.pump();
      expect((data()['retrieval_model']! as Map)['search_method'], SearchMethod.hybrid);
      expect((data()['retrieval_model']! as Map)['reranking_enable'], isTrue);
      await h.dispose(t);
    });
  });
}
