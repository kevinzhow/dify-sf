/// Dify's emoji-mart 5.6.0 SearchIndex.search and config.ts search-string construction, ported under MIT.
/// Upstream: missive/emoji-mart packages/emoji-mart/src/helpers/search-index.ts; see third_party/emoji-mart.
library;

class EmojiSearchIndex {
  EmojiSearchIndex(Map<String, Object?> data) {
    final emojis = data['emojis'] as Map;
    for (final raw in emojis.values) {
      final emoji = raw as Map;
      final parts = <String>[
        '${emoji['id']}',
        ...'${emoji['name']}'.split(RegExp(r'[-|_|\s]+')),
        for (final word in emoji['keywords'] as List? ?? const []) '$word',
        for (final emoticon in emoji['emoticons'] as List? ?? const []) '$emoticon',
      ].map((s) => s.toLowerCase()).where((s) => s.trim().isNotEmpty);
      final skins = [
        for (final skin in emoji['skins'] as List)
          if (skin['native'] != null) ',${skin['native']}',
      ];
      _terms['${emoji['id']}'] = ',${parts.join(',')}${skins.join()}';
    }
  }

  final _terms = <String, String>{};

  /// Match each distinct query word at a token's start. As upstream, the last word supplies the final score;
  /// exact IDs sort first, then the match's UTF-16 position, then the ID. Dify uses the default 90-result limit.
  List<String> search(String value) {
    if (value.trim().isEmpty) return const [];
    final seen = <String>{};
    final words = value
        .toLowerCase()
        .replaceFirstMapped(RegExp(r'(\w)-'), (m) => '${m[1]} ')
        .split(RegExp(r'[\s|,]+'))
        .where((s) => s.trim().isNotEmpty && seen.add(s));
    var pool = _terms.keys.toList();
    var scores = <String, int>{};
    var hasWords = false;
    for (final word in words) {
      hasWords = true;
      if (pool.isEmpty) break;
      scores = {};
      final matches = <String>[];
      for (final id in pool) {
        final position = _terms[id]!.indexOf(',$word');
        if (position < 0) continue;
        matches.add(id);
        scores[id] = id == word ? 0 : position + 1;
      }
      pool = matches;
    }
    if (!hasWords) return const [];
    pool.sort((a, b) {
      final score = scores[a]!.compareTo(scores[b]!);
      return score == 0 ? compareIds(a, b) : score;
    });
    return pool.take(90).toList();
  }

  /// All 1,870 IDs in the pinned data are ASCII letters, digits and _-+. This punctuation order reproduces
  /// upstream's English Intl localeCompare, verified against every ID, identically on Dart VM and JavaScript.
  static int compareIds(String a, String b) {
    int weight(int c) => switch (c) {
      95 => 0,
      45 => 1,
      43 => 2,
      _ => c,
    };
    final length = a.length < b.length ? a.length : b.length;
    for (var i = 0; i < length; i++) {
      final order = weight(a.codeUnitAt(i)).compareTo(weight(b.codeUnitAt(i)));
      if (order != 0) return order;
    }
    return a.length.compareTo(b.length);
  }
}
