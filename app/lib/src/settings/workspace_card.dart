/// main-nav/components/workspace-card.tsx, workspace-switcher.tsx and workspace-menu-content.tsx: the workspace card
/// at the top of the main navigation, whose menu opens the workspace settings (the account setting's Members tab)
/// and lists the workspaces. dify-sf has one workspace per server (Dify's community edition with one workspace) and
/// no billing (no plan badge, credits or upgrade action, as outside Dify's cloud edition).
library;

import 'dart:async';

import 'package:flutter/semantics.dart' show SemanticsRole;
import 'package:flutter/widgets.dart';

import '../design/dify_icon.dart';
import '../design/dify_tokens.g.dart';
import '../design/widgets/widgets.dart';
import '../workflow_editor/block_selector/selector_widgets.dart' show SelectorSearchInput;
import 'account_setting.dart';
import 'settings_kit.dart';
import 'workspace_members.dart';

/// One workspace of the switcher (`TenantListItemResponse`).
class WorkspaceListItem {
  const WorkspaceListItem({
    required this.id,
    required this.name,
    this.current = false,
    this.createdAt = 0,
    this.lastOpenedAt,
  });

  final String id;
  final String name;
  final bool current;
  final int createdAt;
  final int? lastOpenedAt;
}

/// The skeleton's bars: `animate-pulse rounded bg-text-quaternary opacity-20`.
class _SkeletonBar extends StatelessWidget {
  const _SkeletonBar({required this.width, required this.height, this.radius = DifyRadius.sm});
  final double width, height, radius;

  @override
  Widget build(BuildContext context) => Opacity(
    opacity: 0.2,
    child: Container(
      width: width,
      height: height,
      decoration: BoxDecoration(color: DifyColors.textQuaternary, borderRadius: BorderRadius.circular(radius)),
    ),
  );
}

/// WorkspaceCard: until the workspace's name is known, the skeleton; then the card (`rounded-xl border
/// border-components-card-border bg-components-card-bg shadow-xs`) whose trigger (`py-1.5 pr-3 pl-1.5`, `sm`
/// workspace avatar, the name `max-w-30 system-sm-medium`, `i-ri-expand-up-down-line`; named "NAME Open workspace
/// menu") opens the popover (`bottom-start`, over the trigger: sideOffset -36, alignOffset -28, `w-70` on the
/// blurred panel background): the header (name, `lg` avatar, "Workspace settings" and, for managers, "Invite
/// members", both opening the Members tab) and the workspace switcher.
class WorkspaceCard extends StatefulWidget {
  const WorkspaceCard({super.key, required this.members, this.workspaces, this.onOpenSettings});

  final WorkspaceMembers members;

  /// The switcher's workspaces; by default dify-sf's one workspace.
  final List<WorkspaceListItem>? workspaces;

  /// Opens the account setting on a tab ([showAccountSetting] by default).
  final void Function(AccountSettingTab tab)? onOpenSettings;

  @override
  State<WorkspaceCard> createState() => _WorkspaceCardState();
}

class _WorkspaceCardState extends State<WorkspaceCard> {
  final _popover = DifyFloatingController();
  bool _open = false;
  bool _hovered = false;

  WorkspaceMembers get _m => widget.members;

  @override
  void initState() {
    super.initState();
    _m.addListener(_changed);
    if (!_m.loaded && !_m.loading) unawaited(_m.refresh());
  }

  @override
  void didUpdateWidget(WorkspaceCard old) {
    super.didUpdateWidget(old);
    if (old.members != widget.members) {
      old.members.removeListener(_changed);
      widget.members.addListener(_changed);
    }
  }

  @override
  void dispose() {
    _m.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _openSettings(AccountSettingTab tab) {
    _popover.close();
    final open = widget.onOpenSettings;
    if (open != null) return open(tab);
    unawaited(showAccountSetting(context, members: _m, tab: tab));
  }

  @override
  Widget build(BuildContext context) {
    final name = _m.workspaceName;
    if (name == null) return const _WorkspaceCardSkeleton();
    final workspaces = widget.workspaces ?? [WorkspaceListItem(id: 'workspace', name: name, current: true)];
    final openMenu = stc(context, 'mainNav.workspace.openMenu');
    final card = Container(
      decoration: BoxDecoration(
        color: DifyColors.componentsCardBg,
        borderRadius: BorderRadius.circular(DifyRadius.xl),
        border: Border.all(color: DifyColors.componentsCardBorder),
        boxShadow: DifyShadows.xs,
      ),
      clipBehavior: Clip.antiAlias,
      child: Semantics(
        button: true,
        expanded: _open,
        label: '$name $openMenu',
        tooltip: name,
        onTap: _popover.toggle,
        excludeSemantics: true,
        child: FocusableActionDetector(
          mouseCursor: SystemMouseCursors.click,
          onShowHoverHighlight: (v) => setState(() => _hovered = v),
          actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => _popover.toggle())},
          child: GestureDetector(
            key: const ValueKey('workspace-card-trigger'),
            behavior: HitTestBehavior.opaque,
            onTap: _popover.toggle,
            child: Container(
              padding: const EdgeInsets.fromLTRB(6, 6, 12, 6),
              decoration: BoxDecoration(
                color: !_open && _hovered ? DifyColors.stateBaseHover : null,
                gradient: _open
                    ? LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [DifyColors.backgroundSectionBurn, DifyColors.backgroundSection],
                      )
                    : null,
              ),
              child: Row(
                spacing: 6,
                children: [
                  DifyWorkspaceAvatar(name: name),
                  Expanded(
                    child: Align(
                      heightFactor: 1,
                      alignment: AlignmentDirectional.centerStart,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 120),
                        child: Padding(
                          padding: const EdgeInsetsDirectional.only(end: 2),
                          child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: difyTextStyle(DifyType.systemSmMedium, DifyColors.textPrimary),
                          ),
                        ),
                      ),
                    ),
                  ),
                  RemixIcon('expand-up-down-line', size: 16, color: DifyColors.textTertiary),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    return DifyFloating(
      controller: _popover,
      placement: DifyPlacement.bottomStart,
      // Base UI anchors the popup on the trigger button, which lies inside the card's 1 px border.
      sideOffset: -36 - 1,
      alignOffset: -28,
      // Over the trigger, shifted back into the window (Base UI keeps it on its side: the start edge overflows,
      // and the shift moves it to the collision padding).
      collision: DifyCollision.dropdown,
      onOpenChange: (o) => setState(() => _open = o),
      builder: (context, _) => card,
      popupBuilder: (context) {
        final r = BorderRadius.circular(DifyRadius.xl);
        return Semantics(
          container: true,
          role: SemanticsRole.dialog,
          label: name,
          explicitChildNodes: true,
          child: DifyBlurredBox(
            blur: 5,
            borderRadius: r,
            decoration: DifyMenuPopup.decoration,
            child: ClipRRect(
              borderRadius: r,
              child: SizedBox(
                width: 280,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _WorkspaceMenuHeader(
                      name: name,
                      showInviteMembers: _m.canManage,
                      onOpenSettings: () => _openSettings(AccountSettingTab.members),
                      onInviteMembers: () => _openSettings(AccountSettingTab.members),
                    ),
                    WorkspaceSwitcher(
                      workspaces: workspaces,
                      onSwitchWorkspace: (id) {
                        // The current workspace closes the menu; dify-sf has no other to switch to.
                        _popover.close();
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// WorkspaceCardSkeleton (outside the cloud edition): the card with the avatar, name and icon bars.
class _WorkspaceCardSkeleton extends StatelessWidget {
  const _WorkspaceCardSkeleton();

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Container(
      key: const ValueKey('workspace-card-skeleton'),
      decoration: BoxDecoration(
        color: DifyColors.componentsCardBg,
        borderRadius: BorderRadius.circular(DifyRadius.xl),
        border: Border.all(color: DifyColors.componentsCardBorder),
        boxShadow: DifyShadows.xs,
      ),
      padding: const EdgeInsets.fromLTRB(6, 6, 12, 6),
      child: const Row(
        spacing: 6,
        children: [
          _SkeletonBar(width: 24, height: 24, radius: DifyRadius.lg),
          Expanded(
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: _SkeletonBar(width: 128, height: 16),
            ),
          ),
          _SkeletonBar(width: 16, height: 16),
        ],
      ),
    ),
  );
}

/// WorkspaceMenuHeader: `p-1`, a `rounded-xl border-[0.5px]` box on the section gradient (`pb-2`) with the name
/// (`text-base/5 font-medium`) and the `lg` avatar in an `h-16 px-3` row, then the menu buttons.
class _WorkspaceMenuHeader extends StatelessWidget {
  const _WorkspaceMenuHeader({
    required this.name,
    required this.showInviteMembers,
    required this.onOpenSettings,
    required this.onInviteMembers,
  });

  final String name;
  final bool showInviteMembers;
  final VoidCallback onOpenSettings, onInviteMembers;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(4),
    child: Container(
      padding: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(DifyRadius.xl),
        border: Border.all(color: DifyColors.componentsPanelBorder, width: 0.5),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [DifyColors.backgroundSectionBurn, DifyColors.backgroundSection],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 64,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              spacing: 8,
              children: [
                Expanded(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 16,
                      height: 20 / 16,
                      fontWeight: FontWeight.w500,
                      color: DifyColors.textPrimary,
                    ),
                  ),
                ),
                DifyWorkspaceAvatar(name: name, size: DifyWorkspaceAvatarSize.lg),
              ],
            ),
          ),
          WorkspaceMenuButton(
            key: const ValueKey('workspace-settings'),
            icon: DifyIcon('vender/main-nav/workspace-settings', size: 16, color: DifyColors.textTertiary),
            label: stc(context, 'mainNav.workspace.settings'),
            onTap: onOpenSettings,
          ),
          if (showInviteMembers)
            WorkspaceMenuButton(
              key: const ValueKey('workspace-invite-members'),
              icon: RemixIcon('user-add-line', size: 16, color: DifyColors.textTertiary),
              label: stc(context, 'mainNav.workspace.inviteMembers'),
              onTap: onInviteMembers,
            ),
        ],
      ),
    ),
  );
}

/// A workspace menu button (`flex h-8 w-full items-center gap-2 rounded-lg px-3 py-1`, hover
/// `bg-state-base-hover`) with WorkspaceMenuItemContent: the icon (`size-4 text-text-tertiary`), the label
/// (`system-md-regular text-text-secondary`, truncated) and an optional [trailing] part.
class WorkspaceMenuButton extends StatelessWidget {
  const WorkspaceMenuButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.trailing,
    this.current,
  });

  final Widget icon;
  final String label;
  final VoidCallback onTap;
  final Widget? trailing;

  /// `aria-current` (switcher items).
  final bool? current;

  @override
  Widget build(BuildContext context) => DifyPressable(
    semanticLabel: label,
    onPressed: onTap,
    builder: (context, hovered, focused) => Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: hovered ? DifyColors.stateBaseHover : null,
        borderRadius: BorderRadius.circular(DifyRadius.lg),
        border: focused ? Border.all(color: DifyColors.stateAccentSolid, width: 2) : null,
      ),
      child: Row(
        spacing: 8,
        children: [
          // `flex h-4 w-4 items-center justify-center`: a bigger icon (the `xs` avatar) overflows it, centred.
          SizedBox.square(
            dimension: 16,
            child: OverflowBox(maxWidth: 24, maxHeight: 24, child: icon),
          ),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: difyTextStyle(DifyType.systemMdRegular, DifyColors.textSecondary),
            ),
          ),
          if (trailing != null) SizedBox.square(dimension: 16, child: Center(child: trailing)),
        ],
      ),
    ),
  );
}

/// The switcher's sort orders.
enum WorkspaceSort { lastOpened, createdAt }

/// WorkspaceSwitcher (`p-1 pb-2`): the controls (the "WORKSPACE" label, the sort menu button and the search toggle,
/// whose panel holds the search input) over the list (`max-h-[240px]`, scrolling): each workspace with its `xs`
/// avatar and the check on the current one. Sorted by last opened (then created) or by created time; the search
/// filters by name ("No workspaces found" when nothing matches).
class WorkspaceSwitcher extends StatefulWidget {
  const WorkspaceSwitcher({super.key, required this.workspaces, required this.onSwitchWorkspace});

  final List<WorkspaceListItem> workspaces;
  final ValueChanged<String> onSwitchWorkspace;

  @override
  State<WorkspaceSwitcher> createState() => _WorkspaceSwitcherState();
}

class _WorkspaceSwitcherState extends State<WorkspaceSwitcher> {
  final _searchFocus = FocusNode(debugLabel: 'workspace search');
  String _search = '';
  bool _searchOpen = false;
  WorkspaceSort _sort = WorkspaceSort.lastOpened;

  @override
  void dispose() {
    _searchFocus.dispose();
    super.dispose();
  }

  List<WorkspaceListItem> get _displayed {
    final q = _search.trim().toLowerCase();
    final list = [
      for (final w in widget.workspaces)
        if (q.isEmpty || (w.name.isEmpty ? w.id : w.name).toLowerCase().contains(q)) w,
    ];
    if (_sort == WorkspaceSort.createdAt) {
      list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    } else {
      list.sort((a, b) {
        final byOpened = (b.lastOpenedAt ?? 0).compareTo(a.lastOpenedAt ?? 0);
        return byOpened != 0 ? byOpened : b.createdAt.compareTo(a.createdAt);
      });
    }
    return list;
  }

  void _toggleSearch() {
    setState(() => _searchOpen = !_searchOpen);
    if (_searchOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _searchFocus.requestFocus();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final label = stc(context, 'userProfile.workspace');
    final displayed = _displayed;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 8, 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 2,
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Text(
                      difyTransform(DifyType.systemXsMediumUppercase, label),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: difyTextStyle(DifyType.systemXsMediumUppercase, DifyColors.textTertiary),
                    ),
                  ),
                ),
                DifyDropdownMenu(
                  placement: DifyPlacement.bottomEnd,
                  sideOffset: 4,
                  width: 160,
                  builder: (context, controller) => DifyIconButton(
                    key: const ValueKey('workspace-sort'),
                    label: stc(context, 'mainNav.workspace.sort.openMenu'),
                    icon: const SizedBox.square(dimension: 20, child: Center(child: RemixIcon('sort-desc', size: 14))),
                    onPressed: controller.toggle,
                  ),
                  children: [
                    DifyMenuRadioGroup<WorkspaceSort>(
                      value: _sort,
                      onValueChange: (v) => setState(() => _sort = v),
                      children: [
                        for (final (v, k) in const [
                          (WorkspaceSort.lastOpened, 'mainNav.workspace.sort.lastOpened'),
                          (WorkspaceSort.createdAt, 'mainNav.workspace.sort.createdTime'),
                        ])
                          DifyMenuRadioItem<WorkspaceSort>(
                            value: v,
                            closeOnClick: true,
                            child: Text(
                              stc(context, k),
                              style: difyTextStyle(DifyType.systemMdRegular, DifyColors.textSecondary),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: _searchOpen ? DifyColors.stateBaseHover : null,
                    borderRadius: BorderRadius.circular(DifyRadius.md),
                  ),
                  child: DifyIconButton(
                    key: const ValueKey('workspace-search-toggle'),
                    label: stc(context, 'operation.search'),
                    icon: SizedBox.square(
                      dimension: 20,
                      child: Center(child: RemixIcon('search-line', size: 14, color: DifyColors.textSecondary)),
                    ),
                    onPressed: _toggleSearch,
                  ),
                ),
              ],
            ),
          ),
          if (_searchOpen)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: SelectorSearchInput(
                value: _search,
                placeholder: stc(context, 'mainNav.workspace.searchPlaceholder'),
                focusNode: _searchFocus,
                onChanged: (v) => setState(() => _search = v),
              ),
            ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 240),
            child: displayed.isEmpty
                ? Semantics(
                    liveRegion: true,
                    child: Container(
                      height: 32,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      alignment: AlignmentDirectional.centerStart,
                      child: Text(
                        stc(context, 'mainNav.workspace.noResults'),
                        style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textTertiary),
                      ),
                    ),
                  )
                : SingleChildScrollView(
                    child: Semantics(
                      container: true,
                      label: label,
                      explicitChildNodes: true,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final w in displayed)
                            Semantics(
                              selected: w.current,
                              child: WorkspaceMenuButton(
                                key: ValueKey('workspace-item-${w.id}'),
                                icon: DifyWorkspaceAvatar(
                                  name: w.name.isEmpty ? w.id : w.name,
                                  size: DifyWorkspaceAvatarSize.xs,
                                ),
                                label: w.name.isEmpty ? w.id : w.name,
                                current: w.current,
                                trailing: w.current
                                    ? RemixIcon('check-line', size: 16, color: DifyColors.textAccent)
                                    : null,
                                onTap: () => widget.onSwitchWorkspace(w.id),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
