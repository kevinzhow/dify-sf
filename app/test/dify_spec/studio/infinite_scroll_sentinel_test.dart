// dify-spec: web/app/components/base/infinite-scroll-sentinel/__tests__/index.spec.tsx
import 'package:dify_sf_app/src/studio/infinite_scroll_sentinel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A 400 px viewport over 1000 px of content with the sentinel at the end (its top at 1000).
Future<ScrollController> _harness(
  WidgetTester t, {
  required bool canLoadMore,
  required VoidCallback onLoadMore,
  required PreloadDistance preloadDistance,
  bool sentinel = true,
  ScrollController? controller,
}) async {
  final c = controller ?? ScrollController();
  if (controller == null) addTearDown(c.dispose);
  await t.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Center(
        child: SizedBox(
          width: 300,
          height: 400,
          child: ListView(
            controller: c,
            children: [
              const SizedBox(height: 1000),
              if (sentinel)
                InfiniteScrollSentinel(
                  canLoadMore: canLoadMore,
                  onLoadMore: onLoadMore,
                  preloadDistance: preloadDistance,
                ),
            ],
          ),
        ),
      ),
    ),
  );
  await t.pump();
  return c;
}

/// Scrolls so that the sentinel is [below] px past the viewport's end.
Future<void> _place(WidgetTester t, ScrollController c, double below) async {
  // The sentinel's bottom is at 1001; the viewport shows [pixels, pixels + 400].
  c.jumpTo(1001 - 400 - below);
  await t.pump();
}

void main() {
  group('InfiniteScrollSentinel', () {
    testWidgets('observes the sentinel relative to the provided scroll container', (t) async {
      var calls = 0;
      final c = await _harness(
        t,
        canLoadMore: true,
        onLoadMore: () => calls++,
        preloadDistance: InfiniteScrollSentinel.fixed(160),
      );
      expect(calls, 0, reason: '601 px below the viewport: outside the 160 px margin');
      await _place(t, c, 170);
      expect(calls, 0);
      await _place(t, c, 150);
      expect(calls, 1, reason: 'within 160 px of the scroll container\'s end');
    });

    testWidgets('resolves a business-owned preload distance from the scroll container', (t) async {
      final asked = <double>[];
      var calls = 0;
      final c = await _harness(
        t,
        canLoadMore: true,
        onLoadMore: () => calls++,
        preloadDistance: (p) {
          asked.add(p.viewportDimension);
          return 240;
        },
      );
      await _place(t, c, 230);
      expect(asked, isNotEmpty);
      expect(asked.first, 400, reason: 'the scroll container is passed in');
      expect(calls, 1);
    });

    testWidgets('notifies whenever the sentinel enters the preload area while loading is allowed', (t) async {
      var calls = 0;
      final c = await _harness(
        t,
        canLoadMore: true,
        onLoadMore: () => calls++,
        preloadDistance: InfiniteScrollSentinel.fixed(160),
      );
      await _place(t, c, 0);
      await _place(t, c, 400);
      await _place(t, c, 0);
      expect(calls, 2);
    });

    testWidgets('pauses load notifications while loading is disallowed and resumes when allowed again', (t) async {
      var calls = 0;
      void load() => calls++;
      final c = await _harness(
        t,
        canLoadMore: true,
        onLoadMore: load,
        preloadDistance: InfiniteScrollSentinel.fixed(160),
      );
      await _place(t, c, 0);
      expect(calls, 1);

      await _harness(
        t,
        canLoadMore: false,
        onLoadMore: load,
        preloadDistance: InfiniteScrollSentinel.fixed(160),
        controller: c,
      );
      await _place(t, c, 400);
      await _place(t, c, 0);
      expect(calls, 1);

      await _harness(
        t,
        canLoadMore: true,
        onLoadMore: load,
        preloadDistance: InfiniteScrollSentinel.fixed(160),
        controller: c,
      );
      expect(calls, 2, reason: 'a new observation reports the sentinel that is already in the preload area');
    });

    testWidgets('uses the latest load callback after rerendering', (t) async {
      var first = 0, next = 0;
      final c = await _harness(
        t,
        canLoadMore: true,
        onLoadMore: () => first++,
        preloadDistance: InfiniteScrollSentinel.fixed(160),
      );
      await _harness(
        t,
        canLoadMore: true,
        onLoadMore: () => next++,
        preloadDistance: InfiniteScrollSentinel.fixed(160),
        controller: c,
      );
      await _place(t, c, 0);
      expect(first, 0);
      expect(next, 1);
    });

    testWidgets('disconnects the observer on unmount', (t) async {
      var calls = 0;
      final c = await _harness(
        t,
        canLoadMore: true,
        onLoadMore: () => calls++,
        preloadDistance: InfiniteScrollSentinel.fixed(160),
      );
      await _harness(
        t,
        canLoadMore: true,
        onLoadMore: () => calls++,
        preloadDistance: InfiniteScrollSentinel.fixed(160),
        controller: c,
        sentinel: false,
      );
      await _place(t, c, -1);
      expect(calls, 0);
      expect(t.takeException(), isNull);
    });
  });
}
