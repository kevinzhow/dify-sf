// dify-spec: web/app/components/main-nav/components/__tests__/workspace-card.spec.tsx
//
// dify-sf has one workspace per server and no billing or license: the card names it "<owner>'s Workspace" (Dify's
// default) once the member list is in; the switcher's list can be given (Dify's tests use several workspaces).
import 'dart:async';

import 'package:dify_sf_app/src/settings/account_setting.dart';
import 'package:dify_sf_app/src/settings/workspace_card.dart';
import 'package:dify_sf_app/src/settings/workspace_members.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsRole;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../members/harness.dart';

const _name = "Owner User's Workspace";

/// Members whose list never arrives.
class _Pending extends WorkspaceMembers {
  _Pending(super.auth);

  @override
  Future<void> refresh() => Completer<void>().future;
}

const _openMenu = '$_name common.mainNav.workspace.openMenu';

const _two = [
  WorkspaceListItem(id: 'workspace-1', name: _name, current: true),
  WorkspaceListItem(id: 'workspace-2', name: 'Evan Workspace'),
];

Future<({MembersFixture f, List<AccountSettingTab> opened})> _render(
  WidgetTester t, {
  String as = 'owner@example.com',
  List<WorkspaceListItem>? workspaces = _two,
}) async {
  final f = await MembersFixture.create(
    as: as,
    more: [
      ('editor@example.com', 'Editor User', 'editor'),
      ('dataset@example.com', 'Dataset User', 'dataset_operator'),
    ],
  );
  final opened = <AccountSettingTab>[];
  await renderMembers(
    t,
    Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: 240,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: WorkspaceCard(members: f.members, workspaces: workspaces, onOpenSettings: opened.add),
        ),
      ),
    ),
  );
  return (f: f, opened: opened);
}

Future<void> _openPanel(WidgetTester t) async {
  await tapButton(t, _openMenu);
}

SemanticsFinder get _panel =>
    find.semantics.byPredicate((n) => n.label == _name && n.getSemanticsData().role == SemanticsRole.dialog);

List<String> _listed(WidgetTester t) {
  final items = find.byWidgetPredicate((w) => w is WorkspaceMenuButton && w.current != null).evaluate();
  final positioned = [
    for (final e in items) (y: t.getTopLeft(find.byWidget(e.widget)).dy, name: (e.widget as WorkspaceMenuButton).label),
  ]..sort((a, b) => a.y.compareTo(b.y));
  return [for (final p in positioned) p.name];
}

void main() {
  group('WorkspaceCard', () {
    testWidgets('includes the visible workspace name in the menu trigger accessible name', (t) async {
      await _render(t);
      expect(button(_openMenu), findsOneWidget);
    });

    testWidgets('keeps full workspace names on the final interactive title owner', (t) async {
      await _render(t);
      expect(button(_openMenu).evaluate().single.getSemanticsData().tooltip, _name);
      await _openPanel(t);
      expect(button('Evan Workspace'), findsOneWidget);
      expect(button('common.mainNav.workspace.settings'), findsOneWidget);
    });

    testWidgets('hides cloud-only credits and upgrade actions outside cloud edition', (t) async {
      await _render(t);
      expect(button(_openMenu), findsOneWidget);
      expect(find.textContaining('common.mainNav.workspace.credits'), findsNothing);
      expect(find.text('billing.upgradeBtn.encourageShort'), findsNothing);
    });

    testWidgets('renders a stable skeleton while the current workspace is loading', (t) async {
      final f = await MembersFixture.create();
      // The card's first request is still out.
      await renderMembers(
        t,
        Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: 240, child: WorkspaceCard(members: _Pending(f.auth))),
        ),
      );
      expect(find.byKey(const ValueKey('workspace-card-skeleton')), findsOneWidget);
      expect(button(_openMenu), findsNothing);
      expect(find.text('Evan Workspace'), findsNothing);
    });

    testWidgets('opens workspace actions and switcher in a popover panel', (t) async {
      await _render(t);
      await _openPanel(t);
      expect(_panel, findsOneWidget);
      expect(button('common.mainNav.workspace.settings'), findsOneWidget);
      expect(button('common.mainNav.workspace.inviteMembers'), findsOneWidget);
      expect(find.text('COMMON.USERPROFILE.WORKSPACE'), findsOneWidget);
      expect(button('common.mainNav.workspace.sort.openMenu'), findsOneWidget);
      expect(button('common.operation.search'), findsOneWidget);
      expect(button('Evan Workspace'), findsOneWidget);
      expect(_listed(t), hasLength(2));
    });

    testWidgets('filters workspace switcher options from the search action', (t) async {
      await _render(t);
      await _openPanel(t);
      await tapButton(t, 'common.operation.search');
      expect(find.text('COMMON.USERPROFILE.WORKSPACE'), findsOneWidget);
      expect(button('common.mainNav.workspace.sort.openMenu'), findsOneWidget);
      final search = find.descendant(
        of: find.byWidgetPredicate((w) => w.runtimeType.toString() == 'SelectorSearchInput'),
        matching: find.byType(EditableText),
      );
      expect(t.widget<EditableText>(search).focusNode.hasFocus, isTrue);
      await t.enterText(search, 'evan');
      await t.pump();
      expect(button('Evan Workspace'), findsOneWidget);
      expect(_listed(t), ['Evan Workspace']);
    });

    testWidgets('announces an empty workspace search result', (t) async {
      await _render(t);
      await _openPanel(t);
      await tapButton(t, 'common.operation.search');
      final search = find.descendant(
        of: find.byWidgetPredicate((w) => w.runtimeType.toString() == 'SelectorSearchInput'),
        matching: find.byType(EditableText),
      );
      await t.enterText(search, 'missing');
      await t.pump();
      expect(find.text('common.mainNav.workspace.noResults'), findsOneWidget);
      expect(_listed(t), isEmpty);
    });

    testWidgets('exposes only the current workspace as current', (t) async {
      await _render(t);
      await _openPanel(t);
      final current = find.byWidgetPredicate((w) => w is WorkspaceMenuButton && w.current == true);
      expect(current, findsOneWidget);
      expect(t.widget<WorkspaceMenuButton>(current).label, _name);
      final evan = find.byWidgetPredicate((w) => w is WorkspaceMenuButton && w.label == 'Evan Workspace');
      expect(t.widget<WorkspaceMenuButton>(evan).current, isFalse);
    });

    testWidgets('sorts workspaces by last opened and can sort by created time', (t) async {
      await _render(
        t,
        workspaces: const [
          WorkspaceListItem(id: 'workspace-1', name: _name, createdAt: 1, lastOpenedAt: 20, current: true),
          WorkspaceListItem(id: 'workspace-2', name: 'Evan Workspace', createdAt: 3),
          WorkspaceListItem(id: 'workspace-3', name: 'Atlas Workspace', createdAt: 2, lastOpenedAt: 30),
        ],
      );
      await _openPanel(t);
      expect(_listed(t), ['Atlas Workspace', _name, 'Evan Workspace']);
      await tapButton(t, 'common.mainNav.workspace.sort.openMenu');
      expect(find.text('common.mainNav.workspace.sort.lastOpened'), findsOneWidget);
      await t.tap(find.text('common.mainNav.workspace.sort.createdTime'));
      await settle(t);
      expect(_listed(t), ['Evan Workspace', 'Atlas Workspace', _name]);
    });

    testWidgets('closes the nested sort menu before the workspace popover on Escape', (t) async {
      await _render(t);
      await _openPanel(t);
      await tapButton(t, 'common.mainNav.workspace.sort.openMenu');
      expect(find.text('common.mainNav.workspace.sort.lastOpened'), findsOneWidget);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(t);
      expect(find.text('common.mainNav.workspace.sort.lastOpened'), findsNothing);
      expect(_panel, findsOneWidget);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(t);
      expect(_panel, findsNothing);
    });

    testWidgets('opens members settings from workspace menu when billing is disabled', (t) async {
      final r = await _render(t);
      await _openPanel(t);
      await tapButton(t, 'common.mainNav.workspace.settings');
      expect(r.opened, [AccountSettingTab.members]);
    });

    testWidgets('closes the popover without switching when the current workspace is selected', (t) async {
      await _render(t);
      await _openPanel(t);
      await t.tap(find.byKey(const ValueKey('workspace-item-workspace-1')));
      await settle(t);
      expect(_panel, findsNothing);
    });

    testWidgets('keeps workspace settings visible for dataset operators without member management permission', (
      t,
    ) async {
      await _render(t, as: 'dataset@example.com');
      await _openPanel(t);
      expect(button('common.mainNav.workspace.settings'), findsOneWidget);
      expect(button('common.mainNav.workspace.inviteMembers'), findsNothing);
    });

    testWidgets('shows invite members when member management permission is available', (t) async {
      final r = await _render(t, as: 'admin@example.com');
      await _openPanel(t);
      expect(button('common.mainNav.workspace.settings'), findsOneWidget);
      await tapButton(t, 'common.mainNav.workspace.inviteMembers');
      expect(r.opened, [AccountSettingTab.members]);
    });

    testWidgets('hides invite members when member management permission is missing', (t) async {
      await _render(t, as: 'editor@example.com');
      await _openPanel(t);
      expect(button('common.mainNav.workspace.settings'), findsOneWidget);
      expect(button('common.mainNav.workspace.inviteMembers'), findsNothing);
    });
  });
}
