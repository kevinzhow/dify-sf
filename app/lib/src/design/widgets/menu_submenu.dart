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

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _parent = _MenuScope.of(context);
  }

  @override
  void dispose() {
    _hover?.cancel();
    if (_parent?._openSub == this) _parent?._openSub = null;
    _triggerNode.dispose();
    _popupNode.dispose();
    super.dispose();
  }

  void _open({bool keyboard = false}) {
    _hover?.cancel();
    if (widget.disabled) return;
    final other = _parent?._openSub;
    if (other != null && other != this) other._controller.close(instant: true);
    _parent?._subClose?.cancel();
    _focusFirst = keyboard;
    _controller.open();
    if (keyboard && _controller.isOpen) {
      // Already open: move into it.
      _popupNode.context?.findAncestorStateOfType<_DifyMenuPopupState>()?._move(1, from: -1);
    }
  }

  String? get _name {
    if (widget.popupLabel != null || widget.semanticLabel != null) return widget.popupLabel ?? widget.semanticLabel;
    final l = widget.label;
    return l is Text ? l.data : null;
  }

  @override
  Widget build(BuildContext context) {
    final root = _parent?.widget._root;
    // The submenu anchors to the row's box, inside its mx-1 margin.
    final floating = DifyFloating(
      controller: _controller,
      open: widget.open,
      onOpenChange: (open) {
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
        focusNode: _triggerNode,
        leading: widget.leading,
        trailing: const RemixIcon('arrow-right-s-line', size: 16, color: DifyColors.textTertiary),
        disabled: widget.disabled,
        destructive: widget.variant == DifyMenuItemVariant.destructive,
        semanticLabel: widget.semanticLabel,
        onActivate: (keyboard) => _open(keyboard: keyboard),
        onHover: (inside) {
          _hover?.cancel();
          if (inside && !controller.isOpen) {
            _hover = Timer(const Duration(milliseconds: 100), _open);
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
    return Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: floating);
  }
}
