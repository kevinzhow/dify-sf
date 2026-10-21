// Browser conformance probe for detached-layer captures and GPU texture upload.
// Build this entry point with --wasm, then watch for CAPTURE_RESULT in the console.
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_scene/scene.dart';

const count = 20;
final previews = ValueNotifier<List<ui.Image?>>(List.filled(count, null));
final controllers = List.generate(count, (_) => WidgetTextureController());
Size size(int n) => Size(337.0 + n * 17, 109.0 + n * 13);
double density(int n) => n.isEven ? 1.1473189387299816 : 1.29;

class Pattern extends CustomPainter {
  const Pattern(this.n);
  final int n;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawColor(const Color(0xfff4f6fa), BlendMode.src);
    canvas.drawRRect(
      RRect.fromRectAndRadius((Offset.zero & size).deflate(14), const Radius.circular(12)),
      Paint()..color = const Color(0xff2185c4),
    );
    final text = TextPainter(
      text: TextSpan(
        text: 'Captured card $n',
        style: const TextStyle(color: Color(0xff181d25), fontSize: 16),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    text.paint(canvas, const Offset(23, 26));
    text.dispose();
  }

  @override
  bool shouldRepaint(Pattern old) => old.n != n;
}

Future<void> inspect() async {
  var passed = 0;
  for (var n = 0; n < count; n++) {
    final texture = controllers[n].texture!;
    final gotImage = texture.asImage();
    final got = (await gotImage.toByteData(format: ui.ImageByteFormat.rawStraightRgba))!;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder)..scale(density(n));
    Pattern(n).paint(canvas, size(n));
    final picture = recorder.endRecording();
    final expectedImage = await picture.toImage(texture.width, texture.height);
    final expected = (await expectedImage.toByteData(format: ui.ImageByteFormat.rawStraightRgba))!;
    var different = 0;
    // Ignore a one-pixel edge where fractional capture bounds can clip a sample.
    for (var y = 1; y < texture.height - 1; y++) {
      for (var x = 1; x < texture.width - 1; x++) {
        final pixel = (y * texture.width + x) * 4;
        if (List.generate(4, (c) => (got.getUint8(pixel + c) - expected.getUint8(pixel + c)).abs()).reduce(math.max) >
            2) {
          different++;
        }
      }
    }
    // Antialiasing conversions at glyph edges may round by a few values.
    final ok = different < texture.width * texture.height * 0.001;
    if (ok) passed++;
    print('CAPTURE $n ${texture.width}x${texture.height} different=$different ok=$ok');
    expectedImage.dispose();
    gotImage.dispose();
    picture.dispose();
  }
  print('CAPTURE_RESULT $passed/$count');
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Scene.initializeStaticResources();
  runApp(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Stack(
        children: [
          ValueListenableBuilder<List<ui.Image?>>(
            valueListenable: previews,
            builder: (_, images, _) => Wrap(
              children: [
                for (final image in images)
                  if (image != null) SizedBox(width: 170, height: 100, child: RawImage(image: image)),
              ],
            ),
          ),
          for (var n = 0; n < count; n++)
            WidgetTexture(
              controller: controllers[n],
              width: size(n).width,
              height: size(n).height,
              pixelRatio: density(n),
              update: WidgetUpdatePolicy.manual,
              child: CustomPaint(painter: Pattern(n)),
            ),
        ],
      ),
    ),
  );
  WidgetsBinding.instance.addPostFrameCallback((_) async {
    final ready = controllers.map((controller) {
      final complete = Completer<void>();
      void landed() {
        if (controller.texture == null) return;
        controller.removeListener(landed);
        final index = controllers.indexOf(controller);
        final next = List<ui.Image?>.of(previews.value);
        next[index] = controller.texture!.asImage();
        previews.value = next;
        complete.complete();
      }

      controller.addListener(landed);
      controller.requestCapture();
      return complete.future;
    }).toList();
    await Future.wait(ready).timeout(const Duration(seconds: 60));
    await inspect();
  });
}
