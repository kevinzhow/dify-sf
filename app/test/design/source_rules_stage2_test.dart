import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/cards/dify_cards.dart';
import 'package:dify_sf_app/src/design/dify_tokens.g.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:dify_sf_app/src/design/dify_theme.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/app_fonts.dart';

void main() {
  tearDown(() => DifyColors.useDark(false));
  test('CSS decimal alpha survives token generation until compositing', () {
    DifyColors.useDark(true);
    expect(DifyColors.componentsInputBgActive.a, .05);
    final blend = Color.alphaBlend(DifyColors.componentsInputBgActive, DifyColors.backgroundBody);
    expect(blend.toARGB32(), const Color(0xFF28282B).toARGB32());
    expect(DifyColors.textPlaceholder.a, .3);
  });

  testWidgets('native table defaults include td padding and bold th without stretching', (t) async {
    await useAppFonts();
    await t.pumpWidget(
      MaterialApp(
        home: Material(
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 400,
              child: DifyTable(
                columns: const [
                  DifyTableColumn(header: DifyTextLine('Name')),
                  DifyTableColumn(header: DifyTextLine('Status')),
                ],
                rows: const [
                  DifyTableRow(cells: [DifyTextLine('Alpha'), DifyTextLine('Ready')]),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(t.getSize(find.byType(DifyTable)).height, closeTo(47, .001));
    expect(t.getTopLeft(find.text('Alpha')).dx, 1);
    final header = t.widget<RichText>(find.descendant(of: find.text('Name'), matching: find.byType(RichText)).first);
    expect(header.text.style!.fontWeight, FontWeight.w700);
    expect(t.takeException(), isNull);
  });

  testWidgets('design-system navigation keeps label position on focus and grows for text scaling', (t) async {
    await useAppFonts();
    Widget nav(double scale) => MaterialApp(
      theme: difyTheme(fontFamily: 'Noto Sans'),
      home: Material(
        child: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(scale)),
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 300,
              child: MainNavLink(
                label: 'Create',
                icon: 'vender/main-nav/studio-v2',
                activeIcon: 'vender/main-nav/studio-v2-active',
                active: true,
                onTap: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await t.pumpWidget(nav(1));
    await t.pumpAndSettle();
    final before = t.getRect(find.text('Create'));
    await t.sendKeyEvent(LogicalKeyboardKey.tab);
    await t.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus!.context!.findAncestorWidgetOfExactType<MainNavLink>(), isNotNull);
    expect(t.getRect(find.text('Create')), before);
    expect(t.getSize(find.byType(MainNavLink)).height, 32);
    await t.pumpWidget(nav(2));
    await t.pumpAndSettle();
    expect(t.getSize(find.byType(MainNavLink)).height, greaterThan(32));
    expect(t.takeException(), isNull);
  });

  testWidgets('replaced-inline layout preserves the measured document strut below a textarea', (t) async {
    await useAppFonts();
    Widget box(double scale) => MaterialApp(
      theme: difyTheme(fontFamily: 'Noto Sans'),
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(scale)),
        child: const Align(
          alignment: Alignment.topLeft,
          child: DifyInlineReplacedBox(
            child: SizedBox(width: 200, height: 104),
          ),
        ),
      ),
    );
    await t.pumpWidget(box(1));
    await t.pumpAndSettle();
    expect(t.getSize(find.byType(DifyInlineReplacedBox)).height, 110);
    await t.pumpWidget(box(2));
    await t.pumpAndSettle();
    expect(t.getSize(find.byType(DifyInlineReplacedBox)).height, 116);
    expect(t.takeException(), isNull);
  });

  test('SimpleNode keeps its two-pixel wrapper; the ordinary node retains one', () {
    const simple = Node(id: 'exit', type: 'loop-end', title: 'Exit Loop', x: 0, y: 0);
    const ordinary = Node(id: 'code', type: 'code', title: 'Code', x: 0, y: 0);
    final doc = Document(nodes: [simple, ordinary]);
    final a = const DifyCards().layoutOf(simple, doc);
    final b = const DifyCards().layoutOf(ordinary, doc);
    expect(a.selectionBorderWidth, 2);
    expect(a.card.topLeft, const Offset(2, 2));
    expect(a.card.inflate(a.selectionBorderWidth), const Rect.fromLTWH(0, 0, 244, 54));
    expect(b.selectionBorderWidth, 1);
    expect(b.card.left, 1);
  });
}
