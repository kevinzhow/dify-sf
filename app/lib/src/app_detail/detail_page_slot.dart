/// The page interface of an opened app (Dify 1.17.1's `/app/{id}/{page}`): how the app detail shell's sidebar builds
/// each page. **Stable**: pages built elsewhere (Access Point, Annotations) plug in here and nothing else of the shell.
///
/// A page is an [AppDetailPageBuilder] registered in [appDetailPageBuilders]. The shell builds it inside Dify's
/// padded, rounded page panel (every page but the editor), once the route guard (`layout-main.tsx`) has allowed it,
/// and keeps it alive while the user switches pages. Everything a page needs comes from [AppDetailContext] (also
/// reachable below the page with [AppDetailContext.of]).
library;

import 'package:collab_client/collab_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../workflow/workspace_models.dart';
import 'app_permission.dart';
import 'detail_pages.dart';

/// The pages of an opened app, in the sidebar's order. Dify's Deploy and Resource Access pages are enterprise-only
/// (no community-edition role gets them) and are not part of dify-sf.
enum AppDetailPageId {
  /// "Orchestrate": the workflow editor.
  workflow('workflow'),
  accessPoint('access-point'),
  logs('logs'),

  /// Chatflow apps only.
  annotations('annotations'),
  overview('overview');

  const AppDetailPageId(this.segment);

  /// The last segment of Dify's path.
  final String segment;

  /// The page of a Dify path (`/app/{id}/{segment}`); `configuration` is Dify's alias of the editor. Null: not a page
  /// of dify-sf (`/apps`, enterprise pages).
  static AppDetailPageId? fromPath(String path) {
    final segment = path.split('/').last;
    if (segment == 'configuration') return workflow;
    for (final p in values) {
      if (p.segment == segment) return p;
    }
    return null;
  }
}

/// Builds one page. The page is built when first shown and its element stays alive across page switches (keep state
/// in the widgets it returns: the builder runs again whenever the shell rebuilds, with the same context object unless
/// a navigation brought new [AppDetailContext.query]). Rebuild on [AppDetailContext.app] yourself (a
/// `ValueListenableBuilder`) where the page shows app info.
typedef AppDetailPageBuilder = Widget Function(BuildContext context, AppDetailContext detail);

/// What the shell gives every page.
class AppDetailContext {
  AppDetailContext({
    required this.app,
    required this.apps,
    required this.navigate,
    required this.refreshApp,
    this.account,
    this.models,
    this.query = const {},
    this._services = const {},
  });

  /// The open app (Dify's `appDetail`): `GET /v1/apps/{id}`, refetched after edits, renames from the sidebar or the
  /// editor's header, and `app_meta_update`. Its [AppInfo.permissionKeys] drive [capabilities].
  final ValueListenable<AppInfo> app;

  /// The rights of the signed-in user on this app (`getAppACLCapabilities`), from the current [app].
  AppACLCapabilities get capabilities => appACLCapabilities(app.value.permissionKeys);

  final AppsApi apps;

  /// The signed-in account (null in tests and the demo without one).
  final Account? account;

  /// The workspace's model providers and models (protocol 1.9), when the session has them.
  final WorkspaceModels? models;

  /// Switches to another page of this app (Dify's `router.push('/app/{id}/{page}?...')`); [query] carries Dify's
  /// search params for the target (for example `{'accessPoint': 'webapp'}`, `{'conversation_id': ...}`). A page the
  /// user may not open goes where Dify's guard sends it.
  final void Function(AppDetailPageId page, {Map<String, String> query}) navigate;

  /// Refetches [app] (react-query's invalidation of the app detail).
  final Future<void> Function() refreshApp;

  /// The search params of the last navigation to this page (empty when opened from the sidebar).
  final Map<String, String> query;

  final Map<Type, Object> _services;

  /// An injected API by type (for example `AccessApi`, `AnnotationsApi`, `VersionsApi`, `StatsApi`, `LogsApi` from
  /// collab_client); null when the session has none (a page then shows its empty state).
  T? service<T extends Object>() => _services[T] as T?;

  /// The same context with other search params.
  AppDetailContext withQuery(Map<String, String> query) => AppDetailContext(
    app: app,
    apps: apps,
    navigate: navigate,
    refreshApp: refreshApp,
    account: account,
    models: models,
    query: query,
    services: _services,
  );

  /// The context of the page that contains [context].
  static AppDetailContext of(BuildContext context) => maybeOf(context)!;

  static AppDetailContext? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppDetailContextScope>()?.detail;
}

/// Puts an [AppDetailContext] above a page.
class AppDetailContextScope extends InheritedWidget {
  const AppDetailContextScope({super.key, required this.detail, required super.child});

  final AppDetailContext detail;

  @override
  bool updateShouldNotify(AppDetailContextScope old) => old.detail != detail;
}

/// The page builders. The shell builds [AppDetailPageId.workflow] itself (the editor); a page missing here shows a
/// placeholder. Register a page by adding its entry in `detail_pages.dart`'s [registeredAppDetailPages].
Map<AppDetailPageId, AppDetailPageBuilder> get appDetailPageBuilders => registeredAppDetailPages;
