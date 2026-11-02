// dify-sf phone layout (no Dify spec): the segmented control's touch size (mockup 2 "Steps | Canvas").
import 'phone_harness.dart';

const _segments = [
  (value: 'steps', label: 'Steps', child: DifySegmentLabel(icon: RemixIcon('list-unordered', size: 16), text: 'Steps')),
  (value: 'canvas', label: 'Canvas', child: DifySegmentLabel(icon: RemixIcon('flow-chart', size: 16), text: 'Canvas')),
];

void main() {
  group('DifySegmentedControl touch size', () {
    testWidgets('is 36 px with 30 px items and leading icons in a 48 px box; the regular size is unchanged', (t) async {
      await renderControl(
        t,
        const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DifySegmentedControl(
              key: ValueKey('touch'),
              value: 'steps',
              segments: _segments,
              size: DifySegmentedControlSize.touch,
            ),
            DifySegmentedControl(
              key: ValueKey('regular'),
              value: 'steps',
              segments: [
                (value: 'steps', label: 'Steps', child: DifyTextLine('Steps')),
                (value: 'canvas', label: 'Canvas', child: DifyTextLine('Canvas')),
              ],
            ),
          ],
        ),
      );
      expect(t.getSize(find.byKey(const ValueKey('touch'))).height, 48);
      final visual = find.descendant(
        of: find.byKey(const ValueKey('touch')),
        matching: find.byWidgetPredicate(
          (w) =>
              w is Container &&
              (w.decoration as BoxDecoration?)?.color == DifyColors.componentsSegmentedControlBgNormal,
        ),
      );
      expect(t.getSize(visual).height, 36);
      expect(t.getSize(find.byKey(const ValueKey('regular'))).height, 32);
      final touchPills = find.descendant(
        of: find.byKey(const ValueKey('touch')),
        matching: find.byWidgetPredicate((w) => w is Container && w.decoration is DifyFocusDecoration),
      );
      for (final e in touchPills.evaluate()) {
        expect(t.getSize(find.byWidget(e.widget)).height, 30);
      }
      expect(find.byType(RemixIcon), findsNWidgets(2));
      RichText text(String s) => t.widget<RichText>(
        find
            .descendant(
              of: find.descendant(of: find.byKey(const ValueKey('touch')), matching: find.text(s)),
              matching: find.byType(RichText),
            )
            .first,
      );
      expect(text('Steps').text.style!.color, DifyColors.textPrimary);
      expect(text('Canvas').text.style!.color, DifyColors.textTertiary);
      final regular = t.widget<RichText>(
        find
            .descendant(
              of: find.descendant(of: find.byKey(const ValueKey('regular')), matching: find.text('Steps')),
              matching: find.byType(RichText),
            )
            .first,
      );
      expect(regular.text.style!.color, DifyColors.textAccentLightModeOnly);
    });

    testWidgets('every point of its 48 px box selects the segment under the finger', (t) async {
      final changes = <String>[];
      await renderControl(
        t,
        SizedBox(
          height: 100,
          child: Center(
            child: DifySegmentedControl(
              value: 'steps',
              segments: _segments,
              size: DifySegmentedControlSize.touch,
              onChanged: changes.add,
            ),
          ),
        ),
      );
      final box = t.getRect(find.byType(DifySegmentedControl<String>));
      expect(box.height, 48);
      final canvasX = t.getCenter(find.text('Canvas')).dx;
      await t.tapAt(Offset(canvasX, box.top + 7)); // the control's padding
      await t.tapAt(Offset(canvasX, box.top + 2)); // 4 px above the control, 2 px inside the box
      await t.tapAt(Offset(canvasX, box.bottom - 2)); // 4 px below it
      await t.tapAt(Offset(canvasX, box.bottom + 1)); // outside the box
      await t.pump();
      expect(changes, ['canvas', 'canvas', 'canvas']);
    });
  });
}
