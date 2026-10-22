/// `app/(commonLayout)/app/(appDetailLayout)/[appId]/layout-main.tsx` with the app detail sidebar (Dify 1.17.1): an
/// opened app. The sidebar takes the main navigation's place; next to it the current page: the editor (edge to
/// edge) or any other page in Dify's padded, rounded panel. The app is read with `GET /v1/apps/{id}` (a 404 goes back
/// to the Studio), every page is guarded by the user's rights on the app (a refused page goes where Dify's
/// `getRedirectionPath` sends it), and the window title is `<page> · <app name>`. Pages are built when first shown and
/// stay alive while another one shows (the editor keeps its session, stream and journal); a page that is not shown
/// gets no ticks, no focus and no page-wide keys.
library;

import 'dart:async';

import 'package:collab_client/collab_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../active_page.dart';
import '../auth/widgets/auth_widgets.dart' show DifyDocumentTitle;
import '../design/dify_tokens.g.dart';
import '../design/widgets/app_icon_picker.dart' show UploadAppIcon;
import '../i18n/dify_i18n.dart';
import '../studio/export_app_dsl.dart';
import '../studio/studio_scope.dart' show saveDslFile, SaveDslFile;
import '../workflow/workspace_models.dart';
import '../workflow_editor/dsl/update_dsl_modal.dart' show WorkflowImport;
import 'app_info_actions.dart';
import 'app_permission.dart';
import 'app_sidebar.dart';
import 'detail_page_slot.dart';
import 'detail_sidebar.dart';
import '../design/widgets/widgets.dart';

String _c(String key) => DifyI18n.tr('common', key);

/// What the shell gives the editor page.
class AppDetailEditorHost {
  AppDetailEditorHost._(this.app, this._registerImport, this.navigate, this.refreshApp);

  /// The open app (its name follows renames from the sidebar).
  final ValueListenable<AppInfo> app;
  final void Function(WorkflowImport? import) _registerImport;

  /// Switches page (the publisher's Access Point action, for example).
  final void Function(AppDetailPageId page, {Map<String, String> query}) navigate;

  /// Re-reads the app (`GET /v1/apps/{id}`) into [app], the sidebar's and the editor header's shared app info: the
  /// editor calls it on its stream's app notices (protocol 1.11 `event: app`, Dify's `app_meta_update`).
  final Future<void> Function() refreshApp;

  /// The editor's "replace the workflow with a DSL file", once its session is up (null again when it closes): the
  /// sidebar's Import DSL runs through it.
  void registerImport(WorkflowImport? import) => _registerImport(import);
}

/// Builds the editor page (the host's `EditorPage` for the app's document).
typedef AppDetailEditorBuilder = Widget Function(BuildContext context, AppDetailEditorHost host);

/// `layout-main.tsx`'s `appDetailPageTitle`.
String appDetailPageTitle(AppDetailPageId? page) => switch (page) {
  AppDetailPageId.workflow => _c('appMenus.promptEng'),
  AppDetailPageId.accessPoint => _c('appMenus.accessPoint'),
  AppDetailPageId.logs => _c('appMenus.logs'),
  AppDetailPageId.annotations => _c('appMenus.annotations'),
  AppDetailPageId.overview => _c('appMenus.overview'),
  null => _c('menus.appDetail'),
};

/// `layout-main.tsx`'s guard: whether [page] may open for [acl].
bool appDetailPageAllowed(AppDetailPageId page, AppACLCapabilities acl) => switch (page) {
  AppDetailPageId.workflow => acl.canAccessLayout,
  AppDetailPageId.logs || AppDetailPageId.annotations => acl.canAccessLogAndAnnotation,
  AppDetailPageId.overview => acl.canMonitor,
  AppDetailPageId.accessPoint => acl.canViewAccessPoint,
};

class AppDetailPage extends StatefulWidget {
  const AppDetailPage({
    super.key,
    required this.appId,
    required this.apps,
    this.initialApp,
    this.initialPage,
    this.query = const {},
    this.account,
    this.models,
    this.services = const {},
    this.editor,
    this.canCreateApp = false,
    this.environmentVariables,
    this.saveDsl = saveDslFile,
    this.uploadIcon,
    this.openApp,
    this.onLeave,
    this.pageBuilders,
  });

  /// The pages; null: [appDetailPageBuilders] (tests pass their own).
  final Map<AppDetailPageId, AppDetailPageBuilder>? pageBuilders;

  final String appId;
  final AppsApi apps;

  /// The app as the Studio listed it (re-read on open).
  final AppInfo? initialApp;

  /// The page to open (Dify's path); null: where `getRedirectionPath` leads.
  final AppDetailPageId? initialPage;
  final Map<String, String> query;
  final Account? account;
  final WorkspaceModels? models;

  /// The APIs the pages get by type ([AppDetailContext.service]).
  final Map<Type, Object> services;

  /// The editor page; null: the editor shows a placeholder (tests of other pages).
  final AppDetailEditorBuilder? editor;

  /// The workspace key `app.create_and_management` (the app menu's Duplicate).
  final bool canCreateApp;

  /// The app's environment variables (Dify JSON), for the export's secret check; null: exports without the check.
  final Future<List<Map<String, Object?>>> Function(String appId)? environmentVariables;
  final SaveDslFile saveDsl;
  final UploadAppIcon? uploadIcon;

  /// Opens another app at [path] in place of this one (a duplicate: Dify's `router.replace`); null: none.
  final void Function(AppInfo app, String path)? openApp;

  /// Back to the Studio (`/apps`); null: pops this route.
  final VoidCallback? onLeave;

  @override
  State<AppDetailPage> createState() => AppDetailPageState();
}

class AppDetailPageState extends State<AppDetailPage> {
  /// The app store's `appDetail` (null until `GET /apps/{id}` answers).
  ValueNotifier<AppInfo>? _app;
  AppDetailPageId? _page;
  Map<String, String> _query = const {};
  final _visited = <AppDetailPageId>{};
  final _contexts = <AppDetailPageId, AppDetailContext>{};
  bool _left = false;

  WorkflowImport? _editorImport;
  final _importWaiters = <Completer<WorkflowImport?>>[];

  late final _exporter = AppDslExporter(
    exportDsl: (id, {includeSecret = false}) => widget.apps.exportDsl(id, includeSecret: includeSecret),
    environmentVariables: (id) async => await widget.environmentVariables?.call(id) ?? const [],
    saveDsl: (name, yaml) => widget.saveDsl(name, yaml),
  )..addListener(_rebuild);

  late final AppInfoActions actions = AppInfoActions(
    apps: widget.apps,
    appDetail: () => _app?.value,
    setAppDetail: (app) {
      if (app != null) _setApp(app);
    },
    exporter: _exporter,
    resetKey: widget.appId,
    redirect: (path, {app}) {
      if (path.startsWith('/app/') && app != null && widget.openApp != null) {
        widget.openApp!(app, path);
      } else if (path == '/apps' || !path.startsWith('/app/')) {
        _leave();
      }
    },
  )..addListener(_rebuild);

  /// The open app (tests).
  AppInfo? get app => _app?.value;

  /// The page on screen (tests).
  AppDetailPageId? get page => _page;

  @override
  void initState() {
    super.initState();
    _query = widget.query;
    unawaited(_load());
  }

  @override
  void dispose() {
    _exporter.dispose();
    actions.dispose();
    _app?.dispose();
    for (final w in _importWaiters) {
      w.complete(null);
    }
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    try {
      final app = await widget.apps.get(widget.appId);
      if (!mounted) return;
      _setApp(app);
      _select(widget.initialPage, widget.query);
    } on TransportException catch (e) {
      if (!mounted) return;
      if (e.statusCode == 404 || e.appDeleted) _leave();
    } on Object {
      // Unreachable: the loading state stays (Dify's Suspense); the user can go back.
    }
  }

  /// `setAppDetail`, then the guard again (the rights may have changed).
  void _setApp(AppInfo app) {
    final current = _app;
    if (current == null) {
      setState(() => _app = ValueNotifier(app));
      return;
    }
    current.value = app;
    if (_page != null) _select(_page, _query);
    _rebuild();
  }

  Future<void> refreshApp() async {
    try {
      final app = await widget.apps.get(widget.appId);
      if (mounted) _setApp(app);
    } on TransportException catch (e) {
      if (mounted && (e.statusCode == 404 || e.appDeleted)) _leave();
    }
  }

  void _leave() {
    if (_left) return;
    _left = true;
    if (widget.onLeave case final leave?) {
      leave();
    } else {
      unawaited(Navigator.of(context).maybePop());
    }
  }

  /// Opens [page] (null: the redirection target) if the rights allow it, else where Dify's guard sends the user.
  void navigate(AppDetailPageId page, {Map<String, String> query = const {}}) => _select(page, query);

  void _select(AppDetailPageId? page, Map<String, String> query) {
    final app = _app?.value;
    if (app == null) return;
    final acl = appACLCapabilities(app.permissionKeys);
    var target = page;
    if (target == null || !appDetailPageAllowed(target, acl)) {
      target = AppDetailPageId.fromPath(
        appRedirectionPath(id: app.id, mode: app.mode, permissionKeys: app.permissionKeys),
      );
      query = const {};
    }
    if (target == null) {
      _leave();
      return;
    }
    if (target == _page && mapEquals(query, _query)) return;
    setState(() {
      _page = target;
      _query = query;
      _visited.add(target!);
      _contexts.remove(target);
    });
  }

  AppDetailContext _contextFor(AppDetailPageId page) => _contexts[page] ??= AppDetailContext(
    app: _app!,
    apps: widget.apps,
    navigate: navigate,
    refreshApp: refreshApp,
    account: widget.account,
    models: widget.models,
    query: page == _page ? _query : const {},
    services: widget.services,
  );

  late final _editorHost = AppDetailEditorHost._(
    _app!,
    (import) {
      _editorImport = import;
      if (import != null) {
        for (final w in _importWaiters) {
          w.complete(import);
        }
        _importWaiters.clear();
      }
    },
    navigate,
    refreshApp,
  );

  /// The editor's import, waiting for the editor if it is still opening (it opens offstage when never shown).
  Future<ReplaceResult> _importDsl(String yaml, {bool confirm = false}) async {
    var import = _editorImport;
    if (import == null) {
      if (!_visited.contains(AppDetailPageId.workflow)) setState(() => _visited.add(AppDetailPageId.workflow));
      final waiter = Completer<WorkflowImport?>();
      _importWaiters.add(waiter);
      import = await waiter.future;
    }
    if (import == null) throw StateError('the editor is closed');
    return import(yaml, confirm: confirm);
  }

  @override
  Widget build(BuildContext context) {
    final app = _app?.value;
    final page = _page;
    final title = '${appDetailPageTitle(page)} · ${app?.name ?? _c('menus.appDetail')}';
    return DifyDocumentTitle(
      title: title,
      child: DifyPage(
        backgroundColor: DifyColors.backgroundBody,
        body: DetailSidebarFrame(
          account: widget.account,
          renderTop: (context, expand, onToggle) => AppDetailTop(expand: expand, onToggle: onToggle, onHome: _leave),
          renderSection: (context, expand) => app == null || page == null
              ? const SizedBox.shrink()
              : AppDetailSection(
                  app: app,
                  acl: appACLCapabilities(app.permissionKeys),
                  current: page,
                  expand: expand,
                  onSelect: navigate,
                  appInfo: AppInfoTrigger(
                    app: app,
                    expand: expand,
                    operationGroups: actions.operationGroups(
                      app,
                      appACLCapabilities(app.permissionKeys),
                      canCreateApp: widget.canCreateApp,
                    ),
                  ),
                ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (app == null || page == null)
                ColoredBox(color: DifyColors.backgroundBody, child: const DifyLoading())
              else
                _pages(page),
              if (app != null)
                AppInfoModalsHost(
                  actions: actions,
                  app: app,
                  importDsl: _importDsl,
                  uploadIcon: widget.uploadIcon,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pages(AppDetailPageId current) {
    final pages = [
      for (final p in AppDetailPageId.values)
        if (_visited.contains(p)) p,
    ];
    return IndexedStack(
      index: pages.indexOf(current),
      sizing: StackFit.expand,
      children: [
        for (final p in pages)
          KeyedSubtree(
            key: ValueKey('app-detail-page-${p.segment}'),
            child: ActivePage(
              active: p == current,
              child: TickerMode(
                enabled: p == current,
                child: ExcludeFocus(excluding: p != current, child: _buildPage(p)),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildPage(AppDetailPageId p) {
    final detail = _contextFor(p);
    if (p == AppDetailPageId.workflow) {
      return ColoredBox(
        color: DifyColors.componentsPanelBg,
        child: AppDetailContextScope(
          detail: detail,
          child: Builder(
            builder: (context) =>
                widget.editor?.call(context, _editorHost) ?? const _Placeholder(page: AppDetailPageId.workflow),
          ),
        ),
      );
    }
    final builder = (widget.pageBuilders ?? appDetailPageBuilders)[p];
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 4, 4, 4),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: DifyColors.componentsPanelBg,
          borderRadius: BorderRadius.circular(DifyRadius.lg),
          boxShadow: [BoxShadow(offset: const Offset(0, 1), blurRadius: 0.866, color: DifyColors.shadowShadow3)],
        ),
        child: AppDetailContextScope(
          detail: detail,
          child: Builder(builder: (context) => builder?.call(context, detail) ?? _Placeholder(page: p)),
        ),
      ),
    );
  }
}

/// A page that is not built yet.
class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.page});
  final AppDetailPageId page;

  @override
  Widget build(BuildContext context) => Center(
    key: ValueKey('app-detail-placeholder-${page.segment}'),
    child: Text(appDetailPageTitle(page), style: TextStyle(color: DifyColors.textTertiary)),
  );
}
