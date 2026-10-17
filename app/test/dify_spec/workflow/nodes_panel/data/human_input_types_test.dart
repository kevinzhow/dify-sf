// dify-spec: web/app/components/workflow/nodes/human-input/__tests__/types.spec.ts
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/human_input/human_input_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('human-input/types', () {
    group('type guards', () {
      test('should identify each form input kind', () {
        final paragraph = createDefaultFormInputByType(FormInputType.paragraph, 'comment');
        final select = createDefaultFormInputByType(FormInputType.select, 'decision');
        final singleFile = createDefaultFormInputByType(FormInputType.singleFile, 'attachment');
        final multiFiles = createDefaultFormInputByType(FormInputType.multiFiles, 'attachments');

        expect(isParagraphFormInput(paragraph), isTrue);
        expect(isParagraphFormInput(select), isFalse);
        expect(isSelectFormInput(select), isTrue);
        expect(isSelectFormInput(singleFile), isFalse);
        expect(isFileFormInput(singleFile), isTrue);
        expect(isFileFormInput(multiFiles), isFalse);
        expect(isFileListFormInput(multiFiles), isTrue);
        expect(isFileListFormInput(paragraph), isFalse);
      });
    });

    group('default factories', () {
      test('should create a paragraph input with an empty constant default', () {
        expect(createDefaultParagraphFormInput('review'), {
          'type': 'paragraph',
          'output_variable_name': 'review',
          'default': {'type': 'constant', 'selector': <Object?>[], 'value': ''},
        });
      });

      test('should create defaults for every supported input type', () {
        expect(createDefaultFormInputByType(FormInputType.select, 'choice'), {
          'type': 'select',
          'output_variable_name': 'choice',
          'option_source': {'type': 'constant', 'selector': <Object?>[], 'value': <Object?>[]},
        });
        expect(createDefaultFormInputByType(FormInputType.singleFile, 'file'), {
          'type': 'file',
          'output_variable_name': 'file',
          'allowed_file_extensions': <Object?>[],
          'allowed_file_types': ['image'],
          'allowed_file_upload_methods': ['local_file', 'remote_url'],
        });
        expect(createDefaultFormInputByType(FormInputType.multiFiles, 'files'), {
          'type': 'file-list',
          'output_variable_name': 'files',
          'allowed_file_extensions': <Object?>[],
          'allowed_file_types': ['image'],
          'allowed_file_upload_methods': ['local_file', 'remote_url'],
          'number_limits': 5,
        });
      });
    });
  });
}
