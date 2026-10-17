// dify-spec: web/app/components/workflow/nodes/http/__tests__/utils.spec.ts
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/http/http_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('transformToBodyPayload', () {
    // Bodies without a key (json, raw-text, binary) keep the raw string untouched.
    group('when hasKey is false', () {
      test('should keep the whole string as a single text value', () {
        final result = transformToBodyPayload('{"url":"https://a:1"}', false);

        expect(result, [
          {'type': 'text', 'value': '{"url":"https://a:1"}'},
        ]);
      });
    });

    // form-data / x-www-form-urlencoded bodies are stored as `key:value` lines.
    group('when hasKey is true', () {
      test('should split a simple key:value pair', () {
        expect(transformToBodyPayload('name:alice', true), [
          {'key': 'name', 'type': 'text', 'value': 'alice'},
        ]);
      });

      test('should keep colons that belong to the value', () {
        expect(transformToBodyPayload('url:https://host:8080/path', true)[0], {
          'key': 'url',
          'type': 'text',
          'value': 'https://host:8080/path',
        });
      });

      test('should parse each line independently', () {
        expect(transformToBodyPayload('a:1\nb:2:3', true), [
          {'key': 'a', 'type': 'text', 'value': '1'},
          {'key': 'b', 'type': 'text', 'value': '2:3'},
        ]);
      });

      test('should use an empty value when the line has no colon', () {
        expect(transformToBodyPayload('lonelykey', true), [
          {'key': 'lonelykey', 'type': 'text', 'value': ''},
        ]);
      });
    });
  });
}
