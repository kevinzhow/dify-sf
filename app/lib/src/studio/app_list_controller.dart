/// The Studio's data (apps/list.tsx + app-list-catalog.tsx): the filters, the infinite app list (`useInfiniteQuery`
/// over `GET /apps`, 30 per page, next page while `has_more`), the starred row (`GET /apps/starred`, the same filters,
/// limit 100) and their refetches. Dify keeps the previous results on screen while a new filter loads
/// (`keepPreviousData`) and, with collaboration on, refetches every 10 s.
library;

import 'dart:async';

import 'package:collab_client/collab_client.dart';
import 'package:flutter/foundation.dart';

/// constants.ts `APP_LIST_SEARCH_DEBOUNCE_MS`.
const appListSearchDebounce = Duration(milliseconds: 500);

/// The Studio's page size (list.tsx `limit: 30`).
const appListPageSize = 30;

/// app-list-catalog.tsx `STARRED_APP_LIMIT`.
const starredAppLimit = 100;

/// query-params.ts `studioAppListCategories`: the type filter's values. dify-sf offers only the modes it can run
/// (owner decision); the others stay valid list filters (a Dify URL with `category=chat` lists nothing).
const studioAppListCategories = [AppModes.all, AppModes.workflow, AppModes.advancedChat];

class StudioAppList extends ChangeNotifier {
  StudioAppList(this.api, {this.pollInterval, this.debounce = appListSearchDebounce});

  final AppsApi api;

  /// Dify's `refetchInterval` with collaboration on (10 s); null: no polling.
  final Duration? pollInterval;
  final Duration debounce;

  // ----- filters (list.tsx state) -----

  String _category = AppModes.all;
  String _keywords = '';
  String _debouncedKeywords = '';
  List<String> _creatorIds = const [];
  String _sortBy = AppSortBy.lastModified;
  Timer? _debounceTimer;

  String get category => _category;
  String get keywords => _keywords;
  String get debouncedKeywords => _debouncedKeywords;
  List<String> get creatorIds => _creatorIds;
  String get sortBy => _sortBy;

  /// list.tsx `hasActiveFilters` (tags are not part of dify-sf).
  bool get hasActiveFilters =>
      _category != AppModes.all ||
      _keywords.trim().isNotEmpty ||
      _debouncedKeywords.trim().isNotEmpty ||
      _creatorIds.isNotEmpty;

  /// The query of page [page] (list.tsx `appListQuery`).
  AppListQuery queryFor(int page, {int limit = appListPageSize}) => AppListQuery(
    page: page,
    limit: limit,
    name: _debouncedKeywords,
    sortBy: _sortBy,
    creatorIds: _creatorIds,
    mode: _category,
  );

  void setCategory(String value) {
    if (value == _category) return;
    _category = value;
    _filtersChanged();
  }

  void setSortBy(String value) {
    if (value == _sortBy) return;
    _sortBy = value;
    _filtersChanged();
  }

  void setCreatorIds(List<String> value) {
    if (listEquals(value, _creatorIds)) return;
    _creatorIds = List.unmodifiable(value);
    _filtersChanged();
  }

  /// The search box's text; the list follows [debounce] later (`useDebounce`).
  void setKeywords(String value) {
    if (value == _keywords) return;
    _keywords = value;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(debounce, () {
      _debounceTimer = null;
      if (_debouncedKeywords == _keywords) return;
      _debouncedKeywords = _keywords;
      _filtersChanged();
    });
    _notify();
  }

  // ----- results (app-list-catalog.tsx) -----

  List<AppPage> _pages = const [];
  List<AppInfo>? _starred;
  bool _starredFailed = false;
  bool _fetching = false;
  bool _fetchingNext = false;
  bool _nextPageError = false;
  bool _placeholder = false;
  Object? _error;
  int _generation = 0;
  Timer? _poll;
  bool _disposed = false;
  bool _started = false;

  /// The loaded pages (Dify's `appList.data.pages`); empty before the first page arrives.
  List<AppPage> get pages => _pages;

  /// Every loaded app, in order.
  List<AppInfo> get apps => [for (final p in _pages) ...p.data];

  /// The starred row; null until it arrives (empty when it failed: the catalog stays usable).
  List<AppInfo> get starredApps => _starred ?? const [];

  /// app-list-catalog.tsx's skeleton condition: no first page yet, or no starred answer yet (and no error there).
  bool get loadingFirstPage => _pages.isEmpty || (_starred == null && !_starredFailed);

  /// The first page failed and there is nothing to show (Dify throws to its error boundary).
  Object? get error => _error;

  bool get hasNextPage => _pages.isNotEmpty && _pages.last.hasMore;
  bool get isFetching => _fetching;
  bool get isFetchingNextPage => _fetchingNext;
  bool get isFetchNextPageError => _nextPageError;

  /// The pages on screen belong to the previous filters while the new ones load (`isPlaceholderData`).
  bool get isPlaceholderData => _placeholder;

  /// `appListPages[0].total > 0`.
  bool get hasAnyApp => _pages.isNotEmpty && _pages.first.total > 0;

  /// Loads the first page and the starred row (once; later calls are refreshes).
  Future<void> start() {
    if (_started) return refresh();
    _started = true;
    if (pollInterval case final every?) {
      _poll = Timer.periodic(every, (_) {
        if (!_fetching) unawaited(refresh());
      });
    }
    return _load();
  }

  void _filtersChanged() {
    _notify();
    if (_started) unawaited(_load());
  }

  /// A new query: the first page and the starred row; the old pages stay as placeholders until it answers.
  Future<void> _load() async {
    final gen = ++_generation;
    _placeholder = _pages.isNotEmpty;
    _fetching = true;
    _nextPageError = false;
    _notify();
    final starred = _loadStarred(gen);
    try {
      final first = await api.list(queryFor(1));
      if (gen != _generation || _disposed) return;
      _pages = [first];
      _error = null;
    } on Object catch (e) {
      if (gen != _generation || _disposed) return;
      if (_pages.isEmpty || _placeholder) {
        _error = e;
        _pages = const [];
      }
    } finally {
      if (gen == _generation && !_disposed) {
        _placeholder = false;
        _fetching = false;
        _notify();
      }
    }
    await starred;
  }

  Future<void> _loadStarred(int gen) async {
    try {
      final page = await api.starred(queryFor(1, limit: starredAppLimit));
      if (gen != _generation || _disposed) return;
      _starred = page.data;
      _starredFailed = false;
    } on Object {
      if (gen != _generation || _disposed) return;
      _starredFailed = true;
    }
    _notify();
  }

  /// `fetchNextPage({cancelRefetch: false})`: the page after the last one, unless one is already loading.
  Future<void> fetchNextPage() async {
    if (!hasNextPage || _fetchingNext) return;
    final gen = _generation;
    _fetchingNext = true;
    _fetching = true;
    _notify();
    try {
      final next = await api.list(queryFor(_pages.last.page + 1));
      if (gen != _generation || _disposed) return;
      _pages = [..._pages, next];
      _nextPageError = false;
    } on Object {
      if (gen != _generation || _disposed) return;
      _nextPageError = true;
    } finally {
      if (gen == _generation && !_disposed) {
        _fetchingNext = false;
        _fetching = false;
        _notify();
      }
    }
  }

  /// A refetch of what is loaded (react-query's invalidation after a mutation, and the poll): every loaded page in
  /// turn and the starred row. Failures keep the data on screen.
  Future<void> refresh() async {
    if (!_started) return start();
    final gen = ++_generation;
    final count = _pages.isEmpty ? 1 : _pages.length;
    _fetching = true;
    _fetchingNext = false;
    _notify();
    final starred = _loadStarred(gen);
    try {
      final fresh = <AppPage>[];
      for (var p = 1; p <= count; p++) {
        final page = await api.list(queryFor(p));
        if (gen != _generation || _disposed) return;
        fresh.add(page);
        if (!page.hasMore) break;
      }
      _pages = fresh;
      _error = null;
    } on Object catch (e) {
      if (gen != _generation || _disposed) return;
      if (_pages.isEmpty) _error = e;
    } finally {
      if (gen == _generation && !_disposed) {
        _fetching = false;
        _notify();
      }
    }
    await starred;
  }

  /// Replaces [app] wherever it is shown (a star toggle's answer before the refetch).
  void replace(AppInfo app) {
    _pages = [
      for (final p in _pages)
        AppPage(
          page: p.page,
          limit: p.limit,
          total: p.total,
          hasMore: p.hasMore,
          data: [for (final a in p.data) a.id == app.id ? app : a],
        ),
    ];
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _debounceTimer?.cancel();
    _poll?.cancel();
    super.dispose();
  }
}
