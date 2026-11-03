/// `app/(commonLayout)/app/(appDetailLayout)/[appId]/layout-main.tsx` with the app detail sidebar (Dify 1.17.1): an
/// opened app. The sidebar takes the main navigation's place; next to it the current page: the editor (edge to
/// edge) or any other page in Dify's padded, rounded panel. The app is read with `GET /v1/apps/{id}` (a 404 goes back
/// to the Studio), every page is guarded by the user's rights on the app (a refused page goes where Dify's
/// `getRedirectionPath` sends it), and the window title is `<page> · <app name>`. Pages are built when first shown and
/// stay alive while another one shows (the editor keeps its session, stream and journal); a page that is not shown
/// gets no ticks, no focus and no page-wide keys.
///
/// In a compact window (a phone, dify-sf) there is no sidebar: the editor fills the page edge to edge (or, without
/// the right to edit, the page the guard leads to, under an app bar), the app's other pages open as pushed pages with
/// an app bar from the editor's "…" menu (back returns to the editor), and so do the app's operations (edit info,
/// duplicate, export, import, delete). A landscape phone (a short window driven by touch) keeps that phone shell, so
/// turning the phone changes nothing here. On a tablet (touch, not short) the other pages keep the sidebar with touch
/// sizes, and the editor fills the window edge to edge with its touch chrome (its "…" opens the other pages): beside
/// a sidebar, the canvas and the editor's side panel would not fit.
library;

import 'dart:async';

import 'package:collab_client/collab_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../active_page.dart';
import '../auth/widgets/auth_widgets.dart' show DifyDocumentTitle;
import '../design/dify_icon.dart';
import '../design/dify_tokens.g.dart';
import '../design/widgets/app_icon_picker.dart' show UploadAppIcon;
import '../i18n/dify_i18n.dart';
import '../shell/phone_page.dart';
import '../studio/export_app_dsl.dart';
import '../studio/studio_scope.dart' show saveDslFile, SaveDslFile;
import '../workflow/workspace_models.dart';
import '../workflow_editor/dsl/update_dsl_modal.dart' show WorkflowImport;
import '../workflow_editor/phone/phone_editor_controller.dart' show PhoneEditorHostActions;
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

  /// The pages move between the desktop frame and the phone layout with their state (a rotation keeps the editor).
  final _pagesKey = GlobalKey(debugLabel: 'app detail pages');

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
      final root = _compact(context) ? phoneRootPage : null;
      final initial = widget.initialPage;
      if (root != null && initial != null && initial != root) {
        // A phone opens the editor (or the guard's page) and pushes the asked page over it.
        _select(root, const {});
        if (appDetailPageAllowed(initial, appACLCapabilities(app.permissionKeys))) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _pushPhonePage(initial, widget.query);
          });
        }
        return;
      }
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
      // A pop, not maybePop: back would first close an open popup, and leaving must leave (on a phone, from under
      // one of the app's pushed pages as well).
      final route = ModalRoute.of(context);
      final navigator = Navigator.of(context);
      if (_compact(context) && route != null && !route.isCurrent) navigator.popUntil((r) => r == route);
      navigator.pop();
    }
  }

  /// Opens [page] (null: the redirection target) if the rights allow it, else where Dify's guard sends the user. On a
  /// phone a page other than the root ([phoneRootPage]) is pushed over it, and the root is shown again by popping.
  void navigate(AppDetailPageId page, {Map<String, String> query = const {}}) {
    if (mounted && _compact(context)) {
      final root = phoneRootPage;
      final app = _app?.value;
      if (root != null &&
          app != null &&
          page != root &&
          appDetailPageAllowed(page, appACLCapabilities(app.permissionKeys))) {
        _pushPhonePage(page, query);
        return;
      }
      if (root != null && page == root) {
        final route = ModalRoute.of(context);
        if (route != null && !route.isCurrent) Navigator.of(context).popUntil((r) => r == route);
      }
    }
    _select(page, query);
  }

  /// The phone shell (no sidebar, the app's other pages pushed over the root page): a compact window, or a short one
  /// driven by touch (a landscape phone).
  static bool _compact(BuildContext context) => switch (DifyLayoutMode.of(context)) {
    DifyLayoutMode.phone => true,
    DifyLayoutMode.touch => DifyWindowClass.shortOf(context),
    DifyLayoutMode.desktop => false,
  };

  /// A tablet's editor: edge to edge without the sidebar (the touch chrome's "…" has the other pages).
  static bool _touchEditor(BuildContext context, AppDetailPageId? page) =>
      page == AppDetailPageId.workflow && DifyLayoutMode.of(context) == DifyLayoutMode.touch;

  /// The page a phone shows under its app's pushed pages: the editor when the user may open it, else the page the
  /// guard leads to. Null until the app is loaded.
  AppDetailPageId? get phoneRootPage {
    final app = _app?.value;
    if (app == null) return null;
    final acl = appACLCapabilities(app.permissionKeys);
    if (appDetailPageAllowed(AppDetailPageId.workflow, acl)) return AppDetailPageId.workflow;
    return AppDetailPageId.fromPath(appRedirectionPath(id: app.id, mode: app.mode, permissionKeys: app.permissionKeys));
  }

  /// A page of this app pushed on a phone: its app bar (back to the root page) over the page.
  void _pushPhonePage(AppDetailPageId page, Map<String, String> query) {
    final app = _app;
    if (app == null) return;
    final detail = _contextFor(page).withQuery(query);
    final builder = (widget.pageBuilders ?? appDetailPageBuilders)[page];
    unawaited(
      pushPhonePage<void>(
        context,
        title: appDetailPageTitle(page),
        subtitle: app.value.name,
        scrollable: false,
        settings: RouteSettings(name: 'app-detail-${page.segment}'),
        builder: (context) => DifyDocumentTitle(
          title: '${appDetailPageTitle(page)} · ${app.value.name}',
          child: AppDetailContextScope(
            detail: detail,
            child: Builder(
              builder: (context) => KeyedSubtree(
                key: ValueKey('app-detail-phone-page-${page.segment}'),
                child: builder?.call(context, detail) ?? _Placeholder(page: page),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The editor's "…" entries on a phone: the app's other pages, then its operations.
  List<DifyActionSheetAction> _phoneMenu() {
    final app = _app?.value;
    if (app == null) return const [];
    final acl = appACLCapabilities(app.permissionKeys);
    final root = phoneRootPage;
    final color = DifyColors.textSecondary;
    return [
      for (final item in appDetailNavigation(app, acl))
        if (item.page != root)
          DifyActionSheetAction(
            label: item.name,
            icon: IconTheme.merge(
              data: IconThemeData(color: color),
              child: item.icon(color, false),
            ),
            onTap: () => navigate(item.page),
          ),
      for (final group in actions.operationGroups(app, acl, canCreateApp: widget.canCreateApp))
        for (final op in group)
          DifyActionSheetAction(
            label: op.title,
            icon: RemixIcon(op.icon, size: 20),
            destructive: op.destructive,
            enabled: !op.loading,
            onTap: op.onClick,
          ),
    ];
  }

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
    if (_compact(context) || (app != null && _touchEditor(context, page))) {
      return DifyDocumentTitle(title: title, child: _phone(context, app, page));
    }
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
          child: _content(app, page),
        ),
      ),
    );
  }

  /// The pages (or the loading state) and the app info dialogs' host.
  Widget _content(AppInfo? app, AppDetailPageId? page) => Stack(
    fit: StackFit.expand,
    children: [
      if (app == null || page == null)
        ColoredBox(color: DifyColors.backgroundBody, child: const DifyLoading())
      else
        KeyedSubtree(key: _pagesKey, child: _pages(page)),
      if (app != null)
        AppInfoModalsHost(
          actions: actions,
          app: app,
          importDsl: _importDsl,
          uploadIcon: widget.uploadIcon,
        ),
    ],
  );

  /// The phone layout: the root page edge to edge, the editor with its own bars, any other root page under an app bar
  /// whose "…" offers the app's other pages and operations.
  Widget _phone(BuildContext context, AppInfo? app, AppDetailPageId? page) {
    if (app == null || page == null) {
      return DifyPage(
        backgroundColor: DifyColors.backgroundBody,
        body: _content(app, page),
      );
    }
    if (page == AppDetailPageId.workflow) {
      return DifyPage(edgeToEdge: true, backgroundColor: DifyColors.backgroundBody, body: _content(app, page));
    }
    final menu = _phoneMenu();
    return DifyPage(
      edgeToEdge: true,
      backgroundColor: DifyColors.componentsPanelBg,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DifyTopAppBar(
            title: appDetailPageTitle(page),
            subtitle: app.name,
            backgroundColor: DifyColors.componentsPanelBg,
            actions: [
              if (menu.isNotEmpty)
                DifyTouchIconButton(
                  key: const ValueKey('app-detail-phone-more'),
                  label: _c('operation.more'),
                  icon: const RemixIcon('more-fill', size: 22),
                  onPressed: () => unawaited(showDifyActionSheet(context, title: app.name, actions: _phoneMenu())),
                ),
            ],
          ),
          Expanded(
            child: MediaQuery.removePadding(
              context: context,
              removeTop: true,
              child: SafeArea(top: false, child: DifyTouchSurface(child: _content(app, page))),
            ),
          ),
        ],
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
          // The phone editor's "…" menu gets the app's other pages and operations (the desktop has the sidebar).
          child: PhoneEditorHostActions(
            actions: _phoneMenu,
            child: Builder(
              builder: (context) =>
                  widget.editor?.call(context, _editorHost) ?? const _Placeholder(page: AppDetailPageId.workflow),
            ),
          ),
        ),
      );
    }
    final builder = (widget.pageBuilders ?? appDetailPageBuilders)[p];
    // A phone shows the page full bleed under its app bar (the same widgets, so a rotation keeps the page).
    final phone = _compact(context);
    return Padding(
      padding: phone ? EdgeInsets.zero : const EdgeInsets.fromLTRB(0, 4, 4, 4),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: DifyColors.componentsPanelBg,
          borderRadius: BorderRadius.circular(phone ? 0 : DifyRadius.lg),
          boxShadow: phone
              ? null
              : [BoxShadow(offset: const Offset(0, 1), blurRadius: 0.866, color: DifyColors.shadowShadow3)],
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
    child: DifyTextLine(appDetailPageTitle(page), style: TextStyle(color: DifyColors.textTertiary)),
  );
}
