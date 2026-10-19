import 'dart:async';

import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart' show FakeAppsApi;
import 'package:dify_sf_app/src/studio/app_card.dart';
import 'package:dify_sf_app/src/studio/studio_scope.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

/// An [AppsApi] that records every call, fails the calls named in [failures] once (or always with [failAlways]) and
/// holds the calls named in [hold] until their completer completes. Everything else goes to [inner].
class ScriptedAppsApi implements AppsApi {
  ScriptedAppsApi([FakeAppsApi? inner]) : inner = inner ?? FakeAppsApi();

  final FakeAppsApi inner;
  final calls = <(String, Map<String, Object?>)>[];
  final failures = <String, Object>{};
  final failAlways = <String>{};
  final hold = <String, Completer<void>>{};

  /// What [exportDsl] answers for apps [inner] does not know.
  String exportYaml = 'kind: app\nversion: 0.1.5\n';

  int count(String name) => calls.where((c) => c.$1 == name).length;
  Map<String, Object?> last(String name) => calls.lastWhere((c) => c.$1 == name).$2;

  Future<T> _call<T>(String name, Map<String, Object?> args, Future<T> Function() run) async {
    calls.add((name, args));
    if (hold[name] case final h?) await h.future;
    final f = failAlways.contains(name) ? failures[name] : failures.remove(name);
    if (f != null) throw f;
    return run();
  }

  @override
  Future<AppPage> list([AppListQuery query = const AppListQuery()]) =>
      _call('list', {'query': query}, () => inner.list(query));
  @override
  Future<AppPage> starred([AppListQuery query = const AppListQuery(limit: 100)]) =>
      _call('starred', {'query': query}, () => inner.starred(query));
  @override
  Future<AppInfo> get(String id) => _call('get', {'id': id}, () => inner.get(id));
  @override
  Future<void> star(String id) => _call('star', {'id': id}, () async {});
  @override
  Future<void> unstar(String id) => _call('unstar', {'id': id}, () async {});
  @override
  Future<AppInfo> create({
    required String name,
    required String mode,
    String? description,
    String? iconType,
    String? icon,
    String? iconBackground,
  }) => _call(
    'create',
    {'name': name, 'mode': mode, 'description': description, 'icon_type': iconType, 'icon': icon},
    () => inner.create(
      name: name,
      mode: mode,
      description: description,
      iconType: iconType,
      icon: icon,
      iconBackground: iconBackground,
    ),
  );
  @override
  Future<AppImport> importDsl(
    String yamlContent, {
    String? name,
    String? description,
    String? iconType,
    String? icon,
    String? iconBackground,
  }) => _call('importDsl', {'yaml': yamlContent}, () => inner.importDsl(yamlContent));
  @override
  Future<AppImport> confirmImport(String importId) =>
      _call('confirmImport', {'id': importId}, () => inner.confirmImport(importId));
  @override
  Future<AppInfo> update(
    String id, {
    required String name,
    String? description,
    String? iconType,
    String? icon,
    String? iconBackground,
    bool? useIconAsAnswerIcon,
    int? maxActiveRequests,
  }) => _call('update', {
    'id': id,
    'name': name,
    'icon_type': iconType,
    'icon': icon,
    'icon_background': iconBackground,
    'description': description,
    'use_icon_as_answer_icon': useIconAsAnswerIcon,
    'max_active_requests': maxActiveRequests,
  }, () async => testApp(id: id, name: name));
  @override
  Future<AppInfo> copy(
    String id, {
    String? name,
    String? description,
    String? iconType,
    String? icon,
    String? iconBackground,
  }) => _call('copy', {
    'id': id,
    'name': name,
    'icon_type': iconType,
    'icon': icon,
    'icon_background': iconBackground,
  }, () async => testApp(id: 'new-app-id', name: name ?? 'Copy'));
  @override
  Future<void> delete(String id) => _call('delete', {'id': id}, () async {});
  @override
  Future<String> exportDsl(String id, {bool includeSecret = false}) =>
      _call('exportDsl', {'id': id, 'include_secret': includeSecret}, () async => exportYaml);
}

/// Dify's `createMockApp`: a chat app with the owner's keys (Dify's mock grants them through the maintainer rule).
AppInfo testApp({
  String id = 'test-app-id',
  String name = 'Test App',
  String description = 'Test app description',
  String mode = AppModes.chat,
  String? iconType = 'emoji',
  String? icon = '🤖',
  String? iconBackground = '#FFEAD5',
  String? iconUrl,
  String? authorName = 'Test Author',
  bool isStarred = false,
  List<String>? permissionKeys,
}) => AppInfo(
  id: id,
  name: name,
  description: description,
  mode: mode,
  iconType: iconType,
  icon: icon,
  iconBackground: iconBackground,
  iconUrl: iconUrl,
  authorName: authorName,
  createdBy: 'user-1',
  createdAt: 1704067200,
  updatedAt: 1704153600,
  isStarred: isStarred,
  permissionKeys: permissionKeys ?? AppPermissionKeys.forRole('owner'),
);

/// The card alone (Dify renders `<AppCard app={…} />`), in the page's services over [api].
Future<StudioCalls> renderCard(
  WidgetTester t,
  AppInfo app, {
  required ScriptedAppsApi api,
  bool starred = false,
  bool canCreateApp = true,
  StudioCalls? calls,
}) async {
  final c = calls ?? StudioCalls();
  await renderMembers(
    t,
    StudioScope(
      services: StudioServices(
        api: api,
        canCreateApp: canCreateApp,
        currentUserId: 'user-1',
        openApp: (app, {required readOnly}) async => c.opened.add((app: app, readOnly: readOnly)),
        refresh: () async {},
        environmentVariables: (id) async {
          c.envCalls.add(id);
          if (c.envError != null) throw c.envError!;
          return c.env;
        },
        saveDsl: (name, yaml) async => c.saved.add((name: name, yaml: yaml)),
      ),
      child: Align(
        alignment: Alignment.topLeft,
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: SizedBox(
            width: 337,
            child: AppCard(app: app, starred: starred),
          ),
        ),
      ),
    ),
  );
  return c;
}

/// The button whose semantics label is [label] (Dify's `getByRole('button', {name})`), tapped through its semantics
/// action (pointer events do not reach the hidden action bar, as in jsdom where CSS hides nothing).
Future<void> pressButton(WidgetTester t, String label) => tapButton(t, label);

/// The More trigger of [name] (`common.operation.moreActionsFor`).
String moreLabel(String name) => 'common.operation.moreActionsFor:{"name":"$name"}';

/// Opens the More menu of the card of [name].
Future<void> openOperations(WidgetTester t, [String name = 'Test App']) => pressButton(t, moreLabel(name));

/// Taps the menu item showing [text].
Future<void> tapMenuItem(WidgetTester t, String text) async {
  await t.tap(find.text(text).last);
  await settle(t);
}

/// Whether a toast with [text] (or containing it, with [contains]) is shown.
bool toastShown(String text, {bool contains = false}) =>
    (contains ? find.textContaining(text) : find.text(text)).evaluate().isNotEmpty;
