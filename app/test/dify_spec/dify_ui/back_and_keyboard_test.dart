// dify-sf phone layout (no Dify spec): Android back closes the newest layer first (popups, DifyBackDismiss layers),
// newest first, then the route; Escape is untouched. Full-window forms keep the focused field and the primary action
// above the keyboard (DifyKeyboardScrollView, after raft-flutter's RaftKeyboardScrollView).
import 'dart:async';

import 'phone_harness.dart';

Future<bool> _back(WidgetTester t) async {
  final handled = await t.binding.handlePopRoute();
  await t.pumpAndSettle();
  return handled;
}

List<String> _systemPops(WidgetTester t) {
  final calls = <String>[];
  t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'SystemNavigator.pop') calls.add(call.method);
    return null;
  });
  addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
  return calls;
}

Widget _menu() => DifyDropdownMenu(
  key: const ValueKey('menu'),
  builder: (context, c) =>
      DifyButton(key: const ValueKey('menu-trigger'), onPressed: c.toggle, child: const DifyTextLine('Open')),
  children: [DifyMenuItem(onSelect: () {}, child: const DifyTextLine('Item'))],
);

void main() {
  group('Android back', () {
    testWidgets('closes an open popup before the page; on the home route the system then leaves the app', (t) async {
      phoneView(t);
      final pops = _systemPops(t);
      await pumpPhoneApp(t, DifyPage(body: Center(child: _menu())));
      await t.tap(find.byKey(const ValueKey('menu-trigger')));
      await t.pumpAndSettle();
      expect(find.text('Item'), findsOneWidget);
      expect(await _back(t), isTrue);
      expect(find.text('Item'), findsNothing);
      expect(pops, isEmpty);
      expect(await _back(t), isFalse);
      expect(pops, ['SystemNavigator.pop']);
    });

    testWidgets('closes a popup in a pushed page, then pops the page', (t) async {
      phoneView(t);
      final nav = await pumpPhoneApp(t, const DifyPage(body: DifyTextLine('Home')));
      unawaited(
        nav.currentState!.push(
          difyPageRoute<void>(
            builder: (_) => DifyPage(body: Center(child: _menu())),
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('menu-trigger')));
      await t.pumpAndSettle();
      expect(await _back(t), isTrue);
      expect(find.text('Item'), findsNothing);
      expect(find.byKey(const ValueKey('menu-trigger')), findsOneWidget, reason: 'the page stays');
      expect(await _back(t), isTrue);
      expect(find.text('Home'), findsOneWidget);
    });

    testWidgets('a popup closed in code leaves no step behind for a maybePop in the same event', (t) async {
      phoneView(t);
      final nav = await pumpPhoneApp(t, const DifyPage(body: DifyTextLine('Home')));
      final controller = DifyFloatingController();
      unawaited(
        nav.currentState!.push(
          difyPageRoute<void>(
            builder: (_) => DifyPage(
              body: Center(
                child: DifyPopover(
                  controller: controller,
                  builder: (context, c) => const DifyTextLine('Anchor'),
                  content: Builder(
                    builder: (context) => DifyButton(
                      key: const ValueKey('leave'),
                      onPressed: () {
                        controller.close();
                        Navigator.of(context).maybePop();
                      },
                      child: const DifyTextLine('Leave'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      controller.open();
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('leave')));
      await t.pumpAndSettle();
      expect(find.text('Home'), findsOneWidget, reason: 'the page popped');
    });

    testWidgets('DifyBackDismiss layers unwind newest first; a disabled layer holds no step', (t) async {
      phoneView(t);
      final pops = _systemPops(t);
      final closed = <String>[];
      var a = true, b = false;
      late StateSetter set;
      await pumpPhoneApp(
        t,
        DifyPage(
          body: StatefulBuilder(
            builder: (context, setState) {
              set = setState;
              return DifyBackDismiss(
                enabled: a,
                onDismiss: () => setState(() {
                  a = false;
                  closed.add('a');
                }),
                child: DifyBackDismiss(
                  enabled: b,
                  onDismiss: () => setState(() {
                    b = false;
                    closed.add('b');
                  }),
                  child: const SizedBox.expand(),
                ),
              );
            },
          ),
        ),
      );
      await t.pumpAndSettle();
      set(() => b = true);
      await t.pumpAndSettle();
      expect(await _back(t), isTrue);
      expect(closed, ['b']);
      expect(await _back(t), isTrue);
      expect(closed, ['b', 'a']);
      expect(await _back(t), isFalse);
      expect(pops, hasLength(1));

      // Turned off in code: no step left.
      set(() => a = true);
      await t.pumpAndSettle();
      set(() => a = false);
      await t.pumpAndSettle();
      expect(await _back(t), isFalse);
      expect(closed, ['b', 'a']);
    });

    testWidgets('Escape still closes a popup on desktop and does not pop the route', (t) async {
      phoneView(t, size: const Size(1200, 800));
      final nav = await pumpPhoneApp(t, const DifyPage(body: DifyTextLine('Home')));
      unawaited(
        nav.currentState!.push(
          difyPageRoute<void>(
            builder: (_) => DifyPage(body: Center(child: _menu())),
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('menu-trigger')));
      await t.pumpAndSettle();
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(find.text('Item'), findsNothing);
      expect(find.byKey(const ValueKey('menu-trigger')), findsOneWidget);
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
  });

  group('DifyKeyboardScrollView', () {
    testWidgets('keeps the focused field and the primary action above the keyboard', (t) async {
      phoneView(t, size: const Size(360, 780), padding: const EdgeInsets.only(top: 32, bottom: 24));
      final first = TextEditingController(), last = TextEditingController();
      addTearDown(first.dispose);
      addTearDown(last.dispose);
      Widget field(TextEditingController c, String key) => SizedBox(
        height: 48,
        child: DifyTextField(key: ValueKey(key), controller: c),
      );
      await pumpPhoneApp(
        t,
        Builder(
          builder: (context) => Padding(
            // The page spends the keyboard inset itself (no resizing Scaffold).
            padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
            child: DifyKeyboardScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 420),
                  field(first, 'first'),
                  const SizedBox(height: 12),
                  field(last, 'last'),
                  const SizedBox(height: 12),
                  DifyPrimaryAction(
                    child: DifyButton(key: const ValueKey('submit'), onPressed: () {}, child: const DifyTextLine('Go')),
                  ),
                  const SizedBox(height: 200),
                ],
              ),
            ),
          ),
        ),
      );
      await t.tap(find.descendant(of: find.byKey(const ValueKey('last')), matching: find.byType(EditableText)));
      t.view.viewInsets = const FakeViewPadding(bottom: 300);
      t.view.padding = const FakeViewPadding(top: 32);
      await t.pumpAndSettle(const Duration(milliseconds: 50));
      await t.pump(const Duration(milliseconds: 300));
      await t.pumpAndSettle();
      const keyboardTop = 780 - 300.0;
      expect(t.getRect(find.byKey(const ValueKey('last'))).bottom, lessThanOrEqualTo(keyboardTop));
      expect(t.getRect(find.byKey(const ValueKey('submit'))).bottom, lessThanOrEqualTo(keyboardTop));
      expect(find.byKey(const ValueKey('submit')).hitTestable(), findsOneWidget);
    });
  });
}
