import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../dify_icon.dart';
import '../dify_tokens.g.dart';
import 'floating.dart';
import 'placement.dart';
import 'surface.dart';
import 'text.dart';

part 'menu_items.dart';
part 'menu_submenu.dart';

/// `MenuItemVariant`.
enum DifyMenuItemVariant { normal, destructive }

/// The menu a popup belongs to: the root's controller (closing it closes the tree; also the tap-region group) and
/// whether it is a context menu (submenus open to the right) or a dropdown (to the left).
class _MenuRoot {
  const _MenuRoot(this.controller, {required this.contextMenu});
  final DifyFloatingController controller;
  final bool contextMenu;
}

class _MenuScope extends InheritedWidget {
  const _MenuScope({required this.popup, required super.child});
  final _DifyMenuPopupState popup;

  static _DifyMenuPopupState? of(BuildContext context) => context.getInheritedWidgetOfExactType<_MenuScope>()?.popup;

  @override
  bool updateShouldNotify(_MenuScope old) => old.popup != popup;
}

/// The menu popup surface (overlay-shared.ts `menuPopupClassName`): `rounded-xl border-[0.5px]
/// border-components-panel-border bg-components-panel-bg-blur py-1 shadow-lg backdrop-blur-[5px]`, `text-sm
/// text-text-secondary`, scrolling past `--available-height`. As wide as its widest row unless [width] is given.
/// Arrow keys, Home and End move the highlight; ArrowLeft closes a submenu.
class DifyMenuPopup extends StatefulWidget {
  const DifyMenuPopup({super.key, required this.children, this.width, this.semanticLabel})
    : _root = null,
      _focusNode = null,
      _focusFirst = false,
      _onArrowLeft = null,
      _parent = null;

  const DifyMenuPopup._({
    required this.children,
    this.width,
    this.semanticLabel,
    required _MenuRoot this._root,
    required FocusNode this._focusNode,
    this._focusFirst = false,
    this._onArrowLeft,
    this._parent,
  });

  final List<Widget> children;
  final double? width;
  final String? semanticLabel;
  final _MenuRoot? _root;
  final FocusNode? _focusNode;
  final bool _focusFirst;
  final VoidCallback? _onArrowLeft;
  final _DifyMenuPopupState? _parent;

  static final decoration = BoxDecoration(
    color: DifyColors.componentsPanelBgBlur,
    border: Border.all(color: DifyColors.componentsPanelBorder, width: 0.5),
    borderRadius: BorderRadius.circular(DifyRadius.xl),
    boxShadow: DifyShadows.lg,
  );

  @override
  State<DifyMenuPopup> createState() => _DifyMenuPopupState();
}

class _DifyMenuPopupState extends State<DifyMenuPopup> {
  final _rows = <_MenuRowState>{};
  FocusNode? _ownNode;
  _DifyMenuSubmenuState? _openSub;
  Timer? _subClose;

  FocusNode get _node => widget._focusNode ?? (_ownNode ??= FocusNode(debugLabel: 'DifyMenuPopup'));

  @override
  void initState() {
    super.initState();
    if (widget._focusFirst || (widget._parent == null && widget._root != null && lastInputWasKeyboard)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _move(1, from: -1);
      });
    }
  }

  @override
  void dispose() {
    _subClose?.cancel();
    _ownNode?.dispose();
    super.dispose();
  }

  /// Closes the whole menu (an item was chosen).
  void closeAll({bool instant = false}) {
    for (_DifyMenuPopupState? p = this; p != null; p = p.widget._parent) {
      p._openSub?._controller.close(instant: instant);
    }
    widget._root?.controller.close(instant: instant);
  }

  List<_MenuRowState> get _enabled {
    final rows = _rows.where((r) => !r.widget.disabled && r.mounted).toList();
    double top(_MenuRowState r) => (r.context.findRenderObject() as RenderBox?)?.localToGlobal(Offset.zero).dy ?? 0;
    rows.sort((a, b) => top(a).compareTo(top(b)));
    return rows;
  }

  void _move(int delta, {int? from}) {
    final rows = _enabled;
    if (rows.isEmpty) return;
    final i = from ?? rows.indexWhere((r) => r._node.hasFocus);
    final next = i < 0 ? (delta > 0 ? 0 : rows.length - 1) : (i + delta) % rows.length;
    rows[next]._node.requestFocus();
  }

  void _highlighted(_MenuRowState row, {required bool pointer}) {
    final sub = _openSub;
    if (sub == null || sub._row == row) return _subClose?.cancel();
    _subClose?.cancel();
    if (pointer) {
      // Base UI keeps a submenu open while the pointer crosses towards it (safe polygon); a short grace period
      // stands in for that.
      _subClose = Timer(const Duration(milliseconds: 100), () => sub._controller.close());
    } else {
      sub._controller.close();
    }
  }

  void _unhighlight() {
    if (_node.context != null) _node.requestFocus();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.arrowDown) {
      _move(1);
    } else if (k == LogicalKeyboardKey.arrowUp) {
      _move(-1);
    } else if (k == LogicalKeyboardKey.home) {
      _move(1, from: -1);
    } else if (k == LogicalKeyboardKey.end) {
      _move(-1, from: 0);
    } else if (k == LogicalKeyboardKey.arrowLeft && widget._onArrowLeft != null) {
      widget._onArrowLeft!();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(DifyRadius.xl);
    Widget column = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: widget.children,
    );
    column = SingleChildScrollView(padding: const EdgeInsets.symmetric(vertical: 4), child: column);
    column = widget.width != null ? SizedBox(width: widget.width, child: column) : IntrinsicWidth(child: column);
    return _MenuScope(
      popup: this,
      child: Semantics(
        container: true,
        role: SemanticsRole.menu,
        label: widget.semanticLabel,
        explicitChildNodes: true,
        child: Focus(
          focusNode: _node,
          onKeyEvent: _onKey,
          child: MouseRegion(
            onEnter: (_) => widget._parent?._subClose?.cancel(),
            child: DefaultTextStyle.merge(
              style: const TextStyle(fontSize: 14, height: 20 / 14, color: DifyColors.textSecondary),
              child: DifyBlurredBox(
                blur: 5,
                borderRadius: r,
                decoration: DifyMenuPopup.decoration,
                child: ClipRRect(borderRadius: r, child: column),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// dify-ui's DropdownMenu (Root + Trigger + DropdownMenuContent): [builder] builds the trigger, which toggles the
/// menu with the controller; the menu opens at `bottom-end`, 4 px below, and closes when an item is chosen, on
/// Escape and on outside taps.
class DifyDropdownMenu extends StatefulWidget {
  const DifyDropdownMenu({
    super.key,
    required this.builder,
    required this.children,
    this.controller,
    this.open,
    this.onOpenChange,
    this.placement = DifyPlacement.bottomEnd,
    this.sideOffset = 4,
    this.alignOffset = 0,
    this.width,
    this.semanticLabel,
  });

  final DifyTriggerBuilder builder;
  final List<Widget> children;
  final DifyFloatingController? controller;
  final bool? open;
  final ValueChanged<bool>? onOpenChange;
  final DifyPlacement placement;
  final double sideOffset;
  final double alignOffset;
  final double? width;
  final String? semanticLabel;

  @override
  State<DifyDropdownMenu> createState() => _DifyDropdownMenuState();
}

class _DifyDropdownMenuState extends State<DifyDropdownMenu> {
  final _own = DifyFloatingController();
  final _popupNode = FocusNode(debugLabel: 'DifyDropdownMenu popup');

  @override
  void dispose() {
    _popupNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller ?? _own;
    return DifyFloating(
      controller: controller,
      open: widget.open,
      onOpenChange: widget.onOpenChange,
      placement: widget.placement,
      sideOffset: widget.sideOffset,
      alignOffset: widget.alignOffset,
      collision: DifyCollision.dropdown,
      constrainHeight: true,
      initialFocus: _popupNode,
      builder: widget.builder,
      popupBuilder: (context) => DifyMenuPopup._(
        root: _MenuRoot(controller, contextMenu: false),
        focusNode: _popupNode,
        width: widget.width,
        semanticLabel: widget.semanticLabel,
        children: widget.children,
      ),
    );
  }
}

/// dify-ui's ContextMenu (Root + Trigger + ContextMenuContent): right-clicking [child] (or a long press on touch)
/// opens the menu at the pointer, `bottom-start` with no offset; it keeps its side and flips its alignment or
/// shifts to stay on screen (Base UI's point anchor). Opened through [open] alone it anchors at the overlay's
/// origin, like Base UI's initial virtual anchor.
class DifyContextMenu extends StatefulWidget {
  const DifyContextMenu({
    super.key,
    required this.child,
    required this.children,
    this.controller,
    this.open,
    this.onOpenChange,
    this.placement = DifyPlacement.bottomStart,
    this.sideOffset = 0,
    this.alignOffset = 0,
    this.width,
    this.disabled = false,
    this.semanticLabel,
  });

  final Widget child;
  final List<Widget> children;
  final DifyFloatingController? controller;
  final bool? open;
  final ValueChanged<bool>? onOpenChange;
  final DifyPlacement placement;
  final double sideOffset;
  final double alignOffset;
  final double? width;
  final bool disabled;
  final String? semanticLabel;

  @override
  State<DifyContextMenu> createState() => _DifyContextMenuState();
}

class _DifyContextMenuState extends State<DifyContextMenu> {
  final _own = DifyFloatingController();
  final _popupNode = FocusNode(debugLabel: 'DifyContextMenu popup');

  DifyFloatingController get _controller => widget.controller ?? _own;

  @override
  void dispose() {
    _popupNode.dispose();
    super.dispose();
  }

  // After the tap region has seen the same pointer down (which closes an open menu), so a second right click
  // reopens the menu at the new point.
  void _openAt(Offset p) => scheduleMicrotask(() {
    if (mounted && !widget.disabled) _controller.open(at: p);
  });

  @override
  Widget build(BuildContext context) => DifyFloating(
    controller: _controller,
    open: widget.open,
    onOpenChange: widget.onOpenChange,
    placement: widget.placement,
    sideOffset: widget.sideOffset,
    alignOffset: widget.alignOffset,
    collision: DifyCollision.contextMenu,
    constrainHeight: true,
    triggerInsideTapRegion: false,
    pointAnchor: true,
    initialFocus: _popupNode,
    builder: (context, _) => Listener(
      onPointerDown: (e) {
        if (e.kind == PointerDeviceKind.mouse && e.buttons == kSecondaryButton) _openAt(e.position);
      },
      child: GestureDetector(
        supportedDevices: const {PointerDeviceKind.touch, PointerDeviceKind.stylus},
        onLongPressStart: (d) => _openAt(d.globalPosition),
        child: widget.child,
      ),
    ),
    popupBuilder: (context) => DifyMenuPopup._(
      root: _MenuRoot(_controller, contextMenu: true),
      focusNode: _popupNode,
      width: widget.width,
      semanticLabel: widget.semanticLabel,
      children: widget.children,
    ),
  );
}
