// dify-spec: web/app/components/workflow/nodes/_base/components/variable/__tests__/match-schema-type.spec.ts
import 'package:dify_sf_app/src/workflow/match_schema_type.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _fileProperties() => {
  'name': {'type': 'string', 'description': 'file name'},
  'size': {'type': 'number', 'description': 'file size'},
  'extension': {'type': 'string', 'description': 'file extension'},
  'type': {'type': 'string', 'description': 'file type'},
  'mime_type': {'type': 'string', 'description': 'file mime type'},
  'transfer_method': {'type': 'string', 'description': 'file transfer method'},
  'url': {'type': 'string', 'description': 'file url'},
  'related_id': {'type': 'string', 'description': 'file related id'},
};

void main() {
  group('match the schema type', () {
    test('should return true for identical primitive types', () {
      expect(matchTheSchemaType({'type': 'string'}, {'type': 'string'}), true);
      expect(matchTheSchemaType({'type': 'number'}, {'type': 'number'}), true);
    });

    test('should return false for different primitive types', () {
      expect(matchTheSchemaType({'type': 'string'}, {'type': 'number'}), false);
    });

    test('should ignore values and only compare types', () {
      expect(matchTheSchemaType({'type': 'string', 'value': 'hello'}, {'type': 'string', 'value': 'world'}), true);
      expect(matchTheSchemaType({'type': 'number', 'value': 42}, {'type': 'number', 'value': 100}), true);
    });

    test('should return true for structural differences but no types', () {
      expect(
        matchTheSchemaType(
          {
            'type': 'string',
            'other': {'b': 'xxx'},
          },
          {'type': 'string', 'other': 'xxx'},
        ),
        true,
      );
      expect(
        matchTheSchemaType(
          {
            'type': 'string',
            'other': {'b': 'xxx'},
          },
          {'type': 'string'},
        ),
        true,
      );
    });

    test('should handle nested objects with same structure and types', () {
      final obj1 = {
        'type': 'object',
        'properties': {
          'name': {'type': 'string'},
          'age': {'type': 'number'},
          'address': {
            'type': 'object',
            'properties': {
              'street': {'type': 'string'},
              'city': {'type': 'string'},
            },
          },
        },
      };
      final obj2 = {
        'type': 'object',
        'properties': {
          'name': {'type': 'string', 'value': 'Alice'},
          'age': {'type': 'number', 'value': 30},
          'address': {
            'type': 'object',
            'properties': {
              'street': {'type': 'string', 'value': '123 Main St'},
              'city': {'type': 'string', 'value': 'Wonderland'},
            },
          },
        },
      };
      expect(matchTheSchemaType(obj1, obj2), true);
    });
    test('should return false for nested objects with different structures', () {
      final obj1 = {
        'type': 'object',
        'properties': {
          'name': {'type': 'string'},
          'age': {'type': 'number'},
        },
      };
      final obj2 = {
        'type': 'object',
        'properties': {
          'name': {'type': 'string'},
          'address': {'type': 'string'},
        },
      };
      expect(matchTheSchemaType(obj1, obj2), false);
    });

    test('file struct should match file type', () {
      final fileSchema = {
        r'$id': 'https://dify.ai/schemas/v1/file.json',
        r'$schema': 'http://json-schema.org/draft-07/schema#',
        'version': '1.0.0',
        'type': 'object',
        'title': 'File Schema',
        'description': 'Schema for file objects (v1)',
        'properties': _fileProperties(),
        'required': ['name'],
      };
      final file = {
        'type': 'object',
        'title': 'File',
        'description': 'Schema for file objects (v1)',
        'properties': _fileProperties(),
        'required': ['name'],
      };
      expect(matchTheSchemaType(fileSchema, file), true);
    });
  });
}
