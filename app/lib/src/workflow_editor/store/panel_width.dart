/// Dify's panel size limits: nodes/_base/components/workflow-panel/helpers.tsx (node panel), panel/panel-width.ts
/// (debug/preview panel), variable-inspect/index.tsx (variable inspect panel height). Sizes in logical pixels;
/// a null canvas size means "not measured yet".
library;

import 'dart:math';

const minNodePanelWidth = 400.0;
const defaultMaxNodePanelWidth = 720.0;

const minPreviewPanelWidth = 400.0;
const minVariableInspectPanelHeight = 120.0;

/// operator/index.tsx: the bottom panel's minimum width (the layout slice's comment).
const minBottomPanelWidth = 400.0;

/// The widest the node panel may be: what the canvas leaves after the other panel and the canvas width kept visible
/// ([reservedCanvasWidth], 400), never below the minimum; 720 before the canvas is measured.
double getMaxNodePanelWidth(
  double? workflowCanvasWidth,
  double? otherPanelWidth, [
  double reservedCanvasWidth = minNodePanelWidth,
]) {
  if (workflowCanvasWidth == null || workflowCanvasWidth == 0) return defaultMaxNodePanelWidth;
  final available = workflowCanvasWidth - (otherPanelWidth ?? 0) - reservedCanvasWidth;
  return max(available, minNodePanelWidth);
}

double clampNodePanelWidth(double width, double maxNodePanelWidth) =>
    max(minNodePanelWidth, min(width, maxNodePanelWidth));

/// The width the node panel shrinks to when the canvas is too narrow for it (not persisted); null when it fits or
/// the canvas is not measured.
double? getCompressedNodePanelWidth(
  double nodePanelWidth,
  double? workflowCanvasWidth,
  double? otherPanelWidth, [
  double reservedCanvasWidth = minNodePanelWidth,
]) {
  if (workflowCanvasWidth == null || workflowCanvasWidth == 0) return null;
  final total = nodePanelWidth + (otherPanelWidth ?? 0) + reservedCanvasWidth;
  if (total <= workflowCanvasWidth) return null;
  return clampNodePanelWidth(
    workflowCanvasWidth - (otherPanelWidth ?? 0) - reservedCanvasWidth,
    getMaxNodePanelWidth(workflowCanvasWidth, otherPanelWidth, reservedCanvasWidth),
  );
}

/// The widest the debug/preview panel may be: keeps the canvas visible and lets an open node panel shrink to its
/// minimum; [fallback] before the canvas is measured (the panel passes 720).
double getPreviewPanelMaxWidth(double? workflowCanvasWidth, bool hasSelectedNode, [double fallback = 1024]) {
  if (workflowCanvasWidth == null || workflowCanvasWidth == 0) return fallback;
  final reservedWidth = 400.0 + (hasSelectedNode ? 400.0 : 0.0);
  return max(400.0, workflowCanvasWidth - reservedWidth);
}

/// The tallest the variable inspect panel may be: the canvas height less 60, at least 120; 480 before the canvas is
/// measured. The panel also shrinks a stored height that exceeds it.
double getVariableInspectPanelMaxHeight(double? workflowCanvasHeight) {
  if (workflowCanvasHeight == null || workflowCanvasHeight == 0) return 480.0;
  return max(minVariableInspectPanelHeight, workflowCanvasHeight - 60);
}
