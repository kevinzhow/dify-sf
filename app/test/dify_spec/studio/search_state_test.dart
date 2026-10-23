// dify-spec: web/app/components/base/search-input/__tests__/search-state.spec.ts
import 'package:dify_sf_app/src/studio/search_input.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('search-state', () {
    test('detects trimmed search text', () {
      expect(hasSearchText(' query '), isTrue);
      expect(hasSearchText('   '), isFalse);
      expect(hasSearchText(), isFalse);
    });

    test('treats search empty as filtering existing source data to no results', () {
      expect(isSearchResultEmpty(isLoading: false, resultCount: 0, searchText: 'missing', sourceCount: 2), isTrue);
    });

    test('does not treat loading or true source empty as search empty', () {
      expect(isSearchResultEmpty(isLoading: true, resultCount: 0, searchText: 'missing', sourceCount: 2), isFalse);
      expect(isSearchResultEmpty(isLoading: false, resultCount: 0, searchText: 'missing', sourceCount: 0), isFalse);
    });

    test('supports non-text filters', () {
      expect(isSearchResultEmpty(hasActiveFilter: true, isLoading: false, resultCount: 0, sourceCount: 2), isTrue);
    });
  });
}
