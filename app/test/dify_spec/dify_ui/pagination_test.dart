// dify-spec: packages/dify-ui/src/pagination/__tests__/index.spec.tsx
import 'dart:convert';
import 'dart:io';

import 'package:dify_sf_app/src/i18n/dify_i18n.dart';

import 'control_harness.dart';

/// The en-US `common` strings (the spec renders the English labels).
class _EnCommon implements Translator {
  _EnCommon() : _m = (jsonDecode(File('assets/i18n/en-US/common.json').readAsStringSync()) as Map).cast();
  final Map<String, Object?> _m;

  @override
  String t(String ns, String key, [Map<String, Object?> params = const {}]) {
    var s = '${_m[key] ?? key}';
    params.forEach((k, v) => s = s.replaceAll('{{$k}}', '$v'));
    return s;
  }
}

Future<List<int>> _render(
  WidgetTester t, {
  int page = 2,
  int totalPages = 200,
  int? pageSize = 25,
  int siblingCount = 1,
  int boundaryCount = 1,
  List<int>? pageSizes,
  String Function(int, int)? editPageNumberLabel,
}) async {
  DifyI18n.current = _EnCommon();
  addTearDown(() => DifyI18n.current = KeyEchoTranslator());
  final changes = <int>[];
  t.view.physicalSize = const Size(1200, 400);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      home: Material(
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 944,
            child: DifyPagination(
              page: page,
              totalPages: totalPages,
              onPageChange: changes.add,
              pageSize: pageSize,
              onPageSizeChange: pageSizes?.add,
              siblingCount: siblingCount,
              boundaryCount: boundaryCount,
              editPageNumberLabel: editPageNumberLabel,
            ),
          ),
        ),
      ),
    ),
  );
  await t.pump();
  return changes;
}

Finder _named(String label) => find.bySemanticsLabel(label);

SemanticsData _data(WidgetTester t, String label) => t.getSemantics(_named(label)).getSemanticsData();

/// The page buttons' numbers, in order (the semantics tree below the pagination's node).
List<int> _pageNumbers(WidgetTester t) {
  final out = <int>[];
  final pattern = RegExp(r'^(?:Go to page (\d+)|Page (\d+), current page)');
  bool visit(SemanticsNode n) {
    if (pattern.firstMatch(n.label) case final m?) out.add(int.parse(m.group(1) ?? m.group(2)!));
    n.visitChildren(visit);
    return true;
  }

  visit(t.getSemantics(find.bySemanticsLabel('Pagination')));
  return out;
}

Future<void> _openEditor(WidgetTester t, {String label = 'Edit page number, current page 2 of 200'}) async {
  await t.tap(_named(label));
  await t.pump();
  await t.pump();
  await t.pump();
}

void main() {
  group('Pagination primitive', () {
    testWidgets('renders the pagination structure with semantic navigation', (t) async {
      await _render(t);
      expect(find.bySemanticsLabel('Pagination'), findsOneWidget);
      expect(_named('Previous page'), findsOneWidget);
      expect(_named('Next page'), findsOneWidget);
      final summary = _named('Edit page number, current page 2 of 200');
      expect(summary, findsOneWidget);
      expect(
        [
          for (final w in t.widgetList<Text>(
            find.descendant(of: find.byType(DifyPressable), matching: find.byType(Text)),
          ))
            w.data,
        ].take(3).join(),
        '2/200',
      );
      final current = _data(t, 'Page 2, current page');
      expect(current.flagsCollection.isSelected, Tristate.isTrue);
      expect(find.text('…'), findsOneWidget);
    });

    testWidgets('uses one-based page changes for previous, next, and page buttons', (t) async {
      final changes = await _render(t, page: 100);
      await t.tap(_named('Previous page'));
      await t.tap(_named('Next page'));
      await t.tap(_named('Go to page 1'));
      expect(changes, [99, 101, 1]);
    });

    testWidgets('does not report a page change when the current page is activated', (t) async {
      final changes = await _render(t, page: 4);
      await t.tap(_named('Page 4, current page'));
      expect(changes, isEmpty);
    });

    testWidgets('keeps a compact page window %s', (t) async {
      for (final (page, expected, ellipses) in [
        (2, [1, 2, 3, 4, 5, 200], 1),
        (100, [1, 99, 100, 101, 200], 2),
        (199, [1, 196, 197, 198, 199, 200], 1),
      ]) {
        await _render(t, page: page);
        expect(_pageNumbers(t), expected, reason: 'page $page');
        expect(find.text('…'), findsNWidgets(ellipses), reason: 'page $page');
      }
    });

    testWidgets('uses sibling and boundary counts as the page range contract', (t) async {
      await _render(t, page: 100, siblingCount: 0, boundaryCount: 2);
      expect(_pageNumbers(t), [1, 2, 100, 199, 200]);
    });

    testWidgets('disables previous at the first page', (t) async {
      await _render(t, page: 1, totalPages: 10);
      expect(_data(t, 'Previous page').flagsCollection.isEnabled, Tristate.isFalse);
    });

    testWidgets('disables next at the last page', (t) async {
      await _render(t, page: 10, totalPages: 10);
      expect(_data(t, 'Next page').flagsCollection.isEnabled, Tristate.isFalse);
    });

    testWidgets('clamps invalid root page values without exposing invalid state', (t) async {
      await _render(t, page: 999, totalPages: 10);
      expect(_data(t, 'Page 10, current page').flagsCollection.isSelected, Tristate.isTrue);
    });

    testWidgets('switches the page summary into a selected labelled number field', (t) async {
      await _render(t);
      await _openEditor(t);
      final field = t.widget<EditableText>(find.byType(EditableText));
      expect(field.controller.text, '2');
      expect(field.controller.selection, const TextSelection(baseOffset: 0, extentOffset: 1));
      expect(t.getSemantics(find.byType(DifyInput)).label, contains('Page number'));
    });

    testWidgets('returns to the summary button when the page input loses focus', (t) async {
      await _render(t);
      await _openEditor(t);
      t.widget<EditableText>(find.byType(EditableText)).focusNode.unfocus();
      await t.pump();
      expect(_named('Edit page number, current page 2 of 200'), findsOneWidget);
      expect(find.byType(EditableText), findsNothing);
    });

    testWidgets('commits the page input editing mode with Enter', (t) async {
      final changes = await _render(t);
      await _openEditor(t);
      expect(t.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus, isTrue);
      await t.testTextInput.receiveAction(TextInputAction.done);
      await t.pump();
      await t.pump();
      expect(find.byType(EditableText), findsNothing);
      expect(
        Focus.of(t.element(find.descendant(of: find.byType(DifyPressable), matching: find.text('200')).first)).hasFocus,
        isTrue,
      );
      expect(changes, isEmpty);
    });

    testWidgets('cancels the page input editing mode with Escape', (t) async {
      final changes = await _render(t);
      await _openEditor(t);
      await t.enterText(find.byType(EditableText), '7');
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pump();
      await t.pump();
      expect(find.byType(EditableText), findsNothing);
      expect(
        Focus.of(t.element(find.descendant(of: find.byType(DifyPressable), matching: find.text('200')).first)).hasFocus,
        isTrue,
      );
      expect(changes, isEmpty);
    });

    testWidgets('uses required single-choice semantics for page size', (t) async {
      final sizes = <int>[];
      await _render(t, pageSizes: sizes);
      final selected = _data(t, '25');
      expect(selected.flagsCollection.isChecked, CheckedState.isTrue);
      expect(selected.flagsCollection.isInMutuallyExclusiveGroup, isTrue);
      await t.tap(_named('50'));
      expect(sizes, [50]);
    });

    testWidgets('renders the complete pagination bar with optional page size controls', (t) async {
      await _render(t, totalPages: 10, pageSizes: []);
      expect(_named('Edit page number, current page 2 of 10'), findsOneWidget);
      expect(_data(t, 'Items per page').role, SemanticsRole.radioGroup);
    });

    testWidgets('uses a localized action label for editing the page number', (t) async {
      await _render(t, totalPages: 10, editPageNumberLabel: (p, n) => 'Change page, current page $p of $n');
      expect(_named('Change page, current page 2 of 10'), findsOneWidget);
    });

    testWidgets('keeps facade page numbers centered when page size controls are omitted', (t) async {
      await _render(t, totalPages: 10, pageSize: null);
      expect(find.bySemanticsLabel('Pagination'), findsOneWidget);
      // The page list stays centred: the summary group and the (empty) page size side share the rest equally.
      final row = t.getRect(find.byType(DifyPagination));
      final pages = t.getRect(_named('Page 2, current page'));
      final first = t.getRect(_named('Go to page 1')), last = t.getRect(_named('Go to page 10'));
      expect(((first.left + last.right) / 2 - row.center.dx).abs(), lessThan(1));
      expect(pages.width, greaterThan(0));
    });

    testWidgets('does not expose invalid page controls when there are no pages', (t) async {
      await _render(t, page: 1, totalPages: 0);
      expect(find.bySemanticsLabel('Pagination'), findsNothing);
      expect(find.bySemanticsLabel(RegExp('current page 1 of 0')), findsNothing);
    });
  });
}
