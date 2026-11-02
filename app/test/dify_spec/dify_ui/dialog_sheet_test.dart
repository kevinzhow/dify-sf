// The design's dialog on a phone (a dify-sf divergence, raft-flutter's form policy): a modal bottom sheet with the
// dialog's title and close in its header, the body scrolling, the actions as 44 px buttons pinned at its bottom above
// the keyboard and the gesture bar; Back closes it first; only the topmost layer is read. Confirmations stay centred.
// Wide windows keep Dify's centred dialog. And DifyActionRow: a panel row's hover actions by touch on a phone.
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';

import '../../support/platform_semantics.dart';
import 'phone_harness.dart';

const _sizes = [Size(411, 914), Size(360, 780)];

/// A dialog built from the design's parts, as the migrated dialogs are: its own title row (shown in a dialog), a
/// scrolling body of [rows] rows with a text field, Cancel / Save.
Widget _dialog(BuildContext context, {int rows = 30, Widget? extra}) => DifyDialogSurface(
  label: 'Rename',
  width: 400,
  child: Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      DifyDialogTitle(
        title: 'Rename',
        description: 'Give it a name',
        child: const Padding(
          key: ValueKey('desktop-title'),
          padding: EdgeInsets.all(24),
          child: DifyTextLine('Rename'),
        ),
      ),
      Flexible(
        child: SingleChildScrollView(
          key: const ValueKey('dialog-body'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const DifyInput(key: ValueKey('dialog-field'), value: '', semanticLabel: 'Name'),
              ?extra,
              for (var i = 0; i < rows; i++)
                SizedBox(height: 40, child: DifyTextLine('Row $i', key: ValueKey('row-$i'))),
            ],
          ),
        ),
      ),
      DifyAlertDialogActions(
        children: [
          DifyButton(
            key: const ValueKey('dialog-cancel'),
            onPressed: () => Navigator.of(context).pop('cancel'),
            child: const DifyTextLine('Cancel'),
          ),
          DifyButton(
            key: const ValueKey('dialog-save'),
            variant: DifyButtonVariant.primary,
            onPressed: () => Navigator.of(context).pop('save'),
            child: const DifyTextLine('Save'),
          ),
        ],
      ),
    ],
  ),
);

void openKeyboard(WidgetTester t, {double height = 300, EdgeInsets insets = gestureInsets}) {
  t.view.viewPadding = FakeViewPadding(top: insets.top, bottom: insets.bottom);
  t.view.padding = FakeViewPadding(top: insets.top);
  t.view.viewInsets = FakeViewPadding(bottom: height);
}

void closeKeyboard(WidgetTester t, {EdgeInsets insets = gestureInsets}) {
  t.view.padding = FakeViewPadding(top: insets.top, bottom: insets.bottom);
  t.view.viewInsets = FakeViewPadding.zero;
}

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 12; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

/// The page under the dialogs: a label and a portal sheet (as the phone editor's node settings) that opens the
/// dialog from its own content.
class _Page extends StatefulWidget {
  const _Page({required this.open});
  final void Function(BuildContext context) open;

  @override
  State<_Page> createState() => _PageState();
}

class _PageState extends State<_Page> {
  bool sheet = false;

  @override
  Widget build(BuildContext context) => DifyPage(
    edgeToEdge: true,
    body: Column(
      children: [
        const SizedBox(height: 80),
        const DifyTextLine('The page', key: ValueKey('page-text')),
        DifyButton(
          key: const ValueKey('open-sheet'),
          onPressed: () => setState(() => sheet = true),
          child: const DifyTextLine('Settings'),
        ),
        DifySheetPortal(
          open: sheet,
          onDismiss: () => setState(() => sheet = false),
          builder: (context) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const DifySheetHeader(title: 'Node settings'),
              Padding(
                padding: const EdgeInsets.all(16),
                child: DifyButton(
                  key: const ValueKey('open-dialog'),
                  onPressed: () => widget.open(context),
                  child: const DifyTextLine('Add'),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

/// The labels in the order the platform reads them (traversal order: sort keys, then geometry), an overlay child
/// under its portal's place as [platformLabels] does.
List<String> _readingOrder(WidgetTester t) {
  final roots = [for (final view in t.binding.renderViews) ?view.owner?.semanticsOwner?.rootSemanticsNode];
  final grafted = <Object, List<SemanticsNode>>{};
  void index(SemanticsNode n) {
    if (n.getSemanticsData().traversalChildIdentifier case final id?) (grafted[id] ??= []).add(n);
    n.visitChildren((c) {
      index(c);
      return true;
    });
  }

  roots.forEach(index);
  final out = <String>[];
  void walk(SemanticsNode n) {
    if (n.label.isNotEmpty) out.add(n.label);
    final children = [
      for (final c in n.debugListChildrenInOrder(DebugSemanticsDumpOrder.traversalOrder))
        if (c.getSemanticsData().traversalChildIdentifier == null) c,
    ];
    if (n.getSemanticsData().traversalParentIdentifier case final id?) children.addAll(grafted[id] ?? const []);
    children.forEach(walk);
  }

  roots.forEach(walk);
  return out;
}

void main() {
  setUpAll(() => DifyI18n.load('en-US'));

  for (final size in _sizes) {
    final name = '${size.width.toInt()}x${size.height.toInt()}';

    testWidgets('$name: a dialog is a sheet: the header has its title and a 44 px close, the body scrolls, Cancel and '
        'Save are 44 px buttons at its bottom above the gesture bar, then above the keyboard', (t) async {
      phoneView(t, size: size, padding: gestureInsets);
      final nav = await pumpPhoneApp(t, const DifyPage(edgeToEdge: true, body: SizedBox.expand()), edgeToEdge: true);
      final result = showDifyDialog<String>(nav.currentContext!, builder: (context) => _dialog(context));
      await _settle(t);

      expect(find.byType(DifySheetGrabHandle), findsOneWidget, reason: 'a sheet');
      expect(find.byKey(const ValueKey('desktop-title')), findsNothing, reason: "the dialog's own title row");
      final header = find.byType(DifySheetHeader);
      expect(find.descendant(of: header, matching: find.text('Rename')), findsOneWidget);
      expect(find.descendant(of: header, matching: find.text('Give it a name')), findsOneWidget);
      final close = find.descendant(of: header, matching: find.byType(DifyTouchIconButton));
      expect(t.getSize(close).height, greaterThanOrEqualTo(44));
      // Edge to edge, the full detent stops at the status bar.
      expect(t.getRect(find.byType(DifySheetGrabHandle)).left, 0);
      expect(t.getRect(find.byType(DifySheetGrabHandle)).top, greaterThanOrEqualTo(gestureInsets.top));

      final save = t.getRect(find.byKey(const ValueKey('dialog-save')));
      final cancel = t.getRect(find.byKey(const ValueKey('dialog-cancel')));
      expect(save.height, greaterThanOrEqualTo(44));
      expect(cancel.height, greaterThanOrEqualTo(44));
      expect(save.right, closeTo(size.width - 16, 0.5), reason: 'end-aligned in px-4');
      expect(save.bottom, lessThanOrEqualTo(size.height - gestureInsets.bottom));
      expect(save.bottom, greaterThan(size.height - gestureInsets.bottom - 24), reason: 'at the bottom: $save');
      // The body scrolls under the pinned actions: its last row is not in view, the actions are.
      expect(t.getRect(find.byKey(const ValueKey('row-29'), skipOffstage: false)).top, greaterThan(save.top));
      await t.drag(find.byKey(const ValueKey('dialog-body')), const Offset(0, -2000));
      await _settle(t);
      expect(t.getRect(find.byKey(const ValueKey('row-29'))).bottom, lessThanOrEqualTo(save.top));
      expect(t.getRect(find.byKey(const ValueKey('dialog-save'))), save, reason: 'the actions stay');

      // The keyboard: the sheet rises with it, the actions sit on it.
      openKeyboard(t, height: 300, insets: gestureInsets);
      await _settle(t);
      final lifted = t.getRect(find.byKey(const ValueKey('dialog-save')));
      expect(lifted.bottom, lessThanOrEqualTo(size.height - 300));
      expect(lifted.bottom, greaterThan(size.height - 300 - 24));
      expect(find.descendant(of: header, matching: find.text('Rename')).hitTestable(), findsOneWidget);
      closeKeyboard(t, insets: gestureInsets);
      await _settle(t);

      await t.tap(find.byKey(const ValueKey('dialog-save')));
      await _settle(t);
      expect(await result, 'save');
      expect(find.byType(DifySheetGrabHandle), findsNothing);
      expect(t.takeException(), isNull);
    });
  }

  testWidgets('a wide window keeps the centred dialog: its own title row, no sheet header', (t) async {
    phoneView(t, size: const Size(1280, 800));
    final nav = await pumpPhoneApp(t, const DifyPage(body: SizedBox.expand()));
    showDifyDialog<String>(nav.currentContext!, builder: (context) => _dialog(context, rows: 2));
    await _settle(t);
    expect(find.byType(DifySheetGrabHandle), findsNothing);
    expect(find.byType(DifySheetHeader), findsNothing);
    expect(find.byKey(const ValueKey('desktop-title')), findsOneWidget);
    final save = t.getRect(find.byKey(const ValueKey('dialog-save')));
    expect(save.height, 32, reason: "Dify's button");
    final box = t.getRect(find.byKey(const ValueKey('desktop-title')));
    expect(box.width, 400);
    expect(box.center.dx, 640);
  });

  testWidgets('Back closes the dialog before the portal sheet it was opened from; Back again closes the sheet; the '
      'close button, the scrim and a drag down close the dialog', (t) async {
    phoneView(t, size: const Size(411, 914), padding: gestureInsets);
    await pumpPhoneApp(
      t,
      _Page(open: (context) => showDifyDialog<String>(context, builder: (context) => _dialog(context, rows: 2))),
      edgeToEdge: true,
    );
    await t.tap(find.byKey(const ValueKey('open-sheet')));
    await _settle(t);
    Future<void> openDialog() async {
      await t.tap(find.byKey(const ValueKey('open-dialog')));
      await _settle(t);
      expect(find.text('Rename'), findsOneWidget);
    }

    await openDialog();
    expect(await t.binding.handlePopRoute(), isTrue);
    await _settle(t);
    expect(find.text('Rename'), findsNothing, reason: 'Back closed the dialog');
    expect(find.text('Node settings'), findsOneWidget, reason: 'the sheet under it stays');

    await openDialog();
    await t.tap(find.descendant(of: find.byType(DifySheetHeader).last, matching: find.byType(DifyTouchIconButton)));
    await _settle(t);
    expect(find.text('Rename'), findsNothing, reason: 'the header close');

    await openDialog();
    await t.tapAt(const Offset(200, 40));
    await _settle(t);
    expect(find.text('Rename'), findsNothing, reason: 'the scrim');
    expect(find.text('Node settings'), findsOneWidget);

    await openDialog();
    await t.drag(find.byType(DifySheetGrabHandle).last, const Offset(0, 600));
    await _settle(t);
    expect(find.text('Rename'), findsNothing, reason: 'a drag down');

    expect(await t.binding.handlePopRoute(), isTrue);
    await _settle(t);
    expect(find.text('Node settings'), findsNothing, reason: 'then Back closes the sheet');
  });

  testWidgets('a dialog whose outside clicks do not close it: the scrim does nothing, Back still closes it', (t) async {
    phoneView(t, size: const Size(411, 914), padding: gestureInsets);
    final nav = await pumpPhoneApp(t, const DifyPage(edgeToEdge: true, body: SizedBox.expand()), edgeToEdge: true);
    showDifyDialog<String>(nav.currentContext!, dismissible: false, builder: (context) => _dialog(context, rows: 2));
    await _settle(t);
    await t.tapAt(const Offset(200, 40));
    await _settle(t);
    expect(find.text('Rename'), findsOneWidget);
    expect(await t.binding.handlePopRoute(), isTrue);
    await _settle(t);
    expect(find.text('Rename'), findsNothing);
  });

  testWidgets('accessibility: with the dialog open only the dialog is read (not the sheet or the page under it); a '
      'picker sheet over it hides the dialog\'s form; closing each brings the layer below back', (t) async {
    final semantics = t.ensureSemantics();
    phoneView(t, size: const Size(411, 914), padding: gestureInsets);
    await pumpPhoneApp(
      t,
      _Page(
        open: (context) => showDifyDialog<String>(
          context,
          builder: (context) => _dialog(
            context,
            rows: 1,
            extra: DifySelect<String>(
              key: const ValueKey('dialog-select'),
              value: 'a',
              placeholder: 'Kind',
              options: const [(value: 'a', label: 'Alpha'), (value: 'b', label: 'Beta')],
              onChanged: (_) {},
            ),
          ),
        ),
      ),
      edgeToEdge: true,
    );
    await t.tap(find.byKey(const ValueKey('open-sheet')));
    await _settle(t);
    expect(platformLabels(t), contains('Node settings'));
    await t.tap(find.byKey(const ValueKey('open-dialog')));
    await _settle(t);
    var labels = platformLabels(t).join(' | ');
    expect(labels, contains('Rename'));
    expect(labels, contains('Save'));
    expect(labels, isNot(contains('Node settings')), reason: labels);
    expect(labels, isNot(contains('The page')), reason: labels);

    await t.tap(find.byKey(const ValueKey('dialog-select')));
    await _settle(t);
    labels = platformLabels(t).join(' | ');
    expect(labels, contains('Beta'), reason: labels);
    expect(labels, isNot(contains('Save')), reason: 'the form behind the picker: $labels');
    expect(labels, isNot(contains('Row 0')), reason: labels);

    expect(await t.binding.handlePopRoute(), isTrue, reason: 'Back closes the picker first');
    await _settle(t);
    labels = platformLabels(t).join(' | ');
    expect(labels, contains('Save'), reason: labels);
    expect(find.text('Rename'), findsWidgets);
    semantics.dispose();
  });

  testWidgets('a confirmation stays centred on a phone (raft\'s confirm policy), its buttons 44 px', (t) async {
    phoneView(t, size: const Size(411, 914), padding: gestureInsets);
    final nav = await pumpPhoneApp(t, const DifyPage(edgeToEdge: true, body: SizedBox.expand()), edgeToEdge: true);
    final ok = showDifyConfirm(
      nav.currentContext!,
      title: 'Delete it?',
      confirmKey: const ValueKey('ok'),
      cancelKey: const ValueKey('no'),
    );
    await _settle(t);
    expect(find.byType(DifySheetGrabHandle), findsNothing);
    expect(find.byType(DifyAlertDialogContent), findsOneWidget);
    expect(t.getSize(find.byKey(const ValueKey('ok'))).height, greaterThanOrEqualTo(44));
    expect(t.getSize(find.byKey(const ValueKey('no'))).height, greaterThanOrEqualTo(44));
    final box = t.getRect(find.byType(DifyAlertDialogContent));
    expect(box.center.dy, closeTo((gestureInsets.top + 914 - gestureInsets.bottom) / 2, 1));
    await t.tap(find.byKey(const ValueKey('ok')));
    await _settle(t);
    expect(await ok, isTrue);
  });

  testWidgets('accessibility of a portal sheet: its title names the sheet (announced when it opens) and is read '
      'first, then its close and content; the scrim\'s Close comes last', (t) async {
    final semantics = t.ensureSemantics();
    phoneView(t, size: const Size(411, 914), padding: gestureInsets);
    await pumpPhoneApp(t, _Page(open: (_) {}), edgeToEdge: true);
    await t.tap(find.byKey(const ValueKey('open-sheet')));
    await _settle(t);
    final order = _readingOrder(t);
    final title = order.indexOf('Node settings');
    expect(title, 0, reason: '$order');
    expect(order.indexOf('Close'), greaterThan(title), reason: '$order');
    expect(order.indexOf('Add'), greaterThan(order.indexOf('Close')), reason: '$order');
    expect(order.last, 'Close', reason: 'the scrim last: $order');
    expect(order.where((l) => l == 'Close'), hasLength(2), reason: 'the header close and the scrim');
    final node = t.getSemantics(find.text('Node settings'));
    expect(node.getSemanticsData().flagsCollection.namesRoute, isTrue);
    semantics.dispose();
  });

  group('DifyActionRow', () {
    Widget card(String key) => Container(
      key: ValueKey(key),
      height: 32,
      color: const Color(0xFFEEEEEE),
      child: Row(
        children: [
          const DifyTextLine('text · Text'),
          const Spacer(),
          DifyIconButton(label: 'Hover edit', icon: const RemixIcon('edit-line', size: 16), onPressed: () {}),
        ],
      ),
    );

    testWidgets('a phone: 48 px, one node named by its label with its actions; tap edits; long press and "…" open '
        'Edit, Delete, Move up, Move down', (t) async {
      final semantics = t.ensureSemantics();
      phoneView(t, size: const Size(411, 914), padding: gestureInsets);
      final log = <String>[];
      await pumpPhoneApp(
        t,
        DifyPage(
          edgeToEdge: true,
          body: Padding(
            padding: const EdgeInsets.fromLTRB(16, 100, 16, 0),
            child: Column(
              children: [
                DifyActionRow(
                  label: 'text, Text, required',
                  onTap: () => log.add('edit'),
                  actions: [
                    DifyActionRow.edit(() => log.add('edit')),
                    DifyActionRow.delete(() => log.add('delete')),
                    DifyActionRow.moveUp(() => log.add('up'), enabled: false),
                    DifyActionRow.moveDown(() => log.add('down')),
                  ],
                  child: card('card'),
                ),
              ],
            ),
          ),
        ),
        edgeToEdge: true,
      );
      final row = find.byKey(const ValueKey('card'));
      expect(t.getSize(row).height, 48);
      final node = t.getSemantics(find.ancestor(of: row, matching: find.byType(Semantics)).first);
      final data = node.getSemanticsData();
      expect(data.label, 'text, Text, required');
      expect(data.hasAction(SemanticsAction.tap), isTrue);
      expect(data.hasAction(SemanticsAction.longPress), isTrue);
      final custom = [
        for (final id in data.customSemanticsActionIds ?? <int>[]) CustomSemanticsAction.getAction(id)!.label,
      ];
      expect(custom, containsAll(['Edit', 'Delete', 'Move down']));
      expect(custom, isNot(contains('Move up')), reason: 'off for the first row');
      expect(platformLabels(t), isNot(contains('Hover edit')), reason: "the card's hover controls are not read");

      // The card ignores pointers on a phone: the row around it takes the tap.
      await t.tap(row, warnIfMissed: false);
      await _settle(t);
      expect(log, ['edit']);

      final more = find.byKey(const ValueKey('dify-action-row-more-text, Text, required'));
      expect(t.getSize(more), const Size(44, 44));
      expect(find.bySemanticsLabel('More actions for text, Text, required'), findsOneWidget);
      await t.tap(more);
      await _settle(t);
      for (final a in ['Edit', 'Delete', 'Move up', 'Move down']) {
        expect(find.text(a), findsOneWidget, reason: a);
      }
      await t.tap(find.text('Move up'));
      await _settle(t);
      expect(find.text('Move down'), findsOneWidget, reason: 'a disabled action does nothing');
      await t.tap(find.text('Move down'));
      await _settle(t);
      expect(log, ['edit', 'down']);

      await t.longPress(row, warnIfMissed: false);
      await _settle(t);
      await t.tap(find.text('Delete'));
      await _settle(t);
      expect(log, ['edit', 'down', 'delete']);
      semantics.dispose();
    });

    testWidgets('a wide window: the row as Dify draws it (no "…", its own height and hover controls)', (t) async {
      phoneView(t, size: const Size(1280, 800));
      await pumpPhoneApp(
        t,
        DifyPage(
          body: Center(
            child: SizedBox(
              width: 400,
              child: DifyActionRow(
                label: 'text',
                onTap: () {},
                actions: [DifyActionRow.delete(() {})],
                child: card('card'),
              ),
            ),
          ),
        ),
      );
      expect(t.getSize(find.byKey(const ValueKey('card'))).height, 32);
      expect(find.byType(DifyTouchIconButton), findsNothing);
      expect(find.bySemanticsLabel('Hover edit'), findsOneWidget);
    });
  });
}
