// dify-spec: web/app/components/workflow/utils/__tests__/variable.spec.ts
//
// variableTransformer's two directions are templateToSelector / selectorToTemplate.
import 'package:dify_sf_app/src/workflow/dify_json.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/var_reference_picker.dart' show isExceptionVariable;
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/prompt_chips.dart' as chips;
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('variableTransformer', () {
    group('string → array (template to selector)', () {
      test('should parse a simple template variable', () {
        expect(templateToSelector('{{#node1.output#}}'), ['node1', 'output']);
      });

      test('should parse a deeply nested path', () {
        expect(templateToSelector('{{#node1.data.items.0.name#}}'), ['node1', 'data', 'items', '0', 'name']);
      });

      test('should handle a single-segment path', () {
        expect(templateToSelector('{{#value#}}'), ['value']);
      });
    });

    group('array → string (selector to template)', () {
      test('should join an array into a template variable', () {
        expect(selectorToTemplate(['node1', 'output']), '{{#node1.output#}}');
      });

      test('should join a single-element array', () {
        expect(selectorToTemplate(['value']), '{{#value#}}');
      });
    });
  });

  group('isExceptionVariable', () {
    // The panel's copy and the prompt editor's copy agree.
    bool check(String variable, [String? nodeType]) {
      final a = isExceptionVariable(variable, nodeType);
      expect(chips.isExceptionVariable(variable, nodeType), a);
      return a;
    }

    const errorHandleTypes = ['llm', 'tool', 'http-request', 'code', 'agent'];

    for (final nodeType in errorHandleTypes) {
      test('should return true for error_message with %s node type', () {
        expect(check('error_message', nodeType), isTrue);
      });
    }

    for (final nodeType in errorHandleTypes) {
      test('should return true for error_type with %s node type', () {
        expect(check('error_type', nodeType), isTrue);
      });
    }

    test('should return false for error_message with non-error-handle node types', () {
      expect(check('error_message', 'start'), isFalse);
      expect(check('error_message', 'end'), isFalse);
      expect(check('error_message', 'if-else'), isFalse);
    });

    test('should return false for normal variables with error-handle node types', () {
      expect(check('output', 'llm'), isFalse);
      expect(check('text', 'tool'), isFalse);
    });

    test('should return false when nodeType is undefined', () {
      expect(check('error_message'), isFalse);
    });
  });
}
