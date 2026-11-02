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
import '../active_page.dart';
import '../design/widgets/widgets.dart';
import '../i18n/dify_i18n.dart';
import '../settings/workspace_members.dart';
import 'app_card.dart';
import 'app_row.dart';
import 'app_list_controller.dart';
import 'create_app_modal.dart';
import 'create_from_dsl_modal.dart';
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
    this.fetchDslUrl,
    this.uploadIcon,
    this.onOpenAccount,
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
  final Future<String> Function(String url)? fetchDslUrl;
  final UploadAppIcon? uploadIcon;

  /// The phone layout's workspace avatar opens the Account tab (where the workspace switcher is); null hides it.
  final VoidCallback? onOpenAccount;

  @override
  State<StudioPage> createState() => StudioPageState();
}

class StudioPageState extends State<StudioPage> {
  late final list = StudioAppList(widget.api, pollInterval: widget.pollInterval, debounce: widget.debounce)
    ..addListener(_changed);
  late final drop = DslDragDrop(onDslFileDropped: (f) => unawaited(_droppedFile(f)), enabled: _canCreate);
  final _scroll = ScrollController();
  int _dialogs = 0;

  /// The phone layout's inline search is open (the app bar shows the field).
  bool _searching = false;

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
          importUrl: widget.fetchDslUrl == null ? widget.api.importDslUrl : null,
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
    if (DifyWindowClass.of(context) == DifyWindowClass.compact) return _phone(members);
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

  // ----- the phone layout (compact windows; a dify-sf divergence, mockup 1) -----

  void _openSearch() => setState(() => _searching = true);

  /// Closes the inline search; its query goes with it (the list shows every app again).
  void _closeSearch() {
    if (!_searching) return;
    setState(() => _searching = false);
    if (list.keywords.isNotEmpty) {
      _resetScroll();
      list.setKeywords('');
    }
  }

  /// The large "Studio" app bar (search, the workspace avatar) or, while searching, the search field; a chip row of
  /// the filters; the apps as rows (pull to refresh on touch); "Create" as a floating button.
  Widget _phone(WorkspaceMembers? members) {
    final active = ActivePage.of(context);
    final workspace = members?.workspaceName;
    final bar = _searching
        ? DifyTopAppBar.search(
            key: const ValueKey('studio-search-bar'),
            onBack: _closeSearch,
            field: DifySearchInput(
              key: const ValueKey('studio-search'),
              value: list.keywords,
              height: 40,
              autofocus: true,
              placeholder: _a('gotoAnything.actions.searchApplications'),
              semanticLabel: _a('gotoAnything.actions.searchApplications'),
              onValueChange: (v) {
                _resetScroll();
                list.setKeywords(v);
              },
            ),
          )
        : DifyTopAppBar.large(
            title: _c('menus.apps'),
            actions: [
              DifyTouchIconButton(
                key: const ValueKey('studio-search-open'),
                label: _c('operation.search'),
                icon: const RemixIcon('search-line', size: 22),
                onPressed: _openSearch,
              ),
              if (widget.onOpenAccount case final open? when workspace != null)
                DifyTouchIconButton(
                  key: const ValueKey('studio-workspace'),
                  label: '$workspace ${_c('mainNav.workspace.openMenu')}',
                  icon: DifyWorkspaceAvatar(name: workspace, size: DifyWorkspaceAvatarSize.lg),
                  onPressed: open,
                ),
            ],
          );
    return DifyBackDismiss(
      // Back closes the search before it leaves the Studio (only while the Studio is the tab on screen).
      enabled: _searching && active,
      onDismiss: _closeSearch,
      child: StudioScope(
        services: _services,
        child: DifySurface(
          child: ColoredBox(
            color: DifyColors.backgroundBody,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                bar,
                DifyChipBar(key: const ValueKey('studio-filter-chips'), children: _phoneFilters(members)),
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ColoredBox(color: DifyColors.componentsPanelBg, child: _phoneCatalog()),
                      if (_canCreate && !_searching)
                        Positioned(
                          right: 16,
                          bottom: 16,
                          child: DifyFab.extended(
                            key: const ValueKey('studio-create-fab'),
                            icon: const RemixIcon('add-line', size: 22),
                            label: _c('operation.create'),
                            onPressed: _openCreateSheet,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The filters as chips: the app types (All, Workflow, Chatflow) inline, Creators and the sort order as pickers in
  /// bottom sheets. The same list state as the desktop header.
  List<Widget> _phoneFilters(WorkspaceMembers? members) {
    final creators = list.creatorIds.length;
    return [
      for (final c in studioAppListCategories)
        DifyFilterChip(
          key: ValueKey('studio-type-chip-$c'),
          label: AppTypeFilter.option(c).$1,
          selected: list.category == c,
          onPressed: () {
            _resetScroll();
            list.setCategory(c);
          },
        ),
      DifyFilterChip(
        key: const ValueKey('studio-creators-chip'),
        label: creators > 0 ? '${_a('studio.filters.creators')} · $creators' : _a('studio.filters.creators'),
        selected: creators > 0,
        leading: const RemixIcon('filter-3-line', size: 16),
        onPressed: () => unawaited(_pickCreators(members)),
      ),
      DifyFilterChip(
        key: const ValueKey('studio-sort-chip'),
        label: AppSortFilter.label(list.sortBy),
        semanticLabel: '${_a('studio.sort.sortBy')} ${AppSortFilter.label(list.sortBy)}',
        leading: const RemixIcon('sort-desc', size: 16),
        onPressed: _pickSort,
      ),
    ];
  }

  void _pickSort() => unawaited(
    showDifyActionSheet(
      context,
      title: _a('studio.sort.sortBy'),
      actions: [
        for (final s in AppSortBy.all)
          DifyActionSheetAction(
            label: AppSortFilter.label(s),
            icon: s == list.sortBy ? const RemixIcon('check-line', size: 20) : const SizedBox.square(dimension: 20),
            onTap: () {
              _resetScroll();
              list.setSortBy(s);
            },
          ),
      ],
    ),
  );

  Future<void> _pickCreators(WorkspaceMembers? members) => showDifyBottomSheet<void>(
    context,
    (context) => CreatorsSheet(
      members: members,
      value: list.creatorIds,
      currentUserId: members?.meAsMember?.id ?? widget.currentUserId,
      onChange: (v) {
        _resetScroll();
        list.setCreatorIds(v);
      },
    ),
  );

  /// Create's options (the desktop dropdown's): from blank, import DSL. dify-sf has no templates.
  void _openCreateSheet() => unawaited(
    showDifyActionSheet(
      context,
      title: _c('operation.create'),
      actions: [
        DifyActionSheetAction(
          label: _a('newApp.startFromBlank'),
          icon: const RemixIcon('sticky-note-add-line', size: 20),
          onTap: () => unawaited(openCreateBlank()),
        ),
        DifyActionSheetAction(
          label: _a('importDSL'),
          icon: const RemixIcon('file-upload-line', size: 20),
          onTap: () => unawaited(openImportDsl()),
        ),
      ],
    ),
  );

  /// The phone catalog: the same states as the grid (loading, error, first empty, no match, the starred section,
  /// infinite scroll), as rows.
  Widget _phoneCatalog() {
    if (list.error != null && list.pages.isEmpty) return _errorState();
    if (list.loadingFirstPage) {
      return Semantics(
        key: const ValueKey('studio-catalog-loading'),
        label: _c('loading'),
        role: SemanticsRole.status,
        container: true,
        child: ListView(
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.zero,
          children: [for (var i = 0; i < 8; i++) const AppListRowSkeleton()],
        ),
      );
    }
    final hasAnyApp = list.hasAnyApp;
    final placeholder = list.isPlaceholderData;
    final emptyStatus = !placeholder && list.pages.isNotEmpty && !hasAnyApp ? _a('filterEmpty.noApps') : '';
    final showFirstEmpty = !placeholder && !hasAnyApp && _canCreate && !list.hasActiveFilters;
    final starred = list.starredApps;
    Widget catalog = CustomScrollView(
      key: const ValueKey('studio-catalog'),
      controller: _scroll,
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        if (starred.isNotEmpty) ...[
          SliverToBoxAdapter(child: DifyListSectionHeader(_a('studio.starred'))),
          SliverList.list(
            children: [
              for (final a in starred)
                KeyedSubtree(
                  key: ValueKey('starred-${a.id}'),
                  child: AppListRow(app: a),
                ),
            ],
          ),
          SliverToBoxAdapter(child: DifyListSectionHeader(_a('studio.allApps'))),
        ],
        if (hasAnyApp) ...[
          SliverList.list(
            children: [
              for (final a in list.apps)
                KeyedSubtree(
                  key: ValueKey('row-${a.id}'),
                  child: AppListRow(app: a),
                ),
              if (list.hasNextPage) ...[for (var i = 0; i < 3; i++) const AppListRowSkeleton()],
            ],
          ),
          if (list.hasNextPage && list.isFetchNextPageError) SliverToBoxAdapter(child: _nextPageError()),
          if (list.hasNextPage)
            SliverToBoxAdapter(
              child: InfiniteScrollSentinel(
                canLoadMore: !list.isFetching && !list.isFetchNextPageError,
                onLoadMore: () => unawaited(list.fetchNextPage()),
                preloadDistance: (p) => (p.viewportDimension * 0.25).clamp(160, 320).toDouble(),
              ),
            ),
        ] else
          SliverFillRemaining(
            hasScrollBody: false,
            child: SizedBox(height: 360, child: StudioEmpty(message: _a('filterEmpty.noApps'))),
          ),
        // Room for the floating Create button under the last row.
        const SliverToBoxAdapter(child: SizedBox(height: DifyFab.size + 32)),
      ],
    );
    // Pulling is a touch gesture: a narrow desktop window gets the phone layout without it.
    if (DifyTouch.isCoarse(context)) catalog = DifyRefreshIndicator(onRefresh: list.refresh, child: catalog);
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
              : catalog,
        ),
      ],
    );
  }

  /// StudioListHeader: `sticky top-0 flex flex-col gap-3.5 bg-background-body px-8 pt-4 pb-2`.
  Widget _header(WorkspaceMembers? members) {
    final compact = DifyAdaptive.compactOf(context);
    final filters = Wrap(
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
          width: DifyAdaptive.compactOf(context) ? DifyAdaptive.widthOf(context) - 24 : 200,
          value: list.keywords,
          semanticLabel: _a('gotoAnything.actions.searchApplications'),
          onChange: (v) {
            _resetScroll();
            list.setKeywords(v);
          },
        ),
      ],
    );
    final create = CreateAppDropdown(
      onCreateBlank: () => unawaited(openCreateBlank()),
      onImportDSL: () => unawaited(openImportDsl()),
    );
    final title = Semantics(
      header: true,
      child: DifyTextLine(_c('menus.apps'), style: difyTextStyle(DifyType.title2xlSemiBold, DifyColors.textPrimary)),
    );
    return Container(
      color: DifyColors.backgroundBody,
      padding: EdgeInsets.fromLTRB(compact ? 12 : 32, 16, compact ? 12 : 32, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 14,
        children: [
          SizedBox(
            height: compact ? 36 : 24,
            child: Row(
              children: [
                Expanded(child: title),
                if (compact && _canCreate) create,
              ],
            ),
          ),
          if (compact)
            filters
          else
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 8,
              children: [
                Expanded(child: filters),
                if (_canCreate) create,
              ],
            ),
        ],
      ),
    );
  }

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
          child: DifyTextLine(
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
          DifyTextLine(
            _c('errorBoundary.title'),
            style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textTertiary),
          ),
          DifyButton(
            key: const ValueKey('studio-next-page-retry'),
            size: DifyButtonSize.small,
            variant: DifyButtonVariant.secondary,
            loading: list.isFetchingNextPage,
            semanticLabel: _c('operation.retry'),
            onPressed: () => unawaited(list.fetchNextPage()),
            child: DifyTextLine(_c('operation.retry')),
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
        DifyTextLine(
          _c('errorBoundary.title'),
          style: difyTextStyle(DifyType.systemSmRegular, DifyColors.textTertiary),
        ),
        DifyTextLine('${list.error}', style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textQuaternary)),
        DifyButton(
          key: const ValueKey('studio-retry'),
          size: DifyButtonSize.small,
          semanticLabel: _c('operation.retry'),
          onPressed: () => unawaited(list.refresh()),
          child: DifyTextLine(_c('operation.retry')),
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
          DifyTextLine(_a('newApp.dropDSLToCreateApp'), style: difyTextStyle(DifyType.systemXsRegular, color)),
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
            DifyTextLine(message, style: difyTextStyle(DifyType.systemSmRegular, DifyColors.textTertiary)),
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
                      child: DifyTextLine(
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
                        DifyTextLine(
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
                DifyTextLine(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: difyTextStyle(DifyType.systemMdMedium, DifyColors.textSecondary),
                ),
                DifyTextLine(
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
