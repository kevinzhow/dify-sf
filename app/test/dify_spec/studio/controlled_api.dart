import 'dart:async';

import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart' show FakeAppsApi;

/// [FakeAppsApi] with test controls over its reads (Dify's specs mock react-query's states): every list / starred
/// query is recorded; [holdList] / [holdStarred] keep the next answers until completed; [failList] / [failStarred]
/// make them fail.
class ControlledAppsApi implements AppsApi {
  ControlledAppsApi(this.inner);

  final FakeAppsApi inner;
  final listQueries = <AppListQuery>[];
  final starredQueries = <AppListQuery>[];
  Completer<void>? holdList, holdStarred;
  Object? Function(AppListQuery query)? failList;
  Object? failStarred;

  @override
  Future<AppPage> list([AppListQuery query = const AppListQuery()]) async {
    listQueries.add(query);
    if (holdList case final h?) await h.future;
    if (failList?.call(query) case final e?) throw e;
    return inner.list(query);
  }

  @override
  Future<AppPage> starred([AppListQuery query = const AppListQuery(limit: 100)]) async {
    starredQueries.add(query);
    if (holdStarred case final h?) await h.future;
    if (failStarred case final e?) throw e;
    return inner.starred(query);
  }

  @override
  Future<AppInfo> get(String id) => inner.get(id);
  @override
  Future<void> star(String id) => inner.star(id);
  @override
  Future<void> unstar(String id) => inner.unstar(id);
  @override
  Future<AppInfo> create({
    required String name,
    required String mode,
    String? description,
    String? iconType,
    String? icon,
    String? iconBackground,
  }) => inner.create(
    name: name,
    mode: mode,
    description: description,
    iconType: iconType,
    icon: icon,
    iconBackground: iconBackground,
  );
  @override
  Future<AppImport> importDsl(
    String yamlContent, {
    String? name,
    String? description,
    String? iconType,
    String? icon,
    String? iconBackground,
  }) => inner.importDsl(
    yamlContent,
    name: name,
    description: description,
    iconType: iconType,
    icon: icon,
    iconBackground: iconBackground,
  );
  @override
  Future<AppImport> importDslUrl(String url) async => throw StateError('No URL fixture');

  @override
  Future<AppImport> confirmImport(String importId) => inner.confirmImport(importId);
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
  }) => inner.update(
    id,
    name: name,
    description: description,
    iconType: iconType,
    icon: icon,
    iconBackground: iconBackground,
    useIconAsAnswerIcon: useIconAsAnswerIcon,
    maxActiveRequests: maxActiveRequests,
  );
  @override
  Future<AppInfo> copy(
    String id, {
    String? name,
    String? description,
    String? iconType,
    String? icon,
    String? iconBackground,
  }) => inner.copy(
    id,
    name: name,
    description: description,
    iconType: iconType,
    icon: icon,
    iconBackground: iconBackground,
  );
  @override
  Future<void> delete(String id) => inner.delete(id);
  @override
  Future<String> exportDsl(String id, {bool includeSecret = false}) =>
      inner.exportDsl(id, includeSecret: includeSecret);
}
