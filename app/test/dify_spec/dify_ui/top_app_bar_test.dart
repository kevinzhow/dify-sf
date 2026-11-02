// dify-sf phone layout (no Dify spec): the phone app bar (mockups 1-4, 7).
import 'phone_harness.dart';

void main() {
  group('DifyTopAppBar', () {
    testWidgets('is 56 px with the title, a one-line subtitle and 44 px actions', (t) async {
      phoneView(t);
      await pumpPhoneApp(
        t,
        DifyPage(
          body: Column(
            children: [
              DifyTopAppBar(
                title: 'Self-host check with a very long name that does not fit on one phone line at all',
                subtitle: 'Saved · editing with Winnie and with several other collaborators at once',
                actions: [
                  DifyButton(variant: DifyButtonVariant.primary, onPressed: () {}, child: const DifyTextLine('Run')),
                  DifyTouchIconButton(label: 'More', icon: const RemixIcon('more-fill', size: 22), onPressed: () {}),
                ],
              ),
            ],
          ),
        ),
      );
      final bar = t.getRect(find.byType(DifyTopAppBar));
      expect(bar.height, DifyTopAppBar.height);
      expect(t.getSize(find.byType(DifyTouchIconButton)), const Size(44, 44));
      expect(find.byType(DifyAppBarBackButton), findsNothing, reason: 'the first route cannot pop');
      final title = t.widget<RichText>(
        find.descendant(of: find.byType(DifyTopAppBar), matching: find.byType(RichText)).first,
      );
      expect(title.maxLines, 1);
      expect(title.overflow, TextOverflow.ellipsis);
      expect(title.text.style!.fontSize, 17);
      expect(t.takeException(), isNull);
    });

    testWidgets('implies a back button that pops the route, and honours a PopScope', (t) async {
      phoneView(t);
      final navigator = await pumpPhoneApp(t, const DifyPage(body: SizedBox()));
      navigator.currentState!.push(
        difyPageRoute<void>(
          builder: (_) => const DifyPage(
            body: Column(children: [DifyTopAppBar(title: 'Detail')]),
          ),
        ),
      );
      await t.pumpAndSettle();
      final back = find.byType(DifyAppBarBackButton);
      expect(back, findsOneWidget);
      expect(t.getSize(back), const Size(44, 44));
      expect(find.bySemanticsLabel('operation.back'), findsOneWidget);
      await t.tap(back);
      await t.pumpAndSettle();
      expect(find.text('Detail'), findsNothing);

      var blocked = 0;
      navigator.currentState!.push(
        difyPageRoute<void>(
          builder: (_) => PopScope(
            canPop: false,
            onPopInvokedWithResult: (didPop, _) => blocked++,
            child: const DifyPage(
              body: Column(children: [DifyTopAppBar(title: 'Editing')]),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.byType(DifyAppBarBackButton));
      await t.pumpAndSettle();
      expect(find.text('Editing'), findsOneWidget);
      expect(blocked, 1);
    });

    testWidgets('the large variant has a 22 px title 18 px from the edge and no back button', (t) async {
      phoneView(t);
      final navigator = await pumpPhoneApp(t, const DifyPage(body: SizedBox()));
      navigator.currentState!.push(
        difyPageRoute<void>(
          builder: (_) => const DifyPage(
            body: Column(children: [DifyTopAppBar.large(title: 'Studio')]),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.byType(DifyAppBarBackButton), findsNothing);
      expect(t.getTopLeft(find.text('Studio')).dx, 18);
      expect(
        t
            .widget<RichText>(find.descendant(of: find.text('Studio'), matching: find.byType(RichText)).first)
            .text
            .style!
            .fontSize,
        22,
      );
      expect(t.getSize(find.byType(DifyTopAppBar)).height, 56);
    });

    testWidgets('edge to edge: paints under the status bar and keeps the content below it and the side insets', (
      t,
    ) async {
      phoneView(t, size: const Size(915, 412), padding: landscapeInsets);
      await pumpPhoneApp(
        t,
        DifyPage(
          edgeToEdge: true,
          body: Column(
            children: [
              DifyTopAppBar(
                title: 'Self-host check',
                backgroundColor: DifyColors.componentsPanelBg,
                leading: DifyAppBarBackButton(onPressed: () {}),
                actions: [
                  DifyTouchIconButton(label: 'More', icon: const RemixIcon('more-fill', size: 22), onPressed: () {}),
                ],
              ),
            ],
          ),
        ),
        edgeToEdge: true,
      );
      final bar = t.getRect(find.byType(DifyTopAppBar));
      expect(bar, const Rect.fromLTWH(0, 0, 915, 24 + 56), reason: 'the background reaches the window edges');
      final background = find.descendant(of: find.byType(DifyTopAppBar), matching: find.byType(ColoredBox)).first;
      expect(t.getRect(background), bar);
      expect(t.getRect(find.byType(DifyAppBarBackButton)).left, 32 + 8);
      expect(t.getRect(find.byType(DifyAppBarBackButton)).top, 24 + 6);
      expect(t.getRect(find.byType(DifyTouchIconButton).last).right, 915 - 48 - 8);
    });
  });
}
