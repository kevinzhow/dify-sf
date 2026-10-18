import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../dify_spec/workflow/hooks/editor_harness.dart';

void main() {
  testWidgets('double-click zooms about the pointer; Shift reverses and limits clamp', (t) async {
    final h = await EditorHarness.start(t, [node('a', x: 100, y: 100)]);
    final v = h.canvas.view;
    final at = const Offset(1000, 700);
    final local = at;
    v.scale = 0.7;
    final anchor = v.toCanvas(local);
    Future<void> twice() async {
      await t.tapAt(at, kind: PointerDeviceKind.mouse);
      await t.pump(const Duration(milliseconds: 60));
      await t.tapAt(at, kind: PointerDeviceKind.mouse);
      await t.pump(const Duration(milliseconds: 350));
    }

    await twice();
    expect(v.scale, closeTo(1.4, 1e-9));
    expect((v.toCanvas(local) - anchor).distance, lessThan(1e-8));
    await twice();
    expect(v.scale, 2);
    await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await twice();
    expect(v.scale, 1);
    await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await h.dispose(t);
  });

  testWidgets('a drag followed by a click is not a double-click', (t) async {
    final h = await EditorHarness.start(t, [node('a', x: 100, y: 100)]);
    final at = const Offset(1000, 700), scale = h.canvas.view.scale;
    await t.dragFrom(at, const Offset(50, 0));
    await t.pump(const Duration(milliseconds: 60));
    await t.tapAt(at);
    await t.pump(const Duration(milliseconds: 350));
    expect(h.canvas.view.scale, scale);
    await h.dispose(t);
  });
}
