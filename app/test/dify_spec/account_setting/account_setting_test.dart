// dify-spec: web/app/components/header/account-setting/__tests__/index.spec.tsx
//
// dify-sf's account setting has the Members tab (Dify's community edition without RBAC, billing, customization or
// archives also shows only Members in its workspace group) and Preferences (protocol 1.12).
import 'package:dify_sf_app/src/design/dify_icon.dart';
import 'package:dify_sf_app/src/settings/account_setting.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../members/harness.dart';

Future<({List<AccountSettingTab> tabs, List<int> cancels})> _render(
  WidgetTester t, {
  String as = 'owner@example.com',
  Size size = const Size(1440, 900),
}) async {
  final f = await MembersFixture.create(as: as, more: [('editor@example.com', 'Editor User', 'editor')]);
  final tabs = <AccountSettingTab>[], cancels = <int>[];
  await renderMembers(
    t,
    AccountSetting(members: f.members, onTabChange: tabs.add, onCancel: () => cancels.add(1)),
  );
  if (size != const Size(1440, 900)) {
    t.view.physicalSize = size;
    await settle(t);
  }
  return (tabs: tabs, cancels: cancels);
}

const _absentTabs = [
  'common.settings.provider',
  'common.settings.rolesAndPermissions',
  'common.settings.permissionSet',
  'common.settings.billing',
  'appLog.archives.title',
  'common.settings.dataSource',
  'common.settings.customEndpoint',
  'custom.custom',
];

void main() {
  group('AccountSetting', () {
    group('Rendering', () {
      testWidgets('should render the sidebar with correct menu items', (t) async {
        await _render(t);
        expect(find.semantics.byPredicate((n) => n.label == 'common.settings.settings'), findsWidgets);
        expect(find.text('COMMON.SETTINGS.WORKSPACE'), findsOneWidget);
        expect(button('common.settings.members'), findsOneWidget);
        for (final tab in _absentTabs) {
          expect(find.text(tab), findsNothing, reason: tab);
        }
      });

      testWidgets('should hide sidebar labels on mobile', (t) async {
        await _render(t, size: const Size(600, 900));
        expect(find.text('COMMON.SETTINGS.WORKSPACE'), findsNothing);
        // The tab keeps its accessible name; the page title still names it.
        expect(button('common.settings.members'), findsOneWidget);
        expect(find.text('common.settings.members'), findsOneWidget);
        expect(find.text('common.settings.provider'), findsNothing);
      });

      testWidgets('should hide role and permission set entries when role management permission is missing', (t) async {
        await _render(t, as: 'editor@example.com');
        expect(button('common.settings.members'), findsOneWidget);
        expect(button('common.settings.rolesAndPermissions'), findsNothing);
        expect(button('common.settings.permissionSet'), findsNothing);
      });

      testWidgets('should hide role and permission set entries when RBAC is disabled', (t) async {
        await _render(t);
        expect(button('common.settings.members'), findsOneWidget);
        expect(button('common.settings.rolesAndPermissions'), findsNothing);
        expect(button('common.settings.permissionSet'), findsNothing);
      });

      testWidgets('should hide billing and custom tabs when disabled', (t) async {
        await _render(t);
        expect(find.text('common.settings.billing'), findsNothing);
        expect(find.text('custom.custom'), findsNothing);
      });

      testWidgets('should hide workflow log archives outside cloud edition', (t) async {
        await _render(t);
        expect(button('appLog.archives.title'), findsNothing);
      });
    });

    group('Tab Navigation', () {
      testWidgets('should change active tab when clicking on menu item', (t) async {
        final r = await _render(t);
        await tapButton(t, 'common.settings.members');
        expect(r.tabs, [AccountSettingTab.members]);
        // The sidebar entry and the content's title.
        expect(find.text('common.settings.members'), findsNWidgets(2));
      });

      testWidgets('should switch the preferences icon when the tab is active', (t) async {
        final r = await _render(t);
        RemixIcon icon() => t.widget<RemixIcon>(
          find.descendant(
            of: find.byKey(const ValueKey('account-setting-tab-preferences')),
            matching: find.byType(RemixIcon),
          ),
        );
        expect(button('common.settings.preferences'), findsOneWidget);
        expect(icon().name, 'equalizer-2-line');
        await tapButton(t, 'common.settings.preferences');
        expect(icon().name, 'equalizer-2-fill');
        expect(r.tabs, [AccountSettingTab.preferences]);
        // The tab's title is Dify's `account.general`.
        expect(find.text('common.account.general'), findsOneWidget);
      });
    });

    group('Interactions', () {
      testWidgets('should call onCancel when clicking close button', (t) async {
        final r = await _render(t);
        await tapButton(t, 'common.operation.close');
        expect(r.cancels, [1]);
      });

      testWidgets('should call onCancel when pressing Escape key', (t) async {
        final r = await _render(t);
        await t.sendKeyEvent(LogicalKeyboardKey.escape);
        await t.pump();
        expect(r.cancels, [1]);
      });

      testWidgets('should handle scroll event in panel', (t) async {
        await _render(t, size: const Size(1440, 400));
        final scroll = find.byKey(const ValueKey('account-setting-scroll'));
        expect(scroll, findsOneWidget);
        await t.drag(scroll, const Offset(0, -100));
        await t.pump();
        await t.drag(scroll, const Offset(0, 100));
        await t.pump();
        expect(scroll, findsOneWidget);
      });
    });
  });
}
