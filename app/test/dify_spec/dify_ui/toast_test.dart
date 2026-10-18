// dify-spec: packages/dify-ui/src/toast/__tests__/index.spec.tsx
import 'dart:async';

import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

/// The page: [children] stacked over an 800 x 600 window (the host fills it).
Future<void> render(WidgetTester t, List<Widget> children) async {
  await t.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Material(
        child: Stack(fit: StackFit.expand, children: children),
      ),
    ),
  );
}

/// Lets toasts enter (Base UI's 500 ms transition).
Future<void> settle(WidgetTester t) async {
  await t.pump();
  await t.pump(const Duration(milliseconds: 600));
}

/// The card of the toast titled [title].
Finder card(String title) => find.ancestor(of: find.text(title), matching: find.byType(DifyBlurredBox)).first;

/// Whether the toast titled [title] takes pointer events (not while it is leaving or limited).
bool live(String title) => find.text(title).hitTestable().evaluate().isNotEmpty;

/// A button at [rect] (from the window's top-right) that counts its presses.
Widget underlying(EdgeInsets at, Size size, VoidCallback onPressed) => Positioned(
  top: at.top,
  right: at.right,
  width: size.width,
  height: size.height,
  child: GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: onPressed,
    child: const SizedBox.expand(),
  ),
);

void main() {
  group('@langgenius/dify-ui/toast', () {
    testWidgets('should render a success toast when called through the typed shortcut', (t) async {
      final semantics = t.ensureSemantics();
      await render(t, [const DifyToastHost()]);

      toast.success('Saved', description: 'Your changes are available now.');
      await settle(t);

      expect(find.text('Saved'), findsOneWidget);
      expect(find.text('Your changes are available now.'), findsOneWidget);
      final viewport = find.semantics.byLabel('Notifications').evaluate().single;
      expect(viewport.getSemanticsData().flagsCollection.isLiveRegion, isTrue);
      semantics.dispose();
    });

    testWidgets('should keep multiple toast roots mounted in a collapsed stack', (t) async {
      final semantics = t.ensureSemantics();
      await render(t, [const DifyToastHost()]);

      toast('First toast');
      await settle(t);
      expect(find.text('First toast'), findsOneWidget);

      toast('Second toast');
      toast('Third toast');
      await settle(t);

      expect(find.text('Third toast'), findsOneWidget);
      expect(allByRole(SemanticsRole.dialog), hasLength(3));
      semantics.dispose();
    });

    testWidgets('should not intercept pointer events below a collapsed top-anchored stack', (t) async {
      var pressed = 0;
      await render(t, [
        underlying(EdgeInsets.zero, const Size(400, 300), () => pressed++),
        const DifyToastHost(timeout: Duration.zero),
      ]);

      toast('Older notification');
      toast('Newest notification');
      await settle(t);

      final newest = t.getRect(card('Newest notification'));
      final stackBottom = [
        t.getRect(card('Older notification')).bottom,
        newest.bottom,
      ].reduce((a, b) => a > b ? a : b);
      await t.tapAt(Offset(newest.center.dx, stackBottom + 4));

      expect(pressed, 1);
    });

    testWidgets('should reject a downward swipe and dismiss upward from the top-right viewport', (t) async {
      await render(t, [const DifyToastHost(timeout: Duration.zero, top: 120)]);

      toast('Directional notification');
      await settle(t);
      final initial = t.getRect(card('Directional notification'));

      await t.timedDrag(find.text('Directional notification'), const Offset(0, 240), const Duration(milliseconds: 200));
      await settle(t);

      expect(live('Directional notification'), isTrue);
      expect(t.getRect(card('Directional notification')).top, moreOrLessEquals(initial.top, epsilon: 0.5));

      await t.timedDrag(
        find.text('Directional notification'),
        const Offset(0, -120),
        const Duration(milliseconds: 200),
      );
      await t.pump(const Duration(milliseconds: 50));

      expect(live('Directional notification'), isFalse);
      expect(t.getRect(card('Directional notification')).bottom, lessThan(initial.top));
    });

    testWidgets('should dismiss an expanded background toast from its current row when swiped right', (t) async {
      await render(t, [const DifyToastHost(timeout: Duration.zero)]);

      toast('Background notification');
      toast('Front notification');
      await settle(t);

      final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: t.getRect(card('Front notification')).center);
      await settle(t);
      final front = t.getRect(card('Front notification'));
      final bounds = t.getRect(card('Background notification'));
      expect(bounds.top, greaterThanOrEqualTo(front.bottom + 8 - 0.5), reason: 'expanded: listed below the front');

      await mouse.moveTo(bounds.center);
      await mouse.down(bounds.center);
      for (var i = 0; i < 10; i++) {
        await mouse.moveBy(const Offset(20, 0));
        await t.pump(const Duration(milliseconds: 16));
      }
      await mouse.up();
      await t.pump(const Duration(milliseconds: 50));

      expect(live('Background notification'), isFalse);
      expect(t.getRect(card('Background notification')).top, moreOrLessEquals(bounds.top, epsilon: 0.5));
      await mouse.removePointer();
    });

    testWidgets('should render a neutral toast when called directly', (t) async {
      await render(t, [const DifyToastHost()]);

      toast('Neutral toast');
      await settle(t);

      expect(find.text('Neutral toast'), findsOneWidget);
    });

    testWidgets('should isolate toasts between managers', (t) async {
      final localManager = DifyToastManager();
      final localToast = DifyToast(localManager);
      await render(t, [
        const DifyToastHost(key: Key('global')),
        DifyToastHost(key: const Key('local'), manager: localManager),
      ]);

      localToast.error('Local error');
      toast.success('Global success');
      await settle(t);

      expect(find.text('Local error'), findsOneWidget);
      expect(find.text('Global success'), findsOneWidget);
      final global = find.byKey(const Key('global')), local = find.byKey(const Key('local'));
      expect(find.descendant(of: global, matching: find.text('Global success')), findsOneWidget);
      expect(find.descendant(of: local, matching: find.text('Local error')), findsOneWidget);
      expect(find.descendant(of: global, matching: find.text('Local error')), findsNothing);
      expect(find.descendant(of: local, matching: find.text('Global success')), findsNothing);
    });

    testWidgets('should apply custom positioning to the viewport', (t) async {
      final localManager = DifyToastManager();
      final localToast = DifyToast(localManager);
      await render(t, [DifyToastHost(manager: localManager, top: 80)]);

      localToast('Positioned viewport');
      await settle(t);

      expect(find.text('Positioned viewport'), findsOneWidget);
      expect(t.getRect(card('Positioned viewport')).top, moreOrLessEquals(80, epsilon: 0.5));
    });

    testWidgets('should mark overflow toasts as limited when the stack exceeds the configured limit', (t) async {
      await render(t, [const DifyToastHost(limit: 1)]);

      toast('First toast');
      toast('Second toast');
      await settle(t);

      expect(find.text('Second toast'), findsOneWidget);
      expect(find.text('First toast'), findsOneWidget, reason: 'still mounted');
      expect(live('First toast'), isFalse);
      final opacity = t.widget<Opacity>(
        find.ancestor(of: card('First toast'), matching: find.byType(Opacity)).first,
      );
      expect(opacity.opacity, 0);
    });

    testWidgets('should dismiss a toast when dismiss(id) is called', (t) async {
      await render(t, [const DifyToastHost()]);

      final id = toast('Closable', description: 'This toast can be removed.');
      await settle(t);
      expect(find.text('Closable'), findsOneWidget);

      toast.dismiss(id);
      await settle(t);

      expect(find.text('Closable'), findsNothing);
    });

    testWidgets('should close a toast when the dismiss button is clicked', (t) async {
      var closed = 0;
      await render(t, [const DifyToastHost()]);

      toast('Dismiss me', description: 'Manual dismissal path.', onClose: () => closed++);
      await settle(t);

      expect(find.bySemanticsLabel('Close notification'), findsOneWidget);
      await t.tap(find.bySemanticsLabel('Close notification'));
      await settle(t);

      expect(find.text('Dismiss me'), findsNothing);
      expect(closed, 1);
    });

    testWidgets('should let pointer events pass through a toast while it is exiting', (t) async {
      var pressed = 0;
      await render(t, [
        underlying(const EdgeInsets.only(top: 16, right: 32), const Size(360, 96), () => pressed++),
        const DifyToastHost(),
      ]);

      toast('Dismiss me', timeout: Duration.zero);
      await settle(t);
      final rect = t.getRect(card('Dismiss me'));

      await t.tap(find.bySemanticsLabel('Close notification'));
      await t.pump(const Duration(milliseconds: 16));
      expect(live('Dismiss me'), isFalse);

      await t.tapAt(Offset(800 - 32 - 180, 16 + 48));
      expect(rect.contains(const Offset(800 - 32 - 180, 16 + 48)), isTrue, reason: 'where the toast was');
      expect(pressed, 1);
    });

    testWidgets('should pass the host timeout to added toasts', (t) async {
      await render(t, [const DifyToastHost(timeout: Duration(milliseconds: 1000))]);

      toast('Auto dismiss');
      await t.pump();
      expect(find.text('Auto dismiss'), findsOneWidget);

      await t.pump(const Duration(milliseconds: 999));
      expect(live('Auto dismiss'), isTrue);

      await t.pump(const Duration(milliseconds: 1));
      await t.pump();
      expect(live('Auto dismiss'), isFalse);
    });

    testWidgets('should keep a toast persistent when its timeout is zero', (t) async {
      await render(t, [const DifyToastHost(timeout: Duration(milliseconds: 1000))]);

      toast('Persistent', timeout: Duration.zero);
      await settle(t);

      await t.pump(const Duration(seconds: 5));
      expect(find.text('Persistent'), findsOneWidget);
      expect(live('Persistent'), isTrue);
    });

    testWidgets('should update an existing toast', (t) async {
      await render(t, [const DifyToastHost()]);

      final id = toast.info('Loading', description: 'Preparing your data…');
      await settle(t);
      expect(find.text('Loading'), findsOneWidget);

      toast.update(
        id,
        const DifyToastUpdate(title: 'Done', description: 'Your data is ready.', type: DifyToastType.success),
      );
      await t.pump();

      expect(find.text('Done'), findsOneWidget);
      expect(find.text('Your data is ready.'), findsOneWidget);
      expect(find.text('Loading'), findsNothing);
    });

    testWidgets('should upsert an existing toast when add is called with the same id', (t) async {
      final semantics = t.ensureSemantics();
      await render(t, [const DifyToastHost()]);

      toast('Draft saving', id: 'draft-save-status', description: 'Saving changes…');
      await settle(t);
      expect(find.text('Draft saving'), findsOneWidget);

      toast.success('Draft saved', id: 'draft-save-status', description: 'All changes are saved.');
      await settle(t);

      expect(find.text('Draft saving'), findsNothing);
      expect(find.text('Draft saved'), findsOneWidget);
      expect(find.text('All changes are saved.'), findsOneWidget);
      expect(allByRole(SemanticsRole.dialog), hasLength(1));
      semantics.dispose();
    });

    testWidgets('should render and invoke toast action props', (t) async {
      var acted = 0;
      await render(t, [const DifyToastHost()]);

      toast(
        'Action toast',
        action: DifyToastAction(label: 'Undo', onPressed: () => acted++),
      );
      await settle(t);

      expect(find.bySemanticsLabel('Undo'), findsOneWidget);
      await t.tap(find.text('Undo'));

      expect(acted, 1);
    });

    testWidgets('should transition a promise toast from loading to success', (t) async {
      await render(t, [const DifyToastHost()]);

      final done = Completer<String>();
      unawaited(
        toast.promise<String>(
          done.future,
          loading: 'Saving…',
          success: (result) => DifyToastUpdate(title: 'Saved', description: result, type: DifyToastType.success),
          error: (_) => const DifyToastUpdate(title: 'Failed'),
        ),
      );
      await t.pump();
      expect(find.text('Saving…'), findsOneWidget);

      done.complete('Your changes are available now.');
      await t.pump();
      await t.pump();

      expect(find.text('Saved'), findsOneWidget);
      expect(find.text('Your changes are available now.'), findsOneWidget);
    });
  });
}
