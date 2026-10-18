// dify-spec: web/app/components/base/chat/chat/answer/human-input-content/__tests__/utils.spec.ts
//
// FileEntity values are dify-sf's HumanInputFile.
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/human_input/human_input_model.dart';
import 'package:dify_sf_app/src/workflow_editor/run/ui/human_input_content.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> paragraphInput([Map<String, Object?> o = const {}]) => {
  'type': 'paragraph',
  'output_variable_name': 'field',
  'default': {'type': 'constant', 'value': '', 'selector': <Object?>[]},
  ...o,
};

Map<String, Object?> selectInput([Map<String, Object?> o = const {}]) => {
  'type': 'select',
  'output_variable_name': 'field',
  'option_source': {
    'type': 'constant',
    'value': ['option-a', 'option-b'],
    'selector': <Object?>[],
  },
  ...o,
};

Map<String, Object?> fileInput([Map<String, Object?> o = const {}]) => {
  'type': 'file',
  'output_variable_name': 'field',
  'allowed_file_extensions': <Object?>[],
  'allowed_file_types': ['image'],
  'allowed_file_upload_methods': ['local_file'],
  ...o,
};

Map<String, Object?> fileListInput([Map<String, Object?> o = const {}]) => {
  'type': 'file-list',
  'output_variable_name': 'field',
  'allowed_file_extensions': <Object?>[],
  'allowed_file_types': ['image'],
  'allowed_file_upload_methods': ['local_file'],
  'number_limits': 5,
  ...o,
};

const uploadedFile = HumanInputFile(
  transferMethod: 'local_file',
  supportFileType: 'image',
  uploadedId: 'upload-file-1',
  name: 'avatar.png',
  size: 128,
);
const uploadingFile = HumanInputFile(
  transferMethod: 'local_file',
  supportFileType: 'image',
  progress: 50,
  name: 'avatar.png',
  size: 128,
);

Map<String, Object?> fileResponse(String id, String name) => {
  'related_id': id,
  'size': 128,
  'extension': '.pdf',
  'filename': name,
  'mime_type': 'application/pdf',
  'transfer_method': 'local_file',
  'type': 'document',
  'url': 'https://example.com/$name',
  'upload_file_id': 'upload-$id',
  'remote_url': '',
};

void main() {
  group('human-input utils', () {
    group('getButtonStyle', () {
      test('should map all supported button styles', () {
        expect(getButtonStyle(UserActionButtonType.primary), 'primary');
        expect(getButtonStyle(UserActionButtonType.defaultStyle), 'secondary');
        expect(getButtonStyle(UserActionButtonType.accent), 'secondary-accent');
        expect(getButtonStyle(UserActionButtonType.ghost), 'ghost');
      });

      test('should return undefined for unsupported style values', () {
        expect(getButtonStyle('unknown'), isNull);
      });
    });

    group('splitByOutputVar', () {
      test('should split content around output variable placeholders', () {
        expect(splitByOutputVar(r'Hello {{#$output.user_name#}}!'), ['Hello ', r'{{#$output.user_name#}}', '!']);
      });

      test('should return original content when no placeholders exist', () {
        expect(splitByOutputVar('no placeholders'), ['no placeholders']);
      });
    });

    group('form content inputs', () {
      test('should extract and filter input fields rendered in form content', () {
        final formInputs = [
          selectInput({'output_variable_name': 'visible_select'}),
          paragraphInput({'output_variable_name': 'visible_paragraph'}),
          fileInput({'output_variable_name': 'stale_file'}),
        ];
        const content = r'Select {{#$output.visible_select#}} and write {{#$output.visible_paragraph#}}';
        expect(formContentInputNames(content), ['visible_select', 'visible_paragraph']);
        expect(renderedFormInputs(formInputs, content).map(inputNameOf), ['visible_select', 'visible_paragraph']);
      });
    });

    group('initializeInputs', () {
      test('should initialize paragraph fields with constants and variable defaults', () {
        final formInputs = [
          paragraphInput({
            'output_variable_name': 'name',
            'default': {'type': 'constant', 'value': 'John', 'selector': <Object?>[]},
          }),
          paragraphInput({
            'output_variable_name': 'bio',
            'default': {'type': 'variable', 'value': '', 'selector': <Object?>[]},
          }),
        ];
        expect(initializeInputs(formInputs, {'bio': 'Lives in Berlin'}), {'name': 'John', 'bio': 'Lives in Berlin'});
      });

      test('should initialize select fields with empty strings', () {
        expect(
          initializeInputs([
            selectInput({'output_variable_name': 'role'}),
          ]),
          {'role': ''},
        );
      });

      test('should initialize single file fields with null', () {
        expect(
          initializeInputs([
            fileInput({'output_variable_name': 'avatar'}),
          ]),
          {'avatar': null},
        );
      });

      test('should initialize file list fields with empty arrays', () {
        expect(
          initializeInputs([
            fileListInput({'output_variable_name': 'attachments'}),
          ]),
          {'attachments': []},
        );
      });

      test('should fallback to empty string when variable default is missing', () {
        final formInputs = [
          paragraphInput({
            'output_variable_name': 'summary',
            'default': {'type': 'variable', 'value': '', 'selector': <Object?>[]},
          }),
        ];
        expect(initializeInputs(formInputs, {}), {'summary': ''});
      });

      test('should fallback to default paragraph values when resolved defaults are not strings', () {
        final formInputs = [
          paragraphInput({
            'output_variable_name': 'summary',
            'default': {'type': 'variable', 'value': '', 'selector': <Object?>[]},
          }),
        ];
        expect(initializeInputs(formInputs, {'summary': fileResponse('file-1', 'brief.pdf')}), {'summary': ''});
      });

      test('should ignore resolved defaults for non-paragraph fields', () {
        final formInputs = [
          selectInput({'output_variable_name': 'role'}),
          fileInput({'output_variable_name': 'avatar'}),
          fileListInput({'output_variable_name': 'attachments'}),
        ];
        expect(
          initializeInputs(formInputs, {
            'role': 'maintainer',
            'avatar': fileResponse('file-2', 'avatar.png'),
            'attachments': [fileResponse('file-3', 'notes.txt')],
          }),
          {'role': '', 'avatar': null, 'attachments': []},
        );
      });

      test('should ignore unsupported input types', () {
        expect(
          initializeInputs([
            {'type': 'unsupported', 'output_variable_name': 'unknown'},
          ]),
          <String, Object?>{},
        );
      });
    });

    group('required input checks', () {
      test('should ignore fields that are not present in values', () {
        final formInputs = [
          selectInput({'output_variable_name': 'visible_select'}),
          fileInput({'output_variable_name': 'stale_file'}),
          paragraphInput({'output_variable_name': 'stale_paragraph'}),
        ];
        final values = {'visible_select': 'approved'};
        expect(hasInvalidSelectOrFileInput(formInputs, values), isFalse);
        expect(hasInvalidRequiredHumanInput(formInputs, values), isFalse);
      });

      test('should detect empty select values and unuploaded file values', () {
        expect(
          hasInvalidSelectOrFileInput(
            [
              selectInput({'output_variable_name': 'decision'}),
            ],
            {'decision': ''},
          ),
          isTrue,
        );
        expect(
          hasInvalidRequiredHumanInput(
            [
              paragraphInput({'output_variable_name': 'summary'}),
            ],
            {'summary': '   '},
          ),
          isTrue,
        );
        expect(
          hasInvalidSelectOrFileInput(
            [
              fileInput({'output_variable_name': 'attachment'}),
            ],
            {'attachment': uploadingFile},
          ),
          isTrue,
        );
        expect(
          hasInvalidRequiredHumanInput(
            [
              fileListInput({'output_variable_name': 'attachments'}),
            ],
            {
              'attachments': [uploadedFile, uploadingFile],
            },
          ),
          isTrue,
        );
      });

      test('should accept uploaded single and multiple file values', () {
        final inputs = [
          fileInput({'output_variable_name': 'attachment'}),
          fileListInput({'output_variable_name': 'attachments'}),
        ];
        final values = {
          'attachment': [uploadedFile],
          'attachments': [uploadedFile],
        };
        expect(hasInvalidSelectOrFileInput(inputs, values), isFalse);
        expect(hasInvalidRequiredHumanInput(inputs, values), isFalse);
      });

      test('should treat unsupported input types as valid by default', () {
        final unsupported = [
          {'type': 'unsupported', 'output_variable_name': 'unknown'},
        ];
        expect(hasInvalidSelectOrFileInput(unsupported, {'unknown': 'value'}), isFalse);
        expect(hasInvalidRequiredHumanInput(unsupported, {'unknown': 'value'}), isFalse);
      });
    });

    group('getProcessedHumanInputFormInputs', () {
      test('should return undefined when no values are provided', () {
        expect(processedHumanInputFormInputs(const [], null), isNull);
      });

      test('should process file values and fallback invalid file values', () {
        const processed = {
          'type': 'image',
          'transfer_method': 'local_file',
          'url': '',
          'upload_file_id': 'upload-file-1',
        };
        expect(
          processedHumanInputFormInputs(
            [
              fileInput({'output_variable_name': 'attachment'}),
              fileInput({'output_variable_name': 'attachmentFromArray'}),
              fileInput({'output_variable_name': 'emptyAttachment'}),
              fileListInput({'output_variable_name': 'attachments'}),
              fileListInput({'output_variable_name': 'emptyAttachments'}),
            ],
            {
              'attachment': uploadedFile,
              'attachmentFromArray': [uploadedFile],
              'emptyAttachment': '',
              'attachments': [uploadedFile],
              'emptyAttachments': null,
            },
          ),
          {
            'attachment': processed,
            'attachmentFromArray': processed,
            'emptyAttachment': null,
            'attachments': [processed],
            'emptyAttachments': [],
          },
        );
      });
    });

    group('time helpers', () {
      test('should format relative time for supported and fallback locales', () {
        final twoMinutesAgo = DateTime.now().millisecondsSinceEpoch - 2 * 60 * 1000;
        expect(getRelativeTime(twoMinutesAgo, 'en-US'), matches(RegExp('ago', caseSensitive: false)));
        expect(getRelativeTime(twoMinutesAgo, 'es-ES'), matches(RegExp('ago', caseSensitive: false)));
      });

      test('should compare utc timestamp against current time', () {
        final now = DateTime.now().millisecondsSinceEpoch;
        expect(isRelativeTimeSameOrAfter(now + 60000), isTrue);
        expect(isRelativeTimeSameOrAfter(now - 60000), isFalse);
      });
    });
  });
}
