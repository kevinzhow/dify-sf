/// Dify's Emoji Mart 1.2.1 catalog, reused verbatim (see third_party/emoji-mart-data).
library;

import 'dart:convert';

import 'package:flutter/services.dart';

class IconEmoji {
  const IconEmoji(this.id, this.native, this.name, this.keywords);
  final String id, native, name;
  final List<String> keywords;
}

class IconEmojiCategory {
  const IconEmojiCategory(this.id, this.emojis);
  final String id;
  final List<IconEmoji> emojis;
}

class EmojiCatalog {
  EmojiCatalog._(this.categories, this.emojis);
  final List<IconEmojiCategory> categories;
  final Map<String, IconEmoji> emojis;
  static Future<EmojiCatalog>? _cached;
  static EmojiCatalog? _loaded;
  static EmojiCatalog? get loaded => _loaded;
  static Future<EmojiCatalog> load() => _cached ??= rootBundle.loadString('assets/emoji/native.json').then((data) {
    final json = jsonDecode(data) as Map;
    final emojis = <String, IconEmoji>{};
    (json['emojis'] as Map).forEach((id, value) {
      final v = value as Map;
      emojis['$id'] = IconEmoji('$id', '${(v['skins'] as List).first['native']}', '${v['name']}', [
        for (final k in v['keywords'] as List? ?? const []) '$k',
      ]);
    });
    return _loaded = EmojiCatalog._([
      for (final c in json['categories'] as List)
        IconEmojiCategory('${c['id']}', [
          for (final id in c['emojis'] as List)
            if (emojis[id] != null) emojis[id]!,
        ]),
    ], emojis);
  });

  List<IconEmoji> search(String query) {
    final terms = query.trim().toLowerCase().split(RegExp(r'\s+'));
    return [
      for (final e in emojis.values)
        if (terms.every((term) => '${e.id} ${e.name} ${e.native} ${e.keywords.join(' ')}'.toLowerCase().contains(term)))
          e,
    ];
  }
}

/// Dify emoji-picker/constants.ts.
const iconEmojiBackgrounds = [
  '#FFEAD5',
  '#E4FBCC',
  '#D3F8DF',
  '#E0F2FE',
  '#E0EAFF',
  '#EFF1F5',
  '#FBE8FF',
  '#FCE7F6',
  '#FEF7C3',
  '#E6F4D7',
  '#D5F5F6',
  '#D1E9FF',
  '#D1E0FF',
  '#D5D9EB',
  '#ECE9FE',
  '#FFE4E8',
];
