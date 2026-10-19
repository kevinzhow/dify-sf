import 'dart:async';
import 'dart:ui' show ViewFocusEvent, ViewFocusState;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../active_page.dart';
import '../../canvas/canvas_controller.dart';
import '../../design/widgets/widgets.dart';
import '../../editor/editor_controller.dart';
import '../store/store.dart';
import 'workflow_actions.dart';

/// hotkeys.ts `shouldPreventWorkflowBrowserDefault`: exactly Mod+D, Mod+Z, Mod+Y, Mod+Shift+Z or Mod+S (Mod is Cmd on
/// a Mac, Ctrl elsewhere), whose browser default the editor suppresses.
bool shouldPreventWorkflowBrowserDefault({
  required LogicalKeyboardKey key,
  bool control = false,
  bool meta = false,
  bool shift = false,
  bool alt = false,
  required bool mac,
}) {
  final mod = mac ? meta && !control : control && !meta;
  if (!mod || alt) return false;
  if (key == LogicalKeyboardKey.keyZ) return true; // Mod+Z, Mod+Shift+Z
  return !shift && {LogicalKeyboardKey.keyD, LogicalKeyboardKey.keyY, LogicalKeyboardKey.keyS}.contains(key);
}

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

class _WorkflowShortcutsState extends State<WorkflowShortcuts> with WidgetsBindingObserver {
  late WorkflowActions _actions;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addEarlyKeyEventHandler(_onKey);
    WidgetsBinding.instance.addObserver(this);
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
    WidgetsBinding.instance.removeObserver(this);
    widget.canvas.dimming.value = null;
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _actions.undimAllNodes();
  }

  @override
  void didChangeViewFocus(ViewFocusEvent event) {
    if (event.state == ViewFocusState.unfocused) _actions.undimAllNodes();
  }

  KeyEventResult _onKey(KeyEvent e) {
    // An app detail page other than the editor is on screen (the editor stays alive behind it).
    if (!mounted || !ActivePage.isActive(context)) return KeyEventResult.ignored;
    if (e.logicalKey == LogicalKeyboardKey.shiftLeft || e.logicalKey == LogicalKeyboardKey.shiftRight) {
      if (e is KeyUpEvent && !HardwareKeyboard.instance.isShiftPressed) _actions.undimAllNodes();
      if (e is KeyDownEvent && !_typing() && (ModalRoute.isCurrentOf(context) ?? true)) _actions.dimOtherNodes();
      return KeyEventResult.ignored;
    }
    if (e is! KeyDownEvent || !(ModalRoute.isCurrentOf(context) ?? true)) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    final mac = DifyPlatform.current == DifyPlatform.mac;
    // index.tsx's keydown guard: the browser's own Mod+S (save page) and Mod+D (bookmark) never run in the editor,
    // not even while typing (a handled key is not passed on to the browser).
    final guarded = shouldPreventWorkflowBrowserDefault(
      key: e.logicalKey,
      control: keys.isControlPressed,
      meta: keys.isMetaPressed,
      shift: keys.isShiftPressed,
      alt: keys.isAltPressed,
      mac: mac,
    );
    final browserOnly = guarded && (e.logicalKey == LogicalKeyboardKey.keyS || e.logicalKey == LogicalKeyboardKey.keyD);
    if (_typing()) return browserOnly ? KeyEventResult.handled : KeyEventResult.ignored;
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
      return browserOnly ? KeyEventResult.handled : KeyEventResult.ignored;
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
