// dify-spec: web/app/components/workflow/nodes/document-extractor/__tests__/panel.spec.tsx
//
// The panel over a document (a Start node with a file-list input before the extractor) instead of a mocked
// use-config; the supported types and the help link come from DocExtractorHost.
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/document_extractor/document_extractor_panel.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

const link = 'https://docs.example.com/document-extractor';
const extensions = ['PDF', 'md', 'md', 'DOCX'];

final start = difyNode('node-1', {
  'type': 'start',
  'title': 'Input Files',
  'variables': [
    {'variable': 'files', 'label': 'files', 'type': 'file-list', 'required': false},
  ],
});

Future<Harness> renderDocPanel(
  WidgetTester t, {
  List<String> selector = const [],
  bool isArrayFile = false,
  bool chinese = false,
  List<String>? opened,
}) async {
  final h = await Harness.start(
    t,
    [
      start,
      difyNode(
        'doc-node',
        {
          'type': 'document-extractor',
          'title': 'Document Extractor',
          'variable_selector': selector,
          'is_array_file': isArrayFile,
        },
        others: [start],
        x: 300,
      ),
    ],
    edges: [edge('node-1', 'doc-node')],
  );
  await renderBody(
    t,
    h,
    'doc-node',
    documentExtractorPanelBody,
    openUrl: opened?.add,
    host: (child) =>
        DocExtractorHost(allowedExtensions: extensions, helpLink: link, chineseSeparator: chinese, child: child),
  );
  return h;
}

/// Opens the (collapsed) output variables section.
Future<void> openOutputs(WidgetTester t) async {
  await t.tap(find.text('WORKFLOW.NODES.COMMON.OUTPUTVARS'));
  await Harness.settle(t);
}

void main() {
  group('document-extractor/panel', () {
    testWidgets('wires variable changes and renders supported file types for english locales', (t) async {
      final opened = <String>[];
      final h = await renderDocPanel(t, opened: opened);

      await t.tap(find.byKey(const Key('var-reference-picker-trigger')));
      await Harness.settle(t);
      await t.tap(find.text('files').first);
      await Harness.settle(t);

      expect(dataOf(h, 'doc-node')['variable_selector'], ['node-1', 'files']);
      expect(dataOf(h, 'doc-node')['is_array_file'], true);
      expect(
        find.textContaining('workflow.nodes.docExtractor.supportFileTypes:{"types":"pdf, markdown, docx"}'),
        findsOneWidget,
      );
      await t.tap(find.text('workflow.nodes.docExtractor.learnMore'));
      expect(opened, [link]);
      await openOutputs(t);
      expect(find.text('array[string]'), findsOneWidget);
      await h.dispose(t);
    });

    testWidgets('uses chinese separators and array output types when the input is an array of files', (t) async {
      final h = await renderDocPanel(t, selector: const ['node-1', 'files'], isArrayFile: true, chinese: true);

      expect(
        find.textContaining('workflow.nodes.docExtractor.supportFileTypes:{"types":"pdf、 markdown、 docx"}'),
        findsOneWidget,
      );
      await openOutputs(t);
      expect(find.text('text'), findsOneWidget);
      expect(find.text('array[string]'), findsOneWidget);
      await h.dispose(t);
    });
  });
}
