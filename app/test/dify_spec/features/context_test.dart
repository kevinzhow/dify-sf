// dify-spec: web/app/components/base/features/__tests__/context.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/features/features.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// TestConsumer: the store's moreLikeThis as `enabled` / `disabled`.
Widget consumer() => Builder(
  builder: (context) {
    final store = FeaturesScope.maybeOf(context);
    if (store == null) return const Text('no store', textDirection: TextDirection.ltr);
    final on = featureEnabled(store.features.value, 'moreLikeThis');
    return Text(on ? 'enabled' : 'disabled', textDirection: TextDirection.ltr);
  },
);

void main() {
  group('FeaturesProvider', () {
    testWidgets('should provide store to children when FeaturesProvider wraps them', (t) async {
      await t.pumpWidget(FeaturesProvider(child: consumer()));
      expect(find.text('disabled'), findsOneWidget);
    });

    testWidgets('should provide initial features state when features prop is provided', (t) async {
      await t.pumpWidget(
        FeaturesProvider(
          features: const {
            'moreLikeThis': {'enabled': true},
          },
          child: consumer(),
        ),
      );
      expect(find.text('enabled'), findsOneWidget);
    });

    testWidgets('should maintain the same store reference across re-renders', (t) async {
      final refs = <FeaturesStore?>[];
      Widget collector() => Builder(
        builder: (context) {
          refs.add(FeaturesScope.maybeOf(context));
          return const SizedBox();
        },
      );
      await t.pumpWidget(FeaturesProvider(child: collector()));
      await t.pumpWidget(FeaturesProvider(child: collector()));
      expect(refs, hasLength(2));
      expect(identical(refs[0], refs[1]), isTrue);
    });

    testWidgets('should handle empty features object', (t) async {
      await t.pumpWidget(FeaturesProvider(features: const {}, child: consumer()));
      expect(find.text('disabled'), findsOneWidget);
    });
  });
}
