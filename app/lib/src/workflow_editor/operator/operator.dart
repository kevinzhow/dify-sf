/// Dify's workflow operator (operator/**, header/undo-redo.tsx, header/view-workflow-history.tsx and their
/// shortcuts) for [WorkflowEditor]:
///
/// ```dart
/// const options = OperatorOptions(onOrganize: ..., onExportImage: ...);
/// OperatorShortcuts(
///   history: controller.undo,
///   options: options,
///   child: WorkflowEditor(
///     controller: controller,
///     control: workflowControlBuilder(options),
///     operator: workflowOperatorBuilder(controller, options),
///   ),
/// )
/// ```
library;

import 'package:flutter/widgets.dart';

import '../../canvas/canvas_controller.dart';
import '../../editor/editor_controller.dart';
import 'actions.dart';
import 'control.dart';
import 'operator_bar.dart';

export 'action_bar.dart';
export 'actions.dart' show ExportImageFormat, OperatorActions, OperatorOptions, OperatorReadOnly;
export 'control.dart';
export 'mini_map.dart';
export 'operator_bar.dart';
export 'shortcuts.dart';
export 'undo_redo.dart';
export 'view_workflow_history.dart';
export 'zoom_in_out.dart';

/// [WorkflowEditor.control]: the left control bar.
Widget Function(BuildContext, CanvasController) workflowControlBuilder([
  OperatorOptions options = const OperatorOptions(),
]) =>
    (context, canvas) => WorkflowControl(canvas: canvas, options: options);

/// [WorkflowEditor.operator]: the bottom bar, with [editor]'s undo history; the minimap follows its document.
Widget Function(BuildContext, CanvasController) workflowOperatorBuilder(
  EditorController editor, [
  OperatorOptions options = const OperatorOptions(),
  Widget? variableTrigger,
  Widget? variableInspectPanel,
]) =>
    (context, canvas) => WorkflowOperator(
      canvas: canvas,
      history: editor.undo,
      graphChanges: editor,
      options: options,
      variableTrigger: variableTrigger,
      variableInspectPanel: variableInspectPanel,
    );
