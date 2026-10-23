// dify-spec: web/app/components/workflow/nodes/code/__tests__/code-parser.spec.ts
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/core/code_parser.dart';
import 'package:flutter_test/flutter_test.dart';

const python3 = 'python3', javascript = 'javascript';

Map<String, Object?> strings(List<String> keys) => {
  for (final k in keys) k: {'type': 'string', 'children': null},
};

const _py = (
  noParams: 'def main():',
  singleParam: 'def main(param1):',
  multipleParams: 'def main(param1, param2, param3):\n      return {"result": param1}',
  withTypes:
      'def main(param1: str, param2: int, param3: List[str]):\n      result = process_data(param1, param2)\n'
      '      return {"output": result}',
  withDefaults: 'def main(param1: str = "default", param2: int = 0):\n      return {"data": param1}',
);

const _js = (
  noParams: 'function main() {',
  singleParam: 'function main(param1) {',
  multipleParams: 'function main(param1, param2, param3) {\n      return { result: param1 }\n    }',
  withComments:
      '// Main function\n    function main(param1, param2) {\n      // Process data\n'
      '      return { output: process(param1, param2) }\n    }',
  withSpaces: 'function main(  param1  ,   param2  ) {',
);

const _pyReturn = (
  singleReturn: '\ndef main(param1):\n    return {"result": "value"}',
  multipleReturns: '\ndef main(param1, param2):\n    return {"result": "value", "status": "success"}',
  noReturn: '\ndef main():\n    print("Hello")',
  complexReturn: '\ndef main():\n    data = process()\n    return {"result": data, "count": 42, "messages": ["hello"]}',
  nestedObject:
      "\n    def main(name, age, city):\n        return {\n            'personal_info': {\n"
      "                'name': name,\n                'age': age,\n                'city': city\n            },\n"
      "            'timestamp': int(time.time()),\n            'status': 'active'\n        }",
);

const _jsReturn = (
  singleReturn: '\nfunction main(param1) {\n    return { result: "value" }\n}',
  multipleReturns: '\nfunction main(param1) {\n    return { result: "value", status: "success" }\n}',
  withParentheses: '\nfunction main() {\n    return ({ result: "value", status: "success" })\n}',
  noReturn: '\nfunction main() {\n    console.log("Hello")\n}',
  withQuotes: '\nfunction main() {\n    return { "result": \'value\', \'status\': "success" }\n}',
  nestedObject:
      '\nfunction main(name, age, city) {\n    return {\n        personal_info: {\n            name: name,\n'
      '            age: age,\n            city: city\n        },\n        timestamp: Date.now(),\n'
      "        status: 'active'\n    }\n}",
);

void main() {
  group('extractFunctionParams', () {
    group('Python3', () {
      test('handles no parameters', () => expect(extractFunctionParams(_py.noParams, python3), isEmpty));
      test('extracts single parameter', () => expect(extractFunctionParams(_py.singleParam, python3), ['param1']));
      test('extracts multiple parameters', () {
        expect(extractFunctionParams(_py.multipleParams, python3), ['param1', 'param2', 'param3']);
      });
      test('handles type hints', () {
        expect(extractFunctionParams(_py.withTypes, python3), ['param1', 'param2', 'param3']);
      });
      test('handles default values', () {
        expect(extractFunctionParams(_py.withDefaults, python3), ['param1', 'param2']);
      });
    });

    group('JavaScript', () {
      test('handles no parameters', () => expect(extractFunctionParams(_js.noParams, javascript), isEmpty));
      test('extracts single parameter', () {
        expect(extractFunctionParams(_js.singleParam, javascript), ['param1']);
      });
      test('extracts multiple parameters', () {
        expect(extractFunctionParams(_js.multipleParams, javascript), ['param1', 'param2', 'param3']);
      });
      test('handles comments in code', () {
        expect(extractFunctionParams(_js.withComments, javascript), ['param1', 'param2']);
      });
      test('handles whitespace', () => expect(extractFunctionParams(_js.withSpaces, javascript), ['param1', 'param2']));
    });
  });

  group('extractReturnType', () {
    group('Python3', () {
      test('extracts single return value', () {
        expect(extractReturnType(_pyReturn.singleReturn, python3), strings(['result']));
      });
      test('extracts multiple return values', () {
        expect(extractReturnType(_pyReturn.multipleReturns, python3), strings(['result', 'status']));
      });
      test('returns empty object when no return statement', () {
        expect(extractReturnType(_pyReturn.noReturn, python3), isEmpty);
      });
      test('handles complex return statement', () {
        expect(extractReturnType(_pyReturn.complexReturn, python3), strings(['result', 'count', 'messages']));
      });
      test('handles nested object structure', () {
        expect(
          extractReturnType(_pyReturn.nestedObject, python3),
          strings(['personal_info', 'timestamp', 'status']),
        );
      });
    });

    group('JavaScript', () {
      test('extracts single return value', () {
        expect(extractReturnType(_jsReturn.singleReturn, javascript), strings(['result']));
      });
      test('extracts multiple return values', () {
        expect(extractReturnType(_jsReturn.multipleReturns, javascript), strings(['result', 'status']));
      });
      test('handles return with parentheses', () {
        expect(extractReturnType(_jsReturn.withParentheses, javascript), strings(['result', 'status']));
      });
      test('returns empty object when no return statement', () {
        expect(extractReturnType(_jsReturn.noReturn, javascript), isEmpty);
      });
      test('handles quoted keys', () {
        expect(extractReturnType(_jsReturn.withQuotes, javascript), strings(['result', 'status']));
      });
      test('handles nested object structure', () {
        expect(
          extractReturnType(_jsReturn.nestedObject, javascript),
          strings(['personal_info', 'timestamp', 'status']),
        );
      });
    });
  });
}
