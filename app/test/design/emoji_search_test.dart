import 'dart:convert';
import 'dart:io';

import 'package:dify_sf_app/src/design/widgets/emoji_catalog.dart';
import 'package:dify_sf_app/src/design/widgets/emoji_search.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final fixture = jsonDecode(File('test/fixtures/emoji_search_v5_6_0.json').readAsStringSync()) as Map;
  final data = (jsonDecode(File('assets/emoji/native.json').readAsStringSync()) as Map).cast<String, Object?>();
  final index = EmojiSearchIndex(data);
  group('emoji-mart 5.6.0 original library comparison', () {
    for (final row in fixture['cases'] as List) {
      test('query ${jsonEncode(row['query'])}', () {
        expect(index.search(row['query'] as String), row['ids']);
      });
    }
    test('every pinned ID has the same collation as original localeCompare', () {
      final ids = (data['emojis'] as Map).keys.cast<String>().toList()..sort(EmojiSearchIndex.compareIds);
      expect(ids, fixture['sortedIds']);
    });
    test('the catalog returns the original first-skin native strings in search order', () async {
      final catalog = await EmojiCatalog.load();
      for (final row in fixture['cases'] as List) {
        expect(catalog.search(row['query'] as String).map((e) => e.native).toList(), [
          for (final id in row['ids'] as List) ((data['emojis'] as Map)[id]['skins'] as List).first['native'],
        ], reason: '${row['query']}');
      }
    });
  });
}
