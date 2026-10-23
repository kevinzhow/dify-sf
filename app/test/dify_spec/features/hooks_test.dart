// dify-spec: web/app/components/base/features/__tests__/hooks.spec.ts
import 'package:dify_sf_app/src/workflow_editor/features/features.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// renderHook: what [hook] returns inside [wrapper] (or the error it throws).
Future<Object?> renderHook(WidgetTester t, Object? Function(BuildContext) hook, {FeaturesStore? store}) async {
  Object? result;
  final probe = Builder(
    builder: (context) {
      try {
        result = hook(context);
      } on StateError catch (e) {
        result = e;
      }
      return const SizedBox();
    },
  );
  await t.pumpWidget(store == null ? probe : FeaturesScope(store: store, child: probe));
  return result;
}

void main() {
  group('useFeatures', () {
    testWidgets('should return selected state from the store when useFeatures is called with selector', (t) async {
      final store = FeaturesStore(
        features: {
          'moreLikeThis': {'enabled': true},
        },
      );
      final r = await renderHook(
        t,
        (c) => featureEnabled(FeaturesScope.of(c).features.value, 'moreLikeThis'),
        store: store,
      );
      expect(r, true);
    });

    testWidgets('should throw error when used outside FeaturesContext.Provider', (t) async {
      final r = await renderHook(t, (c) => FeaturesScope.of(c).features.value);
      expect(r, isA<StateError>().having((e) => e.message, 'message', 'Missing FeaturesContext.Provider in the tree'));
    });

    testWidgets('should return undefined when feature does not exist', (t) async {
      final store = FeaturesStore(features: {});
      final r = await renderHook(t, (c) => FeaturesScope.of(c).features.value['nonexistent'], store: store);
      expect(r, isNull);
    });
  });

  group('useFeaturesStore', () {
    testWidgets('should return the store from context when used within provider', (t) async {
      final store = FeaturesStore();
      final r = await renderHook(t, FeaturesScope.maybeOf, store: store);
      expect(identical(r, store), isTrue);
    });

    testWidgets('should return null when used outside provider', (t) async {
      final r = await renderHook(t, FeaturesScope.maybeOf);
      expect(r, isNull);
    });
  });
}
