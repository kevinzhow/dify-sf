/// The phone home (compact windows, below 600 dp): the edge-to-edge shell with the bottom navigation (Studio,
/// Integrations, Account), Android back, the destination surviving rotation and theme changes, and wider windows
/// keeping Dify's main navigation.
library;

import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/account/account_tab.dart';
import 'package:dify_sf_app/src/app_detail/app_detail_page.dart';
import 'package:dify_sf_app/src/app_detail/detail_sidebar.dart';
import 'package:dify_sf_app/src/design/dify_theme_mode.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/home_page.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/settings/integrations_page.dart';
import 'package:dify_sf_app/src/shell/phone_home_shell.dart';
import 'package:dify_sf_app/src/studio/app_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/app_fonts.dart';
import 'phone_harness.dart';

Finder _nav(String label) =>
    find.descendant(of: find.byKey(const ValueKey('phone-home-navigation')), matching: find.text(label));

PhoneHomeShell _shell(WidgetTester t) => t.widget<PhoneHomeShell>(find.byType(PhoneHomeShell));

void main() {
  setUpAll(() async {
    await DifyI18n.load('en-US');
    await useAppFonts();
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final w in phoneWindows) {
    testWidgets('${w.name}: the shell is edge to edge with Studio, Integrations and Account', (t) async {
      phoneWindow(t, size: w.size, insets: w.insets);
      final ws = await workspace();
      ws.api.seed(name: 'Support triage', creatorName: 'Owner User');
      ws.api.seed(name: 'Release notes', mode: AppModes.advancedChat);
      await pumpApp(t, ws);
      expect(t.takeException(), isNull);

      // No desktop chrome: no 248 px frame, no rail with its toggle.
      expect(find.byType(MainNavFrame), findsNothing);
      expect(find.byType(DetailSidebarToggleButton), findsNothing);

      // The page fills the window; the bars paint to its edges and keep their content in the safe area.
      final window = Offset.zero & w.size;
      expect(t.getRect(find.byType(Scaffold).first), window);
      final bar = t.getRect(find.byKey(const ValueKey('phone-home-navigation')));
      expect(bar.bottom, w.size.height);
      expect(bar.left, 0);
      expect(bar.right, w.size.width);
      expect(bar.height, DifyNavigationBar.height + w.insets.bottom);
      for (final label in ['Studio', 'Integrations', 'Account']) {
        expect(t.getRect(_nav(label)), insideSafeArea(w.size, w.insets), reason: label);
      }
      final title = find.descendant(of: find.byType(DifyTopAppBar), matching: find.text('Studio'));
      expect(t.getRect(title), insideSafeArea(w.size, w.insets));
      expect(t.getTopLeft(title).dy, lessThan(w.insets.top + DifyTopAppBar.height));

      // Studio: one-line rows, the Create button above the navigation bar.
      expect(find.byType(AppListRow), findsNWidgets(2));
      expect(find.text('Support triage'), findsOneWidget);
      final fab = t.getRect(find.byKey(const ValueKey('studio-create-fab')));
      expect(fab.bottom, moreOrLessEquals(bar.top - 16));
      expect(fab.right, moreOrLessEquals(w.size.width - 16));

      await t.tap(_nav('Integrations'));
      await settle(t);
      expect(find.byType(IntegrationsPage), findsOneWidget);
      expect(find.byKey(const ValueKey('integrations-section-title')), findsOneWidget);
      expect(_shell(t).tab, HomeTab.integrations);
      expect(t.takeException(), isNull);

      await t.tap(_nav('Account'));
      await settle(t);
      expect(find.byType(AccountTab), findsOneWidget);
      expect(find.byKey(const ValueKey('account-tab-profile')), findsOneWidget);
      expect(find.text('owner@example.com'), findsOneWidget);
      expect(t.takeException(), isNull);

      await t.tap(_nav('Studio'));
      await settle(t);
      expect(find.byType(AppListRow), findsNWidgets(2));
      await unmount(t);
    });
  }

  testWidgets('Android back: a tab returns to the Studio, the Studio leaves the app', (t) async {
    phoneWindow(t);
    final pops = recordSystemPops(t);
    final ws = await workspace();
    ws.api.seed(name: 'Support triage');
    await pumpApp(t, ws);

    await t.tap(_nav('Integrations'));
    await settle(t);
    expect(await systemBack(t), isTrue);
    expect(_shell(t).tab, HomeTab.studio);
    expect(pops, isEmpty);

    await t.tap(_nav('Account'));
    await settle(t);
    await t.tap(_nav('Integrations'));
    await settle(t);
    // One step back to the Studio, whichever tab came in between.
    expect(await systemBack(t), isTrue);
    expect(_shell(t).tab, HomeTab.studio);

    // The Studio is the home: back is the system's (the app goes to the background).
    expect(await systemBack(t), isFalse);
    expect(pops, ['SystemNavigator.pop']);
    expect(find.byType(PhoneHomeShell), findsOneWidget);
    await unmount(t);
  });

  testWidgets('Android back on a tab closes a popup open there first, then returns to the Studio', (t) async {
    phoneWindow(t);
    final ws = await workspace();
    await pumpApp(t, ws);
    await t.tap(_nav('Integrations'));
    await settle(t);
    // A popup opened on the tab (a menu, a select) holds a back step on the same route, like DifyFloating does.
    var popupClosed = 0;
    final popup = DifyBackStep(onDismiss: () => popupClosed++);
    popup.attach(t.element(find.byType(PhoneHomeShell)));
    await t.pump();

    expect(await systemBack(t), isTrue);
    expect(popupClosed, 1);
    expect(_shell(t).tab, HomeTab.integrations, reason: 'one back press closes only the newest layer');

    expect(await systemBack(t), isTrue);
    expect(_shell(t).tab, HomeTab.studio);
    expect(popupClosed, 1);
    await unmount(t);
  });

  testWidgets('Android back closes a sheet, then the search, before it leaves the Studio', (t) async {
    phoneWindow(t);
    final pops = recordSystemPops(t);
    final ws = await workspace();
    ws.api.seed(name: 'Support triage');
    await pumpApp(t, ws);

    await t.tap(find.byKey(const ValueKey('studio-search-open')));
    await settle(t);
    expect(find.byKey(const ValueKey('studio-search')), findsOneWidget);

    await tapVisible(t, find.byKey(const ValueKey('studio-sort-chip')));
    expect(find.text('Recently created'), findsOneWidget);
    expect(await systemBack(t), isTrue);
    expect(find.text('Recently created'), findsNothing, reason: 'the sheet closed');
    expect(find.byKey(const ValueKey('studio-search')), findsOneWidget, reason: 'the search stays');

    expect(await systemBack(t), isTrue);
    expect(find.byKey(const ValueKey('studio-search')), findsNothing, reason: 'the search closed');
    expect(find.byKey(const ValueKey('studio-search-open')), findsOneWidget);
    expect(pops, isEmpty);

    expect(await systemBack(t), isFalse);
    expect(pops, ['SystemNavigator.pop']);
    await unmount(t);
  });

  testWidgets('Android back from an opened app returns to the Studio; the app page reaches under the bars', (t) async {
    phoneWindow(t, insets: threeButtonInsets);
    final ws = await workspace();
    ws.api.seed(name: 'Support triage');
    await pumpApp(t, ws);

    await t.tap(find.text('Support triage'));
    await settle(t, 2500);
    expect(find.byType(AppDetailPage), findsOneWidget);
    // Pushed edge to edge: the page's Scaffold (its background) fills the window, its content stays safe.
    final page = find.descendant(of: find.byType(AppDetailPage), matching: find.byType(Scaffold));
    expect(t.getRect(page.first), const Offset(0, 0) & const Size(411, 914));
    final safe = find.descendant(of: page.first, matching: find.byType(SafeArea));
    expect(t.getRect(safe.first), insideSafeArea(const Size(411, 914), EdgeInsets.zero));
    expect(MediaQuery.paddingOf(t.element(find.byType(DetailSidebarFrame))), EdgeInsets.zero);

    expect(await systemBack(t), isTrue);
    await settle(t, 1000);
    expect(find.byType(AppDetailPage), findsNothing);
    expect(find.byType(AppListRow), findsOneWidget);
    await unmount(t);
  });

  testWidgets('the destination survives a theme change and a rotation through the desktop layout', (t) async {
    phoneWindow(t);
    final ws = await workspace();
    ws.api.seed(name: 'Support triage');
    final theme = AppTheme(DifyThemeMode.light, remember: false);
    await pumpApp(t, ws, theme: theme);
    await t.tap(_nav('Account'));
    await settle(t);
    expect(_shell(t).tab, HomeTab.account);

    await theme.set(DifyThemeMode.dark);
    await settle(t);
    expect(_shell(t).tab, HomeTab.account);
    expect(find.byType(AccountTab), findsOneWidget);

    // Landscape is a medium window: Dify's main navigation, as before this batch.
    t.view.physicalSize = const Size(914, 411);
    t.view.padding = const FakeViewPadding(left: 32, right: 48);
    t.view.viewPadding = const FakeViewPadding(left: 32, right: 48);
    await settle(t);
    expect(find.byType(PhoneHomeShell), findsNothing);
    expect(find.byType(MainNavFrame), findsOneWidget);

    t.view.physicalSize = const Size(411, 914);
    t.view.padding = const FakeViewPadding(top: 32, bottom: 24);
    t.view.viewPadding = const FakeViewPadding(top: 32, bottom: 24);
    await settle(t);
    expect(_shell(t).tab, HomeTab.account);
    expect(find.byType(AccountTab), findsOneWidget);
    await theme.set(DifyThemeMode.light);
    await unmount(t);
  });

  testWidgets('the navigation bar gives way to the keyboard', (t) async {
    phoneWindow(t);
    final ws = await workspace();
    await pumpApp(t, ws);
    expect(find.byKey(const ValueKey('phone-home-navigation')), findsOneWidget);
    openKeyboard(t);
    await settle(t, 300);
    expect(find.byKey(const ValueKey('phone-home-navigation')), findsNothing);
    closeKeyboard(t);
    await settle(t, 300);
    expect(find.byKey(const ValueKey('phone-home-navigation')), findsOneWidget);
    await unmount(t);
  });

  for (final size in [const Size(600, 900), const Size(1440, 900)]) {
    testWidgets('a ${size.width.toInt()} px window keeps the desktop home', (t) async {
      phoneWindow(t, size: size, insets: EdgeInsets.zero);
      final ws = await workspace();
      ws.api.seed(name: 'Support triage');
      await pumpApp(t, ws);
      expect(find.byType(PhoneHomeShell), findsNothing);
      expect(find.byType(DifyNavigationBar), findsNothing);
      expect(find.byType(AppListRow), findsNothing);
      expect(find.byKey(const ValueKey('studio-page')), findsOneWidget);
      expect(find.byKey(const ValueKey('studio-create')), findsOneWidget, reason: 'the desktop Create dropdown');
      if (size.width >= 720) {
        expect(find.byType(MainNavFrame), findsOneWidget);
      } else {
        // 600-719: today's narrow layout (the rail with its toggle).
        expect(find.byType(DetailSidebarToggleButton), findsOneWidget);
      }
      await unmount(t);
    });
  }
}
