// dify-spec: web/app/components/workflow/panel/__tests__/panel-width.spec.ts
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('getPreviewPanelMaxWidth', () {
    test('uses the caller fallback before canvas width is measured (%s)', () {
      for (final canvasWidth in [null, 0.0]) {
        expect(getPreviewPanelMaxWidth(canvasWidth, false), 1024);
        expect(getPreviewPanelMaxWidth(canvasWidth, true, 720), 720);
      }
    });

    test('reserves space for the canvas and an open node panel (selected: \$hasSelectedNode)', () {
      for (final (hasSelectedNode, expected) in [(false, 1000), (true, 600)]) {
        expect(getPreviewPanelMaxWidth(1400, hasSelectedNode), expected);
        expect(getPreviewPanelMaxWidth(1400, hasSelectedNode, 720), expected);
      }
    });

    test('keeps the preview usable on a \$canvasWidth px canvas (selected: \$hasSelectedNode)', () {
      for (final (canvasWidth, hasSelectedNode, expected) in [
        (600.0, false, 400),
        (800.0, false, 400),
        (801.0, false, 401),
        (1000.0, true, 400),
        (1200.0, true, 400),
        (1201.0, true, 401),
      ]) {
        expect(
          getPreviewPanelMaxWidth(canvasWidth, hasSelectedNode),
          expected,
          reason: '$canvasWidth $hasSelectedNode',
        );
      }
    });
  });
}
