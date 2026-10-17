import 'package:flutter/widgets.dart';

import '../canvas/canvas_controller.dart';
import '../canvas/workflow_canvas.dart';
import '../editor/editor_controller.dart';

/// Dify's workflow editor page (components/workflow/index.tsx and workflow-app): the canvas filling the area, with
/// the header, the left control bar, the bottom operator bar and the right panels floating over it. The chrome only
/// talks to the canvas through [CanvasController] and to the document through [EditorController].
///
/// Slots are filled as the chrome is ported; an empty slot draws nothing.
class WorkflowEditor extends StatefulWidget {
  const WorkflowEditor({
    super.key,
    required this.controller,
    this.header,
    this.control,
    this.operator,
    this.panels,
  });

  final EditorController controller;

  /// header/index.tsx: `absolute top-7 left-0 z-10 flex h-0 w-full items-center justify-between px-3`.
  final WidgetBuilder? header;

  /// operator/control.tsx in `absolute top-0 left-0 z-10 flex w-12 items-center justify-center p-1 pl-2`, centred on
  /// the canvas height above the bottom panel.
  final Widget Function(BuildContext context, CanvasController canvas)? control;

  /// operator/index.tsx: `absolute inset-x-0 bottom-0 z-10 px-1`.
  final Widget Function(BuildContext context, CanvasController canvas)? operator;

  /// panel/index.tsx: `absolute top-14 right-0 bottom-1 z-10 flex`.
  final Widget Function(BuildContext context, CanvasController canvas)? panels;

  @override
  State<WorkflowEditor> createState() => _WorkflowEditorState();
}

class _WorkflowEditorState extends State<WorkflowEditor> {
  final canvas = CanvasController();

  @override
  void dispose() {
    canvas.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    return Stack(
      fit: StackFit.expand,
      children: [
        WorkflowCanvas(controller: w.controller, canvas: canvas),
        if (w.header != null)
          Positioned(
            top: 28,
            left: 0,
            right: 0,
            height: 0,
            child: OverflowBox(
              maxHeight: double.infinity,
              child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: w.header!(context)),
            ),
          ),
        if (w.control != null)
          Positioned(
            top: 0,
            left: 0,
            bottom: 0,
            width: 48,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
              child: Center(child: w.control!(context, canvas)),
            ),
          ),
        if (w.operator != null)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: w.operator!(context, canvas)),
          ),
        if (w.panels != null) Positioned(top: 56, right: 0, bottom: 4, child: w.panels!(context, canvas)),
      ],
    );
  }
}
