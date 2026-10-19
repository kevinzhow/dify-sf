/// `:focus-visible`, as one app-wide answer: true while the last input came from the keyboard.
///
/// Flutter's own [FocusManager.highlightMode] cannot answer this on a desktop or web page: a mouse event only
/// changes it for touch and stylus, so the mode stays at whatever the keyboard last set (and at the platform
/// default, traditional, before any input at all). A control that draws a ring for `focus-visible` would then show
/// it on a dialog that focused it programmatically after a click.
///
/// One listener for the whole app: any key event sets [keyboardFocusVisible], any pointer down clears it. Controls
/// read the notifier; see the Import DSL uploader's Browse button.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

abstract final class DifyInputMode {
  /// True while the keyboard is the last thing the user touched.
  static final ValueNotifier<bool> keyboardFocusVisible = ValueNotifier<bool>(false);

  static FocusManager? _keyHandlerOn;
  static bool _pointerRouteAdded = false;

  /// Installs the listeners, once per [FocusManager] (a test replaces it between cases; the app keeps one).
  static void ensureInstalled() {
    final manager = FocusManager.instance;
    if (!identical(_keyHandlerOn, manager)) {
      _keyHandlerOn = manager;
      manager.addEarlyKeyEventHandler(_onKey);
    }
    if (!_pointerRouteAdded) {
      _pointerRouteAdded = true;
      GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
    }
  }

  static KeyEventResult _onKey(KeyEvent event) {
    if (!keyboardFocusVisible.value) keyboardFocusVisible.value = true;
    return KeyEventResult.ignored;
  }

  static void _onPointer(PointerEvent event) {
    if (event is PointerDownEvent && keyboardFocusVisible.value) keyboardFocusVisible.value = false;
  }

  @visibleForTesting
  static void reset() => keyboardFocusVisible.value = false;
}
