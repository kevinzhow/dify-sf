/// apps/app-card (AppCard), apps/starred-app-card.tsx and app-card/interactions.tsx: a card opens the app; its
/// hover action bar has the star toggle and the More menu (also the card's context menu): Edit info, Duplicate,
/// Export DSL, Delete. dify-sf has no tags, no web-app access control and no Explore, so the tag strip, "Open in
/// Explore" and "Access config" are left out, and so is Switch (chat / completion apps only, which dify-sf cannot
/// hold).
library;

import 'dart:async';

import 'package:collab_client/collab_client.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../design/css_metrics.dart';
import '../design/dify_icon.dart';
import '../design/dify_tokens.g.dart';
import '../design/widgets/widgets.dart';
import '../i18n/dify_i18n.dart';
import '../workflow_editor/dsl/dsl_export_confirm_modal.dart' show showDslExportConfirm;
import '../workflow_editor/header/format.dart' show formatTime;
import 'app_icons.dart';
import 'app_modals.dart';
import 'export_app_dsl.dart';
import 'studio_scope.dart';

String _a(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('app', key, params);
String _c(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('common', key, params);

/// The card's mode label (`appModeLabel`): Dify's type names, else the mode itself.
String appModeLabel(String mode) => switch (mode) {
  AppModes.chat => _a('types.chatbot'),
  AppModes.advancedChat => _a('types.advanced'),
  AppModes.agentChat => _a('types.agent'),
  AppModes.completion => _a('types.completion'),
  AppModes.workflow => _a('types.workflow'),
  _ => mode,
};

/// `editTimeText`: "Edited at `MM/DD/YYYY HH:mm`" of `updated_at || created_at` (local time); "" without either.
String appEditTimeText(AppInfo app) {
  final ts = app.updatedAt != 0 ? app.updatedAt : app.createdAt;
  if (ts == 0) return '';
  final time = formatTime(ts, DifyI18n.tr('dataset-documents', 'segment.dateTimeFormat'));
  return '${DifyI18n.tr('dataset-documents', 'segment.editedAt')} $time';
}

/// base/icons vender/Star (18 x 18, `currentColor`).
const _starSvg =
    '<svg width="18" height="18" viewBox="0 0 18 18" fill="none" xmlns="http://www.w3.org/2000/svg"><path d="M9.00009 '
    '12.75L4.59172 15.4426L5.7903 10.4179L1.86719 7.05737L7.01634 6.64456L9.00009 1.875L10.9839 6.64456L16.133 7.05737L'
    '12.2099 10.4179L13.4085 15.4426L9.00009 12.75ZM9.00009 10.9923L11.1126 12.2827L10.5383 9.8748L12.4183 8.2644L9.95072'
    ' 8.06655L9.00009 5.78094L8.04947 8.06655L5.58195 8.2644L7.46194 9.8748L6.88758 12.2827L9.00009 10.9923Z" '
    'fill="currentColor"/></svg>';

/// The app icon with its mode badge at the bottom right (`absolute -right-0.5 -bottom-0.5 h-4 w-4 shadow-sm`).
class _IconWithBadge extends StatelessWidget {
  const _IconWithBadge({required this.app});
  final AppInfo app;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 40,
    height: 40,
    child: Stack(
      clipBehavior: Clip.none,
      children: [
        DifyAppIcon(
          size: DifyAppIconSize.large,
          iconType: app.iconType,
          icon: app.icon,
          background: app.iconBackground,
          imageUrl: app.iconUrl,
        ),
        Positioned(
          right: -2,
          bottom: -2,
          child: AppTypeIcon(type: app.mode, box: 16, iconSize: 12, shadow: true),
        ),
      ],
    ),
  );
}

/// AppCard (`h-41.5`) or, with [starred], StarredAppCard (`h-18`).
class AppCard extends StatefulWidget {
  const AppCard({super.key, required this.app, this.starred = false});

  final AppInfo app;
  final bool starred;

  @override
  State<AppCard> createState() => _AppCardState();
}

class _AppCardState extends State<AppCard> {
  bool _hovered = false, _focusWithin = false, _menuOpen = false, _togglingStar = false;
  final _menu = DifyFloatingController();
  late StudioServices _services;

  /// `useExportAppDsl` / `useExportWorkflowAppDsl` over the page's services.
  late final _exporter = AppDslExporter(
    exportDsl: (id, {includeSecret = false}) => _services.api.exportDsl(id, includeSecret: includeSecret),
    environmentVariables: (id) => _services.environmentVariables(id),
    saveDsl: (name, yaml) => _services.saveDsl(name, yaml),
  )..addListener(_exportChanged);

  AppInfo get app => widget.app;
  bool get _exporting => _exporter.isExporting;

  void _exportChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _exporter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final services = _services = StudioScope.of(context);
    final previewOnly = hasOnlyAppPreviewPermission(app.permissionKeys);
    final acl = appACLCapabilities(app.permissionKeys);
    final ops = _Operations(
      edit: acl.canEdit,
      duplicate: services.canCreateApp,
      export: acl.canImportExportDSL,
      delete: acl.canDelete,
    );
    final popup = _menuOpen || _exporting;
    final lifted = !previewOnly && (_hovered || popup);
    final content = widget.starred ? _starredContent() : _cardContent();
    Widget link = Semantics(
      hint: app.description.isEmpty ? null : app.description,
      child: DifyPressable(
        key: ValueKey('app-card-link-${app.id}'),
        semanticLabel: app.name,
        onPressed: previewOnly
            ? () => toast.warning(_a('noAccessResourcePermission'))
            : () => unawaited(services.open(app)),
        builder: (context, hovered, focused) => Container(
          decoration: focused
              ? BoxDecoration(
                  borderRadius: BorderRadius.circular(DifyRadius.xl),
                  border: Border.all(color: DifyColors.stateAccentSolid, width: 2),
                )
              : null,
          // `overflow-hidden`: the card's content is laid out at its own height and clipped to the card.
          child: Opacity(
            opacity: previewOnly ? 0.6 : 1,
            child: ClipRect(
              child: OverflowBox(
                alignment: Alignment.topCenter,
                minHeight: 0,
                maxHeight: double.infinity,
                child: content,
              ),
            ),
          ),
        ),
      ),
    );
    link = MergeSemantics(child: link);
    if (!previewOnly && ops.any) {
      link = DifyContextMenu(
        key: ValueKey('app-card-context-${app.id}'),
        width: 216,
        children: _menuItems(context, services, ops),
        child: link,
      );
    }
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onFocusChange: (v) => setState(() => _focusWithin = v),
        child: Container(
          key: ValueKey('app-card-${app.id}'),
          height: widget.starred ? 72 : 166,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: lifted || _focusWithin ? DifyColors.componentsCardBgAlt : DifyColors.componentsCardBg,
            borderRadius: BorderRadius.circular(DifyRadius.xl),
            border: Border.all(color: DifyColors.componentsCardBorder, width: Css.hairline),
            boxShadow: lifted ? DifyShadows.md : DifyShadows.xs,
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              link,
              if (!previewOnly) _actionBar(context, services, ops, visible: _hovered || _focusWithin || popup),
            ],
          ),
        ),
      ),
    );
  }

  Widget _cardContent() {
    final edit = appEditTimeText(app);
    final meta = difyTextStyle(DifyType.systemXsRegular, DifyColors.textTertiary);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            spacing: 12,
            children: [
              _IconWithBadge(app: app),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 1),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 4,
                    children: [
                      DifyTextLine(
                        app.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        // `text-sm/5 font-semibold text-text-secondary`
                        style: difyTextStyle(DifyType.systemMdSemibold, DifyColors.textSecondary),
                      ),
                      DifyTextLine(
                        difyTransform(DifyType.system2xsMediumUppercase, appModeLabel(app.mode)),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: difyTextStyle(DifyType.system2xsMediumUppercase, DifyColors.textTertiary),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 32),
            child: DifyTextLine(app.description, maxLines: 2, overflow: TextOverflow.ellipsis, style: meta),
          ),
        ),
        const SizedBox(height: 26),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: _metaLine(edit, meta),
        ),
      ],
    );
  }

  /// `<author> · <edit time>` (the card always shows the dot after an author; the starred card only between both).
  Widget _metaLine(String edit, TextStyle style) {
    final author = app.authorName ?? '';
    final dot = author.isNotEmpty && (edit.isNotEmpty || !widget.starred);
    return DifyTextLine(
      [if (author.isNotEmpty) author, if (dot) '·', if (edit.isNotEmpty) edit].join(' '),
      key: ValueKey('app-card-meta-${app.id}'),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: style,
    );
  }

  Widget _starredContent() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    child: Row(
      spacing: 12,
      children: [
        _IconWithBadge(app: app),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 1),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 2,
              children: [
                DifyTextLine(
                  app.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: difyTextStyle(DifyType.systemMdSemibold, DifyColors.textSecondary),
                ),
                _metaLine(appEditTimeText(app), difyTextStyle(DifyType.systemXsRegular, DifyColors.textTertiary)),
              ],
            ),
          ),
        ),
      ],
    ),
  );

  // ----- the action bar -----

  Widget _actionBar(BuildContext context, StudioServices services, _Operations ops, {required bool visible}) {
    final starLabel = _a('studio.starApp');
    return Positioned(
      top: -0.5,
      right: -0.5,
      width: 120,
      height: 64,
      child: IgnorePointer(
        ignoring: !visible,
        child: Opacity(
          opacity: visible ? 1 : 0,
          // `opacity-0` keeps the actions in the accessibility tree.
          alwaysIncludeSemantics: true,
          child: Container(
            padding: const EdgeInsets.all(8),
            alignment: Alignment.topRight,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: const Alignment(-0.92, 0.39),
                end: const Alignment(0.92, -0.39),
                colors: [DifyColors.componentsCardBgAltTransparent, DifyColors.componentsCardBgAlt],
                stops: const [0, 0.75],
              ),
            ),
            child: DifyBlurredBox(
              blur: 4,
              borderRadius: BorderRadius.circular(10),
              decoration: BoxDecoration(
                color: DifyColors.componentsActionbarBg,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: DifyColors.componentsActionbarBorder, width: Css.hairline),
                boxShadow: DifyShadows.lg,
              ),
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DifyTooltip(
                      content: DifyTextLine(starLabel),
                      child: MergeSemantics(
                        child: Semantics(
                          toggled: app.isStarred,
                          child: Opacity(
                            opacity: _togglingStar ? 0.7 : 1,
                            child: DifyIconButton(
                              key: ValueKey('app-card-star-${app.id}'),
                              label: '$starLabel: ${app.name}',
                              size: DifyIconButtonSize.lg,
                              disabled: _togglingStar,
                              icon: SvgPicture.string(
                                _starSvg,
                                width: 18,
                                height: 18,
                                colorFilter: ColorFilter.mode(
                                  app.isStarred ? DifyColors.textWarningSecondary : DifyColors.textTertiary,
                                  BlendMode.srcIn,
                                ),
                              ),
                              onPressed: () => unawaited(_toggleStar(services, !app.isStarred)),
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (ops.any)
                      DifyDropdownMenu(
                        key: ValueKey('app-card-menu-${app.id}'),
                        controller: _menu,
                        open: _menuOpen,
                        onOpenChange: (v) => setState(() => _menuOpen = v),
                        placement: DifyPlacement.bottomEnd,
                        width: 216,
                        builder: (context, controller) => DifyIconButton(
                          key: ValueKey('app-card-more-${app.id}'),
                          label: _exporting
                              ? _c('operation.exporting')
                              : _c('operation.moreActionsFor', {'name': app.name}),
                          size: DifyIconButtonSize.lg,
                          disabled: _exporting,
                          restyle: _menuOpen ? (look, _) => look.copyWith(background: DifyColors.stateBaseHover) : null,
                          icon: _exporting
                              ? DifySpinner(color: DifyColors.textTertiary, size: 18)
                              : RemixIcon('more-fill', size: 18, color: DifyColors.textTertiary),
                          onPressed: controller.toggle,
                        ),
                        children: _menuItems(context, services, ops),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _menuItems(BuildContext context, StudioServices services, _Operations ops) {
    Widget item(String key, String label, VoidCallback onSelect, {bool destructive = false, bool disabled = false}) =>
        DifyMenuItem(
          key: ValueKey('app-card-$key-${app.id}'),
          paddingX: 12,
          disabled: disabled,
          variant: destructive ? DifyMenuItemVariant.destructive : DifyMenuItemVariant.normal,
          onSelect: onSelect,
          child: DifyTextLine(
            label,
            style: destructive
                ? difyTextStyle(DifyType.systemSmRegular, DifyColors.textDestructive)
                : difyTextStyle(DifyType.systemSmRegular, DifyColors.textSecondary),
          ),
        );
    final createExport = ops.duplicate || ops.export;
    return [
      if (ops.edit) item('edit', _a('editApp'), () => _afterMenu(() => _edit(services))),
      if (ops.edit && (createExport || ops.delete)) const DifyMenuSeparator(),
      if (ops.duplicate) item('duplicate', _a('duplicate'), () => _afterMenu(() => _duplicate(services))),
      if (ops.export) item('export', _a('export'), () => unawaited(_export()), disabled: _exporting),
      if (createExport && ops.delete) const DifyMenuSeparator(),
      if (ops.delete)
        item('delete', _c('operation.delete'), () => _afterMenu(() => _delete(services)), destructive: true),
    ];
  }

  /// `setIsOperationsMenuOpen(false); queueMicrotask(() => setActiveDialog(...))`.
  void _afterMenu(Future<void> Function() open) {
    if (mounted) setState(() => _menuOpen = false);
    scheduleMicrotask(() {
      if (mounted) unawaited(open());
    });
  }

  Future<void> _toggleStar(StudioServices services, bool pressed) async {
    if (_togglingStar) return;
    setState(() => _togglingStar = true);
    try {
      if (pressed) {
        await services.api.star(app.id);
      } else {
        await services.api.unstar(app.id);
      }
      await services.refresh();
    } on TransportException catch (e) {
      toast.error(e.message.isNotEmpty ? e.message : _a('studio.starFailed'));
    } on Object {
      toast.error(_a('studio.starFailed'));
    } finally {
      if (mounted) setState(() => _togglingStar = false);
    }
  }

  Future<void> _edit(StudioServices services) => showEditAppModal(
    context,
    (hide) => EditAppModal(
      isEditModal: true,
      appName: app.name,
      appIconType: app.iconType,
      appIcon: app.icon ?? '',
      appIconBackground: app.iconBackground,
      appIconUrl: app.iconUrl,
      appDescription: app.description,
      appMode: app.mode,
      appUseIconAsAnswerIcon: app.useIconAsAnswerIcon,
      maxActiveRequests: app.maxActiveRequests,
      uploadIcon: services.uploadIcon,
      onHide: hide,
      onConfirm: (p) async {
        try {
          await services.api.update(
            app.id,
            name: p.name,
            iconType: p.iconType,
            icon: p.icon,
            iconBackground: p.iconBackground,
            description: p.description,
            useIconAsAnswerIcon: p.useIconAsAnswerIcon,
            maxActiveRequests: p.maxActiveRequests,
          );
          toast.success(_a('editDone'));
          await services.refresh();
        } on TransportException catch (e) {
          toast.error(e.message.isNotEmpty ? e.message : _a('editFailed'));
        } on Object {
          toast.error(_a('editFailed'));
        }
      },
    ),
  );

  Future<void> _duplicate(StudioServices services) => showDifyDialog<void>(
    context,
    builder: (dialog) => DuplicateAppModal(
      appName: app.name,
      iconType: app.iconType,
      icon: app.icon ?? '',
      iconBackground: app.iconBackground,
      iconUrl: app.iconUrl,
      uploadIcon: services.uploadIcon,
      onHide: () => Navigator.pop(dialog),
      onConfirm: (p) async {
        final AppInfo copy;
        try {
          copy = await services.api.copy(
            app.id,
            name: p.name,
            iconType: p.iconType,
            icon: p.icon,
            iconBackground: p.iconBackground,
          );
        } on Object {
          toast.error(_a('newApp.appCreateFailed'));
          return;
        }
        toast.success(_a('newApp.appCreated'));
        unawaited(services.refresh());
        await services.open(copy);
      },
    ),
  );

  Future<void> _delete(StudioServices services) => showDifyDialog<void>(
    context,
    dismissible: false,
    builder: (dialog) => DeleteAppDialog(
      appName: app.name,
      onClose: () => Navigator.pop(dialog),
      onConfirm: () async {
        try {
          await services.api.delete(app.id);
        } on TransportException catch (e) {
          toast.error('${_a('appDeleteFailed')}${e.message.isNotEmpty ? ': ${e.message}' : ''}');
          return false;
        } on Object {
          toast.error(_a('appDeleteFailed'));
          return false;
        }
        toast.success(_a('appDeleted'));
        unawaited(services.refresh());
        return true;
      },
    ),
  );

  /// `exportCheck`: a workflow / chatflow asks first when its environment holds secrets.
  Future<void> _export() async {
    if (_exporting) return;
    setState(() => _menuOpen = false);
    final result = app.mode == AppModes.workflow || app.mode == AppModes.advancedChat
        ? await _exporter.exportWorkflowAppDsl(appId: app.id, appName: app.name)
        : await _exporter.exportAppDsl(appId: app.id, appName: app.name);
    if (result.status != 'confirmation-required' || !mounted) return;
    await showDslExportConfirm(
      context,
      envList: result.secretEnvList,
      onConfirm: (include) async {
        await _exporter.exportAppDsl(appId: app.id, appName: app.name, includeSecret: include);
      },
    );
  }
}

class _Operations {
  const _Operations({
    required this.edit,
    required this.duplicate,
    required this.export,
    required this.delete,
  });

  final bool edit, duplicate, export, delete;

  /// `shouldShowOperationsMenu`.
  bool get any => edit || duplicate || export || delete;
}

/// The app card grid (`grid-cols-[repeat(auto-fill,minmax(min(100%,288px),1fr))] gap-2.5`): as many 288+ px columns
/// as fit.
int appGridColumns(double width, {double gap = 10, double min = 288}) =>
    width <= min ? 1 : ((width + gap) / (min + gap)).floor().clamp(1, 1 << 20);

/// AppCardSkeleton (apps/app-card-skeleton.tsx): the `h-40 overflow-hidden rounded-xl border-[0.5px] p-4 shadow-xs`
/// card with a SkeletonContainer: the icon (`size-10 rounded-lg`), title (`h-4 w-2/3`) and subtitle (`h-3 w-1/3`)
/// beside it, then (`mt-4 gap-2`) two description lines (`h-3`, full and `w-4/5`), all pulsing.
class AppCardSkeleton extends StatelessWidget {
  const AppCardSkeleton({super.key});

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Container(
      height: 160,
      padding: const EdgeInsets.all(16),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: DifyColors.componentsCardBg,
        borderRadius: BorderRadius.circular(DifyRadius.xl),
        border: Border.all(color: DifyColors.componentsCardBorder, width: Css.hairline),
        boxShadow: DifyShadows.xs,
      ),
      child: const DifySkeletonContainer(
        children: [
          DifySkeletonRow(
            children: [
              DifySkeletonRectangle(width: 40, height: 40, radius: DifyRadius.lg, pulse: true),
              Expanded(
                child: DifySkeletonContainer(
                  children: [
                    DifySkeletonRectangle(widthFactor: 2 / 3, height: 16, pulse: true),
                    DifySkeletonRectangle(widthFactor: 1 / 3, height: 12, pulse: true),
                  ],
                ),
              ),
            ],
          ),
          Padding(
            padding: EdgeInsets.only(top: 16),
            child: DifySkeletonContainer(
              gap: 8,
              children: [
                DifySkeletonRectangle(height: 12, pulse: true),
                DifySkeletonRectangle(widthFactor: 0.8, height: 12, pulse: true),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

/// A row of semantics-only text (Dify's `sr-only` status).
class SrOnlyStatus extends StatelessWidget {
  const SrOnlyStatus(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    role: SemanticsRole.status,
    label: text,
    child: const SizedBox.shrink(),
  );
}
