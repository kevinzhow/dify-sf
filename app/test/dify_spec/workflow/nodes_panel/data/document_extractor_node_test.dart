// dify-spec: web/app/components/workflow/nodes/document-extractor/__tests__/node.spec.tsx
//
// The card body (cards/bodies/data_bodies.dart) over a document node. The card writes its label in English
// ("Input Variable", upper-cased by its style) where Dify translates `nodes.docExtractor.inputVar`.
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/cards/bodies/data_bodies.dart';
import 'package:dify_sf_app/src/cards/card_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

final start = difyNode('node-1', {
  'type': 'start',
  'title': 'Input Files',
  'variables': [
    {'variable': 'files', 'label': 'files', 'type': 'file-list', 'required': false},
  ],
});

Node docNode({List<String> selector = const ['node-1', 'files']}) => difyNode(
  'doc-node',
  {
    'type': 'document-extractor',
    'title': 'Document Extractor',
    'variable_selector': selector,
    'is_array_file': false,
  },
  others: [start],
);

Future<void> renderCard(WidgetTester t, Node node) => t.pumpWidget(
  MaterialApp(
    home: Material(
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 238,
          child: Builder(
            builder: (c) => const DocumentExtractorBody().build(
              c,
              BodyContext(node, (id) => id == 'node-1' ? start : null, start: start),
            ),
          ),
        ),
      ),
    ),
  ),
);

void main() {
  group('document-extractor/node', () {
    testWidgets('renders nothing when no input variable is configured', (t) async {
      await renderCard(t, docNode(selector: const []));
      expect(find.text('INPUT VARIABLE'), findsNothing);
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('renders the selected input variable label', (t) async {
      await renderCard(t, docNode());
      expect(find.text('INPUT VARIABLE'), findsOneWidget);
      expect(find.text('Input Files'), findsOneWidget);
      expect(find.text('files'), findsOneWidget);
    });
  });
}
