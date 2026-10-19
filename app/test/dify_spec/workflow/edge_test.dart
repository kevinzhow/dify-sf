// dify-spec: web/app/components/workflow/utils/__tests__/edge.spec.ts
// dify-spec: web/app/components/workflow/__tests__/custom-edge.spec.tsx
// dify-spec: web/app/components/workflow/workflow-preview/components/__tests__/custom-edge.spec.tsx
//
// custom-edge.tsx's stroke is dify-sf's [customEdgeStroke] (both canvas renderers stroke edges with it): Dify's
// `url(#id)` is a gradient stroke from the source status colour to the target status colour.
import 'package:dify_sf_app/src/canvas/run_view.dart';
import 'package:dify_sf_app/src/design/dify_tokens.g.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('getEdgeColor', () {
    test('should return success color when status is Succeeded', () {
      expect(getEdgeColor('succeeded'), DifyColors.workflowLinkLineSuccessHandle);
    });

    test('should return error color when status is Failed', () {
      expect(getEdgeColor('failed'), DifyColors.workflowLinkLineErrorHandle);
    });

    test('should return failure color when status is Exception', () {
      expect(getEdgeColor('exception'), DifyColors.workflowLinkLineFailureHandle);
    });

    test('should return default running color when status is Running and not fail branch', () {
      expect(getEdgeColor('running'), DifyColors.workflowLinkLineHandle);
    });

    test('should return failure color when status is Running and is fail branch', () {
      expect(getEdgeColor('running', true), DifyColors.workflowLinkLineFailureHandle);
    });

    test('should return normal color when status is undefined', () {
      expect(getEdgeColor(), DifyColors.workflowLinkLineNormal);
    });

    test('should return normal color for other statuses', () {
      expect(getEdgeColor('waiting'), DifyColors.workflowLinkLineNormal);
      expect(getEdgeColor('not-start'), DifyColors.workflowLinkLineNormal);
    });
  });

  group('CustomEdge', () {
    test('should prefer the running stroke color when the edge is selected', () {
      final stroke = customEdgeStroke(
        const EdgeRunView(sourceStatus: 'succeeded', targetStatus: 'running'),
        selected: true,
      );
      expect(stroke.isGradient, isFalse);
      expect(stroke.start, DifyColors.workflowLinkLineHandle);
    });

    test('should use the fail-branch running color while the connected node is hovering', () {
      final stroke = customEdgeStroke(EdgeRunView.idle, connectedNodeIsHovering: true, isFailBranch: true);
      expect(stroke, EdgeStroke(DifyColors.workflowLinkLineFailureHandle));
    });

    test('should fall back to the default edge color when no highlight state is active', () {
      final stroke = customEdgeStroke(EdgeRunView.idle);
      expect(stroke, EdgeStroke(DifyColors.workflowLinkLineNormal));
      expect(stroke.opacity, 1);
      expect(stroke.dashed, isFalse);
    });
  });

  group('workflow preview custom edge', () {
    test('renders a gradient edge when both ends have finished statuses', () {
      final stroke = customEdgeStroke(
        const EdgeRunView(sourceStatus: 'succeeded', targetStatus: 'running', waiting: true),
      );
      expect(hasEdgeGradient(const EdgeRunView(sourceStatus: 'succeeded', targetStatus: 'running')), isTrue);
      expect(stroke.start, DifyColors.workflowLinkLineSuccessHandle);
      expect(stroke.end, DifyColors.workflowLinkLineHandle);
      expect(stroke.isGradient, isTrue);
      expect(stroke.opacity, 0.7);
      // The gradient runs from the source handle (t = 0) to the target handle (t = 1).
      expect(stroke.at(0), DifyColors.workflowLinkLineSuccessHandle.withValues(alpha: 0.7));
      expect(stroke.at(1), DifyColors.workflowLinkLineHandle.withValues(alpha: 0.7));
      // `_dimmed` (0.3) wins over `_waitingRun`; `_isTemp` dashes the stroke.
      final dimmed = customEdgeStroke(
        const EdgeRunView(sourceStatus: 'succeeded', targetStatus: 'failed', waiting: true),
        dimmed: true,
        isTemp: true,
      );
      expect(
        (dimmed.start, dimmed.end),
        (DifyColors.workflowLinkLineSuccessHandle, DifyColors.workflowLinkLineErrorHandle),
      );
      expect(dimmed.opacity, 0.3);
      expect(dimmed.dashed, isTrue);
    });

    test('prefers the running stroke color when the edge is selected', () {
      final stroke = customEdgeStroke(
        const EdgeRunView(sourceStatus: 'succeeded', targetStatus: 'succeeded'),
        selected: true,
      );
      expect(stroke, EdgeStroke(DifyColors.workflowLinkLineHandle));
    });
  });
}
