// dify-spec: web/app/components/apps/__tests__/creators-filter.spec.tsx
import 'package:collab_client/collab_client.dart' show Member;
import 'package:dify_sf_app/src/studio/filters.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsRole;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

const _members = [
  Member(id: 'member-1', name: 'Zoe', email: 'zoe@example.com', role: 'editor', status: 'active'),
  Member(id: 'member-2', name: 'Alice', email: 'alice@example.com', role: 'owner', status: 'active'),
  Member(id: 'member-3', name: 'Bob', email: 'bob@example.com', role: 'editor', status: 'active'),
  Member(id: 'member-4', name: 'Pending User', email: 'p@example.com', role: 'normal', status: 'pending'),
];

final _changes = <List<String>>[];

/// The filter for `member-2` (Alice); [stateful] keeps the value (`StatefulCreatorsFilter`).
class _Host extends StatefulWidget {
  const _Host({this.initial = const [], this.stateful = false});
  final List<String> initial;
  final bool stateful;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late List<String> value = widget.initial;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topLeft,
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: CreatorsFilter(
        value: value,
        members: _members,
        currentUserId: 'member-2',
        onChange: (v) {
          _changes.add(v);
          if (widget.stateful) setState(() => value = v);
        },
      ),
    ),
  );
}

Finder _search() =>
    find.descendant(of: find.byKey(const ValueKey('studio-creators-search')), matching: find.byType(EditableText));

Finder _option(String id) => find.byKey(ValueKey('studio-creator-$id'));

bool _focusIn(Finder f) {
  final focused = FocusManager.instance.primaryFocus?.context;
  if (focused == null) return false;
  final targets = f.evaluate().toSet();
  var inside = targets.contains(focused);
  focused.visitAncestorElements((e) {
    if (targets.contains(e)) inside = true;
    return !inside;
  });
  return inside;
}

Future<void> _open(WidgetTester t) => tapButton(t, 'app.studio.filters.creators');

Future<void> _typeSearch(WidgetTester t, String text) async {
  await t.enterText(_search(), text);
  await settle(t, 2);
}

void main() {
  setUp(_changes.clear);

  group('CreatorsFilter', () {
    testWidgets('should sort the current user first and filter out pending members', (t) async {
      await renderMembers(t, const _Host());
      await _open(t);
      final ids = ['member-2', 'member-3', 'member-1'];
      final ys = [for (final id in ids) t.getTopLeft(_option(id)).dy];
      expect(ys, [...ys]..sort(), reason: 'Alice, Bob, Zoe');
      expect(find.text('app.studio.filters.you'), findsOneWidget);
      expect(find.text('Pending User'), findsNothing);
    });

    testWidgets('should search creators, clear keywords, and select a creator', (t) async {
      await renderMembers(t, const _Host());
      await _open(t);
      await _typeSearch(t, 'zo');
      expect(_option('member-1'), findsOneWidget);
      expect(_option('member-3'), findsNothing);
      expect(t.widget<CreatorRow>(_option('member-1')).highlighted, isTrue, reason: 'autoHighlight');
      await t.tap(find.byKey(const ValueKey('studio-creators-search-clear')));
      await settle(t, 2);
      expect(t.widget<EditableText>(_search()).controller.text, '');
      expect(_focusIn(find.byKey(const ValueKey('studio-creators-search'))), isTrue);
      await t.tap(_option('member-3'));
      await settle(t, 2);
      expect(_changes.last, ['member-3']);
    });

    testWidgets('should clear only the search query from the input action', (t) async {
      await renderMembers(t, const _Host(initial: ['member-2']));
      await _open(t);
      await _typeSearch(t, 'zo');
      await t.tap(find.byKey(const ValueKey('studio-creators-search-clear')));
      await settle(t, 2);
      expect(t.widget<EditableText>(_search()).controller.text, '');
      expect(_focusIn(find.byKey(const ValueKey('studio-creators-search'))), isTrue);
      expect(t.widget<CreatorRow>(_option('member-2')).checked, isTrue);
      expect(_changes, isEmpty);
    });

    testWidgets('should return focus to the trigger after clearing creators from the filter chip', (t) async {
      await renderMembers(t, const _Host(initial: ['member-2', 'member-3'], stateful: true));
      expect(button('app.studio.filters.reset'), findsOneWidget);
      // The reset button is next to the trigger, not inside it.
      expect(
        find.descendant(
          of: find.bySemanticsLabel('app.studio.filters.creators'),
          matching: find.byKey(const ValueKey('studio-creators-reset')),
        ),
        findsNothing,
      );
      await tapButton(t, 'app.studio.filters.reset');
      expect(_changes.last, isEmpty);
      final focused = FocusManager.instance.primaryFocus!;
      expect(focused.debugLabel, 'creators trigger');
      expect(button('app.studio.filters.reset'), findsNothing);
    });

    testWidgets('should preserve unavailable creator ids when removing an available creator', (t) async {
      await renderMembers(t, const _Host(initial: ['missing-member', 'member-2', 'member-3']));
      await _open(t);
      expect(t.widget<CreatorRow>(_option('member-2')).checked, isTrue);
      await t.tap(_option('member-2'));
      await settle(t, 2);
      expect(_changes.last, ['missing-member', 'member-3']);
    });

    testWidgets('should expose the selected creator count from the closed trigger', (t) async {
      await renderMembers(t, const _Host(initial: ['member-2', 'member-3']));
      // The trigger's (sr-only) value; the visible `+2` is not part of its name.
      expect(button('app.studio.filters.creators'), findsOneWidget);
      expect(
        find.semantics.byPredicate((n) => n.getSemanticsData().value == 'common.dynamicSelect.selected:{"count":2}'),
        findsOneWidget,
      );
      expect(find.text('+2'), findsOneWidget);
    });

    testWidgets('should expose the creator picker as a named combobox with keyboard-owned options', (t) async {
      await renderMembers(t, const _Host());
      await _open(t);
      final popup = find.semantics.byPredicate(
        (n) => n.getSemanticsData().role == SemanticsRole.dialog && n.label == 'app.studio.filters.creators',
      );
      expect(popup, findsOneWidget);
      expect(t.widget<CreatorRow>(_option('member-2')).checked, isFalse);
      expect(_focusIn(find.byKey(const ValueKey('studio-creators-search'))), isTrue);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await t.pump();
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(t, 2);
      expect(_changes.last, ['member-2']);
    });
  });
}
