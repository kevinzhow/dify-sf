/// base/search-input's search-state helpers (the `SearchInput` itself lives in design/widgets).
library;

/// search-state.ts `hasSearchText`.
bool hasSearchText([String? searchText]) => searchText?.trim().isNotEmpty ?? false;

/// search-state.ts `isSearchResultEmpty`: a filter (the search text unless [hasActiveFilter] says) narrowed existing
/// data down to nothing; loading and a truly empty source are not.
bool isSearchResultEmpty({
  bool? hasActiveFilter,
  required bool isLoading,
  required int resultCount,
  String? searchText,
  required int sourceCount,
}) {
  final filtering = hasActiveFilter ?? hasSearchText(searchText);
  return !isLoading && sourceCount > 0 && resultCount == 0 && filtering;
}
