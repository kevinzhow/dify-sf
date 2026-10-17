import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../dify_tokens.g.dart';
import 'floating.dart';
import 'placement.dart';
import 'shortcut_kbd.dart';
import 'surface.dart';
import 'text.dart';

/// Base UI's tooltip delay group (Tooltip.Provider): while a tooltip is open, and for [timeout] after it closes, the
/// next tooltip opens at once and without a transition.
abstract final class _TooltipGroup {
  static const timeout = Duration(milliseconds: 400);
  static _DifyTooltipState? active;
  static Timer? _phase;

  static bool get instant => active != null || (_phase?.isActive ?? false);

  static void opened(_DifyTooltipState t) {
    if (active != null && active != t) active!._setOpen(false, instant: true);
    active = t;
    _phase?.cancel();
  }

  static int _mounted = 0;

  static void mount() => _mounted++;

  static void unmount(_DifyTooltipState t) {
    if (active == t) active = null;
    if (--_mounted == 0) {
      _phase?.cancel();
      _phase = null;
    }
  }

  static void closed(_DifyTooltipState t) {
    if (active != t) return;
    active = null;
    _phase = Timer(timeout, () {});
  }
}

/// dify-ui's Tooltip (Root + Trigger + TooltipContent): a short, non-interactive hint for [child]. Opens when a mouse
/// rests on the trigger for [delay] or the trigger gets keyboard focus; closes [closeDelay] after the pointer leaves
/// both trigger and popup (the popup is hoverable, Base UI's default), on blur, on a press of the trigger and on
/// Escape. Placement `top`, sideOffset 8, fading in over 150 ms. The delays default to Dify's app-wide
/// `<TooltipProvider delay={300} closeDelay={200}>` (Base UI alone: 600 and 0).
class DifyTooltip extends StatefulWidget {
  const DifyTooltip({
    super.key,
    required this.child,
    required this.content,
    this.open,
    this.onOpenChange,
    this.placement = DifyPlacement.top,
    this.sideOffset = 8,
    this.alignOffset = 0,
    this.delay = const Duration(milliseconds: 300),
    this.closeDelay = const Duration(milliseconds: 200),
    this.surface = true,
    this.disabled = false,
  });

  final Widget child;
  final Widget content;
  final bool? open;
  final ValueChanged<bool>? onOpenChange;
  final DifyPlacement placement;
  final double sideOffset;
  final double alignOffset;
  final Duration delay;
  final Duration closeDelay;

  /// The TooltipContent box (`max-w-75 rounded-md bg-components-panel-bg px-3 py-2 system-xs-regular
  /// text-text-tertiary shadow-lg`); false shows [content] bare (TipPopup's `bg-transparent p-0 shadow-none`).
  final bool surface;
  final bool disabled;

  @override
  State<DifyTooltip> createState() => _DifyTooltipState();
}

class _DifyTooltipState extends State<DifyTooltip> {
  final _floating = DifyFloatingController();
  bool _open = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _TooltipGroup.mount();
  }

  @override
  void didUpdateWidget(DifyTooltip old) {
    super.didUpdateWidget(old);
    if (widget.disabled && _open) WidgetsBinding.instance.addPostFrameCallback((_) => _setOpen(false));
  }

  @override
  void dispose() {
    _timer?.cancel();
    _TooltipGroup.unmount(this);
    super.dispose();
  }

  void _setOpen(bool open, {bool instant = false}) {
    _timer?.cancel();
    if (open == _open || !mounted) return;
    _open = open;
    if (open) {
      instant = instant || _TooltipGroup.instant;
      _TooltipGroup.opened(this);
      _floating.open(instant: instant);
    } else {
      _TooltipGroup.closed(this);
      _floating.close(instant: instant);
    }
  }

  void _schedule(bool open) {
    _timer?.cancel();
    if (widget.disabled && open) return;
    final wait = open ? (_TooltipGroup.instant ? Duration.zero : widget.delay) : widget.closeDelay;
    if (wait == Duration.zero) return _setOpen(open);
    _timer = Timer(wait, () => _setOpen(open));
  }

  bool _mouse(PointerEvent e) => e.kind == PointerDeviceKind.mouse;

  @override
  Widget build(BuildContext context) {
    final trigger = Focus(
      canRequestFocus: false,
      skipTraversal: true,
      includeSemantics: false,
      onFocusChange: (f) {
        if (!f) return _setOpen(false);
        if (!widget.disabled && FocusManager.instance.highlightMode == FocusHighlightMode.traditional) {
          _setOpen(true);
        }
      },
      onKeyEvent: (_, e) {
        if (_open && e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.escape) {
          _setOpen(false);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Listener(
        onPointerDown: (_) => _setOpen(false), // closeOnClick
        child: MouseRegion(
          onEnter: (e) => _mouse(e) ? _schedule(true) : null,
          onExit: (e) => _mouse(e) ? _schedule(false) : null,
          child: widget.child,
        ),
      ),
    );
    return DifyFloating(
      controller: _floating,
      open: widget.open,
      onOpenChange: widget.onOpenChange,
      placement: widget.placement,
      sideOffset: widget.sideOffset,
      alignOffset: widget.alignOffset,
      transition: DifyFloatingTransition.fade,
      dismissible: false,
      focusPopup: false,
      builder: (context, _) => trigger,
      popupBuilder: (context) => MouseRegion(
        onEnter: (_) => _timer?.cancel(),
        onExit: (e) => _mouse(e) ? _schedule(false) : null,
        child: widget.surface ? DifyTooltipSurface(child: widget.content) : widget.content,
      ),
    );
  }
}

/// The TooltipContent box.
class DifyTooltipSurface extends StatelessWidget {
  const DifyTooltipSurface({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(maxWidth: 300),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(
      color: DifyColors.componentsPanelBg,
      borderRadius: BorderRadius.circular(DifyRadius.md),
      boxShadow: DifyShadows.lg,
    ),
    child: DefaultTextStyle.merge(
      style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textTertiary),
      textAlign: TextAlign.start,
      child: child,
    ),
  );
}

/// The workflow toolbar's TipPopup (operator/tip-popup.tsx): a [DifyTooltip] 4 px from the trigger whose box is
/// `flex items-center gap-1 rounded-lg border-[0.5px] border-components-panel-border bg-components-tooltip-bg p-1.5
/// shadow-lg backdrop-blur-[5px]`, holding the [title] (`system-xs-medium text-text-secondary`) and the [shortcut]'s
/// keycaps.
class DifyTipPopup extends StatelessWidget {
  const DifyTipPopup({super.key, required this.title, required this.child, this.shortcut, this.placement});

  final String title;
  final Widget child;

  /// An id of [difyWorkflowShortcuts].
  final String? shortcut;
  final DifyPlacement? placement;

  @override
  Widget build(BuildContext context) => DifyTooltip(
    sideOffset: 4,
    placement: placement ?? DifyPlacement.top,
    surface: false,
    content: DifyTipPopupBox(title: title, shortcut: shortcut),
    child: child,
  );
}

/// TipPopup's box on its own.
class DifyTipPopupBox extends StatelessWidget {
  const DifyTipPopupBox({super.key, required this.title, this.shortcut});
  final String title;
  final String? shortcut;

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(DifyRadius.lg);
    return DifyBlurredBox(
      blur: 5,
      borderRadius: r,
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: DifyColors.componentsTooltipBg,
        border: Border.all(color: DifyColors.componentsPanelBorder, width: 0.5),
        borderRadius: r,
        boxShadow: DifyShadows.lg,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 4,
        children: [
          Text(title, style: difyTextStyle(DifyType.systemXsMedium, DifyColors.textSecondary)),
          if (shortcut != null) DifyShortcutKbd(shortcut: shortcut),
        ],
      ),
    );
  }
}
