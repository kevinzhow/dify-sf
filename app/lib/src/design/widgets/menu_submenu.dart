part of 'menu.dart';

/// A submenu (`DropdownMenuSub` + `SubTrigger` + `SubContent`): a row with [label] and a trailing
/// `i-ri-arrow-right-s-line` (16 px, `text-text-tertiary`) that opens [children] after the pointer rests on it for
/// 100 ms, on click, or with ArrowRight, Enter or Space. Opens at `left-start` in a dropdown menu and `right-start`
/// in a context menu (Dify's defaults), 4 px away.
class DifyMenuSubmenu extends StatefulWidget {
  const DifyMenuSubmenu({
    super.key,
    required this.label,
    required this.children,
    this.leading,
    this.variant = DifyMenuItemVariant.normal,
    this.disabled = false,
    this.open,
    this.onOpenChange,
    this.placement,
    this.sideOffset = 4,
    this.alignOffset = 0,
    this.width,
    this.semanticLabel,
    this.popupLabel,
    this.paddingX = 8,
    this.marginX = 4,
  });

  final Widget label;
  final List<Widget> children;
  final Widget? leading;
  final DifyMenuItemVariant variant;
  final bool disabled;
  final bool? open;
  final ValueChanged<bool>? onOpenChange;
  final DifyPlacement? placement;
  final double sideOffset;
  final double alignOffset;
  final double? width;

  /// The trigger's accessible name (`aria-label`).
  final String? semanticLabel;

  /// The submenu's name; defaults to [semanticLabel] or the label's text (Base UI labels it by the trigger).
  final String? popupLabel;

  /// A call site's `px-*` over the trigger row's `px-2`.
  final double paddingX;

  /// A call site's `mx-*` over the shared trigger's `mx-1`.
  final double marginX;

  @override
  State<DifyMenuSubmenu> createState() => _DifyMenuSubmenuState();
}

class _DifyMenuSubmenuState extends State<DifyMenuSubmenu> {
  final _controller = DifyFloatingController();
  final _triggerNode = FocusNode(debugLabel: 'DifyMenuSubmenu trigger');
  final _popupNode = FocusNode(debugLabel: 'DifyMenuSubmenu popup');
  _DifyMenuPopupState? _parent;
  _MenuRowState? get _row => _triggerNode.context?.findAncestorStateOfType<_MenuRowState>();
  Timer? _hover;
  bool _focusFirst = false;
  final _popupKey = GlobalKey();
  Offset? _intentOrigin;
  bool _tracking = false;
  bool _hoverDriven = false;

  Rect? _bounds(BuildContext? context) {
    final box = context?.findRenderObject();
    return box is RenderBox && box.hasSize
        ? MatrixUtils.transformRect(box.getTransformTo(null), Offset.zero & box.size)
        : null;
  }

  // The pointer may cross an adjacent row while heading diagonally into a
  // submenu. Keep that corridor open, including the gap between the surfaces.
  // Interaction model: https://floating-ui.com/docs/usehover#safepolygon
  bool _protects(Offset point) {
    final trigger = _bounds(_triggerNode.context);
    final popup = _bounds(_popupKey.currentContext);
    if (trigger == null || popup == null) return false;
    if (trigger.contains(point) || popup.contains(point)) return true;
    final origin = _intentOrigin;
    if (origin == null) return false;
    final r = popup.inflate(0.5);
    final (Offset a, Offset b) = popup.left >= trigger.right
        ? (r.topLeft, r.bottomLeft)
        : popup.right <= trigger.left
        ? (r.topRight, r.bottomRight)
        : popup.top >= trigger.bottom
        ? (r.topLeft, r.topRight)
        : (r.bottomLeft, r.bottomRight);
    return (Path()
          ..moveTo(origin.dx, origin.dy)
          ..lineTo(a.dx, a.dy)
          ..lineTo(b.dx, b.dy)
          ..close())
        .contains(point);
  }

  void _track(bool on) {
    if (_tracking == on) return;
    _tracking = on;
    if (on) {
      _intentOrigin = _parent?._pointer;
      GestureBinding.instance.pointerRouter.addGlobalRoute(_pointerMoved);
    } else {
      GestureBinding.instance.pointerRouter.removeGlobalRoute(_pointerMoved);
    }
  }

  void _pointerMoved(PointerEvent event) {
    if (event is! PointerHoverEvent || event.kind != PointerDeviceKind.mouse || !_controller.isOpen) return;
    final point = event.position;
    _parent?._pointer = point;
    if (_bounds(_triggerNode.context)?.contains(point) ?? false) _intentOrigin = point;
    if (_protects(point)) {
      _parent?._subClose?.cancel();
    } else if (_parent case final parent?) {
      parent._scheduleClose(this);
    }
  }

  @override
  void didUpdateWidget(DifyMenuSubmenu old) {
    super.didUpdateWidget(old);
    if (widget.open != old.open) _track(widget.open == true && _hoverDriven);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _parent = _MenuScope.of(context);
  }

  @override
  void dispose() {
    _hover?.cancel();
    _track(false);
    if (_parent?._openSub == this) _parent?._openSub = null;
    _triggerNode.dispose();
    _popupNode.dispose();
    super.dispose();
  }

  void _open({bool keyboard = false, bool hover = false}) {
    _hover?.cancel();
    if (widget.disabled) return;
    final other = _parent?._openSub;
    if (other != null && other != this) other._controller.close(instant: true);
    _parent?._subClose?.cancel();
    // A touch, accessibility or keyboard activation owns its open state.
    // Compatibility mouse events must not hand it to a hover-close timer.
    _hoverDriven = hover;
    _focusFirst = keyboard;
    _controller.open();
    _track(_controller.isOpen && _hoverDriven);
    if (keyboard && _controller.isOpen) {
      // Already open: move into it.
      _popupNode.context?.findAncestorStateOfType<_DifyMenuPopupState>()?._move(1, from: -1);
    }
  }

  String? get _name {
    if (widget.popupLabel != null || widget.semanticLabel != null) return widget.popupLabel ?? widget.semanticLabel;
    final l = widget.label;
    if (l is DifyTextLine) return l.data ?? l.textSpan?.toPlainText();
    if (l is DifyText) return difyTransform(l.style, l.text);
    return l is Text ? l.data ?? l.textSpan?.toPlainText() : null;
  }

  @override
  Widget build(BuildContext context) {
    final root = _parent?.widget._root;
    // The submenu anchors to the row's box, inside its mx-1 margin.
    final floating = DifyFloating(
      controller: _controller,
      open: widget.open,
      onOpenChange: (open) {
        _track(open && _hoverDriven);
        if (open) {
          _parent?._openSub = this;
        } else if (_parent?._openSub == this) {
          _parent?._openSub = null;
        }
        widget.onOpenChange?.call(open);
      },
      placement: widget.placement ?? (root?.contextMenu ?? false ? DifyPlacement.rightStart : DifyPlacement.leftStart),
      sideOffset: widget.sideOffset,
      alignOffset: widget.alignOffset,
      collision: DifyCollision.popup,
      constrainHeight: true,
      dismissible: false,
      focusPopup: false,
      tapRegionGroup: root?.controller,
      builder: (context, controller) => _MenuRow(
        margin: false,
        paddingX: widget.paddingX,
        focusNode: _triggerNode,
        leading: widget.leading,
        trailing: RemixIcon('arrow-right-s-line', size: 16, color: DifyColors.textTertiary),
        disabled: widget.disabled,
        destructive: widget.variant == DifyMenuItemVariant.destructive,
        semanticLabel: widget.semanticLabel,
        onActivate: (keyboard) => _open(keyboard: keyboard),
        onHover: (inside) {
          _hover?.cancel();
          if (inside && !controller.isOpen) {
            _hover = Timer(const Duration(milliseconds: 100), () => _open(hover: true));
          }
        },
        onKey: (e) {
          if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.arrowRight) {
            _open(keyboard: true);
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: widget.label,
      ),
      popupBuilder: (context) => DifyMenuPopup._(
        key: _popupKey,
        root: root ?? _MenuRoot(_controller, contextMenu: false),
        parent: _parent,
        focusNode: _popupNode,
        focusFirst: _focusFirst,
        width: widget.width,
        semanticLabel: _name,
        onArrowLeft: () => _controller.close(instant: true),
        children: widget.children,
      ),
    );
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: widget.marginX),
      child: floating,
    );
  }
}
