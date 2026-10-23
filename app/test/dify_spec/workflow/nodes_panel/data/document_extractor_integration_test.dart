// dify-spec: web/app/components/workflow/nodes/document-extractor/__tests__/integration.spec.tsx
//
// The card and the panel over a document (see document_extractor_node_test.dart and
// document_extractor_panel_test.dart for the fixtures).
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'document_extractor_node_test.dart' as card;
import 'document_extractor_panel_test.dart' as panel;
import 'harness.dart';

void main() {
  group('document-extractor path', () {
    testWidgets('should render nothing when the node input variable is not configured', (t) async {
      await card.renderCard(t, card.docNode(selector: const []));
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('should render the selected input variable on the node', (t) async {
      await card.renderCard(t, card.docNode());
      expect(find.text('INPUT VARIABLE'), findsOneWidget);
      expect(find.text('Input Files'), findsOneWidget);
      expect(find.text('files'), findsOneWidget);
    });

    testWidgets('should wire panel input changes and format supported file types for english locales', (t) async {
      final opened = <String>[];
      final h = await panel.renderDocPanel(t, opened: opened);

      await t.tap(find.byKey(const Key('var-reference-picker-trigger')));
      await Harness.settle(t);
      await t.tap(find.text('files').first);
      await Harness.settle(t);

      expect(dataOf(h, 'doc-node')['variable_selector'], ['node-1', 'files']);
      expect(
        find.textContaining('workflow.nodes.docExtractor.supportFileTypes:{"types":"pdf, markdown, docx"}'),
        findsOneWidget,
      );
      await t.tap(find.text('workflow.nodes.docExtractor.learnMore'));
      expect(opened, [panel.link]);
      await h.dispose(t);
    });

    testWidgets('should use chinese separators and array output types when the input is an array of files', (t) async {
      final h = await panel.renderDocPanel(t, selector: const ['node-1', 'files'], isArrayFile: true, chinese: true);
      expect(
        find.textContaining('workflow.nodes.docExtractor.supportFileTypes:{"types":"pdf、 markdown、 docx"}'),
        findsOneWidget,
      );
      await panel.openOutputs(t);
      expect(find.text('array[string]'), findsOneWidget);
      await h.dispose(t);
    });
  });
}
