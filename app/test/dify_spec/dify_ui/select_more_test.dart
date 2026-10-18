// dify-spec: packages/dify-ui/src/select/__tests__/index.spec.tsx
import 'control_harness.dart';

void main() {
  group('Select wrappers', () {
    group('SelectContent', () {
      testWidgets('should keep long options inside a narrow viewport', (t) async {
        t.view.physicalSize = const Size(240, 500);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.reset);
        await renderControl(
          t,
          const DifySelect(
            value: 'one',
            popupWidth: 500,
            options: [
              (value: 'one', label: 'Option one'),
              (value: 'two', label: 'A very long option that must remain within a small popup viewport'),
            ],
          ),
        );
        await t.tap(find.byType(DifySelect<String>));
        await t.pump();
        await t.pump(const Duration(milliseconds: 250));
        final rect = t.getRect(find.byType(DifyMenuPopup));
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(240));
        expect(t.takeException(), isNull);
      });
      testWidgets('should preserve an explicit popup width when the viewport has enough space', (t) async {
        await renderControl(
          t,
          const DifySelect(
            value: 'one',
            popupWidth: 240,
            options: [(value: 'one', label: 'Option one'), (value: 'two', label: 'Option two')],
          ),
        );
        await t.tap(find.byType(DifySelect<String>));
        await t.pump();
        await t.pump(const Duration(milliseconds: 250));
        expect(t.getSize(find.byType(DifyMenuPopup)).width, 240);
      });
      testWidgets('should use positioning attributes when placement is not provided', (t) async {
        await renderControl(
          t,
          const DifySelect(
            value: 'one',
            options: [(value: 'one', label: 'Option one'), (value: 'two', label: 'Option two')],
          ),
        );
        await t.tap(find.byType(DifySelect<String>));
        await t.pump();
        await t.pump(const Duration(milliseconds: 250));
        final p = positioner(t, find.byType(DifyMenuPopup));
        expect((p.side, p.align), (DifySide.bottom, DifyAlign.start));
      });
      testWidgets('should preserve positioning attributes when placement props are provided', (t) async {
        await renderControl(
          t,
          const DifySelect(
            value: 'one',
            placement: DifyPlacement.rightStart,
            sideOffset: 12,
            options: [(value: 'one', label: 'Option one'), (value: 'two', label: 'Option two')],
          ),
        );
        await t.tap(find.byType(DifySelect<String>));
        await t.pump();
        await t.pump(const Duration(milliseconds: 250));
        final p = positioner(t, find.byType(DifyMenuPopup));
        expect((p.side, p.align), (DifySide.right, DifyAlign.start));
        expect(
          t.getRect(find.byType(DifyMenuPopup)).left,
          closeTo(t.getRect(find.byType(DifySelect<String>)).right + 12, 0.01),
        );
      });
    });
  });
}
