/// components/detail-sidebar (Dify 1.17.1): the frame of a detail page's sidebar (the app detail's, in dify-sf). It
/// takes the main navigation's place: 248 px wide (`w-62`, a 240 px panel) or collapsed to 64 px (`w-16`, a 56 px
/// panel), remembered in the `app-detail-collapse-or-expand` preference; `Mod+B` toggles it outside text fields;
/// hovering the collapsed panel shows it expanded as a floating preview over the page (closing 120 ms after the
/// pointer leaves) without changing the remembered mode. The account section sits at the bottom. Dify's help menu and
/// its environment tag are not part of dify-sf (as in the main navigation).
library;

import 'dart:async';

import 'package:collab_client/collab_client.dart' show Account;
import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../auth/account_dropdown.dart';
import '../design/dify_icon.dart';
import '../design/dify_tokens.g.dart';
import '../design/widgets/widgets.dart';
import '../i18n/dify_i18n.dart';
import '../workflow_editor/header/hotkey.dart' show PageHotkey;

/// detail-sidebar/hotkeys.ts.
const detailSidebarToggleHotkey = 'Mod+B';

/// detail-sidebar/storage.ts: the preference's key and values (`expand` by default).
const detailSidebarStorageKey = 'app-detail-collapse-or-expand';

/// base/icons vender/SidebarLeftArrowIcon (16 x 16, `currentColor`).
const sidebarLeftArrowSvg =
    '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg"><path d="M13.333 '
    '4.66675C13.333 4.29855 13.0345 4.00008 12.6663 4.00008H3.33301C2.96482 4.00008 2.66634 4.29856 2.66634 4.66675V'
    '11.3334C2.66634 11.7016 2.96481 12.0001 3.33301 12.0001H12.6663C13.0346 12.0001 13.333 11.7016 13.333 11.3334V'
    '4.66675ZM14.6663 11.3334C14.6663 12.438 13.7709 13.3334 12.6663 13.3334H3.33301C2.22844 13.3334 1.33301 12.438 '
    '1.33301 11.3334V4.66675C1.33301 3.56218 2.22844 2.66675 3.33301 2.66675H12.6663C13.7709 2.66675 14.6663 3.56218 '
    '14.6663 4.66675V11.3334Z" fill="currentColor"/><path d="M3.99967 10.0001V6.00008C3.99967 5.63189 4.29815 5.33341 '
    '4.66634 5.33341C5.03453 5.33341 5.33301 5.63189 5.33301 6.00008V10.0001C5.33301 10.3683 5.03453 10.6667 4.66634 '
    '10.6667C4.29815 10.6667 3.99967 10.3683 3.99967 10.0001Z" fill="currentColor"/></svg>';

/// An inline `currentColor` SVG in [color].
Widget svgIcon(String svg, {double size = 16, required Color color}) => SvgPicture.string(
  svg,
  width: size,
  height: size,
  colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
);

/// What the frame hands its top and section builders: whether the panel shows expanded (also during the hover
/// preview) and the toggle.
typedef DetailSidebarRender = Widget Function(BuildContext context, bool expand, VoidCallback onToggle);

/// `DetailSidebarFrame` plus the page next to it: [child] fills the rest of the row, the panel paints over it while
/// the hover preview is open.
class DetailSidebarFrame extends StatefulWidget {
  const DetailSidebarFrame({
    super.key,
    required this.renderTop,
    required this.renderSection,
    required this.child,
    this.account,
    this.accountSection,
  });

  final DetailSidebarRender renderTop;
  final Widget Function(BuildContext context, bool expand) renderSection;
  final Widget child;

  /// The signed-in account (the bottom's account section); null: none (tests, the demo).
  final Account? account;

  /// Builds the bottom's account section instead of [AccountSection] (tests); [compact] while collapsed.
  final Widget Function(BuildContext context, bool compact)? accountSection;

  @override
  State<DetailSidebarFrame> createState() => DetailSidebarFrameState();
}

class DetailSidebarFrameState extends State<DetailSidebarFrame> {
  /// The remembered mode (`useDetailSidebarMode`).
  bool _expanded = true;
  bool _mobileOpen = false;
  bool _previewOpen = false;
  bool _transitionDisabled = false;
  Timer? _closePreview, _transition;

  /// The persisted mode (tests).
  bool get expanded => _expanded;
  bool get previewOpen => !_expanded && _previewOpen;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final stored = (await SharedPreferences.getInstance()).getString(detailSidebarStorageKey);
      if (mounted && stored == 'collapse') setState(() => _expanded = false);
    } on Object {
      // No preferences (some test hosts): stay expanded.
    }
  }

  void _store(bool expand) {
    _expanded = expand;
    unawaited(
      SharedPreferences.getInstance().then(
        (p) => p.setString(detailSidebarStorageKey, expand ? 'expand' : 'collapse'),
        onError: (Object _) => false,
      ),
    );
  }

  @override
  void dispose() {
    _closePreview?.cancel();
    _transition?.cancel();
    super.dispose();
  }

  /// `handleToggleDetailNavigation`: from the hover preview it pins the panel open without a transition.
  void toggle() {
    if (DifyAdaptive.compactOf(context)) {
      setState(() => _mobileOpen = !_mobileOpen);
      return;
    }
    if (previewOpen) {
      _transition?.cancel();
      setState(() {
        _transitionDisabled = true;
        _previewOpen = false;
        _store(true);
      });
      _transition = Timer(const Duration(milliseconds: 200), () {
        if (mounted) setState(() => _transitionDisabled = false);
      });
      return;
    }
    setState(() {
      _previewOpen = false;
      _store(!_expanded);
    });
  }

  void _openPreview() {
    if (_expanded) return;
    _closePreview?.cancel();
    setState(() => _previewOpen = true);
  }

  void _schedulePreviewClose() {
    _closePreview?.cancel();
    _closePreview = Timer(const Duration(milliseconds: 120), () {
      if (mounted) setState(() => _previewOpen = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final compact = DifyAdaptive.compactOf(context);
    final preview = !compact && previewOpen;
    final visibleExpanded = compact || _expanded || preview;
    final duration = _transitionDisabled ? Duration.zero : const Duration(milliseconds: 150);
    const curve = Cubic(0.4, 0, 0.2, 1);
    final panelRadius = BorderRadius.circular(DifyRadius.lg);
    final panel = Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: DifyColors.componentsPanelBg,
        borderRadius: panelRadius,
        border: preview ? Border.all(color: DifyColors.dividerSubtle) : null,
        boxShadow: preview ? DifyShadows.lg : null,
      ),
      child: MouseRegion(
        onExit: _expanded ? null : (_) => _schedulePreviewClose(),
        child: OverflowBox(
          alignment: Alignment.topLeft,
          minWidth: visibleExpanded ? 240 : 56,
          maxWidth: visibleExpanded ? 240 : 56,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: MouseRegion(
                  onEnter: _expanded ? null : (_) => _openPreview(),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      widget.renderTop(context, visibleExpanded, toggle),
                      Expanded(child: widget.renderSection(context, visibleExpanded)),
                    ],
                  ),
                ),
              ),
              _bottom(visibleExpanded),
            ],
          ),
        ),
      ),
    );
    if (compact) {
      return Stack(
        fit: StackFit.expand,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: DifyIconButton(
                  label: DetailSidebarToggleButton.labelFor(false),
                  icon: const RemixIcon('menu-line', size: 20),
                  onPressed: toggle,
                ),
              ),
              Expanded(child: widget.child),
            ],
          ),
          if (_mobileOpen) ...[
            Positioned.fill(child: DifyDrawerBackdrop(onTap: toggle)),
            Positioned(left: 4, top: 4, bottom: 4, width: 240, child: panel),
          ],
        ],
      );
    }
    return PageHotkey(
      hotkey: detailSidebarToggleHotkey,
      onPressed: toggle,
      child: Container(
        color: DifyColors.backgroundBody,
        child: Stack(
          children: [
            Positioned.fill(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AnimatedContainer(duration: duration, curve: curve, width: _expanded ? 248 : 64),
                  Expanded(child: widget.child),
                ],
              ),
            ),
            AnimatedPositioned(
              key: const ValueKey('detail-sidebar'),
              duration: duration,
              curve: curve,
              left: 4,
              top: 4,
              bottom: 4,
              width: visibleExpanded ? 240 : 56,
              child: panel,
            ),
          ],
        ),
      ),
    );
  }

  Widget _bottom(bool expanded) {
    final account = widget.account;
    if (!expanded) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 2,
          children: [
            if (widget.accountSection case final b?)
              b(context, true)
            else if (account != null)
              AccountSection(account: account, compact: true),
          ],
        ),
      );
    }
    return Container(
      width: 240,
      color: DifyColors.componentsPanelBg,
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          if (widget.accountSection case final b?)
            Flexible(child: b(context, false))
          else if (account != null)
            Flexible(child: AccountSection(account: account)),
        ],
      ),
    );
  }
}

/// detail-sidebar/toggle-button.tsx as the app sidebar's top uses it: a 32 px ghost button (`rounded-[10px]`,
/// `text-text-tertiary`, hover `bg-state-base-hover text-text-secondary`) with the sidebar icon, and a tooltip on the
/// right naming the action ("Collapse Sidebar" / "Expand Sidebar") with its `Mod+B` keycaps.
class DetailSidebarToggleButton extends StatelessWidget {
  const DetailSidebarToggleButton({super.key, required this.expand, required this.onToggle, this.icon});

  final bool expand;
  final VoidCallback onToggle;

  /// The icon (the arrow by default; the app sidebar's top passes the sidebar icon).
  final Widget Function(Color color)? icon;

  static String labelFor(bool expand) =>
      DifyI18n.tr('layout', expand ? 'sidebar.collapseSidebar' : 'sidebar.expandSidebar');

  @override
  Widget build(BuildContext context) {
    final label = labelFor(expand);
    return DifyTooltip(
      placement: DifyPlacement.right,
      surface: false,
      content: Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: DifyColors.componentsPanelBg,
          borderRadius: BorderRadius.circular(DifyRadius.lg),
          boxShadow: DifyShadows.lg,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 4,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Text(label, style: difyTextStyle(DifyType.systemXsMedium, DifyColors.textSecondary)),
            ),
            const DifyShortcutKbd(hotkey: detailSidebarToggleHotkey),
          ],
        ),
      ),
      child: DifyPressable(
        key: const ValueKey('detail-sidebar-toggle'),
        semanticLabel: label,
        onPressed: onToggle,
        builder: (context, hovered, focused) {
          final color = hovered ? DifyColors.textSecondary : DifyColors.textTertiary;
          return Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: hovered ? DifyColors.stateBaseHover : null,
              borderRadius: BorderRadius.circular(10),
              border: focused ? Border.all(color: DifyColors.stateAccentSolid, width: 2) : null,
            ),
            child:
                icon?.call(color) ??
                RemixIcon(expand ? 'arrow-left-s-line' : 'arrow-right-s-line', size: 16, color: color),
          );
        },
      ),
    );
  }
}
