/// components/app-sidebar (Dify 1.17.1) for an opened app: the top (home and "/ Studio" breadcrumb, the sidebar
/// toggle), the app info (icon, name, mode, the operations menu) and the page navigation by role and mode. Dify's
/// Goto Anything button is not part of dify-sf (nor is the main navigation's search).
library;

import 'package:collab_client/collab_client.dart';
import 'package:flutter/widgets.dart';

import '../design/dify_icon.dart';
import '../design/dify_tokens.g.dart';
import '../design/widgets/widgets.dart';
import '../i18n/dify_i18n.dart';
import '../studio/app_icons.dart';
import 'app_permission.dart';
import 'detail_page_slot.dart';
import 'detail_sidebar.dart';

String _t(String ns, String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr(ns, key, params);

/// base/icons vender/Annotations (16 x 16, `currentColor`).
const annotationsSvg =
    '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg"><path d="M13.75 '
    '4.068L12.25 5.568V2H5.5V5.75H1.75V14H12.25V11.9319L13.75 10.432V14.7561C13.75 15.167 13.4163 15.5 13.0049 15.5H'
    '0.9951C0.5836 15.5 0.25 15.1626 0.25 14.7449V5L4.7524 0.5H12.9984C13.4135 0.5 13.75 0.84148 13.75 1.24385V4.068Z'
    'M14.3337 5.6057L15.3943 6.6663L9.5606 12.5L8.4984 12.4984L8.5 11.4394L14.3337 5.6057Z" fill="currentColor"/></svg>';

/// app-info/app-mode-labels.ts `getAppModeLabel`.
String getAppModeLabel(String mode) => switch (mode) {
  AppModes.advancedChat => _t('app', 'types.advanced'),
  AppModes.agentChat => _t('app', 'types.agent'),
  AppModes.chat => _t('app', 'types.chatbot'),
  AppModes.completion => _t('app', 'types.completion'),
  _ => _t('app', 'types.workflow'),
};

/// One navigation item (`AppDetailNavItem`): the page, its label and its icons.
typedef AppDetailNavItem = ({AppDetailPageId page, String name, Widget Function(Color color, bool selected) icon});

Widget Function(Color, bool) _remix(String line, String fill) =>
    (color, selected) => RemixIcon(selected ? fill : line, size: 18, color: color);

/// app-detail-section.tsx's `navigation`: Orchestrate (layout access), Access Point, Logs, Annotations (not for
/// workflow and completion apps), Monitoring. Deploy (enterprise `app.acl.deploy`) and Resource Access (RBAC) never
/// show in the community edition and are not part of dify-sf.
List<AppDetailNavItem> appDetailNavigation(AppInfo app, AppACLCapabilities acl) {
  final supportsAnnotations = app.mode != AppModes.workflow && app.mode != AppModes.completion;
  return [
    if (acl.canAccessLayout)
      (
        page: AppDetailPageId.workflow,
        name: _t('common', 'appMenus.promptEng'),
        icon: _remix('terminal-window-line', 'terminal-window-fill'),
      ),
    if (acl.canViewAccessPoint)
      (
        page: AppDetailPageId.accessPoint,
        name: _t('common', 'appMenus.accessPoint'),
        icon: (color, _) => DifyIcon('vender/agent-v2/access-point', size: 18, color: color),
      ),
    if (acl.canAccessLogAndAnnotation)
      (
        page: AppDetailPageId.logs,
        name: _t('common', 'appMenus.logs'),
        icon: _remix('file-list-3-line', 'file-list-3-fill'),
      ),
    if (acl.canAccessLogAndAnnotation && supportsAnnotations)
      (
        page: AppDetailPageId.annotations,
        name: _t('common', 'appMenus.annotations'),
        icon: (color, _) => svgIcon(annotationsSvg, size: 16, color: color),
      ),
    if (acl.canMonitor)
      (
        page: AppDetailPageId.overview,
        name: _t('common', 'appMenus.overview'),
        icon: _remix('dashboard-2-line', 'dashboard-2-fill'),
      ),
  ];
}

/// app-detail-top.tsx: expanded, the combined home control (arrow + home icon) and "/ Studio" on the left and the
/// toggle on the right; collapsed, the toggle alone. Both links lead back to the Studio (dify-sf's home).
class AppDetailTop extends StatelessWidget {
  const AppDetailTop({super.key, required this.expand, this.onToggle, required this.onHome});

  final bool expand;
  final VoidCallback? onToggle;

  /// Home and the Studio breadcrumb (`/` and `/apps`): both the Studio in dify-sf.
  final VoidCallback onHome;

  Widget _toggle() => DetailSidebarToggleButton(
    expand: expand,
    onToggle: onToggle!,
    icon: (color) => svgIcon(sidebarLeftArrowSvg, color: color),
  );

  @override
  Widget build(BuildContext context) {
    if (!expand) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: Center(child: onToggle == null ? const SizedBox(height: 32) : _toggle()),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: Row(
              spacing: 1,
              children: [
                DifyPressable(
                  key: const ValueKey('app-detail-home'),
                  semanticLabel: _t('common', 'mainNav.home'),
                  onPressed: onHome,
                  builder: (context, hovered, focused) {
                    final color = hovered ? DifyColors.textSecondary : DifyColors.textTertiary;
                    return Container(
                      padding: const EdgeInsets.fromLTRB(2, 8, 6, 8),
                      decoration: BoxDecoration(
                        color: hovered ? DifyColors.backgroundDefaultHover : null,
                        borderRadius: BorderRadius.circular(DifyRadius.lg),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          RemixIcon('arrow-left-s-line', size: 16, color: color),
                          DifyIcon('vender/main-nav/app-home', size: 16, color: color),
                        ],
                      ),
                    );
                  },
                ),
                Text('/', style: difyTextStyle(DifyType.systemMdRegular, DifyColors.textQuaternary)),
                Flexible(
                  child: DifyPressable(
                    key: const ValueKey('app-detail-studio'),
                    semanticLabel: _t('common', 'menus.apps'),
                    onPressed: onHome,
                    builder: (context, hovered, focused) => Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                      decoration: BoxDecoration(
                        color: hovered ? DifyColors.backgroundDefaultHover : null,
                        borderRadius: BorderRadius.circular(DifyRadius.lg),
                      ),
                      child: Text(
                        difyTransform(DifyType.systemSmSemiboldUppercase, _t('common', 'menus.apps')),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: difyTextStyle(
                          DifyType.systemSmSemiboldUppercase,
                          hovered ? DifyColors.textPrimary : DifyColors.textSecondary,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (onToggle != null) _toggle(),
        ],
      ),
    );
  }
}

/// nav-link/index.tsx's active rule: [active] when given, else whether [href]'s last segment is the current one (the
/// last segment of [pathname], else the layout [segment], where `annotations` counts as `logs`).
bool navLinkIsActive({String? href, String? pathname, String? segment, bool? active}) {
  if (active != null) return active;
  if (href == null) return false;
  String? format(String? v) {
    final res = v?.toLowerCase();
    return pathname == null && res == 'annotations' ? 'logs' : res;
  }

  final current = format(pathname != null ? pathname.split('/').where((s) => s.isNotEmpty).lastOrNull : segment);
  return href.toLowerCase().split('/').last == current;
}

/// nav-link/index.tsx: a page link, `h-8 rounded-lg pl-3 pr-1` with the 20 px icon box and the label (`ml-2`), or a
/// 32 px square collapsed (the name as its tooltip). Active: `bg-components-menu-item-bg-active`, the highlight border
/// (`border-t-[0.75px] border-r-[0.25px] border-b-[0.25px] border-l-[0.75px]`), `system-sm-semibold
/// text-text-accent-light-mode-only` and the selected icon; else `system-sm-medium text-components-menu-item-text`,
/// hover `bg-components-menu-item-bg-hover text-components-menu-item-text-hover`. Disabled: `opacity-30`, inert.
class AppDetailNavLink extends StatelessWidget {
  const AppDetailNavLink({
    super.key,
    required this.name,
    required this.icon,
    required this.active,
    this.expand = true,
    this.disabled = false,
    this.onTap,
  });

  final String name;
  final Widget Function(Color color, bool selected) icon;
  final bool active, expand, disabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    Widget link = DifyPressable(
      disabled: disabled,
      semanticLabel: name,
      onPressed: onTap,
      builder: (context, hovered, focused) {
        final on = active && !disabled;
        final color = on
            ? DifyColors.textAccentLightModeOnly
            : hovered && !disabled
            ? DifyColors.componentsMenuItemTextHover
            : DifyColors.componentsMenuItemText;
        final borderColor = DifyColors.effectsHighlightLightmodeOff.withValues(alpha: on ? null : 0);
        Widget box = Container(
          height: 32,
          width: expand ? null : 32,
          // Collapsed: `size-8 p-1.5` leaves 19 px for the 20 px icon box (CSS lets it overflow); centred, it is the same.
          padding: expand ? const EdgeInsets.only(left: 12, right: 4) : EdgeInsets.zero,
          decoration: BoxDecoration(
            color: on
                ? DifyColors.componentsMenuItemBgActive
                : hovered
                ? DifyColors.componentsMenuItemBgHover
                : null,
            borderRadius: BorderRadius.circular(DifyRadius.lg),
            border: focused
                ? Border.all(color: DifyColors.stateAccentSolid, width: 2)
                : Border(
                    top: BorderSide(color: borderColor, width: 0.75),
                    right: BorderSide(color: borderColor, width: 0.25),
                    bottom: BorderSide(color: borderColor, width: 0.25),
                    left: BorderSide(color: borderColor, width: 0.75),
                  ),
          ),
          child: Row(
            mainAxisAlignment: expand ? MainAxisAlignment.start : MainAxisAlignment.center,
            children: [
              SizedBox.square(dimension: 20, child: Center(child: icon(color, on))),
              if (expand)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Text(
                      name,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.clip,
                      style: difyTextStyle(on ? DifyType.systemSmSemibold : DifyType.systemSmMedium, color),
                    ),
                  ),
                ),
            ],
          ),
        );
        if (disabled) box = Opacity(opacity: 0.3, child: box);
        return box;
      },
    );
    if (!expand) {
      link = DifyTooltip(placement: DifyPlacement.right, content: Text(name), child: link);
    }
    return Semantics(selected: active, child: link);
  }
}

/// The gradient (expanded) or solid (collapsed) divider between the navigation's groups (`renderNavDivider`).
class _NavDivider extends StatelessWidget {
  const _NavDivider({required this.expand});
  final bool expand;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.symmetric(horizontal: expand ? 12 : 4, vertical: 2),
    child: Container(
      height: 1,
      decoration: BoxDecoration(
        color: expand ? null : DifyColors.dividerSubtle,
        gradient: expand
            ? LinearGradient(colors: [DifyColors.dividerSubtle, DifyColors.backgroundGradientMaskTransparent])
            : null,
      ),
    ),
  );
}

/// app-detail-section.tsx: the collapsed panel's short divider, the app info, then the navigation with dividers
/// around Logs / Annotations.
class AppDetailSection extends StatelessWidget {
  const AppDetailSection({
    super.key,
    required this.app,
    required this.acl,
    required this.current,
    required this.onSelect,
    required this.appInfo,
    this.expand = true,
  });

  final AppInfo app;
  final AppACLCapabilities acl;
  final AppDetailPageId current;
  final ValueChanged<AppDetailPageId> onSelect;

  /// The app info block (`AppInfoView`).
  final Widget appInfo;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final navigation = appDetailNavigation(app, acl);
    final hasLogs = navigation.any((i) => i.page == AppDetailPageId.logs);
    final hasAnnotations = navigation.any((i) => i.page == AppDetailPageId.annotations);
    final links = <Widget>[];
    for (final item in navigation) {
      final isLogs = item.page == AppDetailPageId.logs, isAnnotations = item.page == AppDetailPageId.annotations;
      if (isLogs || (!hasLogs && isAnnotations)) links.add(_NavDivider(expand: expand));
      links.add(
        AppDetailNavLink(
          key: ValueKey('app-nav-${item.page.segment}'),
          name: item.name,
          icon: item.icon,
          expand: expand,
          active: item.page == current,
          onTap: () => onSelect(item.page),
        ),
      );
      if (hasAnnotations ? isAnnotations : isLogs) links.add(_NavDivider(expand: expand));
    }
    return Padding(
      padding: expand ? const EdgeInsets.fromLTRB(8, 0, 8, 8) : const EdgeInsets.only(bottom: 8),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!expand)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 2, 14, 3),
                child: Center(child: Container(width: 27, height: 1, color: DifyColors.dividerSubtle)),
              ),
            Padding(padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8), child: appInfo),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: expand ? 4 : 12, vertical: 4),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, spacing: 2, children: links),
            ),
          ],
        ),
      ),
    );
  }
}

/// One entry of the app info menu (`Operation`).
typedef AppInfoOperation = ({
  String id,
  String title,
  String icon,
  VoidCallback onClick,
  bool loading,
  bool destructive,
});

/// app-info-trigger.tsx + app-operations.tsx: expanded, the large icon, the name (`system-md-semibold
/// text-text-secondary`, truncated) with the More button (`size-5 rounded-md`) and the mode label
/// (`system-2xs-medium-uppercase text-text-tertiary`); collapsed, the medium icon alone. The menu (`min-w-40`, bottom
/// end, 4 px) lists the operation groups with separators; no menu without any operation.
class AppInfoTrigger extends StatefulWidget {
  const AppInfoTrigger({super.key, required this.app, required this.expand, required this.operationGroups});

  final AppInfo app;
  final bool expand;
  final List<List<AppInfoOperation>> operationGroups;

  @override
  State<AppInfoTrigger> createState() => _AppInfoTriggerState();
}

class _AppInfoTriggerState extends State<AppInfoTrigger> {
  final _menu = DifyFloatingController();
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final icon = DifyAppIcon(
      key: const ValueKey('app-info-icon'),
      size: widget.expand ? DifyAppIconSize.large : DifyAppIconSize.medium,
      iconType: app.iconType,
      icon: app.icon,
      background: app.iconBackground,
      imageUrl: app.iconUrl,
    );
    if (!widget.expand) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        alignment: Alignment.center,
        child: icon,
      );
    }
    final groups = [
      for (final g in widget.operationGroups)
        if (g.isNotEmpty) g,
    ];
    final modeLabel = getAppModeLabel(app.mode);
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 8,
        children: [
          icon,
          Expanded(
            child: SizedBox(
              height: 40,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 2,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Row(
                      spacing: 8,
                      children: [
                        Expanded(
                          child: Text(
                            app.name,
                            key: const ValueKey('app-info-name'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: difyTextStyle(DifyType.systemMdSemibold, DifyColors.textSecondary),
                          ),
                        ),
                        if (groups.isNotEmpty) _operations(app, groups),
                      ],
                    ),
                  ),
                  Text(
                    difyTransform(DifyType.system2xsMediumUppercase, modeLabel),
                    key: const ValueKey('app-info-mode'),
                    maxLines: 1,
                    softWrap: false,
                    style: difyTextStyle(DifyType.system2xsMediumUppercase, DifyColors.textTertiary),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _operations(AppInfo app, List<List<AppInfoOperation>> groups) => DifyDropdownMenu(
    key: const ValueKey('app-info-menu'),
    controller: _menu,
    open: _open,
    onOpenChange: (v) => setState(() => _open = v),
    placement: DifyPlacement.bottomEnd,
    sideOffset: 4,
    width: 160,
    builder: (context, controller) => DifyPressable(
      key: const ValueKey('app-info-more'),
      semanticLabel: _t('common', 'operation.moreActionsFor', {'name': app.name}),
      onPressed: controller.toggle,
      builder: (context, hovered, focused) => Container(
        width: 20,
        height: 20,
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: hovered || _open ? DifyColors.stateBaseHover : null,
          borderRadius: BorderRadius.circular(DifyRadius.md),
          border: focused ? Border.all(color: DifyColors.stateAccentSolid, width: 2) : null,
        ),
        child: RemixIcon('more-fill', size: 16, color: DifyColors.textTertiary),
      ),
    ),
    children: [
      for (final (i, group) in groups.indexed) ...[
        if (i > 0) const DifyMenuSeparator(),
        for (final op in group)
          DifyMenuItem(
            key: ValueKey('app-info-op-${op.id}'),
            paddingX: 12,
            disabled: op.loading,
            variant: op.destructive ? DifyMenuItemVariant.destructive : DifyMenuItemVariant.normal,
            onSelect: op.onClick,
            leading: op.loading
                ? DifySpinner(color: DifyColors.textTertiary, size: 16)
                : RemixIcon(
                    op.icon,
                    size: 16,
                    color: op.destructive ? DifyColors.textDestructive : DifyColors.textTertiary,
                  ),
            child: Text(
              op.title,
              style: difyTextStyle(
                DifyType.systemSmRegular,
                op.destructive ? DifyColors.textDestructive : DifyColors.textSecondary,
              ),
            ),
          ),
      ],
    ],
  );
}
