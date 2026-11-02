// The design's controls as TalkBack gets them on a phone (emulator recheck 2 of PR #90; dify-sf's phone layout, no
// Dify spec): a checkbox is one node, and a labelled checkbox's node is its touch-high row; an input is one node as
// tall as its box, named; a table row (DifyActionRow.builder) is a named group whose cells stay its own nodes and whose
// "…" sits inside it; a sheet shown from a page gives a screen reader's focus back to the control that opened it.
// Wide windows keep Dify's rows.
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';

import '../../support/platform_semantics.dart';
import 'phone_harness.dart';

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 12; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

bool _tappable(PlatformNode n) => n.data.hasAction(SemanticsAction.tap);

Future<void> _phone(WidgetTester t, Widget body) async {
  phoneView(t, size: const Size(411, 914), padding: gestureInsets);
  await pumpPhoneApp(
    t,
    DifyPage(
      edgeToEdge: true,
      body: Padding(padding: const EdgeInsets.fromLTRB(16, 100, 16, 0), child: body),
    ),
    edgeToEdge: true,
  );
  await _settle(t);
}

void main() {
  setUpAll(() => DifyI18n.load('en-US'));

  testWidgets('a checkbox is one node: its name, state and tap (not a state node beside an unnamed button)', (t) async {
    final semantics = t.ensureSemantics();
    var checked = false;
    await _phone(
      t,
      StatefulBuilder(
        builder: (context, set) => Align(
          alignment: Alignment.topLeft,
          child: DifyCheckbox(checked: checked, label: 'Required', onChanged: (v) => set(() => checked = v)),
        ),
      ),
    );
    final stops = [
      for (final n in platformNodes(t))
        if (spokenText(n).isNotEmpty || _tappable(n)) n,
    ];
    expect(stops, hasLength(1), reason: describeStops(stops));
    expect(stops.single.data.label, 'Required');
    expect(stops.single.data.flagsCollection.isChecked, CheckedState.isFalse);
    expect(_tappable(stops.single), isTrue);
    semantics.dispose();
  });

  testWidgets('DifyCheckboxLabel: on a phone the node is the whole touch-high row (box and text), a tap on the text '
      'toggles; a wide window keeps the h-6 row', (t) async {
    final semantics = t.ensureSemantics();
    var checked = false;
    Widget row() => StatefulBuilder(
      builder: (context, set) => Align(
        alignment: Alignment.topLeft,
        child: DifyCheckboxLabel(label: 'Required', checked: checked, onChanged: (v) => set(() => checked = v)),
      ),
    );
    await _phone(t, row());
    final stops = [
      for (final n in platformNodes(t))
        if (spokenText(n).isNotEmpty || _tappable(n)) n,
    ];
    expect(stops, hasLength(1), reason: 'no unlabelled stop for the text:\n${describeStops(stops)}');
    final node = stops.single;
    expect(node.data.label, 'Required');
    expect(node.rect.height, greaterThanOrEqualTo(44));
    expect(node.rect.width, greaterThan(16 + 8), reason: 'box and text: ${node.rect}');
    await t.tap(find.text('Required'));
    await _settle(t);
    expect(checked, isTrue);

    phoneView(t, size: const Size(1280, 800));
    await pumpPhoneApp(t, DifyPage(body: row()));
    await _settle(t);
    expect(t.getSize(find.byType(DifyCheckboxLabel)).height, 24);
    semantics.dispose();
  });

  testWidgets('DifyInput on a phone: one node, named, as tall as its 44 px box (no name node of its own around it)', (
    t,
  ) async {
    final semantics = t.ensureSemantics();
    await _phone(
      t,
      Column(
        children: [
          DifyInput(value: '', semanticLabel: 'Search', placeholder: 'Search'),
        ],
      ),
    );
    final named = [
      for (final n in platformNodes(t))
        if (n.data.label.contains('Search') || n.data.hint.contains('Search')) n,
    ];
    expect(named, hasLength(1), reason: describeStops(platformStops(t)));
    expect(named.single.data.flagsCollection.isTextField, isTrue);
    expect(named.single.data.label, contains('Search'));
    expect(named.single.rect.height, 44, reason: '${named.single.rect}');
    semantics.dispose();
  });

  testWidgets('DifyActionRow.builder: the "…" inside the row\'s layout; the row a named group with its actions, its '
      'cells nodes of their own; a wide window gets no "…"', (t) async {
    final semantics = t.ensureSemantics();
    final log = <String>[];
    var checked = true;
    Widget table() => StatefulBuilder(
      builder: (context, set) => DifyActionRow.builder(
        label: 'city',
        semanticLabel: 'city, Required',
        actions: [DifyActionRow.delete(() => log.add('delete'))],
        builder: (context, more) => Container(
          key: const ValueKey('row'),
          color: const Color(0xFFEEEEEE),
          child: Row(
            children: [
              const Expanded(child: DifyTextLine('city')),
              DifyCheckbox(checked: checked, label: 'Required', onChanged: (v) => set(() => checked = v)),
              ?more,
            ],
          ),
        ),
      ),
    );
    await _phone(t, table());
    final row = t.getRect(find.byKey(const ValueKey('row')));
    final more = t.getRect(find.byKey(const ValueKey('dify-action-row-more-city')));
    expect(
      row.contains(more.center) && more.right <= row.right,
      isTrue,
      reason: 'the "…" inside the row: $more in $row',
    );
    final nodes = platformNodes(t);
    final group = nodes.firstWhere((n) => n.data.label == 'city, Required');
    expect(group.data.hasAction(SemanticsAction.longPress), isTrue);
    expect(group.data.customSemanticsActionIds, isNotEmpty);
    expect(group.data.flagsCollection.isChecked, CheckedState.none, reason: "the checkbox's state is not the row's");
    final box = nodes.where((n) => n.data.label == 'Required');
    expect(box, hasLength(1), reason: 'the checkbox is a node of its own');
    await t.tap(find.byType(DifyCheckbox));
    await _settle(t);
    expect(checked, isFalse, reason: 'the cell keeps its own tap');
    await t.tap(find.byKey(const ValueKey('dify-action-row-more-city')));
    await _settle(t);
    await t.tap(find.text('Delete'));
    await _settle(t);
    expect(log, ['delete']);

    phoneView(t, size: const Size(1280, 800));
    await pumpPhoneApp(
      t,
      DifyPage(
        body: Center(child: SizedBox(width: 400, child: table())),
      ),
    );
    await _settle(t);
    expect(find.byType(DifyTouchIconButton), findsNothing);
    semantics.dispose();
  });

  testWidgets('a picker sheet gives a screen reader\'s focus back to the control that opened it when it closes', (
    t,
  ) async {
    final semantics = t.ensureSemantics();
    final sent = <Map<Object?, Object?>>[];
    t.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<Object?>(SystemChannels.accessibility, (m) async {
      if (m is Map) sent.add(m);
      return null;
    });
    addTearDown(
      () => t.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<Object?>(SystemChannels.accessibility, null),
    );
    var open = false;
    await _phone(
      t,
      StatefulBuilder(
        builder: (context, set) => Column(
          children: [
            DifyButton(
              key: const ValueKey('trigger'),
              onPressed: () => set(() => open = true),
              child: const DifyTextLine('Pick'),
            ),
            DifySheetPortal(
              open: open,
              onDismiss: () => set(() => open = false),
              builder: (context) => const DifySheetHeader(title: 'Picker'),
            ),
          ],
        ),
      ),
    );
    final trigger = t.getSemantics(find.byKey(const ValueKey('trigger'))).id;
    ServicesBinding.instance.accessibilityFocus.value = trigger;
    await t.tap(find.byKey(const ValueKey('trigger')));
    await _settle(t);
    expect(find.text('Picker'), findsOneWidget);
    ServicesBinding.instance.accessibilityFocus.value = t.getSemantics(find.text('Picker')).id;
    sent.clear();
    expect(await t.binding.handlePopRoute(), isTrue);
    await _settle(t);
    await t.pump(const Duration(milliseconds: 400));
    expect(find.text('Picker'), findsNothing);
    expect(t.getSemantics(find.byKey(const ValueKey('trigger'))).id, trigger);
    expect(
      [
        for (final m in sent)
          if (m['type'] == 'focus') m['nodeId'],
      ],
      [trigger],
      reason: '$sent',
    );
    ServicesBinding.instance.accessibilityFocus.value = null;
    semantics.dispose();
  });
}
