// dify-sf phone layout (no Dify spec): window classes, touch metrics and touch-size hit areas.
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:flutter/foundation.dart';

import 'phone_harness.dart';

void main() {
  group('DifyWindowClass', () {
    test('uses the Material 3 width breakpoints', () {
      expect(DifyWindowClass.forWidth(360), DifyWindowClass.compact);
      expect(DifyWindowClass.forWidth(599.9), DifyWindowClass.compact);
      expect(DifyWindowClass.forWidth(600), DifyWindowClass.medium);
      expect(DifyWindowClass.forWidth(839.9), DifyWindowClass.medium);
      expect(DifyWindowClass.forWidth(840), DifyWindowClass.expanded);
      expect(DifyWindowClass.forWidth(1440), DifyWindowClass.expanded);
    });

    testWidgets('reads the window, not a DifyViewport, and leaves DifyAdaptive alone', (t) async {
      phoneView(t, size: const Size(700, 900));
      late DifyWindowClass windowClass;
      late bool compact;
      await t.pumpWidget(
        MediaQuery(
          data: MediaQueryData.fromView(t.view),
          child: DifyViewport(
            width: 300,
            child: Builder(
              builder: (context) {
                windowClass = DifyWindowClass.of(context);
                compact = DifyAdaptive.compactOf(context);
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      expect(windowClass, DifyWindowClass.medium);
      expect(compact, isTrue, reason: 'DifyAdaptive still answers for the 300 px viewport (< 720)');
      expect(DifyAdaptive.compactWidth, 720);
    });
  });

  group('DifyTouch', () {
    testWidgets('is coarse on Android and iOS only', (t) async {
      late bool coarse;
      await t.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              coarse = DifyTouch.isCoarse(context);
              return const SizedBox();
            },
          ),
        ),
      );
      final platform = defaultTargetPlatform;
      expect(coarse, platform == TargetPlatform.android || platform == TargetPlatform.iOS);
      expect(DifyTouch.minTarget, 48);
    }, variant: TargetPlatformVariant.all());
  });

  group('DifyTouchTarget', () {
    Future<List<String>> pumpButton(WidgetTester t, {bool wrapped = true}) async {
      final taps = <String>[];
      final button = DifyIconButton(
        key: const ValueKey('button'),
        label: 'Add',
        icon: const RemixIcon('add-line', size: 16),
        onPressed: () => taps.add('add'),
      );
      await renderControl(
        t,
        SizedBox(
          width: 200,
          height: 200,
          child: Center(child: wrapped ? DifyTouchTarget(child: button) : button),
        ),
      );
      return taps;
    }

    testWidgets('a 24 px icon button receives a tap 12 px outside its visual box', (t) async {
      final taps = await pumpButton(t);
      final box = t.getRect(find.byKey(const ValueKey('button')));
      expect(box.size, const Size(24, 24));
      for (final at in [
        box.centerLeft - const Offset(12, 0),
        box.centerRight + const Offset(12, 0),
        box.topCenter - const Offset(0, 12),
        box.bottomCenter + const Offset(0, 12),
        box.topLeft - const Offset(12, 12),
      ]) {
        await t.tapAt(at);
        await t.pump();
      }
      expect(taps, ['add', 'add', 'add', 'add', 'add']);
    });

    testWidgets('ignores taps beyond the 48 px area', (t) async {
      final taps = await pumpButton(t);
      final box = t.getRect(find.byKey(const ValueKey('button')));
      await t.tapAt(box.centerLeft - const Offset(13, 0));
      await t.tapAt(box.bottomCenter + const Offset(0, 13));
      await t.pump();
      expect(taps, isEmpty);
    });

    testWidgets('does not change the layout size', (t) async {
      await pumpButton(t, wrapped: false);
      final bare = t.getRect(find.byKey(const ValueKey('button')));
      await pumpButton(t);
      expect(t.getRect(find.byType(DifyTouchTarget)), bare);
      expect(t.getRect(find.byKey(const ValueKey('button'))), bare);
      expect(t.renderObject<RenderDifyTouchTarget>(find.byType(DifyTouchTarget)).touchRect.size, const Size(48, 48));
    });

    testWidgets('the extra area only works inside the parent (documented limitation)', (t) async {
      final taps = <String>[];
      await renderControl(
        t,
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 24,
              height: 24,
              child: DifyTouchTarget(
                child: DifyIconButton(
                  label: 'Add',
                  icon: const RemixIcon('add-line', size: 16),
                  onPressed: () => taps.add('add'),
                ),
              ),
            ),
          ],
        ),
      );
      final box = t.getRect(find.byType(DifyIconButton));
      await t.tapAt(box.bottomCenter + const Offset(0, 8));
      await t.pump();
      expect(taps, isEmpty, reason: 'the 24 px Row does not forward a point below itself');
    });
  });

  group('DifyTouchIconButton', () {
    testWidgets('is a 44 px button with a 48 px hit area and an accessible name', (t) async {
      final taps = <int>[];
      await renderControl(
        t,
        SizedBox(
          width: 100,
          height: 100,
          child: Center(
            child: DifyTouchIconButton(
              label: 'More',
              icon: const RemixIcon('more-fill', size: 22),
              onPressed: () => taps.add(1),
            ),
          ),
        ),
      );
      final box = t.getRect(find.byType(DifyTouchIconButton));
      expect(box.size, const Size(44, 44));
      await t.tapAt(box.centerRight + const Offset(2, 0));
      await t.pump();
      expect(taps, [1]);
      expect(find.bySemanticsLabel('More'), findsOneWidget);
    });

    testWidgets('a toggle: on shows state-accent-active with a text-accent icon and reports toggled', (t) async {
      final handle = t.ensureSemantics();
      var on = false;
      await renderControl(
        t,
        StatefulBuilder(
          builder: (context, setState) => Center(
            child: DifyTouchIconButton(
              label: 'User input fields',
              selected: on,
              icon: const RemixIcon('equalizer-2-line', size: 22),
              onPressed: () => setState(() => on = !on),
            ),
          ),
        ),
      );
      Color? background() => t
          .widget<DifyButtonSurface>(
            find.descendant(of: find.byType(DifyTouchIconButton), matching: find.byType(DifyButtonSurface)),
          )
          .look
          .background;
      expect(background(), isNull);
      expect(t.getSemantics(find.bySemanticsLabel('User input fields')).flagsCollection.isToggled, Tristate.isFalse);
      await t.tap(find.byType(DifyTouchIconButton));
      await t.pump();
      expect(on, isTrue);
      expect(background(), DifyColors.stateAccentActive);
      expect(t.getSemantics(find.bySemanticsLabel('User input fields')).flagsCollection.isToggled, Tristate.isTrue);
      expect(t.getSize(find.byType(DifyTouchIconButton)), const Size(44, 44));
      handle.dispose();
    });
  });

  group('DifyCopyFeedback (touch)', () {
    testWidgets('in a phone sheet\'s header: a 44 px touch icon button named Copy, then Copied for 2 s', (t) async {
      final copied = <Object?>[];
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text']);
        return null;
      });
      addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await renderControl(t, const Center(child: DifyCopyFeedback(content: 'value', touch: true)));
      String tr(String key) => DifyI18n.tr('app-overview', 'overview.appInfo.embedded.$key');
      final button = find.byType(DifyTouchIconButton);
      expect(t.getSize(button), const Size(44, 44));
      expect(t.widget<DifyTouchIconButton>(button).label, tr('copy'));
      expect(find.byType(DifyTooltip), findsNothing, reason: 'no hover tooltip on touch');
      await t.tap(button);
      await t.pump();
      expect(copied, ['value']);
      expect(t.widget<DifyTouchIconButton>(button).label, tr('copied'));
      await t.pump(const Duration(seconds: 2));
      expect(t.widget<DifyTouchIconButton>(button).label, tr('copy'));
    });

    testWidgets('without touch it stays Dify\'s small icon button with its tooltip', (t) async {
      await renderControl(t, const Center(child: DifyCopyFeedback(content: 'value')));
      expect(find.byType(DifyTouchIconButton), findsNothing);
      expect(find.byType(DifyIconButton), findsOneWidget);
      expect(find.byType(DifyTooltip), findsOneWidget);
    });
  });
}
