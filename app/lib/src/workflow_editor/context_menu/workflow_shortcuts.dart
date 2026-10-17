import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../canvas/canvas_controller.dart';
import '../../design/widgets/widgets.dart';
import '../../editor/editor_controller.dart';
import '../store/store.dart';
import 'workflow_actions.dart';

/// The menu actions' shortcuts of shortcuts/use-workflow-hotkeys.ts, page-wide while mounted and not typing
/// (TanStack's `ignoreInputs`): Delete/Backspace delete the box-selected nodes, else the selected edge, else the
/// selected node; Mod+C copies, Mod+V pastes at the pointer (both off while Debug and Preview is open), Mod+D
/// duplicates. Keys reach these before the focused widget (as Dify's document listeners do), so the canvas's own
/// Delete handling never runs while this is mounted.
///
/// Mount it inside the editor's [WorkflowStoreScope].
class WorkflowShortcuts extends StatefulWidget {
  const WorkflowShortcuts({
    super.key,
    required this.controller,
    required this.canvas,
    this.options = const WorkflowMenuOptions(),
    required this.child,
  });

  final EditorController controller;
  final CanvasController canvas;
  final WorkflowMenuOptions options;
  final Widget child;

  @override
  State<WorkflowShortcuts> createState() => _WorkflowShortcutsState();
}

class _WorkflowShortcutsState extends State<WorkflowShortcuts> {
  late WorkflowActions _actions;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addEarlyKeyEventHandler(_onKey);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _make();
  }

  @override
  void didUpdateWidget(WorkflowShortcuts old) {
    super.didUpdateWidget(old);
    _make();
  }

  void _make() => _actions = WorkflowActions(
    controller: widget.controller,
    canvas: widget.canvas,
    store: WorkflowStoreScope.of(context),
    options: widget.options,
  );

  @override
  void dispose() {
    FocusManager.instance.removeEarlyKeyEventHandler(_onKey);
    super.dispose();
  }

  KeyEventResult _onKey(KeyEvent e) {
    if (e is! KeyDownEvent || !mounted || !(ModalRoute.isCurrentOf(context) ?? true) || _typing()) {
      return KeyEventResult.ignored;
    }
    final keys = HardwareKeyboard.instance;
    final mac = DifyPlatform.current == DifyPlatform.mac;
    bool mod(LogicalKeyboardKey k) => SingleActivator(k, control: !mac, meta: mac).accepts(e, keys);
    final a = _actions;
    final debugOpen = a.store.showDebugAndPreviewPanel.value;
    if (const SingleActivator(LogicalKeyboardKey.delete).accepts(e, keys) ||
        const SingleActivator(LogicalKeyboardKey.backspace).accepts(e, keys)) {
      a.deleteSelection();
    } else if (mod(LogicalKeyboardKey.keyC) && !debugOpen) {
      a.copyNodes();
    } else if (mod(LogicalKeyboardKey.keyV) && !debugOpen) {
      unawaited(a.pasteNodes());
    } else if (mod(LogicalKeyboardKey.keyD)) {
      unawaited(a.duplicateNodes());
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  static bool _typing() {
    final ctx = FocusManager.instance.primaryFocus?.context;
    return ctx != null && (ctx.widget is EditableText || ctx.findAncestorWidgetOfExactType<EditableText>() != null);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
