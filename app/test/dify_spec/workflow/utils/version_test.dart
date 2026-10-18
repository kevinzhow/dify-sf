// dify-spec: web/app/components/workflow/utils/__tests__/version.spec.ts
import 'package:dify_sf_app/src/workflow_editor/header/publisher/utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('getWorkflowVersionName', () {
    test('prefers a marked name over the version number', () {
      expect(
        getWorkflowVersionName(markedName: 'Production', versionNumber: 7, defaultName: 'Untitled Version'),
        'Production',
      );
    });

    test('uses the version number when the marked name is empty', () {
      expect(getWorkflowVersionName(markedName: '', versionNumber: 7, defaultName: 'Untitled Version'), '# 7');
    });

    test('uses the default name for legacy versions without a version number', () {
      expect(
        getWorkflowVersionName(markedName: '', versionNumber: null, defaultName: 'Untitled Version'),
        'Untitled Version',
      );
    });
  });
}
