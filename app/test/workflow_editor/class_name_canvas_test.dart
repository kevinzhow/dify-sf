import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/cards/bodies/llm_bodies.dart';
import 'package:dify_sf_app/src/cards/dify_cards.dart';
import 'package:dify_sf_app/src/cards/class_name_popover.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../dify_spec/workflow/hooks/editor_harness.dart';
import '../support/app_fonts.dart';

void main() {
  setUp(useAppFonts);
  testWidgets('classifier hover uses the live control layer shared by Scene and widget cards, following pan and zoom', (
    t,
  ) async {
    const title = 'A full classifier topic that exceeds fifty characters and must remain readable on the canvas';
    final h = await EditorHarness.start(t, [
      node(
        'qc',
        type: 'question-classifier',
        x: 200,
        y: 200,
        config: {
          'classes': Value.of([
            {'id': 'long', 'name': title},
            {'id': 'short', 'name': 'Short'},
          ]),
        },
      ),
    ]);
    final full = find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText().replaceAll('\u200B', '') == title);
    // The cached card has no popup of its own; exactly one real trigger is provided by CanvasControlLayer.
    expect(find.byType(ClassNamePopover), findsOneWidget);
    expect(find.byKey(const ValueKey('class-topic-qc-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('class-topic-qc-1')), findsNothing);
    final n = h.canvas.graph!['qc']!;
    final ctx = DifyCards.context(n.node.value, (_) => null, null);
    final topic = QuestionClassifierBody.topicBoxes(ctx).first.rect;
    final trigger = n.rect.topLeft + const Offset(1, 45) + topic.center;
    expect((t.getCenter(find.byKey(const ValueKey('class-topic-qc-0'))) - h.screen(trigger)).distance, lessThan(1e-6));
    final before = h.doc.toJson().toString();
    final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(h.screen(trigger));
    await t.pumpAndSettle();
    expect(full, findsNWidgets(2));
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
    expect(full, findsNothing);
    h.canvas.view
      ..scale = 0.8
      ..center = const Offset(550, 350);
    await t.pump();
    expect((t.getCenter(find.byKey(const ValueKey('class-topic-qc-0'))) - h.screen(trigger)).distance, lessThan(1e-6));
    await mouse.moveTo(Offset.zero);
    await t.pump(const Duration(milliseconds: 200));
    await mouse.moveTo(h.screen(trigger));
    await t.pumpAndSettle();
    expect(full, findsNWidgets(2));
    expect(h.doc.toJson().toString(), before);
    await mouse.removePointer();
    await h.dispose(t);
  });
}
