/// The classifier's full topic popover. Its invisible trigger can be placed in the shared canvas control layer;
/// ordinary standalone cards use their visible topic as the same trigger.
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../design/widgets/floating.dart';
import '../design/widgets/popover.dart';
import 'card_kit.dart';

class ClassNamePopover extends StatefulWidget {
  const ClassNamePopover({super.key, required this.text, required this.ctx, required this.child});
  final String text;
  final BodyContext ctx;
  final Widget child;
  @override
  State<ClassNamePopover> createState() => _ClassNamePopoverState();
}

class _ClassNamePopoverState extends State<ClassNamePopover> {
  static _ClassNamePopoverState? _active;
  bool _open = false;
  Timer? _close;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addEarlyKeyEventHandler(_key);
  }

  KeyEventResult _key(KeyEvent event) {
    if (_open && event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape) {
      _set(false);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _set(bool open) {
    _close?.cancel();
    if (open) {
      if (_active != this) _active?._set(false);
      _active = this;
    } else if (_active == this) {
      _active = null;
    }
    if (mounted && _open != open) setState(() => _open = open);
  }

  void _show() => _set(true);
  void _leave() {
    _close?.cancel();
    _close = Timer(const Duration(milliseconds: 150), () => _set(false));
  }

  @override
  void dispose() {
    _close?.cancel();
    if (_active == this) _active = null;
    FocusManager.instance.removeEarlyKeyEventHandler(_key);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => DifyFloating(
    open: _open,
    onOpenChange: _set,
    focusPopup: false,
    sideOffset: 8,
    builder: (context, controller) => MouseRegion(
      onEnter: (_) => _show(),
      onExit: (_) => _leave(),
      child: Focus(
        onFocusChange: (focused) {
          if (focused) {
            _show();
          } else {
            _leave();
          }
        },
        onKeyEvent: (_, event) {
          if (event is KeyDownEvent &&
              (event.logicalKey == LogicalKeyboardKey.enter || event.logicalKey == LogicalKeyboardKey.space)) {
            _show();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Semantics(
          button: true,
          label: widget.text,
          child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: _show, child: widget.child),
        ),
      ),
    ),
    popupBuilder: (context) => MouseRegion(
      onEnter: (_) => _show(),
      onExit: (_) => _leave(),
      child: DifyPopoverSurface(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 300),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: InlineVarText(widget.text, widget.ctx, breakAll: true).build(),
          ),
        ),
      ),
    ),
  );
}
