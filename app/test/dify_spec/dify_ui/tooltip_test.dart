// dify-spec: packages/dify-ui/src/tooltip/__tests__/index.spec.tsx
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

const _trigger = SizedBox(width: 60, height: 20, child: Text('Trigger'));

void main() {
  group('TooltipContent', () {
    group('Placement and offsets', () {
      testWidgets('should use default top placement when placement is not provided', (t) async {
        await renderWithSafeViewport(t, const DifyTooltip(open: true, content: Text('Tooltip body'), child: _trigger));
        final p = positioner(t, find.text('Tooltip body'));
        expect((p.side, p.align), (DifySide.top, DifyAlign.center));
        final popup = t.getRect(find.byType(DifyTooltipSurface));
        final trigger = t.getRect(find.byWidget(_trigger));
        expect(popup.bottom, trigger.top - 8);
        expect(popup.center.dx, trigger.center.dx);
      });

      testWidgets('should apply custom placement when placement props are provided', (t) async {
        await renderWithSafeViewport(
          t,
          const DifyTooltip(
            open: true,
            placement: DifyPlacement.bottomStart,
            sideOffset: 16,
            alignOffset: 6,
            content: Text('Custom tooltip body'),
            child: _trigger,
          ),
        );
        final p = positioner(t, find.text('Custom tooltip body'));
        expect((p.side, p.align), (DifySide.bottom, DifyAlign.start));
        final popup = t.getRect(find.byType(DifyTooltipSurface));
        final trigger = t.getRect(find.byWidget(_trigger));
        expect(popup.top, trigger.bottom + 16);
        expect(popup.left, trigger.left + 6);
      });
    });
  });
}
