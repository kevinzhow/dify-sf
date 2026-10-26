/// App-owned shard selection; shaping, glyph detection and relayout stay in Flutter.
library;

import 'dart:convert';

import 'package:flutter/services.dart';

class FontSubsetCatalog {
  FontSubsetCatalog(Map<String, dynamic> json) : chunks = (json['chunks'] as List).cast<Map<String, dynamic>>() {
    final codepoints = json['codepoints'] as List;
    if (chunks.length != codepoints.length || chunks.isEmpty) throw const FormatException('Invalid font catalog');
    for (var i = 0; i < codepoints.length; i++) {
      for (final cp in (codepoints[i] as List).cast<int>()) {
        if (chunkFor.containsKey(cp)) throw const FormatException('Overlapping font shards');
        chunkFor[cp] = i;
      }
    }
  }
  final List<Map<String, dynamic>> chunks;
  final chunkFor = <int, int>{};
}

typedef FontSubsetRegister = Future<void> Function(String family, List<ByteData> faces);

class FontSubsetLoader {
  FontSubsetLoader({AssetBundle? bundle, FontSubsetRegister? register})
    : _bundle = bundle ?? rootBundle,
      _register = register ?? _registerFonts;
  final AssetBundle _bundle;
  final FontSubsetRegister _register;
  final _catalogs = <String, Future<FontSubsetCatalog>>{};
  final _pending = <String, Future<void>>{};
  final _blockedShards = <String>{};
  void retryFailed() => _blockedShards.clear();
  final _faces = <String, Future<ByteData>>{};
  final _loaded = <String, Set<int>>{};
  final _failures = <String, Set<int>>{};
  String? activeRegion;
  bool _externalFailed = false;
  bool get hasFailure => _externalFailed || (_failures[activeRegion]?.isNotEmpty ?? false);
  void reportExternalFailure(bool value) {
    _externalFailed = value;
    onFailure?.call(hasFailure);
  }

  void Function()? onChanged;
  void Function(bool failed)? onFailure;

  static Future<void> _registerFonts(String family, List<ByteData> faces) async {
    final loader = FontLoader(family);
    for (final face in faces) {
      loader.addFont(Future.value(face));
    }
    await loader.load();
  }

  Future<FontSubsetCatalog> catalog(String region) => _catalogs.putIfAbsent(region, () async {
    try {
      return FontSubsetCatalog(
        jsonDecode(await _bundle.loadString('assets/fonts/subsets/$region.json')) as Map<String, dynamic>,
      );
    } catch (_) {
      _catalogs.remove(region);
      rethrow;
    }
  });

  static String family(String region, int index) => index == 0 ? 'Dify CJK $region' : 'Dify CJK $region shard $index';
  List<String> get families => activeRegion == null
      ? const []
      : [
          for (final index in (_loaded[activeRegion] ?? {}).toList()..sort()) family(activeRegion!, index),
        ];

  Future<void> activate(String region, {required bool warmCore}) async {
    activeRegion = region;
    onFailure?.call(hasFailure);
    final catalog = await this.catalog(region);
    if (warmCore) await _load(region, catalog, 0);
    onChanged?.call();
  }

  Future<ByteData> _face(String path) => _faces.putIfAbsent(path, () async {
    try {
      return await _bundle.load(path);
    } catch (_) {
      _faces.remove(path);
      rethrow;
    }
  });

  Future<void> _load(String region, FontSubsetCatalog catalog, int index) async {
    if (_loaded[region]?.contains(index) ?? false) return;
    final key = '$region:$index';
    if (_blockedShards.contains(key)) throw StateError('Font shard needs retry');
    await _pending
        .putIfAbsent(key, () async {
          // Fetch both weights before registering either. Failure keeps the shard
          // retryable; it must not become a permanent successful cache entry.
          final faces = await Future.wait([
            for (final weight in ['Regular', 'Bold'])
              _face('assets/fonts/subsets/${(catalog.chunks[index][weight] as Map)['path']}'),
          ]);
          await _register(family(region, index), faces);
          (_loaded[region] ??= {}).add(index);
          // Do not retain a second compressed copy after Skia registered it. Keep
          // successful partner faces only when a failed pair still needs a retry.
          for (final weight in ['Regular', 'Bold']) {
            _faces.remove('assets/fonts/subsets/${(catalog.chunks[index][weight] as Map)['path']}');
          }
        })
        .catchError((Object error, StackTrace stack) {
          _blockedShards.add(key);
          Error.throwWithStackTrace(error, stack);
        })
        .whenComplete(() => _pending.remove(key));
  }

  Future<List<int>> ensure(Iterable<int> missing) async {
    final points = missing.toSet();
    final region = activeRegion;
    if (region == null) return points.toList();
    try {
      final catalog = await this.catalog(region);
      final needed = {
        for (final cp in points) ?catalog.chunkFor[cp],
      };
      await Future.wait([for (final index in needed) _load(region, catalog, index)]);
      _failures[region]?.removeAll(points);
      onFailure?.call(hasFailure);
      if (region == activeRegion) onChanged?.call();
      return points.where((cp) => !catalog.chunkFor.containsKey(cp)).toList();
    } catch (_) {
      (_failures[region] ??= {}).addAll(points);
      onFailure?.call(hasFailure);
      rethrow;
    }
  }
}
