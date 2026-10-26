import 'package:flutter/widgets.dart';

/// Marks an editor that owns a platform text input connection without requiring
/// EditableText (for example the native code editor). Page-wide shortcuts must
/// leave text editing commands to that editor, including in its focus overlays.
class DifyTextInputScope extends InheritedWidget {
  const DifyTextInputScope({super.key, required super.child});

  @override
  bool updateShouldNotify(DifyTextInputScope oldWidget) => false;
}

/// Shared equivalent of Dify's ignoreInputs guard. Follow focus ancestry as well
/// as widget ancestry: a selection menu can be rendered in a separate Overlay.
bool difyFocusInTextInput() {
  final focus = FocusManager.instance.primaryFocus;
  if (focus == null) return false;
  for (final node in [focus, ...focus.ancestors]) {
    final context = node.context;
    if (context == null) continue;
    if (context.widget is EditableText ||
        context.widget is DifyTextInputScope ||
        context.findAncestorWidgetOfExactType<EditableText>() != null ||
        context.findAncestorWidgetOfExactType<DifyTextInputScope>() != null) {
      return true;
    }
  }
  return false;
}
