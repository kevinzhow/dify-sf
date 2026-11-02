/// Keeps the focused text field and the page's primary action above the soft keyboard on full-window form pages
/// (sign-in, install, activation, password reset, server connection). A port of raft-flutter's
/// `RaftKeyboardScrollView` (docs/auth-keyboard.md there), on the widgets layer.
///
/// Flutter's EditableText scrolls its caret into view, but only the caret: on a phone the submit button under the
/// last field stays behind the keyboard. [DifyKeyboardScrollView] is the page's scroll view; the page spends the
/// keyboard inset on its own bottom padding (the viewport ends at the keyboard), and on keyboard, window and focus
/// changes this view reveals the focused field and the nearest [DifyPrimaryAction] below it together when both fit,
/// the field alone (at the top) when they do not. It moves only when something is hidden, so switching fields does
/// not jump.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Room kept around the revealed field (its label and frame) and the action.
const double _revealMargin = 16;

class _RevealScope extends InheritedWidget {
  const _RevealScope({required this.state, required super.child});
  final _DifyKeyboardScrollViewState state;

  @override
  bool updateShouldNotify(_RevealScope old) => state != old.state;
}

/// Marks the page's primary action (the submit button): the nearest [DifyKeyboardScrollView] keeps it above the
/// keyboard together with the focused field when both fit.
class DifyPrimaryAction extends StatefulWidget {
  const DifyPrimaryAction({super.key, required this.child});
  final Widget child;

  @override
  State<DifyPrimaryAction> createState() => _DifyPrimaryActionState();
}

class _DifyPrimaryActionState extends State<DifyPrimaryAction> {
  _DifyKeyboardScrollViewState? _scope;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = context.dependOnInheritedWidgetOfExactType<_RevealScope>()?.state;
    if (next == _scope) return;
    _scope?._actions.remove(context);
    _scope = next;
    _scope?._actions.add(context);
  }

  @override
  void dispose() {
    _scope?._actions.remove(context);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// A full-window form page's scroll view (a [SingleChildScrollView] around [child] with [padding]). See the library
/// comment. It reads the window's keyboard height only to know when to reveal; the caller shrinks the viewport.
class DifyKeyboardScrollView extends StatefulWidget {
  const DifyKeyboardScrollView({super.key, required this.child, this.padding});
  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  State<DifyKeyboardScrollView> createState() => _DifyKeyboardScrollViewState();
}

class _DifyKeyboardScrollViewState extends State<DifyKeyboardScrollView> with WidgetsBindingObserver {
  final _controller = ScrollController();
  final Set<BuildContext> _actions = {};
  double _inset = 0;
  Size _size = Size.zero;
  bool _scheduled = false, _animate = false;
  Timer? _settle;

  /// The keyboard height the window reports, in dp: from the view, not `MediaQuery` (a resizing layout above may
  /// have spent the inset already).
  double _keyboard() {
    final view = View.of(context);
    return view.viewInsets.bottom / view.devicePixelRatio;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    FocusManager.instance.addListener(_focusChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final inset = _keyboard(), size = MediaQuery.sizeOf(context);
    final opening = inset > _inset;
    final moved = inset != _inset || size != _size;
    _inset = inset;
    _size = size;
    if (moved && inset > 0) _schedule(animate: false, settle: !opening);
  }

  @override
  void didChangeMetrics() {
    if (!mounted) return;
    final inset = _keyboard(), size = MediaQuery.sizeOf(context);
    final moved = inset != _inset || size != _size;
    final opening = inset > _inset;
    _inset = inset;
    _size = size;
    // The viewport follows the keyboard frame by frame: no animation.
    if (moved && inset > 0) _schedule(animate: false, settle: !opening);
  }

  @override
  void dispose() {
    _settle?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    FocusManager.instance.removeListener(_focusChanged);
    _controller.dispose();
    super.dispose();
  }

  void _focusChanged() {
    if (_inset > 0) _schedule(animate: true, settle: true);
  }

  void _schedule({required bool animate, required bool settle}) {
    _animate = animate;
    if (!_scheduled) {
      _scheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scheduled = false;
        _reveal(_animate);
      });
    }
    _settle?.cancel();
    // EditableText scrolls its caret into view (100 ms) after a focus or inset change; one more pass once that has
    // finished makes this the last word about the action.
    if (settle) {
      _settle = Timer(const Duration(milliseconds: 180), () {
        if (mounted) _reveal(true);
      });
    }
  }

  void _reveal(bool animate) {
    if (!mounted || !_controller.hasClients || _keyboard() <= 0) return;
    final position = _controller.position;
    if (!position.hasPixels || !position.hasContentDimensions) return;
    final focusContext = FocusManager.instance.primaryFocus?.context;
    if (focusContext == null ||
        !focusContext.mounted ||
        focusContext.findAncestorStateOfType<EditableTextState>() == null) {
      return;
    }
    final field = focusContext.findRenderObject();
    if (field is! RenderBox || !field.attached || !field.hasSize) return;
    final viewport = RenderAbstractViewport.maybeOf(field);
    if (viewport == null || Scrollable.maybeOf(focusContext)?.position != position) return;

    double top(RenderBox box, EdgeInsets margin) =>
        viewport.getOffsetToReveal(box, 0, rect: margin.inflateRect(Offset.zero & box.size)).offset;
    double bottom(RenderBox box, EdgeInsets margin) =>
        viewport.getOffsetToReveal(box, 1, rect: margin.inflateRect(Offset.zero & box.size)).offset;

    const fieldMargin = EdgeInsets.symmetric(vertical: _revealMargin);
    // Offsets that show the whole field: [low, high].
    var low = bottom(field, fieldMargin);
    final high = top(field, fieldMargin);

    // The nearest primary action below the field.
    RenderBox? action;
    var actionTop = double.infinity;
    for (final c in _actions) {
      if (!c.mounted) continue;
      final box = c.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) continue;
      if (RenderAbstractViewport.maybeOf(box) != viewport) continue;
      final t = top(box, EdgeInsets.zero);
      if (t >= high - 1 && t < actionTop) {
        actionTop = t;
        action = box;
      }
    }
    if (action != null) {
      final both = math.max(low, bottom(action, const EdgeInsets.only(bottom: _revealMargin / 2)));
      // Both fit: show both; otherwise the field goes to the top, with as much of the form below it as fits.
      low = both <= high ? both : high;
    }

    if (low > high) low = high; // a field taller than the viewport
    final target = position.pixels.clamp(low, high).clamp(position.minScrollExtent, position.maxScrollExtent);
    if ((target - position.pixels).abs() < .5) return;
    if (animate) {
      unawaited(position.animateTo(target, duration: const Duration(milliseconds: 160), curve: Curves.easeOutCubic));
    } else {
      position.jumpTo(target);
    }
  }

  @override
  Widget build(BuildContext context) => _RevealScope(
    state: this,
    child: SingleChildScrollView(
      controller: _controller,
      padding: widget.padding,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.manual,
      child: widget.child,
    ),
  );
}
