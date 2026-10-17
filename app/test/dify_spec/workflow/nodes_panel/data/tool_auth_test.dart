// dify-spec: web/app/components/workflow/nodes/tool/__tests__/auth.spec.ts
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/tool/tool_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isToolAuthorizationRequired', () {
    test('should return true for built-in tools that require authorization and are not authorized', () {
      expect(
        isToolAuthorizationRequired(CollectionType.builtIn, {'allow_delete': true, 'is_team_authorization': false}),
        isTrue,
      );
    });

    test('should return false when the built-in tool is already authorized', () {
      expect(
        isToolAuthorizationRequired(CollectionType.builtIn, {'allow_delete': true, 'is_team_authorization': true}),
        isFalse,
      );
    });

    test('should return false for non-built-in tools even if the provider is unauthorized', () {
      expect(
        isToolAuthorizationRequired(CollectionType.custom, {'allow_delete': true, 'is_team_authorization': false}),
        isFalse,
      );
    });

    test('should return false when the collection is missing or authorization is not required', () {
      expect(isToolAuthorizationRequired(CollectionType.builtIn), isFalse);
      expect(
        isToolAuthorizationRequired(CollectionType.builtIn, {'allow_delete': false, 'is_team_authorization': false}),
        isFalse,
      );
    });
  });
}
