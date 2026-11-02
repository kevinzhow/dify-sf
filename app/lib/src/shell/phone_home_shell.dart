/// The signed-in home on a phone (compact windows, below 600 dp): an edge-to-edge page with the bottom navigation
/// (Studio, Integrations, Account) instead of Dify's 248 px main navigation, which wider windows keep. A dify-sf
/// divergence: Dify's console has no phone layout.
library;

import 'package:flutter/widgets.dart';

import '../active_page.dart';
import '../design/dify_icon.dart';
import '../design/widgets/widgets.dart';
import '../i18n/app_locale.dart';
import '../i18n/dify_i18n.dart';

/// The home's destinations, in the navigation bar's order. Wider windows show Studio or Integrations in the main
/// navigation frame; Account is a phone destination (the frame's account menu and workspace card hold it there).
enum HomeTab { studio, integrations, account }

/// The phone home: the [HomeTab] pages above a [DifyNavigationBar]. A page is built the first time it is shown and
/// then kept (its scroll position, search and loaded data survive switching back), the hidden ones without tickers,
/// focus or key handling ([ActivePage]).
///
/// Android back on Integrations or Account returns to Studio; on Studio it is left to the system (the app goes to the
/// background). Sheets, dialogs and popups above the page close first: they are routes, or close themselves
/// ([DifyFloating]).
class PhoneHomeShell extends StatefulWidget {
  const PhoneHomeShell({
    super.key,
    required this.tab,
    required this.onTab,
    required this.studio,
    required this.integrations,
    required this.account,
    this.keyboardOpen = false,
  });

  final HomeTab tab;

  /// Hides the navigation bar while the soft keyboard is open (Material 3's guidance), leaving the room to the page.
  /// The caller reads it above the page's Scaffold, which takes the keyboard out of its body's MediaQuery.
  final bool keyboardOpen;
  final ValueChanged<HomeTab> onTab;
  final WidgetBuilder studio, integrations, account;

  @override
  State<PhoneHomeShell> createState() => _PhoneHomeShellState();
}

class _PhoneHomeShellState extends State<PhoneHomeShell> {
  late final Set<HomeTab> _visited = {widget.tab};

  @override
  void didUpdateWidget(PhoneHomeShell old) {
    super.didUpdateWidget(old);
    _visited.add(widget.tab);
  }

  Widget _page(HomeTab tab) {
    if (!_visited.contains(tab)) return const SizedBox.shrink();
    final active = tab == widget.tab;
    final builder = switch (tab) {
      HomeTab.studio => widget.studio,
      HomeTab.integrations => widget.integrations,
      HomeTab.account => widget.account,
    };
    return KeyedSubtree(
      key: ValueKey('phone-home-${tab.name}'),
      child: ActivePage(
        active: active,
        child: TickerMode(
          enabled: active,
          child: ExcludeFocus(
            excluding: !active,
            child: Builder(builder: builder),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    AppLocaleScope.of(context);
    String c(String key) => DifyI18n.tr('common', key);
    final tab = widget.tab;
    // Integrations and Account are a back layer over Studio, like a popup: one back step on the route
    // ([DifyBackDismiss]), so a popup opened on the tab closes first and the tab only on the next back. A PopScope
    // here would receive the same back press as the popup's step.
    return DifyBackDismiss(
      enabled: tab != HomeTab.studio,
      onDismiss: () => widget.onTab(HomeTab.studio),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            // The pages sit above the navigation bar, which owns the bottom inset.
            child: MediaQuery.removePadding(
              context: context,
              removeBottom: true,
              child: IndexedStack(
                index: tab.index,
                sizing: StackFit.expand,
                children: [for (final t in HomeTab.values) _page(t)],
              ),
            ),
          ),
          if (!widget.keyboardOpen)
            DifyNavigationBar(
              key: const ValueKey('phone-home-navigation'),
              selectedIndex: tab.index,
              onDestinationSelected: (i) => widget.onTab(HomeTab.values[i]),
              destinations: [
                DifyNavigationDestination(icon: const RemixIcon('apps-2-line', size: 22), label: c('menus.apps')),
                DifyNavigationDestination(
                  icon: const RemixIcon('puzzle-2-line', size: 22),
                  label: c('mainNav.integrations'),
                ),
                DifyNavigationDestination(icon: const RemixIcon('user-line', size: 22), label: c('account.account')),
              ],
            ),
        ],
      ),
    );
  }
}
