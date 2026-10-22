import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dify_sf_app/src/design/dify_theme.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('CSS focus ring leaves translucent and transparent control interiors untouched', (t) async {
    const boundaryKey = ValueKey('pixels');
    for (final background in [const Color(0x08000000), Colors.transparent]) {
      Future<ByteData> capture(bool focused) async {
        await t.pumpWidget(
          MaterialApp(
            theme: difyTheme(),
            home: Center(
              child: RepaintBoundary(
                key: boundaryKey,
                child: ColoredBox(
                  color: Colors.white,
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: SizedBox(
                      width: 100,
                      height: 32,
                      child: DifyButtonSurface(
                        look: DifyButtonLook(foreground: Colors.black, background: background),
                        radius: 8,
                        focused: focused,
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await t.pump();
        return (await t.runAsync(() async {
          final image = await t.renderObject<RenderRepaintBoundary>(find.byKey(boundaryKey)).toImage(pixelRatio: 1);
          final data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
          image.dispose();
          return data;
        }))!;
      }

      final before = await capture(false), after = await capture(true);
      List<int> pixel(ByteData data, int x, int y) => List.generate(4, (i) => data.getUint8((y * 108 + x) * 4 + i));
      expect(pixel(after, 54, 20), pixel(before, 54, 20), reason: 'the center must not become blue');
      expect(pixel(after, 2, 20), isNot(pixel(before, 2, 20)), reason: 'the outline paints outside the box');
      expect(pixel(after, 0, 20), pixel(before, 0, 20), reason: 'ring stays within its 2px CSS width');
    }
  });
}
