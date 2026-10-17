// dify-spec: web/app/components/workflow/nodes/knowledge-retrieval/__tests__/node.spec.tsx
//
// The canvas card (lib/src/cards/bodies/llm_bodies.dart KnowledgeRetrievalBody); the datasets-detail store is the
// BodyContext's datasets.
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/cards/bodies/llm_bodies.dart';
import 'package:dify_sf_app/src/cards/card_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'kr_fixtures.dart';

Future<void> renderWithDatasets(WidgetTester t, List<String> ids, List<Map<String, Object?>> datasets) => t.pumpWidget(
  MaterialApp(
    home: Material(
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 240,
          child: Builder(
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
                datasets: {for (final d in datasets) d['id']! as String: d},
              ),
            ),
          ),
        ),
      ),
    ),
  ),
);

void main() {
  group('knowledge-retrieval/node', () {
    testWidgets(
      'renders matched dataset details and falls back to the default icon info when a dataset has no icon',
      (t) async {
        await renderWithDatasets(
          t,
          ['dataset-1', 'dataset-2'],
          [
            createDataset(),
            createDataset({'id': 'dataset-2', 'name': 'Fallback Icon Dataset', 'icon_info': null}),
          ],
        );
        expect(find.text('Dataset Name'), findsOneWidget);
        expect(find.text('Fallback Icon Dataset'), findsOneWidget);
        expect(find.text('📙'), findsNWidgets(2));
      },
    );

    testWidgets('renders nothing when the node has no dataset ids or no matching dataset details', (t) async {
      await renderWithDatasets(t, ['missing-dataset'], [createDataset()]);
      expect(find.byType(Text), findsNothing);
      await renderWithDatasets(t, [], [createDataset()]);
      expect(find.byType(Text), findsNothing);
    });
  });
}
