// dify-spec: web/app/components/base/prompt-editor/__tests__/constants.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/prompt_blocks.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('prompt-editor constants', () {
    group('check block helpers', () {
      test('should detect context placeholder only when present', () {
        expect(checkHasContextBlock(''), isFalse);
        expect(checkHasContextBlock('plain text'), isFalse);
        expect(checkHasContextBlock('before $contextPlaceholderText after'), isTrue);
      });

      test('should detect history placeholder only when present', () {
        expect(checkHasHistoryBlock(''), isFalse);
        expect(checkHasHistoryBlock('plain text'), isFalse);
        expect(checkHasHistoryBlock('before $historyPlaceholderText after'), isTrue);
      });

      test('should detect query placeholder only when present', () {
        expect(checkHasQueryBlock(''), isFalse);
        expect(checkHasQueryBlock('plain text'), isFalse);
        expect(checkHasQueryBlock('before $queryPlaceholderText after'), isTrue);
      });
    });

    group('getInputVars', () {
      test('should return empty array for invalid or empty input', () {
        expect(getInputVars(''), isEmpty);
        expect(getInputVars('plain text without vars'), isEmpty);
        expect(getInputVars(null), isEmpty);
      });

      test('should ignore placeholders that are not input vars', () {
        expect(getInputVars('a $contextPlaceholderText b $queryPlaceholderText c'), isEmpty);
      });

      test('should parse regular input vars with dotted selectors', () {
        expect(getInputVars('value {{#node123.result.answer#}} and {{#abc.def#}}'), [
          ['node123', 'result', 'answer'],
          ['abc', 'def'],
        ]);
      });

      test('should strip numeric node id for sys selector vars', () {
        expect(getInputVars('value {{#1711617514996.sys.query#}}'), [
          ['sys', 'query'],
        ]);
      });

      test('should keep selector unchanged when sys prefix is not numeric id', () {
        expect(getInputVars('value {{#abc.sys.query#}}'), [
          ['abc', 'sys', 'query'],
        ]);
      });
    });

    group('file extension map', () {
      test('should expose expected file extensions for each supported type', () {
        expect(fileExts['image'], contains('PNG'));
        expect(fileExts['document'], contains('PDF'));
        expect(fileExts['audio'], contains('MP3'));
        expect(fileExts['video'], contains('MP4'));
      });
    });
  });
}
