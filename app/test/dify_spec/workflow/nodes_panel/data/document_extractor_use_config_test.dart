// dify-spec: web/app/components/workflow/nodes/document-extractor/__tests__/use-config.spec.ts
//
// use-config's logic is docExtractorVarChange / docExtractorFilterVar; the variable's type comes from the scope
// (Dify's getCurrentVariableType), here a loop's child reading a Start file list.
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/document_extractor/document_extractor_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/panel_fields.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  group('document-extractor/use-config', () {
    testWidgets('updates the selected variable and tracks array file output types', (t) async {
      final start = difyNode('node-2', {
        'type': 'start',
        'title': 'Start',
        'variables': [
          {'variable': 'files', 'label': 'files', 'type': 'file-list', 'required': false},
        ],
      });
      final h = await Harness.start(
        t,
        [
          start,
          difyNode('loop-1', {'type': 'loop', 'title': 'Loop', 'loop_count': 10}, x: 300),
          difyNode('doc-node', {
            'type': 'document-extractor',
            'variable_selector': <Object?>[],
            'is_array_file': false,
          }, parent: 'loop-1'),
        ],
        edges: [edge('node-2', 'loop-1')],
      );
      await renderBody(t, h, 'doc-node', documentExtractorPanelBody);
      await t.tap(find.byKey(const Key('var-reference-picker-trigger')));
      await Harness.settle(t);
      await t.tap(find.text('files').first);
      await Harness.settle(t);

      final data = dataOf(h, 'doc-node');
      expect(data['variable_selector'], ['node-2', 'files']);
      expect(data['is_array_file'], true);
      expect(
        docExtractorVarChange(const {'is_array_file': true}, const ['x', 'y'], 'file'),
        {
          'is_array_file': false,
          'variable_selector': const ['x', 'y'],
        },
      );
      await h.dispose(t);
    });

    test('only accepts file variables in the picker filter', () {
      expect(docExtractorFilterVar(const PickerVar('a', 'file'), const []), true);
      expect(docExtractorFilterVar(const PickerVar('a', 'array[file]'), const []), true);
      expect(docExtractorFilterVar(const PickerVar('a', 'string'), const []), false);
    });
  });
}
