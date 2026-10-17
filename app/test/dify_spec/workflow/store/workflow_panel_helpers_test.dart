// dify-spec: web/app/components/workflow/nodes/_base/components/workflow-panel/__tests__/helpers.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('workflow-panel helpers', () {
    group('panel width helpers', () {
      test('should use the default max width when canvas width is unavailable', () {
        expect(getMaxNodePanelWidth(null, 120), 720);
      });

      test('should clamp width into the supported panel range', () {
        expect(clampNodePanelWidth(320, 800), 400);
        expect(clampNodePanelWidth(960, 800), 800);
        expect(clampNodePanelWidth(640, 800), 640);
      });

      test('should return a compressed width only when the canvas overflows', () {
        expect(getCompressedNodePanelWidth(500, 1500, 300), isNull);
        expect(getCompressedNodePanelWidth(900, 1200, 200), 600);
      });
    });
  });
}
