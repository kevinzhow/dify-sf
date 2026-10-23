// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file. Local additions: ../../../../PATCHES.md.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:vector_graphics/src/filters/filter_context.dart';
import 'package:vector_graphics/src/filters/filter_executor.dart';
import 'package:vector_graphics_codec/vector_graphics_codec.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'a bounded shadow graph preserves vector foreground edges at a fractional display offset',
    () async {
      final sourceRecorder = ui.PictureRecorder();
      ui.Canvas(sourceRecorder).drawRect(
        const ui.Rect.fromLTWH(2, 1, 188, 128),
        ui.Paint()..color = const ui.Color(0xffffffff),
      );
      final source = sourceRecorder.endRecording();
      final context = FilterContext(
        VectorFilter(
          'filter',
          const <String, String>{
            'filterUnits': 'userSpaceOnUse',
            'x': '0',
            'y': '0',
            'width': '192',
            'height': '132',
            'color-interpolation-filters': 'sRGB',
          },
          <VectorFilter>[
            VectorFilter('feColorMatrix', const <String, String>{
              'in': 'SourceGraphic',
              'result': 'transparent',
              'values': '1 0 0 0 0 0 1 0 0 0 0 0 1 0 0 0 0 0 0 0',
            }),
            VectorFilter('feBlend', const <String, String>{
              'in': 'SourceGraphic',
              'in2': 'transparent',
            }),
          ],
        ),
        source,
        const ui.Rect.fromLTWH(2, 1, 188, 128),
        const ui.Size(192, 132),
        rasterScale: 80 / 192,
        sourceReplayCost: 9,
      );
      Future<Uint8List> render(ui.Picture content) async {
        final recorder = ui.PictureRecorder();
        ui.Canvas(recorder)
          ..drawColor(const ui.Color(0xff101828), ui.BlendMode.src)
          ..translate(0, 12.5)
          ..scale(80 / 192)
          ..drawPicture(content);
        final picture = recorder.endRecording();
        final image = await picture.toImage(80, 80);
        final bytes = (await image.toByteData())!.buffer.asUint8List();
        image.dispose();
        picture.dispose();
        return bytes;
      }

      try {
        final expected = await render(source);
        final result = executeFilter(context);
        final actual = await render(result.picture);
        expect(context.requiresRasterResolution, isTrue);
        for (var i = 0; i < actual.length; i++) {
          expect(
            (actual[i] - expected[i]).abs(),
            lessThanOrEqualTo(16),
            reason: 'channel $i',
          );
        }
      } finally {
        context.dispose();
      }
    },
  );
}
