import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/workflow_editor/features/features.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/app_fonts.dart';

void main() {
  testWidgets('a long feature title stays readable when its card narrows', (t) async {
    await useAppFonts();
    final width = ValueNotifier<double>(400);
    addTearDown(width.dispose);
    final changes = <bool>[];
    const title = 'Citations and Attributions';
    await t.pumpWidget(
      MaterialApp(
        home: Material(
          child: SingleChildScrollView(
            child: Align(
              alignment: Alignment.topLeft,
              child: ValueListenableBuilder<double>(
                valueListenable: width,
                builder: (context, value, _) => SizedBox(
                  width: value,
                  child: FeatureCard(
                    icon: const SizedBox(width: 25, height: 25),
                    title: title,
                    value: false,
                    description: 'Show source document and attributed section of the generated content.',
                    onChange: changes.add,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    final wideHeight = t.getSize(find.byType(FeatureCard)).height;
    // The original 320px page has a 255.5px card after its drawer/padding/border.
    width.value = 255.5;
    await t.pumpAndSettle();
    final paragraph = t.renderObject<RenderParagraph>(find.text(title));
    expect(paragraph.didExceedMaxLines, isFalse, reason: 'The original flex title wraps without a line clamp.');
    final boxes = paragraph.getBoxesForSelection(const TextSelection(baseOffset: 0, extentOffset: title.length));
    expect(boxes.map((box) => box.top).toSet().length, greaterThan(1));
    expect(t.getSize(find.byType(FeatureCard)).height, greaterThan(wideHeight));
    await t.tap(find.byType(DifySwitch));
    await t.pumpAndSettle();
    expect(changes, [true]);
    width.value = 400;
    await t.pumpAndSettle();
    expect(t.getSize(find.byType(FeatureCard)).height, wideHeight);
    expect(t.takeException(), isNull);
  });
}
