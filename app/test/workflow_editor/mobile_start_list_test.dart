import 'package:dify_sf_app/src/design/dify_theme.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/core/start_panel.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/app_fonts.dart';

void main() {
  testWidgets('finger swipe scrolls start variables without reordering them', (t) async {
    await useAppFonts();
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    final changes = <List<Object?>>[];
    final values = List.generate(
      25,
      (i) => <String, Object?>{
        'variable': 'v$i',
        'label': 'Field $i',
        'type': 'text-input',
        'required': false,
      },
    );
    await t.pumpWidget(
      DifyApplication(
        theme: difyTheme(),
        home: Center(
          child: SizedBox(
            width: 390,
            height: 500,
            child: SingleChildScrollView(
              controller: scroll,
              child: StartVarList(readonly: false, list: values, onChange: (next, [change]) => changes.add(next)),
            ),
          ),
        ),
      ),
    );
    final row = find.byKey(const ValueKey('start-var-v6'));
    final finger = await t.startGesture(t.getCenter(row), kind: PointerDeviceKind.touch);
    for (var i = 0; i < 6; i++) {
      await finger.moveBy(const Offset(0, -24));
      await t.pump(const Duration(milliseconds: 15));
    }
    await finger.up();
    await t.pumpAndSettle();
    expect(changes, isEmpty, reason: 'an ordinary swipe must never mutate field order');
    expect(scroll.offset, greaterThan(100));
    await t.pumpWidget(const SizedBox());
  });
  for (final kind in [PointerDeviceKind.touch, PointerDeviceKind.mouse]) {
    testWidgets('$kind can still reorder a variable row', (t) async {
      await useAppFonts();
      final changes = <List<Object?>>[];
      final values = List.generate(
        8,
        (i) => <String, Object?>{'variable': 'v$i', 'label': 'Field $i', 'type': 'text-input', 'required': false},
      );
      await t.pumpWidget(
        DifyApplication(
          theme: difyTheme(),
          home: Center(
            child: SizedBox(
              width: 390,
              height: 500,
              child: SingleChildScrollView(
                child: StartVarList(readonly: false, list: values, onChange: (next, [change]) => changes.add(next)),
              ),
            ),
          ),
        ),
      );
      final from = t.getCenter(find.byKey(const ValueKey('start-var-v1')));
      final drag = await t.startGesture(from, kind: kind);
      if (kind == PointerDeviceKind.touch) await t.pump(const Duration(milliseconds: 600));
      for (var i = 1; i <= 6; i++) {
        await drag.moveTo(from + Offset(0, 20.0 * i));
        await t.pump(const Duration(milliseconds: 50));
      }
      await drag.up();
      await t.pumpAndSettle();
      expect(changes, hasLength(1));
      expect(changes.single, isNot(equals(values)));
      expect((changes.single.first as Map)['variable'], 'v0');
      await t.pumpWidget(const SizedBox());
    });
  }
}
