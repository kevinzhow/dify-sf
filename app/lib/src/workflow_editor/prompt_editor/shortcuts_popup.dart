/// The prompt editor's shortcut popups (base/prompt-editor/plugins/shortcuts-popup-plugin): a hotkey pressed while
/// the editor has focus opens a popup at the caret, or centred beside the workflow's right panel; Escape or a tap
/// outside closes it; what the popup inserts goes into the editor as a command.
library;

import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// `SHORTCUTS_EMPTY_CONTENT`: what a popup without content shows.
const shortcutsEmptyContent = 'shortcuts_empty_content';

/// Something a popup asks the editor to do (Dify's Lexical commands, dispatched through `onInsert`).
abstract class PromptEditorCommand {
  const PromptEditorCommand();
}

/// `INSERT_HITL_INPUT_BLOCK_COMMAND`: the form field [variableName] in a line of its own at the caret.
class InsertHitlInputBlockCommand extends PromptEditorCommand {
  const InsertHitlInputBlockCommand(this.variableName);
  final String variableName;
}

/// A command the caller handles itself (Dify: a command the caller registered on the editor): [handler] gets
/// [params].
class CallbackPromptEditorCommand<T> extends PromptEditorCommand {
  const CallbackPromptEditorCommand(this.handler, this.params);
  final void Function(T params) handler;
  final T params;

  void run() => handler(params);
}

/// `ShortcutPopupInsertHandler`: runs [command] in the editor, then closes the popup.
typedef ShortcutPopupInsertHandler = void Function(PromptEditorCommand command);

/// `ShortcutPopupDisplayMode`.
enum ShortcutPopupDisplayMode { selection, workflowPanelAdjacentCenter }

/// The parts of a key press a hotkey is matched against (KeyboardEvent `key` and its modifier flags).
typedef HotkeyEvent = ({String key, bool ctrl, bool meta, bool alt, bool shift});

/// A Flutter key press as a [HotkeyEvent] (the key's character, else its label).
HotkeyEvent hotkeyEventOf(KeyEvent e) {
  final kb = HardwareKeyboard.instance;
  final ch = e.character;
  final key = ch != null && ch.isNotEmpty && ch.codeUnitAt(0) >= 0x20 ? ch : e.logicalKey.keyLabel;
  return (key: key, ctrl: kb.isControlPressed, meta: kb.isMetaPressed, alt: kb.isAltPressed, shift: kb.isShiftPressed);
}

const _metaAliases = {'meta', 'cmd', 'command'};
const _ctrlAliases = {'ctrl'};
const _altAliases = {'alt', 'option'};
const _shiftAliases = {'shift'};

/// `matchHotkey`. [hotkey] is a string (`'mod+/'`), a list of tokens (`['mod', '/']`), a list of such lists (any
/// combo matches) or a function of the event. `mod` is Ctrl or Meta; a combo without a key matches its modifiers.
bool matchHotkey(HotkeyEvent e, Object? hotkey) {
  if (hotkey == null) return false;
  if (hotkey is bool Function(HotkeyEvent)) return hotkey(e);
  bool combo(List<String> tokens) {
    String? expected;
    var mod = false, ctrl = false, meta = false, alt = false, shift = false;
    for (final p in tokens.map((t) => t.toLowerCase().trim()).where((t) => t.isNotEmpty)) {
      if (p == 'mod') {
        mod = true;
      } else if (_ctrlAliases.contains(p)) {
        ctrl = true;
      } else if (_metaAliases.contains(p)) {
        meta = true;
      } else if (_altAliases.contains(p)) {
        alt = true;
      } else if (_shiftAliases.contains(p)) {
        shift = true;
      } else {
        expected = p;
      }
    }
    if (mod && !(e.meta || e.ctrl)) return false;
    if (ctrl && !e.ctrl) return false;
    if (meta && !e.meta) return false;
    if (alt && !e.alt) return false;
    if (shift && !e.shift) return false;
    if (expected != null) {
      final k = e.key.toLowerCase();
      if ((k == ' ' ? 'space' : k) != expected) return false;
    }
    return true;
  }

  if (hotkey is List) {
    if (hotkey.isNotEmpty && hotkey.first is List) return hotkey.any((c) => combo([for (final t in c as List) '$t']));
    return combo([for (final t in hotkey) '$t']);
  }
  if (hotkey is String) return combo(hotkey.toLowerCase().split('+'));
  return false;
}

/// One shortcut popup of the editor (`shortcutPopups[i]`): [builder] gets `close` and `onInsert`; without it the
/// popup shows [shortcutsEmptyContent].
class ShortcutPopup {
  const ShortcutPopup({
    this.hotkey = 'mod+/',
    this.displayMode = ShortcutPopupDisplayMode.selection,
    this.builder,
    this.onOpen,
    this.onClose,
  });

  final Object hotkey;
  final ShortcutPopupDisplayMode displayMode;
  final Widget Function(BuildContext context, VoidCallback close, ShortcutPopupInsertHandler onInsert)? builder;
  final VoidCallback? onOpen, onClose;
}

/// Marks the workflow's right panel (Dify's `[data-workflow-right-panel]`) for the popups placed beside it.
class WorkflowRightPanelScope extends InheritedWidget {
  const WorkflowRightPanelScope({super.key, required this.panelKey, required super.child});
  final GlobalKey panelKey;

  /// The right panel's rectangle in global coordinates, if one is around [context].
  static Rect? rectOf(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<WorkflowRightPanelScope>();
    final box = scope?.panelKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  @override
  bool updateShouldNotify(WorkflowRightPanelScope old) => old.panelKey != panelKey;
}

/// `getWorkflowPanelAdjacentPlacement` for a window of [window] size: 4 px left of the right panel (the window's
/// edge without one), centred in the height from the panel's top (56 without one) to 8 px above the bottom.
({double right, double top, double availableWidth, double availableHeight}) workflowPanelAdjacentPlacement(
  Size window,
  Rect? rightPanel,
) {
  const padding = 8.0, gap = 4.0;
  final rightBoundary = rightPanel != null && rightPanel.left > 0 ? rightPanel.left : window.width;
  final topBoundary = rightPanel?.top ?? 56;
  final bottomBoundary = window.height - padding;
  final availableWidth = math.max(0.0, rightBoundary - padding * 2);
  final availableHeight = math.max(0.0, bottomBoundary - topBoundary);
  return (
    right: math.max(padding, window.width - rightBoundary + gap),
    top: topBoundary + availableHeight / 2,
    availableWidth: availableWidth,
    availableHeight: availableHeight,
  );
}

/// The popup's box (`absolute rounded-xl bg-components-panel-bg-blur shadow-lg`, the content clipped inside
/// `max-w-(--shortcut-popup-max-width) max-h-(--shortcut-popup-max-height) overflow-hidden rounded-xl`).
class ShortcutPopupBox extends StatelessWidget {
  const ShortcutPopupBox({super.key, required this.maxWidth, required this.maxHeight, required this.child});
  final double maxWidth, maxHeight;
  final Widget child;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    key: const Key('shortcuts-popup'),
    constraints: BoxConstraints(maxWidth: maxWidth, maxHeight: maxHeight),
    child: ClipRRect(borderRadius: BorderRadius.circular(12), child: child),
  );
}
