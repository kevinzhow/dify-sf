import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../dify_tokens.g.dart';
import 'kbd.dart';

/// TanStack Hotkeys' platforms (`'mac' | 'windows' | 'linux'`).
enum DifyPlatform {
  mac,
  windows,
  linux;

  /// The running platform (TanStack's `detectPlatform`: Mac, Windows, else Linux).
  static DifyPlatform get current => switch (defaultTargetPlatform) {
    TargetPlatform.macOS || TargetPlatform.iOS => mac,
    TargetPlatform.windows => windows,
    _ => linux,
  };
}

/// The display hotkey of each workflow canvas shortcut (workflow/shortcuts/definitions.ts
/// `getWorkflowCanvasShortcutDisplayKey`: `displayHotkey`, else the first hotkey, else the hold key).
const difyWorkflowShortcuts = {
  'workflow.delete': 'Delete',
  'workflow.copy': 'Mod+C',
  'workflow.paste': 'Mod+V',
  'workflow.duplicate': 'Mod+D',
  'workflow.undo': 'Mod+Z',
  'workflow.redo': 'Mod+Y',
  'workflow.pointer-mode': 'V',
  'workflow.hand-mode': 'H',
  'workflow.comment-mode': 'C',
  'workflow.organize': 'Mod+O',
  'workflow.zoom-to-fit': 'Mod+1',
  'workflow.zoom-to-100': 'Shift+1',
  'workflow.zoom-to-50': 'Shift+5',
  'workflow.zoom-out': 'Mod+-',
  'workflow.zoom-in': 'Mod+=',
  'workflow.download-import-log': 'Mod+Shift+L',
  'workflow.dim-other-nodes': 'Shift',
};

// TanStack Hotkeys 0.8.0 constants.ts.
const _modifierAliases = {
  'Control': 'Control', 'Ctrl': 'Control', 'control': 'Control', 'ctrl': 'Control', //
  'Shift': 'Shift', 'shift': 'Shift',
  'Alt': 'Alt', 'Option': 'Alt', 'alt': 'Alt', 'option': 'Alt',
  'Command': 'Meta', 'Cmd': 'Meta', 'Meta': 'Meta', 'command': 'Meta', 'cmd': 'Meta', 'meta': 'Meta',
  'OS': 'Meta', 'os': 'Meta', 'Win': 'Meta', 'win': 'Meta',
  'CommandOrControl': 'Mod', 'Mod': 'Mod', 'commandorcontrol': 'Mod', 'mod': 'Mod',
};
const _modifierOrder = ['Control', 'Alt', 'Shift', 'Meta'];
const _macSymbols = {'Control': '⌃', 'Alt': '⌥', 'Shift': '⇧', 'Meta': '⌘', 'Mod': '⌘'};
const _windowsLabels = {'Control': 'Ctrl', 'Alt': 'Alt', 'Shift': 'Shift', 'Meta': 'Win', 'Mod': 'Ctrl'};
const _linuxLabels = {'Control': 'Ctrl', 'Alt': 'Alt', 'Shift': 'Shift', 'Meta': 'Super', 'Mod': 'Ctrl'};
const _keySymbols = {
  'ArrowUp': '↑', 'ArrowDown': '↓', 'ArrowLeft': '←', 'ArrowRight': '→', 'Enter': '↵', //
  'Escape': 'Esc', 'Backspace': '⌫', 'Delete': '⌦', 'Tab': '⇥', 'Space': '␣',
};
const _keyAliases = {
  'Esc': 'Escape', 'esc': 'Escape', 'escape': 'Escape', 'Return': 'Enter', 'return': 'Enter', 'enter': 'Enter', //
  ' ': 'Space', 'space': 'Space', 'Spacebar': 'Space', 'spacebar': 'Space', 'tab': 'Tab', 'backspace': 'Backspace',
  'Del': 'Delete', 'del': 'Delete', 'delete': 'Delete',
  'Up': 'ArrowUp', 'up': 'ArrowUp', 'arrowup': 'ArrowUp', 'Down': 'ArrowDown', 'down': 'ArrowDown',
  'arrowdown': 'ArrowDown', 'Left': 'ArrowLeft', 'left': 'ArrowLeft', 'arrowleft': 'ArrowLeft',
  'Right': 'ArrowRight', 'right': 'ArrowRight', 'arrowright': 'ArrowRight',
  'home': 'Home', 'end': 'End', 'pageup': 'PageUp', 'pagedown': 'PageDown', 'PgUp': 'PageUp', 'PgDn': 'PageDown',
  'pgup': 'PageUp', 'pgdn': 'PageDown',
};

String? _modifier(String s) => _modifierAliases[s] ?? _modifierAliases[s.toLowerCase()];

String _normalizeKey(String key) {
  if (key.isEmpty) return '';
  final alias = _keyAliases[key];
  if (alias != null) return alias;
  if (RegExp(r'^\p{L}$', unicode: true).hasMatch(key)) {
    final upper = key.toUpperCase();
    return upper.length == 1 ? upper : key;
  }
  final upper = key.toUpperCase();
  return RegExp(r'^F([1-9]|1[0-2])$').hasMatch(upper) ? upper : key;
}

/// TanStack Hotkeys' `formatForDisplay` (symbols on): `Mod+Shift+S` is `⌘ ⇧ S` on a Mac and `Ctrl+Shift+S`
/// elsewhere; special keys show as symbols (Delete `⌦`, Enter `↵`, Escape `Esc`, ...).
String formatHotkeyForDisplay(String hotkey, {DifyPlatform? platform}) {
  final p = platform ?? DifyPlatform.current;
  // parseHotkey: the last part is the key, the others modifiers.
  final parts = hotkey.split('+');
  final mods = <String>{};
  var key = '';
  for (var i = 0; i < parts.length; i++) {
    final part = parts[i].trim();
    if (i == parts.length - 1) {
      key = _normalizeKey(part);
    } else {
      final m = _modifier(part);
      if (m != null) mods.add(m == 'Mod' ? (p == DifyPlatform.mac ? 'Meta' : 'Control') : m);
    }
  }
  // normalizeHotkey: the platform's primary modifier collapses back to Mod.
  final canUseMod = p == DifyPlatform.mac
      ? mods.contains('Meta') && !mods.contains('Control')
      : mods.contains('Control') && !mods.contains('Meta');
  final segments = canUseMod
      ? ['Mod', if (mods.contains('Alt')) 'Alt', if (mods.contains('Shift')) 'Shift', _normalizeKey(key)]
      : [..._modifierOrder.where(mods.contains), _normalizeKey(key)];
  return segments
      .map((s) {
        final m = _modifier(s);
        if (m != null) {
          return switch (p) {
            DifyPlatform.mac => _macSymbols[m]!,
            DifyPlatform.windows => _windowsLabels[m]!,
            DifyPlatform.linux => _linuxLabels[m]!,
          };
        }
        return _keySymbols[s] ?? s;
      })
      .join(p == DifyPlatform.mac ? ' ' : '+');
}

/// Dify's ShortcutKbd (workflow/shortcuts/shortcut-kbd.tsx): a hotkey split on `+`, one [DifyKbd] per key, each
/// formatted for display. Give a workflow [shortcut] id, a [hotkey] (`Mod+Shift+L`) or a single [displayKey].
class DifyShortcutKbd extends StatelessWidget {
  const DifyShortcutKbd({
    super.key,
    this.shortcut,
    this.hotkey,
    this.displayKey,
    this.secondaryText = false,
    this.color = DifyKbdColor.gray,
    this.platform,
  }) : assert((shortcut != null ? 1 : 0) + (hotkey != null ? 1 : 0) + (displayKey != null ? 1 : 0) == 1);

  /// An id of [difyWorkflowShortcuts].
  final String? shortcut;
  final String? hotkey;
  final String? displayKey;

  /// `textColor="secondary"`: `text-text-tertiary` on any keycap colour.
  final bool secondaryText;

  /// `bgColor`.
  final DifyKbdColor color;
  final DifyPlatform? platform;

  /// The keycap labels this shows.
  List<String> get keys {
    if (displayKey != null) return [formatHotkeyForDisplay(displayKey!, platform: platform)];
    final h = hotkey ?? difyWorkflowShortcuts[shortcut];
    if (h == null) return const [];
    return [
      for (final k in h.split('+'))
        if (k.isNotEmpty) formatHotkeyForDisplay(k, platform: platform),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final labels = keys;
    if (labels.isEmpty) return const SizedBox.shrink();
    return DifyKbdGroup(
      children: [
        for (final k in labels) DifyKbd(k, color: color, textColor: secondaryText ? DifyColors.textTertiary : null),
      ],
    );
  }
}
