import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/cards/card_kit.dart';
import 'package:dify_sf_app/src/cards/class_name_popover.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/app_fonts.dart';

void main() {
  setUp(useAppFonts);
  testWidgets('hover reveals the full class, remains open over content, and Escape dismisses it', (t) async {
    const title = 'A long classifier topic with enough words to pass the fifty character truncation boundary';
    final ctx = BodyContext(
      const Node(id: 'classifier', type: 'question-classifier', title: 'Classifier'),
      (_) => null,
    );
    await t.pumpWidget(
      MaterialApp(
        home: Material(
          child: Center(
            child: SizedBox(
              width: 220,
              height: 24,
              child: ClassNamePopover(text: title, ctx: ctx, child: const Text('truncated class...')),
            ),
          ),
        ),
      ),
    );
    final full = find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText().replaceAll('\u200B', '') == title);
    expect(full, findsNothing);
    final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(t.getCenter(find.text('truncated class...')));
    await t.pumpAndSettle();
    expect(full, findsNWidgets(2));
    await mouse.moveTo(t.getCenter(full.last));
    await t.pump(const Duration(milliseconds: 300));
    expect(full, findsNWidgets(2));
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
    expect(full, findsNothing);
    await mouse.removePointer();
    await t.pumpWidget(const SizedBox());
  });
}
