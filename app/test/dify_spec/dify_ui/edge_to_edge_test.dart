// dify-sf phone layout (no Dify spec): edge-to-edge. DifyApplication no longer consumes the system insets for the
// whole navigator; every host keeps its content safe itself, and the phone bars and sheets paint under the system bars.
import 'phone_harness.dart';

typedef _Window = ({Size size, EdgeInsets insets});

const Map<String, _Window> _windows = {
  'gesture navigation': (size: Size(412, 915), insets: gestureInsets),
  'three-button navigation': (size: Size(412, 915), insets: threeButtonInsets),
  'landscape, navigation bar on the right': (size: Size(915, 412), insets: landscapeInsets),
};

const _destinations = [
  DifyNavigationDestination(icon: RemixIcon('apps-2-line', size: 22), label: 'Studio'),
  DifyNavigationDestination(icon: RemixIcon('puzzle-2-line', size: 22), label: 'Integrations'),
  DifyNavigationDestination(icon: RemixIcon('user-line', size: 22), label: 'Account'),
];

Widget _sheetContent(BuildContext context) => Column(
  children: [
    const DifySheetHeader(title: 'Insert variable'),
    Expanded(
      child: ListView(children: [for (var i = 0; i < 30; i++) SizedBox(height: 48, child: DifyTextLine('$i'))]),
    ),
  ],
);

/// The dialog's box (DifyDialogSurface itself fills the route to position it).
Rect _dialogBox(WidgetTester t) =>
    t.getRect(find.descendant(of: find.byType(DifyDialogSurface), matching: find.byType(Container)).first);

Rect _sheetSurface(WidgetTester t) =>
    t.getRect(find.ancestor(of: find.byType(DifySheetGrabHandle), matching: find.byType(ClipRRect)).first);

Rect _sheetContentRect(WidgetTester t) =>
    t.getRect(find.ancestor(of: find.byType(DifySheetGrabHandle), matching: find.byType(DifySurface)).first);

Widget _edgeToEdgePage() => DifyPage(
  edgeToEdge: true,
  body: Column(
    children: [
      DifyTopAppBar(title: 'Apps', backgroundColor: DifyColors.componentsPanelBg),
      const Expanded(child: SizedBox.expand(key: ValueKey('content'))),
      const DifyNavigationBar(destinations: _destinations, selectedIndex: 0),
    ],
  ),
);

void main() {
  for (final MapEntry(key: name, value: w) in _windows.entries) {
    final window = Offset.zero & w.size;
    final safe = w.insets.deflateRect(window);
    group(name, () {
      testWidgets('existing pages stay inside the safe area: home, a pushed page, with or without DifyPage', (t) async {
        phoneView(t, size: w.size, padding: w.insets);
        final nav = await pumpPhoneApp(t, const DifyPage(body: SizedBox.expand(key: ValueKey('home'))));
        expect(t.getRect(find.byKey(const ValueKey('home'))), safe);
        nav.currentState!.push(difyPageRoute<void>(builder: (_) => const SizedBox.expand(key: ValueKey('plain'))));
        await t.pumpAndSettle();
        expect(t.getRect(find.byKey(const ValueKey('plain'))), safe);
        expect(MediaQuery.paddingOf(t.element(find.byKey(const ValueKey('plain')))), EdgeInsets.zero);
      });

      testWidgets('a dialog sits in the safe area exactly once; its backdrop covers the window', (t) async {
        phoneView(t, size: w.size, padding: w.insets);
        final nav = await pumpPhoneApp(t, const DifyPage(body: SizedBox()));
        // The centred form (a confirmation on a phone); the sheet form: phone_dialog_sheet_test.
        showDifyDialog<void>(
          nav.currentContext!,
          sheetOnCompact: false,
          builder: (_) => const DifyDialogSurface(top: 0, width: 200, height: 100, child: SizedBox.expand()),
        );
        await t.pumpAndSettle();
        expect(_dialogBox(t), Rect.fromLTWH(safe.center.dx - 100, safe.top, 200, 100));
        expect(t.getRect(find.byType(ModalBarrier).last), window);
      });

      testWidgets('a toast sits in the safe area exactly once', (t) async {
        phoneView(t, size: w.size, padding: w.insets);
        final toasts = DifyToastManager();
        await pumpPhoneApp(t, const DifyPage(body: SizedBox()), toasts: toasts);
        toasts.add(const DifyToastData(id: 'saved', title: 'Saved'));
        await t.pumpAndSettle();
        final area = find.descendant(of: find.byType(DifyToastHost), matching: find.byType(Stack)).first;
        expect(t.getRect(area), safe);
        final title = t.getRect(find.text('Saved'));
        expect(title.top, greaterThanOrEqualTo(safe.top + 16));
        expect(title.right, lessThanOrEqualTo(safe.right - (w.size.width >= 640 ? 32 : 16)));
        await t.pumpWidget(const SizedBox());
      });

      testWidgets('an edge-to-edge page: its bars paint to the edges, their content stays clear of the insets', (
        t,
      ) async {
        phoneView(t, size: w.size, padding: w.insets);
        await pumpPhoneApp(t, _edgeToEdgePage(), edgeToEdge: true);
        final nav = t.getRect(find.byType(DifyNavigationBar));
        expect(nav, Rect.fromLTRB(0, w.size.height - 64 - w.insets.bottom, w.size.width, w.size.height));
        final navBackground = find.descendant(of: find.byType(DifyNavigationBar), matching: find.byType(DecoratedBox));
        expect(t.getRect(navBackground.first), nav);
        expect(backgroundOf(t, navBackground.first), DifyColors.componentsPanelBg);
        for (final label in ['Studio', 'Integrations', 'Account']) {
          final r = t.getRect(find.text(label));
          expect(r.bottom, lessThanOrEqualTo(safe.bottom), reason: label);
          expect(r.left, greaterThanOrEqualTo(safe.left), reason: label);
          expect(r.right, lessThanOrEqualTo(safe.right), reason: label);
        }
        final top = t.getRect(find.byType(DifyTopAppBar));
        expect(top, Rect.fromLTWH(0, 0, w.size.width, w.insets.top + 56));
        expect(t.getRect(find.text('Apps')).top, greaterThanOrEqualTo(safe.top));
        expect(t.getRect(find.text('Apps')).left, greaterThanOrEqualTo(safe.left));
        // The page's own background also reaches under the bars: the Scaffold fills the window.
        expect(t.getRect(find.byType(Scaffold)), window);
      });

      testWidgets('a bottom sheet paints to the bottom and side edges; its content stays clear of the insets', (
        t,
      ) async {
        phoneView(t, size: w.size, padding: w.insets);
        final nav = await pumpPhoneApp(t, const DifyPage(body: SizedBox()));
        showDifyBottomSheet<void>(nav.currentContext!, _sheetContent);
        await t.pumpAndSettle();
        final surface = _sheetSurface(t);
        expect(surface.left, 0);
        expect(surface.right, w.size.width);
        expect(surface.top, w.insets.top, reason: 'full stops at the top safe area');
        expect(surface.bottom, greaterThanOrEqualTo(w.size.height));
        expect(_sheetContentRect(t), Rect.fromLTRB(safe.left, safe.top, safe.right, safe.bottom));
        expect(t.getRect(find.byType(ModalBarrier).last), window, reason: 'the scrim covers the system bars too');
      });

      testWidgets('a persistent sheet in an edge-to-edge page paints to the edges', (t) async {
        phoneView(t, size: w.size, padding: w.insets);
        await pumpPhoneApp(
          t,
          const DifyPage(
            edgeToEdge: true,
            body: Stack(
              fit: StackFit.expand,
              children: [DifyPersistentSheet(child: Builder(builder: _sheetContent))],
            ),
          ),
          edgeToEdge: true,
        );
        await t.pumpAndSettle();
        expect(_sheetSurface(t).left, 0);
        expect(_sheetSurface(t).right, w.size.width);
        expect(_sheetSurface(t).bottom, greaterThanOrEqualTo(w.size.height));
        expect(t.getRect(find.byType(DifySheetGrabHandle)).top, closeTo(w.size.height - w.insets.bottom - 120, 0.5));
        expect(_sheetContentRect(t).left, safe.left);
        expect(_sheetContentRect(t).right, safe.right);
      });
    });
  }

  for (final MapEntry(key: name, value: insets) in {
    'gesture navigation': gestureInsets,
    'three-button navigation': threeButtonInsets,
  }.entries) {
    group('keyboard open over $name', () {
      const size = Size(412, 915), keyboard = 300.0;
      // As Android reports it: the bars' full size stays in viewPadding, the visible part (padding) drops to zero.
      void view(WidgetTester t) => phoneView(
        t,
        size: size,
        padding: insets.copyWith(bottom: 0),
        viewPadding: insets,
        viewInsets: const EdgeInsets.only(bottom: keyboard),
      );

      testWidgets('a bottom sheet: the keyboard replaces the bottom inset, it is not added to it', (t) async {
        view(t);
        final nav = await pumpPhoneApp(t, const DifyPage(body: SizedBox()));
        showDifyBottomSheet<void>(nav.currentContext!, _sheetContent);
        await t.pumpAndSettle();
        expect(_sheetContentRect(t).bottom, size.height - keyboard);
        expect(
          _sheetSurface(t).bottom,
          greaterThanOrEqualTo(size.height),
          reason: 'the surface reaches behind the keyboard',
        );
      });

      testWidgets('an edge-to-edge page: the navigation bar sits on the keyboard without the bottom inset', (t) async {
        view(t);
        await pumpPhoneApp(t, _edgeToEdgePage(), edgeToEdge: true);
        expect(
          t.getRect(find.byType(DifyNavigationBar)),
          Rect.fromLTRB(0, size.height - keyboard - 64, size.width, size.height - keyboard),
        );
      });

      testWidgets('a dialog: centred above the keyboard, no bottom inset added', (t) async {
        view(t);
        final nav = await pumpPhoneApp(t, const DifyPage(body: SizedBox()));
        showDifyDialog<void>(
          nav.currentContext!,
          sheetOnCompact: false,
          builder: (_) => const DifyDialogSurface(width: 200, height: 100, child: SizedBox.expand()),
        );
        await t.pumpAndSettle();
        // Centred between the status bar and the keyboard, each side's 16 px margin included.
        final centre = (insets.top + 16 + size.height - keyboard - 16) / 2;
        expect(_dialogBox(t).center.dy, centre);
      });

      testWidgets('a toast is not moved by the keyboard', (t) async {
        view(t);
        final toasts = DifyToastManager();
        await pumpPhoneApp(t, const DifyPage(body: SizedBox()), toasts: toasts);
        toasts.add(const DifyToastData(id: 'saved', title: 'Saved'));
        await t.pumpAndSettle();
        expect(
          t.getRect(find.descendant(of: find.byType(DifyToastHost), matching: find.byType(Stack)).first),
          Rect.fromLTRB(0, insets.top, size.width, size.height),
        );
        await t.pumpWidget(const SizedBox());
      });
    });
  }

  group('root overlay', () {
    testWidgets('DifyApplication publishes the window insets that pages no longer see', (t) async {
      phoneView(t, padding: gestureInsets);
      await pumpPhoneApp(t, const DifyPage(body: SizedBox.expand(key: ValueKey('page'))));
      final page = t.element(find.byKey(const ValueKey('page')));
      expect(MediaQuery.paddingOf(page), EdgeInsets.zero);
      expect(DifyWindowInsets.of(page), gestureInsets);
    });

    Future<Rect> popup(WidgetTester t, Rect anchor, DifyPlacement placement, EdgeInsets insets) async {
      await t.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: DifyWindowInsets(
            padding: insets,
            child: DifyFloatingLayout(
              anchor: anchor,
              placement: placement,
              animation: kAlwaysCompleteAnimation,
              child: const SizedBox(key: ValueKey('popup'), width: 100, height: 60),
            ),
          ),
        ),
      );
      return t.getRect(find.byKey(const ValueKey('popup')));
    }

    testWidgets('popups, menus and tooltips flip away from the system bars', (t) async {
      phoneView(t);
      const low = Rect.fromLTWH(20, 820, 80, 20);
      // Without insets (desktop) the popup fits below the anchor, as before.
      expect((await popup(t, low, DifyPlacement.bottom, EdgeInsets.zero)).top, 840);
      // Over a 24 px gesture bar it would reach under it: it flips above.
      expect((await popup(t, low, DifyPlacement.bottom, gestureInsets)).bottom, 820);
      const high = Rect.fromLTWH(20, 80, 80, 20);
      expect((await popup(t, high, DifyPlacement.top, EdgeInsets.zero)).bottom, 80);
      expect((await popup(t, high, DifyPlacement.top, gestureInsets)).top, 100, reason: 'flipped below the status bar');
      // Shifted along the cross axis, it stays clear of a side inset.
      final side = await popup(t, const Rect.fromLTWH(0, 200, 10, 20), DifyPlacement.bottomStart, landscapeInsets);
      expect(side.left, greaterThanOrEqualTo(landscapeInsets.left));
    });

    testWidgets('DifyOverlaySafeArea measures edge-positioned overlay content from the safe edges', (t) async {
      phoneView(t);
      await t.pumpWidget(
        MediaQuery(
          data: MediaQueryData.fromView(t.view).copyWith(padding: gestureInsets),
          child: const Directionality(
            textDirection: TextDirection.ltr,
            child: Stack(
              children: [
                DifyOverlaySafeArea(
                  child: Positioned(
                    right: 4,
                    top: 56,
                    bottom: 4,
                    width: 100,
                    child: SizedBox.expand(key: ValueKey('drawer')),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      expect(
        t.getRect(find.byKey(const ValueKey('drawer'))),
        Rect.fromLTRB(412 - 4 - 100, 32 + 56, 412 - 4, 915 - 24 - 4),
      );
      expect(MediaQuery.paddingOf(t.element(find.byKey(const ValueKey('drawer')))), EdgeInsets.zero);
    });
  });

  group('desktop (no insets)', () {
    testWidgets('pages, dialogs, toasts and bars are where they were', (t) async {
      phoneView(t, size: const Size(1280, 800));
      final toasts = DifyToastManager();
      final nav = await pumpPhoneApp(
        t,
        const DifyPage(body: SizedBox.expand(key: ValueKey('home'))),
        toasts: toasts,
      );
      expect(t.getRect(find.byKey(const ValueKey('home'))), const Rect.fromLTWH(0, 0, 1280, 800));
      toasts.add(const DifyToastData(id: 'saved', title: 'Saved'));
      showDifyDialog<void>(
        nav.currentContext!,
        builder: (_) => const DifyDialogSurface(top: 0, width: 200, height: 100, child: SizedBox.expand()),
      );
      await t.pumpAndSettle();
      expect(_dialogBox(t), const Rect.fromLTWH(540, 0, 200, 100));
      expect(
        t.getRect(find.descendant(of: find.byType(DifyToastHost), matching: find.byType(Stack)).first),
        const Rect.fromLTWH(0, 0, 1280, 800),
      );
      await t.pumpWidget(const SizedBox());
    });
  });
}
