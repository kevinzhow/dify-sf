// dify-spec: web/app/components/workflow/nodes/tool/__tests__/output-schema-utils.spec.ts
import 'package:dify_sf_app/src/workflow/output_vars.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/tool/tool_model.dart';
import 'package:flutter_test/flutter_test.dart';

/// The spec's mock of getMatchedSchemaType: the schema's own `schema_type` / `schemaType`.
String? match(Object? schema) => schema is Map ? (schema['schema_type'] ?? schema['schemaType']) as String? : null;

({String type, String? schemaType}) resolve(Object? schema) => resolveVarType(schema, match: match);

void main() {
  group('output-schema-utils', () {
    group('normalizeJsonSchemaType', () {
      test('should return undefined for null or undefined schema', () {
        expect(normalizeJsonSchemaType(null), isNull);
      });

      test('should return the type directly for simple string type', () {
        for (final t in ['string', 'number', 'boolean', 'object', 'array', 'integer']) {
          expect(normalizeJsonSchemaType({'type': t}), t);
        }
      });

      test('should handle array type with nullable (e.g., ["string", "null"])', () {
        expect(
          normalizeJsonSchemaType({
            'type': ['string', 'null'],
          }),
          'string',
        );
        expect(
          normalizeJsonSchemaType({
            'type': ['null', 'number'],
          }),
          'number',
        );
        expect(
          normalizeJsonSchemaType({
            'type': ['object', 'null'],
          }),
          'object',
        );
      });

      test('should handle oneOf schema', () {
        expect(
          normalizeJsonSchemaType({
            'oneOf': [
              {'type': 'string'},
              {'type': 'null'},
            ],
          }),
          'string',
        );
      });

      test('should handle anyOf schema', () {
        expect(
          normalizeJsonSchemaType({
            'anyOf': [
              {'type': 'number'},
              {'type': 'null'},
            ],
          }),
          'number',
        );
      });

      test('should handle allOf schema', () {
        expect(
          normalizeJsonSchemaType({
            'allOf': [
              {'type': 'object'},
            ],
          }),
          'object',
        );
      });

      test('should infer object type from properties', () {
        expect(
          normalizeJsonSchemaType({
            'properties': {
              'name': {'type': 'string'},
            },
          }),
          'object',
        );
      });

      test('should infer array type from items', () {
        expect(
          normalizeJsonSchemaType({
            'items': {'type': 'string'},
          }),
          'array',
        );
      });

      test('should return undefined for empty schema', () {
        expect(normalizeJsonSchemaType({}), isNull);
      });
    });

    group('pickItemSchema', () {
      test('should return undefined for null or undefined schema', () {
        expect(pickItemSchema(null), isNull);
      });

      test('should return undefined if no items property', () {
        expect(pickItemSchema({'type': 'array'}), isNull);
        expect(pickItemSchema({}), isNull);
      });

      test('should return items directly if items is an object', () {
        final item = {'type': 'string'};
        expect(identical(pickItemSchema({'items': item}), item), isTrue);
      });

      test('should return first item if items is an array (tuple schema)', () {
        final first = {'type': 'string'}, second = {'type': 'number'};
        expect(
          identical(
            pickItemSchema({
              'items': [first, second],
            }),
            first,
          ),
          isTrue,
        );
      });
    });

    group('resolveVarType', () {
      group('primitive types', () {
        test('should resolve string type', () => expect(resolve({'type': 'string'}).type, VarType.string));
        test('should resolve number type', () => expect(resolve({'type': 'number'}).type, VarType.number));
        test('should resolve integer type', () => expect(resolve({'type': 'integer'}).type, VarType.integer));
        test('should resolve boolean type', () => expect(resolve({'type': 'boolean'}).type, VarType.boolean));
        test('should resolve object type', () => expect(resolve({'type': 'object'}).type, VarType.object));
      });

      group('array types', () {
        Map<String, Object?> arrayOf(String t) => {
          'type': 'array',
          'items': {'type': t},
        };
        test('should resolve array of strings to arrayString', () {
          expect(resolve(arrayOf('string')).type, VarType.arrayString);
        });
        test('should resolve array of numbers to arrayNumber', () {
          expect(resolve(arrayOf('number')).type, VarType.arrayNumber);
        });
        test('should resolve array of integers to arrayNumber', () {
          expect(resolve(arrayOf('integer')).type, VarType.arrayNumber);
        });
        test('should resolve array of booleans to arrayBoolean', () {
          expect(resolve(arrayOf('boolean')).type, VarType.arrayBoolean);
        });
        test('should resolve array of objects to arrayObject', () {
          expect(resolve(arrayOf('object')).type, VarType.arrayObject);
        });
        test('should resolve array without items to generic array', () {
          expect(resolve({'type': 'array'}).type, VarType.array);
        });
      });

      group('complex schema - user scenario (tags field)', () {
        test('should correctly resolve tags array with object items', () {
          final tags = {
            'type': 'array',
            'description': '标签数组',
            'items': {
              'type': 'object',
              'properties': {
                'id': {'type': 'string', 'description': '标签ID'},
                'k': {'type': 'number', 'description': '标签类型'},
                'group': {'type': 'number', 'description': '标签分组'},
              },
            },
          };
          expect(resolve(tags).type, VarType.arrayObject);
        });
      });

      group('nullable types', () {
        test('should handle nullable string type', () {
          expect(
            resolve({
              'type': ['string', 'null'],
            }).type,
            VarType.string,
          );
        });
        test('should handle nullable array type', () {
          expect(
            resolve({
              'type': ['array', 'null'],
              'items': {'type': 'string'},
            }).type,
            VarType.arrayString,
          );
        });
      });

      group('Dify compact types (workflow-as-tool output_schema)', () {
        test('should resolve array[string] to arrayString (issue #34428)', () {
          expect(resolve({'type': 'array[string]'}).type, VarType.arrayString);
        });
        test('should resolve Array[string] case-insensitively', () {
          expect(resolve({'type': 'Array[string]'}).type, VarType.arrayString);
        });
        test('should resolve array[object] to arrayObject', () {
          expect(resolve({'type': 'array[object]'}).type, VarType.arrayObject);
        });
      });

      group('unknown types', () {
        test('should resolve unknown type to any', () => expect(resolve({'type': 'unknown_type'}).type, VarType.any));
        test('should resolve empty schema to any', () => expect(resolve({}).type, VarType.any));
      });

      group('file types via schemaType', () {
        test('should resolve object with file schemaType to file', () {
          final r = resolve({'type': 'object', 'schema_type': 'file'});
          expect(r.type, VarType.file);
          expect(r.schemaType, 'file');
        });
        test('should resolve array of files to arrayFile', () {
          expect(
            resolve({
              'type': 'array',
              'items': {'type': 'object', 'schema_type': 'file'},
            }).type,
            VarType.arrayFile,
          );
        });
      });

      group('nested arrays', () {
        test('should handle array of arrays as generic array', () {
          expect(
            resolve({
              'type': 'array',
              'items': {
                'type': 'array',
                'items': {'type': 'string'},
              },
            }).type,
            VarType.array,
          );
        });
      });
    });
  });
}
