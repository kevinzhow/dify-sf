import 'dart:io';
import 'dart:ui' as ui;

import 'package:dify_sf_app/src/design/dify_tokens.g.dart';
import 'package:dify_sf_app/src/workflow_editor/features/features.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final dark in [false, true]) {
    testWidgets(
      'card body composites its fill once over the panel (${dark ? "dark" : "light"})',
      (t) async {
        final previous = DifyColors.isDark;
        DifyColors.useDark(dark);
        addTearDown(() => DifyColors.useDark(previous));
        t.view.devicePixelRatio = 1;
        t.view.physicalSize = const Size(400, 220);
        addTearDown(t.view.reset);
        final boundaryKey = GlobalKey();
        await t.pumpWidget(
          MaterialApp(
            home: Align(
              alignment: Alignment.topLeft,
              child: RepaintBoundary(
                key: boundaryKey,
                child: ColoredBox(
                  color: DifyColors.componentsPanelBgAlt,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(
                        width: 300,
                        child: FeatureCard(
                          icon: SizedBox(width: 32, height: 32),
                          title: '',
                          value: false,
                          child: SizedBox(height: 40),
                        ),
                      ),
                      // CSS's border color never paints under the interior fill.
                      // This small patch tests that compositing law, not UI parity.
                      SizedBox(
                        width: 32,
                        height: 32,
                        child: ColoredBox(
                          color: DifyColors.backgroundSectionBurn,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await t.pumpAndSettle();
        final boundary = t.renderObject<RenderRepaintBoundary>(
          find.byKey(boundaryKey),
        );
        final samples = await t.runAsync(() async {
          final image = await boundary.toImage();
          try {
            final bytes = (await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!;
            List<int> pixel(int x, int y) => [
              for (var channel = 0; channel < 4; channel++) bytes.getUint8((y * image.width + x) * 4 + channel),
            ];
            // Original mb-1 (4px) and p-3 (12px): sample the middle of bottom padding,
            // clear of text, the switch, corners and the two highlighted edges.
            final actual = pixel(150, boundary.size.height.floor() - 4 - 6);
            final once = pixel(316, 16);
            const evidenceDir = String.fromEnvironment(
              'DIFY_COMPOSITING_EVIDENCE',
            );
            if (evidenceDir.isNotEmpty) {
              final file = File('$evidenceDir/${dark ? "dark" : "light"}.png');
              if (file.existsSync()) {
                throw StateError('Choose a fresh evidence directory');
              }
              await file.parent.create(recursive: true);
              final png = (await image.toByteData(
                format: ui.ImageByteFormat.png,
              ))!;
              await file.writeAsBytes(png.buffer.asUint8List());
            }
            return (actual, once);
          } finally {
            image.dispose();
          }
        });
        expect(samples, isNotNull);
        final (actual, once) = samples!;
        expect(
          actual,
          once,
          reason: 'Only the top/left border may use the highlight. Interior RGBA must match one fill over its parent.',
        );
        expect(t.takeException(), isNull);
      },
    );
  }
}
