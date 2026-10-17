// dify-spec: web/app/components/base/prompt-editor/__tests__/utils.spec.ts
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/prompt_blocks.dart';
import 'package:flutter_test/flutter_test.dart';

const _context = PromptBlockSet({PromptBlockKind.context});
const _block = PromptBlock(PromptBlockKind.context);

void main() {
  group('prompt-editor/utils', () {
    group('registerLexicalTextEntity', () {
      test('textNodeTransform: creates replacement node at non-zero match.start', () {
        expect(variableValueRanges('x {{a}}'), [(start: 2, end: 7)]);
      });
    });

    group('decoratorTransform', () {
      test('should replace matched segment at start (match.start === 0)', () {
        expect(transformText('{{#context#}} tail', _context), [_block, ' tail']);
      });

      test('should return when nextText is non-empty and nextMatch.start === 0', () {
        expect(transformText('{{#context#}}{{#context#}}', _context), ['{{#context#}}{{#context#}}']);
      });

      test('should split with non-zero start offset', () {
        expect(transformText('a {{#context#}} b', _context), ['a ', _block, ' b']);
      });
    });

    group('textToEditorState', () {
      test('should serialize multiline text into paragraph nodes', () {
        expect(parsePrompt('line 1\nline 2', PromptBlockSet.none), ['line 1', '\n', 'line 2']);
      });

      test('should create one empty paragraph when text is empty string', () {
        expect(parsePrompt('', PromptBlockSet.none), isEmpty);
        expect(parsePrompt('\n', PromptBlockSet.none), ['\n']);
      });
    });

    group('registerLexicalTextEntity - remaining textNodeTransform branches', () {
      test('textNodeTransform: returns when nextText is non-empty and nextMatch.start===0 (line 130-131)', () {
        expect(variableValueRanges('{{a}}{{b}}'), isEmpty);
        expect(variableValueRanges('{{a}} {{b}}'), [(start: 0, end: 5), (start: 6, end: 11)]);
      });
    });
  });
}
