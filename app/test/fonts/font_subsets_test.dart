import 'dart:convert';
import 'dart:typed_data';

import 'package:dify_sf_app/src/design/font_subsets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _Fonts extends CachingAssetBundle {
  final requests = <String, int>{};
  String? fail;
  final index = {
    'codepoints': [
      [65, 20013],
      [0x20BB7],
    ],
    'chunks': [
      for (var i = 0; i < 2; i++)
        {
          'Regular': {'path': '$i-r.woff2'},
          'Bold': {'path': '$i-b.woff2'},
        },
    ],
  };
  @override
  Future<ByteData> load(String key) async {
    requests.update(key, (count) => count + 1, ifAbsent: () => 1);
    await Future<void>.delayed(Duration.zero);
    if (key == fail) throw StateError('synthetic offline');
    return Uint8List.fromList(key.endsWith('.json') ? utf8.encode(jsonEncode(index)) : [1, 2, 3]).buffer.asByteData();
  }
}

void main() {
  test('core preloads both weights, remaining glyph shards deduplicate concurrent misses', () async {
    final bundle = _Fonts(), registered = <String>[];
    final loader = FontSubsetLoader(
      bundle: bundle,
      register: (family, faces) async {
        expect(faces, hasLength(2));
        registered.add(family);
      },
    );
    await loader.activate('SC', warmCore: true);
    expect(registered, ['Dify CJK SC']);
    expect(bundle.requests.keys.any((key) => key.contains('1-')), false);
    final result = await Future.wait([
      loader.ensure([0x20BB7, 0x1F642]),
      loader.ensure([0x20BB7, 20013]),
    ]);
    expect(result, [
      [0x1F642],
      [],
    ]);
    expect(registered, ['Dify CJK SC', 'Dify CJK SC shard 1']);
    expect(bundle.requests.values, everyElement(1));
    expect(loader.families, registered);
  });
  test('failed shard remains retryable and registration waits for both weights', () async {
    final bundle = _Fonts()..fail = 'assets/fonts/subsets/1-b.woff2';
    final registered = <String>[], failures = <bool>[];
    final loader = FontSubsetLoader(
      bundle: bundle,
      register: (family, _) async {
        registered.add(family);
      },
    )..onFailure = failures.add;
    await loader.activate('JP', warmCore: false);
    expect(registered, isEmpty);
    await expectLater(loader.ensure([0x20BB7]), throwsStateError);
    expect(registered, isEmpty);
    expect(failures.last, true);
    bundle.fail = null;
    await expectLater(loader.ensure([0x20BB7]), throwsStateError);
    loader.retryFailed();
    expect(await loader.ensure([0x20BB7]), isEmpty);
    expect(registered, ['Dify CJK JP shard 1']);
    expect(failures.last, false);
    expect(bundle.requests['assets/fonts/subsets/1-b.woff2'], 2);
    expect(bundle.requests['assets/fonts/subsets/1-r.woff2'], 1);
    await loader.ensure([0x20BB7]);
    expect(bundle.requests['assets/fonts/subsets/1-b.woff2'], 2);
    expect(bundle.requests['assets/fonts/subsets/1-r.woff2'], 1);
  });
  test('locale activation replaces active family order without reloading earlier regions', () async {
    final bundle = _Fonts(), registered = <String>[];
    final loader = FontSubsetLoader(
      bundle: bundle,
      register: (family, _) async {
        registered.add(family);
      },
    );
    await loader.activate('SC', warmCore: true);
    await loader.ensure([0x20BB7]);
    await loader.activate('JP', warmCore: true);
    expect(loader.families, ['Dify CJK JP']);
    await loader.activate('SC', warmCore: true);
    expect(loader.families, ['Dify CJK SC', 'Dify CJK SC shard 1']);
    expect(registered.where((s) => s == 'Dify CJK SC'), hasLength(1));
  });
  test('an unrelated success or locale switch cannot clear a pending glyph failure', () async {
    final bundle = _Fonts()..fail = 'assets/fonts/subsets/1-b.woff2';
    final loader = FontSubsetLoader(bundle: bundle, register: (_, _) async {});
    await loader.activate('SC', warmCore: false);
    await expectLater(loader.ensure([0x20BB7]), throwsStateError);
    expect(loader.hasFailure, true);
    await loader.ensure([20013]);
    expect(loader.hasFailure, true);
    await loader.activate('JP', warmCore: false);
    expect(loader.hasFailure, false);
    await loader.activate('SC', warmCore: false);
    expect(loader.hasFailure, true);
    loader.reportExternalFailure(true);
    bundle.fail = null;
    await expectLater(loader.ensure([0x20BB7]), throwsStateError);
    loader.retryFailed();
    await loader.ensure([0x20BB7]);
    expect(loader.hasFailure, true);
    loader.reportExternalFailure(false);
    expect(loader.hasFailure, false);
  });
}
