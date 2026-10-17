// dify-spec: web/app/components/workflow/nodes/http/components/edit-body/index.spec.tsx
import 'package:dify_sf_app/src/workflow/var_types.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/http/http_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('HTTP body variable support', () {
    test('should include structured variables in the selector', () {
      expect(httpBodyVariableTypes, [
        VarType.string,
        VarType.number,
        VarType.secret,
        VarType.object,
        VarType.arrayNumber,
        VarType.arrayString,
        VarType.arrayObject,
      ]);
    });

    test('should accept object and array object variables', () {
      expect(isSupportedHttpBodyVariable(VarType.object), isTrue);
      expect(isSupportedHttpBodyVariable(VarType.arrayObject), isTrue);
    });

    test('should keep unsupported file variables excluded', () {
      expect(isSupportedHttpBodyVariable(VarType.file), isFalse);
      expect(isSupportedHttpBodyVariable(VarType.arrayFile), isFalse);
    });
  });
}
