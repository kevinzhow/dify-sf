// dify-sf phone layout (no Dify spec): the phone gallery dev tool runs and opens every sheet and page.
import '../../../tool/phone_gallery_main.dart';
import 'phone_harness.dart';

void main() {
  testWidgets('the phone gallery opens every sheet and page without errors, light and dark', (t) async {
    phoneView(t, padding: gestureInsets);
    await t.pumpWidget(const PhoneGalleryApp());
    await t.pumpAndSettle();
    expect(find.text('Phone gallery'), findsOneWidget);
    expect(t.takeException(), isNull, reason: 'gallery page');

    Future<void> open(String label) async {
      await t.scrollUntilVisible(find.text(label), 200, scrollable: find.byType(Scrollable).first);
      await t.tap(find.text(label));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull, reason: label);
    }

    Future<void> back() async {
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
    }

    for (final label in ['Sheet: half', 'Sheet: full', 'Sheet: keyboard', 'Action sheet']) {
      await open(label);
      expect(find.byType(DifySheetGrabHandle), findsOneWidget, reason: label);
      await back();
      expect(find.byType(DifySheetGrabHandle), findsNothing, reason: label);
    }

    await open('Persistent peek sheet');
    expect(find.byType(DifyPersistentSheet), findsOneWidget);
    await t.tap(find.text('Start'));
    await t.pump();
    expect(find.textContaining('(taps: 1)'), findsOneWidget);
    await t.tap(find.text('Expand the result'));
    await t.pumpAndSettle();
    expect(t.getRect(find.byType(DifySheetGrabHandle)).top, closeTo(gestureInsets.top, 0.5));
    await back();

    for (final label in ['Edge to edge: before', 'Edge to edge: after']) {
      await open(label);
      final bar = t.getRect(find.byType(DifyNavigationBar));
      expect(bar.bottom, label.contains('after') ? 915 : 915 - gestureInsets.bottom, reason: label);
      await t.tap(find.text('Count Android'));
      await t.pumpAndSettle();
      expect(find.byType(DifySelectionBar), findsOneWidget);
      await back();
    }

    // Batch 4a: a sheet and a page shown from the page's tree, and a select as a sheet (a compact window).
    for (final (label, finder) in [
      ('Sheet portal', find.byKey(const ValueKey('dify-sheet-scrim'))),
      ('Portal page', find.byKey(const ValueKey('dify-portal-page'))),
      ('String', find.text('Number')),
    ]) {
      await t.scrollUntilVisible(find.text(label), 200, scrollable: find.byType(Scrollable).first);
      await t.tap(find.text(label));
      await t.pumpAndSettle();
      expect(finder, findsWidgets, reason: label);
      expect(t.takeException(), isNull, reason: label);
      await back();
      expect(find.byKey(const ValueKey('dify-sheet-scrim')), findsNothing, reason: label);
      expect(find.byKey(const ValueKey('dify-portal-page')), findsNothing, reason: label);
    }

    await t.tap(find.bySemanticsLabel('Theme'));
    await t.pumpAndSettle();
    expect(DifyColors.isDark, isTrue);
    await t.tap(find.bySemanticsLabel('Theme'));
    await t.pumpAndSettle();
    expect(DifyColors.isDark, isFalse);
    expect(t.takeException(), isNull);
  });
}
