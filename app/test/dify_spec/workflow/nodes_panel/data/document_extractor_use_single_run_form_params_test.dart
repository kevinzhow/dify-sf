// dify-spec: web/app/components/workflow/nodes/document-extractor/__tests__/use-single-run-form-params.spec.ts
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/document_extractor/document_extractor_panel.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  setUp(useDifyTestTranslator);

  group('document-extractor/use-single-run-form-params', () {
    test('exposes a single files form and updates run input values', () {
      final calls = <Map<String, Object?>>[];
      final r = docExtractorSingleRunFormParams(
        payload: const {
          'variable_selector': ['start', 'files'],
          'is_array_file': false,
        },
        runInputData: const {
          'files': ['old-file'],
        },
        setRunInputData: calls.add,
      );

      expect(r.forms, hasLength(1));
      expect(r.forms[0].inputs, hasLength(1));
      expect(r.forms[0].inputs[0]['variable'], 'files');
      expect(r.forms[0].inputs[0]['required'], true);

      r.forms[0].onChange(const {
        'files': ['new-file'],
      });
      expect(calls, [
        {
          'files': ['new-file'],
        },
      ]);
      expect(r.getDependentVars(), [
        ['start', 'files'],
      ]);
      expect(r.getDependentVar('files'), ['start', 'files']);
    });
  });
}
