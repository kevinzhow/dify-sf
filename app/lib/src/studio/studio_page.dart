/// apps/index.tsx + list.tsx + app-list-header.tsx + app-list-catalog.tsx: the Studio page. The sticky header (title,
/// filters, Create), the starred row, the "All Apps" grid with infinite scroll, the empty states, the drop hint and
/// the page-wide DSL drop zone. Every mutation refetches the list (react-query's invalidation).
library;

import 'dart:async';

import 'package:collab_client/collab_client.dart';

import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';

import '../design/css_metrics.dart';
import '../design/dify_icon.dart';
import '../design/dify_tokens.g.dart';
import '../design/widgets/app_icon_picker.dart' show UploadAppIcon;
import '../design/widgets/widgets.dart';
import '../i18n/dify_i18n.dart';
import '../settings/workspace_members.dart';
import 'app_card.dart';
import 'app_list_controller.dart';
import 'create_app_modal.dart';
import 'create_from_dsl_modal.dart' as dsl;
import 'create_from_dsl_modal.dart' hide fetchDslUrl;
import 'dsl_drop.dart';
import 'filters.dart';
import 'infinite_scroll_sentinel.dart';
import 'studio_scope.dart';

String _a(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('app', key, params);
String _c(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('common', key, params);

class StudioPage extends StatefulWidget {
  const StudioPage({
    super.key,
    required this.api,
    required this.openApp,
    required this.environmentVariables,
    this.members,
    this.role,
    this.currentUserId,
    this.pollInterval = const Duration(seconds: 10),
    this.debounce = appListSearchDebounce,
    this.saveDsl = saveDslFile,
    this.pickDslFile = pickDslFileData,
    this.fetchDslUrl = dsl.fetchDslUrl,
    this.uploadIcon,
  });

  final AppsApi api;
  final OpenStudioApp openApp;
  final Future<List<Map<String, Object?>>> Function(String appId) environmentVariables;

  /// The workspace's members (the Creators filter); its role wins over [role].
  final WorkspaceMembers? members;
  final String? role;
  final String? currentUserId;

  /// Dify's 10 s refetch with collaboration on; null: none.
  final Duration? pollInterval;
  final Duration debounce;
  final SaveDslFile saveDsl;
  final Future<DslFileData?> Function() pickDslFile;
  final Future<String> Function(String url) fetchDslUrl;
  final UploadAppIcon? uploadIcon;

  @override
  State<StudioPage> createState() => StudioPageState();
}

class StudioPageState extends State<StudioPage> {
  late final list = StudioAppList(widget.api, pollInterval: widget.pollInterval, debounce: widget.debounce)
    ..addListener(_changed);
  late final drop = DslDragDrop(onDslFileDropped: (f) => unawaited(_droppedFile(f)), enabled: _canCreate);
  final _scroll = ScrollController();
  int _dialogs = 0;

  String? get _role => widget.members?.myRole ?? widget.role;
  bool get _canCreate => AppPermissionKeys.canCreate(_role);

  @override
  void initState() {
    super.initState();
    widget.members?.addListener(_changed);
    final m = widget.members;
    if (m != null && !m.loaded && !m.loading) unawaited(m.refresh());
    unawaited(list.start());
  }

  @override
  void didUpdateWidget(StudioPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.members != widget.members) {
      oldWidget.members?.removeListener(_changed);
      widget.members?.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.members?.removeListener(_changed);
    list
      ..removeListener(_changed)
      ..dispose();
    drop.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    drop.enabled = _canCreate && _dialogs == 0;
    setState(() {});
  }

  void _resetScroll() {
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  Future<T?> _dialog<T>(Future<T?> Function() show) async {
    _dialogs++;
    drop.enabled = false;
    try {
      return await show();
    } finally {
      _dialogs--;
      if (mounted) drop.enabled = _canCreate && _dialogs == 0;
    }
  }

  StudioServices get _services => StudioServices(
    api: widget.api,
    canCreateApp: _canCreate,
    currentUserId: widget.currentUserId,
    openApp: (app, {required path}) => widget.openApp(app, path: path).whenComplete(() {
      if (mounted) unawaited(list.refresh());
    }),
    refresh: list.refresh,
    environmentVariables: widget.environmentVariables,
    saveDsl: widget.saveDsl,
    uploadIcon: widget.uploadIcon,
  );

  /// Create from Blank; the new app opens once the dialog is closed (`getRedirection`).
  Future<void> openCreateBlank() async {
    if (!_canCreate) return;
    AppInfo? created;
    await _dialog(
      () => showCreateAppDialogShell<void>(
        context,
        title: _a('newApp.startFromBlank'),
        builder: (dialog) => CreateAppModal(
          defaultAppMode: list.category,
          canCreateApp: _canCreate,
          uploadIcon: widget.uploadIcon,
          onClose: () => Navigator.pop(dialog),
          onCreate: (r) async {
            created = await widget.api.create(
              name: r.name,
              description: r.description,
              mode: r.mode,
              iconType: r.iconType,
              icon: r.icon,
              iconBackground: r.iconBackground,
            );
          },
        ),
      ),
    );
    if (created case final app?) {
      unawaited(list.refresh());
      await _services.open(app);
    }
  }

  /// Import DSL (the Create menu, the first empty state, a dropped file).
  Future<void> openImportDsl({DslFileData? droppedFile}) async {
    if (!_canCreate) return;
    AppImport? imported;
    await _dialog(
      () => showCreateFromDSLModal(
        context,
        (close) => CreateFromDSLModal(
          droppedFile: droppedFile,
          pickFile: widget.pickDslFile,
          fetchUrl: widget.fetchDslUrl,
          importDsl: widget.api.importDsl,
          confirmImport: widget.api.confirmImport,
          onSuccess: () => unawaited(list.refresh()),
          onClose: close,
          onImported: (r) async => imported = r,
        ),
      ),
    );
    if (imported?.appId case final id?) {
      try {
        await _services.open(await widget.api.get(id));
      } on Object catch (e) {
        toast.error('$e');
      }
    }
  }

  Future<void> _droppedFile(DroppedDslFile f) async {
    if (!_canCreate) return;
    final DslFileData data;
    try {
      data = (name: f.name, size: await f.length(), read: f.read);
    } on Object catch (e) {
      toast.error('$e');
      return;
    }
    if (mounted) await openImportDsl(droppedFile: data);
  }

  @override
  Widget build(BuildContext context) {
    final members = widget.members;
    return StudioScope(
      services: _services,
      child: DslDropZone(
        drop: drop,
        child: DifySurface(
          child: ColoredBox(
            color: DifyColors.backgroundBody,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _header(members),
                    Expanded(child: _catalog()),
                  ],
                ),
                if (drop.dragging)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: Container(
                        key: const ValueKey('studio-drop-overlay'),
                        margin: const EdgeInsets.all(2),
                        decoration: BoxDecoration(
                          color: DifyAppListColors.dropOverlay,
                          borderRadius: BorderRadius.circular(DifyRadius.xxl),
                        ),
                        foregroundDecoration: CssDashedBorder(
                          color: DifyColors.componentsDropzoneBorderAccent,
                          width: 2,
                          radius: DifyRadius.xxl,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// StudioListHeader: `sticky top-0 flex flex-col gap-3.5 bg-background-body px-8 pt-4 pb-2`.
  Widget _header(WorkspaceMembers? members) => Container(
    color: DifyColors.backgroundBody,
    padding: const EdgeInsets.fromLTRB(32, 16, 32, 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 14,
      children: [
        SizedBox(
          height: 24,
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: Semantics(
              header: true,
              child: Text(
                _c('menus.apps'),
                // `text-[18px]/[21.6px] font-semibold` (= title-2xl-semi-bold)
                style: difyTextStyle(DifyType.title2xlSemiBold, DifyColors.textPrimary),
              ),
            ),
          ),
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 8,
          children: [
            Expanded(
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  AppTypeFilter(
                    value: list.category,
                    onChange: (v) {
                      _resetScroll();
                      list.setCategory(v);
                    },
                  ),
                  CreatorsFilter(
                    value: list.creatorIds,
                    members: members?.members ?? const [],
                    currentUserId: members?.meAsMember?.id ?? widget.currentUserId,
                    onChange: (v) {
                      _resetScroll();
                      list.setCreatorIds(v);
                    },
                  ),
                  AppSortFilter(
                    value: list.sortBy,
                    onChange: (v) {
                      _resetScroll();
                      list.setSortBy(v);
                    },
                  ),
                  StudioSearchInput(
                    value: list.keywords,
                    semanticLabel: _a('gotoAnything.actions.searchApplications'),
                    onChange: (v) {
                      _resetScroll();
                      list.setKeywords(v);
                    },
                  ),
                ],
              ),
            ),
            if (_canCreate)
              CreateAppDropdown(
                onCreateBlank: () => unawaited(openCreateBlank()),
                onImportDSL: () => unawaited(openImportDsl()),
              ),
          ],
        ),
      ],
    ),
  );

  Widget _catalog() {
    if (list.error != null && list.pages.isEmpty) return _errorState();
    if (list.loadingFirstPage) {
      return Semantics(
        key: const ValueKey('studio-catalog-loading'),
        label: _c('loading'),
        role: SemanticsRole.status,
        container: true,
        child: SingleChildScrollView(
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(32, 8, 32, 0),
          child: _grid([for (var i = 0; i < 6; i++) const AppCardSkeleton()], extent: 160),
        ),
      );
    }
    final hasAnyApp = list.hasAnyApp;
    final placeholder = list.isPlaceholderData;
    final emptyStatus = !placeholder && list.pages.isNotEmpty && !hasAnyApp ? _a('filterEmpty.noApps') : '';
    final showFirstEmpty = !placeholder && !hasAnyApp && _canCreate && !list.hasActiveFilters;
    final starred = list.starredApps;
    final dropHint = _canCreate && !showFirstEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SrOnlyStatus(emptyStatus),
        Expanded(
          child: showFirstEmpty
              ? FirstEmptyState(
                  onCreateBlank: () => unawaited(openCreateBlank()),
                  onImportDSL: () => unawaited(openImportDsl()),
                )
              : CustomScrollView(
                  key: const ValueKey('studio-catalog'),
                  controller: _scroll,
                  slivers: [
                    if (starred.isNotEmpty) ...[
                      SliverToBoxAdapter(child: _sectionHeading(_a('studio.starred'))),
                      _sliverGrid([
                        for (final a in starred) AppCard(key: ValueKey('starred-${a.id}'), app: a, starred: true),
                      ], 72),
                      SliverToBoxAdapter(child: _sectionHeading(_a('studio.allApps'))),
                    ],
                    if (hasAnyApp) ...[
                      _sliverGrid([
                        for (final a in list.apps) AppCard(key: ValueKey('card-${a.id}'), app: a),
                        if (list.hasNextPage) ...[for (var i = 0; i < 3; i++) const AppCardSkeleton()],
                      ], 166),
                      if (list.hasNextPage && list.isFetchNextPageError) SliverToBoxAdapter(child: _nextPageError()),
                      if (list.hasNextPage)
                        SliverToBoxAdapter(
                          child: InfiniteScrollSentinel(
                            canLoadMore: !list.isFetching && !list.isFetchNextPageError,
                            onLoadMore: () => unawaited(list.fetchNextPage()),
                            // app-list-catalog.tsx `getPreloadDistance`.
                            preloadDistance: (p) => (p.viewportDimension * 0.25).clamp(160, 320).toDouble(),
                          ),
                        ),
                    ] else
                      SliverFillRemaining(
                        hasScrollBody: false,
                        child: SizedBox(
                          height: 480,
                          child: StudioEmpty(message: _a('filterEmpty.noApps')),
                        ),
                      ),
                    if (dropHint) SliverToBoxAdapter(child: _dropHint()),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _grid(List<Widget> children, {required double extent}) => LayoutBuilder(
    builder: (context, c) {
      final cols = appGridColumns(c.maxWidth);
      final w = (c.maxWidth - 10 * (cols - 1)) / cols;
      return Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [for (final child in children) SizedBox(width: w, height: extent, child: child)],
      );
    },
  );

  /// The card grid (`APP_LIST_GRID_CLASS_NAME`: `gap-2.5 px-8 pt-2`).
  Widget _sliverGrid(List<Widget> children, double extent) => SliverPadding(
    padding: const EdgeInsets.fromLTRB(32, 8, 32, 0),
    sliver: SliverLayoutBuilder(
      builder: (context, c) => SliverGrid(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: appGridColumns(c.crossAxisExtent),
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          mainAxisExtent: extent,
        ),
        delegate: SliverChildListDelegate(children),
      ),
    ),
  );

  /// AppListSectionHeading: `flex h-7 flex-col px-8 pt-3`, `system-xs-medium-uppercase text-text-tertiary`.
  Widget _sectionHeading(String label) => Padding(
    padding: const EdgeInsets.fromLTRB(32, 12, 32, 0),
    child: SizedBox(
      height: 16,
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: Semantics(
          header: true,
          child: Text(
            difyTransform(DifyType.systemXsMediumUppercase, label),
            style: difyTextStyle(DifyType.systemXsMediumUppercase, DifyColors.textTertiary),
          ),
        ),
      ),
    ),
  );

  /// A failed next page: "error + Retry".
  Widget _nextPageError() => Semantics(
    container: true,
    liveRegion: true,
    child: SizedBox(
      key: const ValueKey('studio-next-page-error'),
      height: 160,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        spacing: 8,
        children: [
          Text(_c('errorBoundary.title'), style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textTertiary)),
          DifyButton(
            key: const ValueKey('studio-next-page-retry'),
            size: DifyButtonSize.small,
            variant: DifyButtonVariant.secondary,
            loading: list.isFetchingNextPage,
            semanticLabel: _c('operation.retry'),
            onPressed: () => unawaited(list.fetchNextPage()),
            child: Text(_c('operation.retry')),
          ),
        ],
      ),
    ),
  );

  Widget _errorState() => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      spacing: 8,
      children: [
        Text(_c('errorBoundary.title'), style: difyTextStyle(DifyType.systemSmRegular, DifyColors.textTertiary)),
        Text('${list.error}', style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textQuaternary)),
        DifyButton(
          key: const ValueKey('studio-retry'),
          size: DifyButtonSize.small,
          semanticLabel: _c('operation.retry'),
          onPressed: () => unawaited(list.refresh()),
          child: Text(_c('operation.retry')),
        ),
      ],
    ),
  );

  /// The drop hint (`flex items-center justify-center gap-2 py-4`, accent while dragging).
  Widget _dropHint() {
    final color = drop.dragging ? DifyColors.textAccent : DifyColors.textQuaternary;
    return Padding(
      key: const ValueKey('studio-drop-hint'),
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        spacing: 8,
        children: [
          RemixIcon('drag-drop-line', size: 16, color: color),
          Text(_a('newApp.dropDSLToCreateApp'), style: difyTextStyle(DifyType.systemXsRegular, color)),
        ],
      ),
    );
  }
}

/// The 4 x 4 placeholder cards under a fading gradient (base/filter-empty-state, first-empty-state's backdrop).
class _PlaceholderCards extends StatelessWidget {
  const _PlaceholderCards();
  static const gap = 12.0;

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      LayoutBuilder(
        builder: (context, c) {
          final cols = (c.maxWidth / 300).floor().clamp(1, 4);
          final w = (c.maxWidth - gap * (cols - 1)) / cols, h = (c.maxHeight - gap * 3) / 4;
          return Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
              for (var i = 0; i < cols * 4; i++)
                Container(
                  width: w,
                  height: h.clamp(0, double.infinity),
                  decoration: BoxDecoration(
                    color: DifyColors.backgroundDefaultLighter.withValues(
                      alpha: DifyColors.backgroundDefaultLighter.a * 0.75,
                    ),
                    borderRadius: BorderRadius.circular(DifyRadius.xl),
                  ),
                ),
            ],
          );
        },
      ),
      DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [DifyColors.backgroundBody.withValues(alpha: 0), DifyColors.backgroundBody],
          ),
        ),
      ),
    ],
  );
}

/// The robot tile of the empty states (`size-14`, a dashed `rounded-xl` card with `i-ri-robot-2-line`).
Widget _robotTile() => SizedBox(
  width: 56,
  height: 56,
  child: Container(
    padding: const EdgeInsets.all(4),
    alignment: Alignment.center,
    decoration: BoxDecoration(color: DifyColors.componentsCardBg, borderRadius: BorderRadius.circular(DifyRadius.xl)),
    foregroundDecoration: CssDashedBorder(color: DifyColors.dividerRegular, radius: DifyRadius.xl),
    child: RemixIcon('robot-2-line', size: 24, color: DifyColors.textTertiary),
  ),
);

/// apps/empty.tsx (base/filter-empty-state): "No apps here" over the placeholder cards.
class StudioEmpty extends StatelessWidget {
  const StudioEmpty({super.key, required this.message});
  final String message;

  @override
  Widget build(BuildContext context) => Stack(
    key: const ValueKey('studio-empty'),
    fit: StackFit.expand,
    children: [
      const IgnorePointer(
        child: Padding(padding: EdgeInsets.fromLTRB(32, 8, 32, 0), child: _PlaceholderCards()),
      ),
      Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 12,
          children: [
            _robotTile(),
            Text(message, style: difyTextStyle(DifyType.systemSmRegular, DifyColors.textTertiary)),
          ],
        ),
      ),
    ],
  );
}

/// first-empty-state: "Build your first App" with the Create from Blank card, "or", and the Import DSL card (dify-sf
/// has no templates and no Learn Dify).
class FirstEmptyState extends StatelessWidget {
  const FirstEmptyState({super.key, required this.onCreateBlank, required this.onImportDSL});

  final VoidCallback onCreateBlank, onImportDSL;

  @override
  Widget build(BuildContext context) => Stack(
    key: const ValueKey('studio-first-empty'),
    fit: StackFit.expand,
    children: [
      const IgnorePointer(
        child: Padding(padding: EdgeInsets.symmetric(horizontal: 32, vertical: 8), child: _PlaceholderCards()),
      ),
      Center(
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              spacing: 24,
              children: [
                Column(
                  mainAxisSize: MainAxisSize.min,
                  spacing: 12,
                  children: [
                    _robotTile(),
                    Semantics(
                      header: true,
                      child: Text(
                        _a('firstEmpty.title'),
                        style: difyTextStyle(DifyType.systemSmRegular, DifyColors.textTertiary),
                      ),
                    ),
                  ],
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 8,
                  children: [
                    _ActionCard(
                      key: const ValueKey('studio-first-empty-blank'),
                      icon: 'add-box-line',
                      title: _a('newApp.startFromBlank'),
                      description: _a('firstEmpty.blankDescription'),
                      onTap: onCreateBlank,
                    ),
                    Row(
                      spacing: 8,
                      children: [
                        Expanded(
                          child: Container(
                            height: 1,
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [DifyColors.backgroundBody.withValues(alpha: 0), DifyColors.dividerRegular],
                              ),
                            ),
                          ),
                        ),
                        Text(
                          difyTransform(DifyType.systemXsMediumUppercase, _a('firstEmpty.or')),
                          style: difyTextStyle(DifyType.systemXsMediumUppercase, DifyColors.textTertiary),
                        ),
                        Expanded(
                          child: Container(
                            height: 1,
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [DifyColors.dividerRegular, DifyColors.backgroundBody.withValues(alpha: 0)],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    _ActionCard(
                      key: const ValueKey('studio-first-empty-dsl'),
                      icon: 'file-upload-line',
                      title: _a('importDSL'),
                      description: _a('firstEmpty.importDescription'),
                      onTap: onImportDSL,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    ],
  );
}

/// FirstEmptyActionCard, `visualStyle="list"`: `rounded-xl bg-components-button-secondary-bg px-3 py-2.5 shadow-xs
/// hover:bg-components-panel-on-panel-item-bg-hover`, a `size-9 rounded-lg bg-background-section` icon, the title
/// and the description.
class _ActionCard extends StatelessWidget {
  const _ActionCard({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    required this.onTap,
  });

  final String icon, title, description;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => DifyPressable(
    semanticLabel: title,
    onPressed: onTap,
    builder: (context, hovered, focused) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: hovered ? DifyColors.componentsPanelOnPanelItemBgHover : DifyColors.componentsButtonSecondaryBg,
        borderRadius: BorderRadius.circular(DifyRadius.xl),
        border: focused ? Border.all(color: DifyColors.stateAccentSolid, width: 2) : null,
        boxShadow: DifyShadows.xs,
      ),
      child: Row(
        spacing: 12,
        children: [
          Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: DifyColors.backgroundSection,
              borderRadius: BorderRadius.circular(DifyRadius.lg),
            ),
            child: RemixIcon(icon, size: 16, color: DifyColors.textTertiary),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 2,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: difyTextStyle(DifyType.systemMdMedium, DifyColors.textSecondary),
                ),
                Text(
                  description,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textTertiary),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
