import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../active_page.dart';
import '../../design/widgets/widgets.dart';

/// header/hotkeys.ts and app-publisher/hotkeys.ts.
const testRunMenuHotkey = 'Alt+R';
const versionHistoryHotkey = 'Mod+Shift+H';
const appPublishHotkey = 'Mod+Shift+P';

/// Whether [event] is [hotkey] (TanStack's `Mod+Shift+H` form: exact modifiers, `Mod` is ⌘ on Mac and Ctrl elsewhere).
bool matchesHotkey(String hotkey, KeyEvent event, {DifyPlatform? platform}) {
  final parts = hotkey.split('+');
  final mac = (platform ?? DifyPlatform.current) == DifyPlatform.mac;
  final want = <String>{for (final m in parts.take(parts.length - 1)) m == 'Mod' ? (mac ? 'Meta' : 'Control') : m};
  final k = HardwareKeyboard.instance;
  final have = <String>{
    if (k.isControlPressed) 'Control',
    if (k.isAltPressed) 'Alt',
    if (k.isShiftPressed) 'Shift',
    if (k.isMetaPressed) 'Meta',
  };
  return want.length == have.length &&
      want.containsAll(have) &&
      event.logicalKey.keyLabel.toUpperCase() == parts.last.toUpperCase();
}

/// Whether the focus is in a text field (TanStack's `ignoreInputs`).
bool focusInTextInput() {
  final ctx = FocusManager.instance.primaryFocus?.context;
  if (ctx == null) return false;
  if (ctx.widget is EditableText) return true;
  return ctx.findAncestorWidgetOfExactType<EditableText>() != null;
}

/// TanStack's `useHotkey(hotkey, callback, { ignoreInputs })`: a page-wide shortcut while this widget is mounted.
/// [enabled] false leaves the key to others.
class PageHotkey extends StatefulWidget {
  const PageHotkey({
    super.key,
    required this.hotkey,
    required this.onPressed,
    this.ignoreInputs = true,
    this.enabled = true,
    required this.child,
  });

  final String hotkey;
  final VoidCallback onPressed;
  final bool ignoreInputs;
  final bool enabled;
  final Widget child;

  @override
  State<PageHotkey> createState() => _PageHotkeyState();
}

class _PageHotkeyState extends State<PageHotkey> {
  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handle);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handle);
    super.dispose();
  }

  bool _handle(KeyEvent e) {
    if (e is! KeyDownEvent || !widget.enabled || !matchesHotkey(widget.hotkey, e)) return false;
    if (!ActivePage.isActive(context)) return false;
    if (widget.ignoreInputs && focusInTextInput()) return false;
    widget.onPressed();
    return true;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
