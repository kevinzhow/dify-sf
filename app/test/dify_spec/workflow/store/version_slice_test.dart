// dify-spec: web/app/components/workflow/store/__tests__/version-slice.spec.ts
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late WorkflowStore store;
  setUp(() => store = WorkflowStore());
  tearDown(() => store.dispose());

  group('Version Slice', () {
    group('setDraftUpdatedAt', () {
      test('should multiply timestamp by 1000 (seconds to milliseconds)', () {
        store.setDraftUpdatedAt(1704067200);
        expect(store.draftUpdatedAt.value, 1704067200000);
      });

      test('should set 0 when given 0', () {
        store.setDraftUpdatedAt(0);
        expect(store.draftUpdatedAt.value, 0);
      });
    });

    group('setPublishedAt', () {
      test('should multiply timestamp by 1000', () {
        store.setPublishedAt(1704067200);
        expect(store.publishedAt.value, 1704067200000);
      });

      test('should set 0 when given 0', () {
        store.setPublishedAt(0);
        expect(store.publishedAt.value, 0);
      });
    });

    group('currentVersion', () {
      test('should default to null', () {
        expect(store.currentVersion.value, isNull);
      });

      test('should update current version', () {
        final version = <String, Object?>{'hash': 'abc', 'updated_at': 1000, 'version': '1.0'};
        store.setCurrentVersion(version);
        expect(store.currentVersion.value, version);
      });
    });

    group('isRestoring', () {
      test('should toggle restoring state', () {
        store.setIsRestoring(true);
        expect(store.isRestoring.value, true);

        store.setIsRestoring(false);
        expect(store.isRestoring.value, false);
      });
    });
  });
}
