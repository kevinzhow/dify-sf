import 'package:flutter/services.dart' hide UndoManager;
import 'package:flutter/widgets.dart';

import '../../canvas/canvas_controller.dart';
import '../../design/widgets/shortcut_kbd.dart' show DifyPlatform;
import '../../design/widgets/text_input_scope.dart';
import '../../editor/undo_manager.dart';
import '../store/store.dart';
import 'actions.dart';

/// A key of shortcuts/definitions.ts: [key] (or, for digits and punctuation, its US position [code], as TanStack
/// falls back to `event.code` when Shift changes the character), with exactly the modifiers [mod] (Cmd on a Mac,
/// Ctrl elsewhere) and [shift].
class _Hotkey {
  const _Hotkey(this.key, {this.code, this.mod = false, this.shift = false});
  final LogicalKeyboardKey key;
  final PhysicalKeyboardKey? code;
  final bool mod;
  final bool shift;

  bool accepts(KeyEvent e, HardwareKeyboard k, bool mac) =>
      (e.logicalKey == key || (code != null && e.physicalKey == code)) &&
      k.isShiftPressed == shift &&
      !k.isAltPressed &&
      (mac ? k.isMetaPressed : k.isControlPressed) == mod &&
      !(mac ? k.isControlPressed : k.isMetaPressed);
}

/// shortcuts/use-workflow-hotkeys.ts, for the operator's actions: undo Mod+Z, redo Mod+Y / Mod+Shift+Z, pointer V,
/// hand H, comment C (with collaboration), organize Mod+O, fit Mod+1, 100% Shift+1, 50% Shift+5, zoom out Mod+-,
/// zoom in Mod+=. Ignored while typing in a text field (`ignoreInputs`); undo and redo are off while the debug panel
/// is open or history shortcuts are disabled.
///
/// Wrap it around the [WorkflowEditor]: keys reach it from the focused canvas, toolbar or panel (it takes the focus
/// itself at first, as a page does). The canvas and the store live inside the editor; the operator's control and
/// bottom bars hand them over ([OperatorShortcutsTarget]), so one of them must be mounted.
class OperatorShortcuts extends StatefulWidget {
  const OperatorShortcuts({
    super.key,
    required this.history,
    this.options = const OperatorOptions(),
    this.autofocus = true,
    required this.child,
  });

  final UndoManager history;
  final OperatorOptions options;
  final bool autofocus;
  final Widget child;

  @override
  State<OperatorShortcuts> createState() => _OperatorShortcutsState();
}

class _OperatorShortcutsState extends State<OperatorShortcuts> {
  final _focus = FocusNode(debugLabel: 'OperatorShortcuts', skipTraversal: true);
  final _targets = <(CanvasController, WorkflowStore)>[];

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  static const _undo = _Hotkey(LogicalKeyboardKey.keyZ, mod: true);
  static const _redo = [
    _Hotkey(LogicalKeyboardKey.keyY, mod: true),
    _Hotkey(LogicalKeyboardKey.keyZ, mod: true, shift: true),
  ];

  static bool _typing() => difyFocusInTextInput();

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if ((e is! KeyDownEvent && e is! KeyRepeatEvent) || _targets.isEmpty || _typing()) return KeyEventResult.ignored;
    final (canvas, store) = _targets.last;
    final a = OperatorActions(canvas, store, history: widget.history, options: widget.options);
    final history = !store.showDebugAndPreviewPanel.value && store.historyShortcutsEnabled.value;
    final bindings = <(List<_Hotkey>, VoidCallback?)>[
      ([_undo], history ? a.historyBack : null),
      (_redo, history ? a.historyForward : null),
      ([const _Hotkey(LogicalKeyboardKey.keyH)], a.modeHand),
      ([const _Hotkey(LogicalKeyboardKey.keyV)], a.modePointer),
      ([const _Hotkey(LogicalKeyboardKey.keyC)], widget.options.collaborationEnabled ? a.modeComment : null),
      ([const _Hotkey(LogicalKeyboardKey.keyO, mod: true)], a.organize),
      (
        [const _Hotkey(LogicalKeyboardKey.digit1, code: PhysicalKeyboardKey.digit1, mod: true)],
        () => a.zoom((c) => c.fitView()),
      ),
      (
        [const _Hotkey(LogicalKeyboardKey.digit1, code: PhysicalKeyboardKey.digit1, shift: true)],
        () => a.zoom((c) => c.zoomTo(1)),
      ),
      (
        [const _Hotkey(LogicalKeyboardKey.digit5, code: PhysicalKeyboardKey.digit5, shift: true)],
        () => a.zoom((c) => c.zoomTo(0.5)),
      ),
      ([const _Hotkey(LogicalKeyboardKey.minus, code: PhysicalKeyboardKey.minus, mod: true)], () => a.zoomBy(-0.1)),
      ([const _Hotkey(LogicalKeyboardKey.equal, code: PhysicalKeyboardKey.equal, mod: true)], () => a.zoomBy(0.1)),
    ];
    final k = HardwareKeyboard.instance, mac = DifyPlatform.current == DifyPlatform.mac;
    for (final (keys, action) in bindings) {
      if (action == null || !keys.any((h) => h.accepts(e, k, mac))) continue;
      action();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) => _Scope(
    state: this,
    child: Focus(focusNode: _focus, autofocus: widget.autofocus, onKeyEvent: _onKey, child: widget.child),
  );
}

class _Scope extends InheritedWidget {
  const _Scope({required this.state, required super.child});
  final _OperatorShortcutsState state;

  @override
  bool updateShouldNotify(_Scope old) => old.state != state;
}

/// Hands the editor's canvas and store to the [OperatorShortcuts] above, for as long as it is mounted (the control
/// and bottom bars include it). Does nothing without [OperatorShortcuts].
class OperatorShortcutsTarget extends StatefulWidget {
  const OperatorShortcutsTarget({super.key, required this.canvas, required this.child});

  final CanvasController canvas;
  final Widget child;

  @override
  State<OperatorShortcutsTarget> createState() => _OperatorShortcutsTargetState();
}

class _OperatorShortcutsTargetState extends State<OperatorShortcutsTarget> {
  _OperatorShortcutsState? _shortcuts;
  (CanvasController, WorkflowStore)? _target;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _detach();
    _shortcuts = context.getInheritedWidgetOfExactType<_Scope>()?.state;
    _target = (widget.canvas, WorkflowStoreScope.of(context));
    _shortcuts?._targets.add(_target!);
  }

  void _detach() => _shortcuts?._targets.remove(_target);

  @override
  void didUpdateWidget(OperatorShortcutsTarget old) {
    super.didUpdateWidget(old);
    if (old.canvas != widget.canvas) didChangeDependencies();
  }

  @override
  void dispose() {
    _detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
