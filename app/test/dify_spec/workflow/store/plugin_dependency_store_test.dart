// dify-spec: web/app/components/workflow/store/__tests__/plugin-dependency-store.spec.ts
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter_test/flutter_test.dart';

DifyJson marketplace(String id) => {
  'type': 'marketplace',
  'value': {'plugin_unique_identifier': id},
};

void main() {
  late PluginDependencyStore store;
  setUp(() => store = PluginDependencyStore());
  tearDown(() => store.dispose());

  group('Plugin Dependency Store', () {
    group('Initial State', () {
      test('should start with empty dependencies', () {
        expect(store.dependencies.value, isEmpty);
      });
    });

    group('setDependencies', () {
      test('should update dependencies list', () {
        final deps = [marketplace('p1'), marketplace('p2')];

        store.setDependencies(deps);
        expect(store.dependencies.value, deps);
      });

      test('should replace existing dependencies', () {
        store.setDependencies([marketplace('p1')]);
        store.setDependencies([marketplace('p2')]);

        expect(store.dependencies.value, hasLength(1));
      });

      test('should handle empty array', () {
        store.setDependencies([marketplace('p1')]);
        store.setDependencies([]);

        expect(store.dependencies.value, isEmpty);
      });
    });
  });
}
