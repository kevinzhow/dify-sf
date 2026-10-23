// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file. Local additions: ../../../../PATCHES.md.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:vector_graphics/src/listener.dart'
    show VectorGraphicsDecodeException;

import 'helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Future<List<int>> sample(String svg, int x, int y) async {
    final ui.Image image = await renderSvg(svg, size: 64);
    final Uint8List data = await pixels(image);
    final result = data.sublist(
      (y * image.width + x) * 4,
      (y * image.width + x) * 4 + 4,
    );
    image.dispose();
    return result;
  }

  const pattern =
      '<pattern id="p" width="1" height="1" patternContentUnits="objectBoundingBox">'
      '<rect width=".5" height="1" fill="red"/><rect x=".5" width=".5" height="1" fill="blue"/>'
      '</pattern>';
  test(
    'forward pattern references use the geometry of each differently sized target',
    () async {
      const svg =
          '<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64">'
          '<rect x="8" y="4" width="16" height="16" fill="url(#p)"/>'
          '<rect x="32" y="4" width="24" height="32" fill="url(#p)"/>'
          '<defs>$pattern</defs></svg>';
      expect(await sample(svg, 12, 12), <int>[255, 0, 0, 255]);
      expect(await sample(svg, 20, 12), <int>[0, 0, 255, 255]);
      expect(await sample(svg, 38, 20), <int>[255, 0, 0, 255]);
      expect(await sample(svg, 50, 20), <int>[0, 0, 255, 255]);
    },
  );
  test(
    'element rotation also rotates object-bounding-box pattern coordinates',
    () async {
      const svg =
          '<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64">'
          '<defs>$pattern</defs><rect width="20" height="10" transform="translate(60 0) rotate(90)" fill="url(#p)"/></svg>';
      expect(await sample(svg, 55, 5), <int>[255, 0, 0, 255]);
      expect(await sample(svg, 55, 15), <int>[0, 0, 255, 255]);
    },
  );
  test(
    'equal-sized targets with different transforms do not share a pattern shader',
    () async {
      const svg =
          '<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64">'
          '<defs>$pattern</defs><rect width="16" height="16" transform="translate(8 4)" fill="url(#p)"/>'
          '<rect width="16" height="16" transform="translate(48 4) rotate(90)" fill="url(#p)"/></svg>';
      expect(await sample(svg, 12, 12), <int>[255, 0, 0, 255]);
      expect(await sample(svg, 20, 12), <int>[0, 0, 255, 255]);
      expect(await sample(svg, 40, 8), <int>[255, 0, 0, 255]);
      expect(await sample(svg, 40, 16), <int>[0, 0, 255, 255]);
    },
  );
  test(
    'a patterned fill does not change later unpatterned fills sharing its paint',
    () async {
      const svg =
          '<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64">'
          '<defs>$pattern</defs><rect x="8" y="4" width="16" height="16" fill="url(#p)"/>'
          '<rect x="32" y="4" width="24" height="32" fill="white"/></svg>';
      expect(await sample(svg, 38, 20), <int>[255, 255, 255, 255]);
    },
  );
  for (final alpha in <bool>[false, true]) {
    test(
      'black mask uses ${alpha ? 'alpha' : 'luminance'} as declared',
      () async {
        final svg =
            '<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64">'
            '<defs><mask id="m" style="mask-type:${alpha ? 'alpha' : 'luminance'}"><rect width="64" height="64" fill="black"/></mask></defs>'
            '<rect width="64" height="64" fill="red" mask="url(#m)"/></svg>';
        expect(
          await sample(svg, 32, 32),
          alpha ? <int>[255, 0, 0, 255] : <int>[0, 0, 0, 0],
        );
      },
    );
  }

  String filtered(String primitives) =>
      '<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64">'
      '<defs><filter id="f" filterUnits="userSpaceOnUse" x="0" y="0" width="64" height="64" '
      'color-interpolation-filters="sRGB">$primitives</filter></defs>'
      '<rect x="24" y="24" width="16" height="16" fill="red" filter="url(#f)"/></svg>';

  test(
    'Gaussian blur spreads alpha outside the source and accepts independent axes',
    () async {
      final blurred = filtered('<feGaussianBlur stdDeviation="4 1"/>');
      expect((await sample(blurred, 21, 32))[3], greaterThan(10));
      expect((await sample(blurred, 32, 21))[3], lessThan(5));
      expect((await sample(blurred, 24, 32))[3], inExclusiveRange(100, 200));
      expect(
        await sample(filtered('<feGaussianBlur stdDeviation="0"/>'), 24, 32),
        <int>[255, 0, 0, 255],
      );
      await expectLater(
        sample(filtered('<feGaussianBlur stdDeviation="-1"/>'), 32, 32),
        throwsA(
          isA<VectorGraphicsDecodeException>().having(
            (e) => e.originalException,
            'cause',
            isFormatException,
          ),
        ),
      );
    },
  );

  for (final mode in <String>['multiply', 'screen']) {
    test('blend $mode combines named red and blue inputs in sRGB', () async {
      final svg = filtered(
        '<feFlood flood-color="red" result="r"/>'
        '<feFlood flood-color="blue" result="b"/><feBlend in="r" in2="b" mode="$mode"/>',
      );
      expect(
        await sample(svg, 32, 32),
        mode == 'screen' ? <int>[255, 0, 255, 255] : <int>[0, 0, 0, 255],
      );
    });
  }
  for (final entry in <String, List<int>>{
    'over': <int>[170, 0, 85, 192],
    'in': <int>[255, 0, 0, 64],
    'out': <int>[255, 0, 0, 64],
    'atop': <int>[128, 0, 128, 128],
    'xor': <int>[128, 0, 128, 128],
    'lighter': <int>[128, 0, 128, 255],
  }.entries) {
    test(
      'composite ${entry.key} preserves Porter-Duff colour and alpha',
      () async {
        final svg = filtered(
          '<feFlood flood-color="red" flood-opacity=".5" result="r"/>'
          '<feFlood flood-color="blue" flood-opacity=".5" result="b"/>'
          '<feComposite in="r" in2="b" operator="${entry.key}"/>',
        );
        final actual = await sample(svg, 32, 32);
        for (var channel = 0; channel < 4; channel++) {
          expect(actual[channel], closeTo(entry.value[channel], 1));
        }
      },
    );
  }
}
