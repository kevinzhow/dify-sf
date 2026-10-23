import 'dart:math';

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../../canvas/canvas_controller.dart';
import '../../canvas/canvas_input.dart' show ControlMode;
import '../../editor/undo_manager.dart';
import '../../design/widgets/adaptive.dart';
import '../store/store.dart';
import 'actions.dart';
import 'mini_map.dart';
import 'shortcuts.dart';
import 'undo_redo.dart';
import 'zoom_in_out.dart';

/// operator/index.tsx: the bottom bar, with undo / redo / change history on the left, [variableTrigger] in the
/// middle, and the zoom control with the minimap above it on the right. As wide as the canvas left of the right
/// panel (at least 400 px) once both are measured; reports its size to the store (bottomPanelWidth / Height). Mount
/// it in [WorkflowEditor.operator] (see `workflowOperatorBuilder`), which adds the `px-1` around it.
class WorkflowOperator extends StatefulWidget {
  const WorkflowOperator({
    super.key,
    required this.canvas,
    required this.history,
    this.graphChanges,
    this.options = const OperatorOptions(),
    this.variableTrigger,
    this.variableInspectPanel,
  });

  final CanvasController canvas;
  final UndoManager history;

  /// Notifies when the nodes change (the EditorController), for the minimap.
  final Listenable? graphChanges;
  final OperatorOptions options;

  /// variable-inspect/trigger.tsx.
  final Widget? variableTrigger;

  /// variable-inspect/index.tsx, under the bar (so the bar, the minimap and the control bar move up while it is
  /// open). It draws its 4 px resize strip in the bottom of the bar's `pb-2`, which the bar gives up while the store
  /// shows the panel.
  final Widget? variableInspectPanel;

  /// The minimap's top above the bar: 73 px tall, `bottom-10` from the bottom of the zoom control's `relative` box,
  /// which the row stretches to its tallest item: the undo / redo bar's 37 px (32 px buttons, p-0.5, the border).
  static const miniMapRise = 73.0 + 40 - 37;

  @override
  State<WorkflowOperator> createState() => _WorkflowOperatorState();
}

class _WorkflowOperatorState extends State<WorkflowOperator> {
  bool _showMiniMap = true;

  @override
  Widget build(BuildContext context) {
    final store = WorkflowStoreScope.of(context);
    final a = OperatorActions(widget.canvas, store, history: widget.history, options: widget.options);
    final compact = DifyAdaptive.compactOf(context);
    final controls = <Widget>[
      UndoRedo(history: widget.history, onUndo: a.historyBack, onRedo: a.historyForward),
      if (widget.variableTrigger != null) SizedBox(height: 36, child: Center(child: widget.variableTrigger)),
      ListenableBuilder(
        listenable: Listenable.merge([store.showUserComments, store.showUserCursors, store.controlMode]),
        builder: (context, _) => ZoomInOut(
          canvas: widget.canvas,
          options: widget.options,
          showMiniMap: _showMiniMap,
          onToggleMiniMap: () => setState(() => _showMiniMap = !_showMiniMap),
          showUserComments: store.showUserComments.value,
          onToggleUserComments: () => store.setShowUserComments(!store.showUserComments.value),
          showUserCursors: store.showUserCursors.value,
          onToggleUserCursors: () => store.setShowUserCursors(!store.showUserCursors.value),
          isCommentMode: store.controlMode.value == ControlMode.comment,
        ),
      ),
    ];
    final bar = _SizeReporter(
      // The editor's px-1 is outside this widget; Dify measures the element with it.
      onSize: (size) => store
        ..setBottomPanelWidth(size.width + 8)
        ..setBottomPanelHeight(size.height),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ValueListenableBuilder(
            valueListenable: store.showVariableInspectPanel,
            builder: (context, open, child) => Padding(
              padding: EdgeInsets.fromLTRB(4, 0, 4, open && widget.variableInspectPanel != null ? 4 : 8),
              child: child,
            ),
            child: LayoutBuilder(
              builder: (context, constraints) => constraints.maxWidth < 480
                  ? Wrap(alignment: WrapAlignment.spaceBetween, spacing: 8, runSpacing: 4, children: controls)
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: controls,
                    ),
            ),
          ),
          ?widget.variableInspectPanel,
        ],
      ),
    );
    return OperatorShortcutsTarget(
      canvas: widget.canvas,
      child: ListenableBuilder(
        listenable: Listenable.merge([store.workflowCanvasWidth, store.rightPanelWidth]),
        builder: (context, child) {
          final canvasWidth = store.workflowCanvasWidth.value ?? 0, rightWidth = store.rightPanelWidth.value ?? 0;
          // 'auto' until both are known.
          final width = compact
              ? null
              : canvasWidth == 0 || rightWidth == 0
              ? null
              : max(canvasWidth - rightWidth, 400.0) - 8;
          return Align(
            alignment: Alignment.bottomLeft,
            child: SizedBox(width: width, child: child),
          );
        },
        // The minimap sits above the bar (absolute in Dify); the space is kept here so it gets pointer events.
        child: Stack(
          children: [
            Padding(
              padding: EdgeInsets.only(top: _showMiniMap ? WorkflowOperator.miniMapRise : 0),
              child: bar,
            ),
            if (_showMiniMap)
              Positioned(
                top: 0,
                right: 4,
                child: WorkflowMiniMap(canvas: widget.canvas, graphChanges: widget.graphChanges ?? widget.canvas.view),
              ),
          ],
        ),
      ),
    );
  }
}

/// Dify's ResizeObserver on the bottom panel: reports the child's size after layout when it changed.
class _SizeReporter extends SingleChildRenderObjectWidget {
  const _SizeReporter({required this.onSize, required super.child});
  final ValueChanged<Size> onSize;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderSizeReporter(onSize);

  @override
  void updateRenderObject(BuildContext context, _RenderSizeReporter renderObject) => renderObject.onSize = onSize;
}

class _RenderSizeReporter extends RenderProxyBox {
  _RenderSizeReporter(this.onSize);
  ValueChanged<Size> onSize;
  Size? _reported;

  @override
  void performLayout() {
    super.performLayout();
    if (size == _reported) return;
    _reported = size;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (attached) onSize(size);
    });
  }
}
