part of 'menu.dart';

/// One menu row (overlay-shared.ts `menuItemClassName`): `mx-1 flex h-8 items-center gap-1 rounded-lg px-2`,
/// highlighted `bg-state-base-hover` (destructive: `text-text-destructive`, `bg-state-destructive-hover`), disabled
/// `opacity-30`. The highlight follows focus (Base UI moves focus to the highlighted item) and the pointer.
class _MenuRow extends StatefulWidget {
  const _MenuRow({
    required this.child,
    this.leading,
    this.trailing,
    this.disabled = false,
    this.destructive = false,
    this.onActivate,
    this.role = SemanticsRole.menuItem,
    this.checked,
    this.semanticLabel,
    this.focusNode,
    this.onHover,
    this.onKey,
    this.margin = true,
    this.marginX = 4,
    this.paddingX = 8,
    this.autoHeight = false,
  });

  /// `mx-1` (a submenu trigger puts it outside its anchor instead).
  final bool margin;

  /// `h-auto py-1`: grows with a second line instead of the fixed `h-8`.
  final bool autoHeight;

  /// A call site's `mx-*` / `px-*` over the row's `mx-1 px-2`.
  final double marginX, paddingX;
  final Widget child;
  final Widget? leading;
  final Widget? trailing;
  final bool disabled;
  final bool destructive;
  final void Function(bool keyboard)? onActivate;
  final SemanticsRole role;
  final bool? checked;
  final String? semanticLabel;
  final FocusNode? focusNode;
  final ValueChanged<bool>? onHover;
  final KeyEventResult Function(KeyEvent e)? onKey;

  @override
  State<_MenuRow> createState() => _MenuRowState();
}

class _MenuRowState extends State<_MenuRow> {
  FocusNode? _ownNode;
  _DifyMenuPopupState? _popup;
  bool _pointer = false;

  FocusNode get _node => widget.focusNode ?? (_ownNode ??= FocusNode(debugLabel: 'DifyMenuItem'));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _popup?._rows.remove(this);
    _popup = _MenuScope.of(context)?.._rows.add(this);
  }

  @override
  void dispose() {
    _popup?._rows.remove(this);
    _ownNode?.dispose();
    super.dispose();
  }

  void _activate(bool keyboard) {
    if (widget.disabled) return;
    _node.requestFocus();
    widget.onActivate?.call(keyboard);
  }

  @override
  Widget build(BuildContext context) {
    final highlighted = _node.hasFocus && !widget.disabled;
    Widget row = Container(
      height: widget.autoHeight ? null : 32,
      constraints: widget.autoHeight ? const BoxConstraints(minHeight: 32) : null,
      margin: widget.margin ? EdgeInsets.symmetric(horizontal: widget.marginX) : null,
      padding: EdgeInsets.symmetric(horizontal: widget.paddingX, vertical: widget.autoHeight ? 4 : 0),
      decoration: BoxDecoration(
        color: highlighted ? (widget.destructive ? DifyColors.stateDestructiveHover : DifyColors.stateBaseHover) : null,
        borderRadius: BorderRadius.circular(DifyRadius.lg),
      ),
      child: Row(
        spacing: 4,
        children: [
          ?widget.leading,
          // The label takes the free width, which puts the trailing part at the end (`ms-auto`).
          Expanded(
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: DifyControlLabelScope(child: widget.child),
            ),
          ),
          ?widget.trailing,
        ],
      ),
    );
    if (widget.destructive) {
      row = DefaultTextStyle.merge(
        style: TextStyle(color: DifyColors.textDestructive),
        child: row,
      );
    }
    if (widget.disabled) row = Opacity(opacity: 0.3, child: row);
    // An accessible name replaces the visible text, like aria-label.
    if (widget.semanticLabel != null) row = ExcludeSemantics(child: row);
    return MergeSemantics(
      child: Semantics(
        container: true,
        role: widget.role,
        label: widget.semanticLabel,
        enabled: !widget.disabled,
        focusable: !widget.disabled,
        focused: _node.hasFocus,
        onFocus: widget.disabled ? null : _node.requestFocus,
        checked: widget.checked,
        inMutuallyExclusiveGroup: widget.role == SemanticsRole.menuItemRadio ? true : null,
        onTap: widget.disabled ? null : () => _activate(false),
        child: Focus(
          focusNode: _node,
          canRequestFocus: !widget.disabled,
          includeSemantics: false,
          onFocusChange: (f) {
            setState(() {});
            if (f) _popup?._highlighted(this, pointer: _pointer);
            _pointer = false;
          },
          onKeyEvent: (node, e) {
            if (e is KeyDownEvent &&
                (e.logicalKey == LogicalKeyboardKey.enter ||
                    e.logicalKey == LogicalKeyboardKey.numpadEnter ||
                    e.logicalKey == LogicalKeyboardKey.space)) {
              _activate(true);
              return KeyEventResult.handled;
            }
            return widget.onKey?.call(e) ?? KeyEventResult.ignored;
          },
          child: MouseRegion(
            cursor: widget.disabled ? SystemMouseCursors.forbidden : SystemMouseCursors.click,
            onEnter: (event) {
              if (widget.disabled || event.kind != PointerDeviceKind.mouse) return;
              _pointer = true;
              _node.requestFocus();
              widget.onHover?.call(true);
            },
            onExit: (event) {
              if (event.kind != PointerDeviceKind.mouse) return;
              widget.onHover?.call(false);
              if (_node.hasFocus) _popup?._unhighlight();
            },
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              excludeFromSemantics: true,
              onTap: widget.disabled ? null : () => _activate(false),
              child: row,
            ),
          ),
        ),
      ),
    );
  }
}

/// A menu item (`DropdownMenuItem` / `ContextMenuItem`). Choosing it calls [onSelect] and, with [closeOnClick] (the
/// default), closes the menu.
class DifyMenuItem extends StatelessWidget {
  const DifyMenuItem({
    super.key,
    required this.child,
    this.onSelect,
    this.leading,
    this.trailing,
    this.variant = DifyMenuItemVariant.normal,
    this.disabled = false,
    this.closeOnClick = true,
    this.semanticLabel,
    this.marginX = 4,
    this.paddingX = 8,
    this.autoHeight = false,
  });

  final Widget child;
  final VoidCallback? onSelect;
  final Widget? leading;
  final Widget? trailing;
  final DifyMenuItemVariant variant;
  final bool disabled;
  final bool closeOnClick;
  final String? semanticLabel;

  /// A call site's `mx-*` / `px-*` (`mx-0 px-3` in the account menu).
  final double marginX, paddingX;

  /// A call site's `h-auto py-1` (an item with a description line).
  final bool autoHeight;

  @override
  Widget build(BuildContext context) => _MenuRow(
    marginX: marginX,
    paddingX: paddingX,
    autoHeight: autoHeight,
    leading: leading,
    trailing: trailing,
    disabled: disabled,
    destructive: variant == DifyMenuItemVariant.destructive,
    semanticLabel: semanticLabel,
    onActivate: (keyboard) {
      onSelect?.call();
      if (closeOnClick) _MenuScope.of(context)?.closeAll(instant: keyboard);
    },
    child: child,
  );
}

/// The checked indicator of checkbox and radio items (`floatingItemIndicatorClassName`: `ms-auto flex shrink-0
/// items-center text-text-accent`, `i-ri-check-line` 16 px).
RemixIcon get _indicator => RemixIcon('check-line', size: 16, color: DifyColors.textAccent);

/// A checkbox item (`DropdownMenuCheckboxItem` with its indicator). Base UI keeps the menu open on click.
class DifyMenuCheckboxItem extends StatelessWidget {
  const DifyMenuCheckboxItem({
    super.key,
    required this.child,
    required this.checked,
    this.onCheckedChange,
    this.leading,
    this.disabled = false,
    this.closeOnClick = false,
  });

  final Widget child;
  final bool checked;
  final ValueChanged<bool>? onCheckedChange;
  final Widget? leading;
  final bool disabled;
  final bool closeOnClick;

  @override
  Widget build(BuildContext context) => _MenuRow(
    leading: leading,
    trailing: checked ? _indicator : null,
    disabled: disabled,
    role: SemanticsRole.menuItemCheckbox,
    checked: checked,
    onActivate: (keyboard) {
      onCheckedChange?.call(!checked);
      if (closeOnClick) _MenuScope.of(context)?.closeAll(instant: keyboard);
    },
    child: child,
  );
}

class _RadioScope extends InheritedWidget {
  const _RadioScope({required this.value, required this.onChange, required super.child});
  final Object? value;
  final ValueChanged<Object?>? onChange;

  @override
  bool updateShouldNotify(_RadioScope old) => old.value != value || old.onChange != onChange;
}

/// A group of [DifyMenuRadioItem]s with one selected [value].
class DifyMenuRadioGroup<T> extends StatelessWidget {
  const DifyMenuRadioGroup({super.key, required this.value, this.onValueChange, required this.children});

  final T? value;
  final ValueChanged<T>? onValueChange;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => _RadioScope(
    value: value,
    onChange: onValueChange == null ? null : (v) => onValueChange!(v as T),
    child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
  );
}

/// A radio item of a [DifyMenuRadioGroup]. Base UI keeps the menu open on click.
class DifyMenuRadioItem<T> extends StatelessWidget {
  const DifyMenuRadioItem({
    super.key,
    required this.value,
    required this.child,
    this.leading,
    this.disabled = false,
    this.closeOnClick = false,
    this.focusNode,
  });

  final T value;
  final Widget child;
  final Widget? leading;
  final bool disabled;
  final bool closeOnClick;

  /// The row's focus node (focused = highlighted), e.g. to highlight the selected item when the menu opens.
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final group = context.dependOnInheritedWidgetOfExactType<_RadioScope>();
    final checked = group?.value == value;
    return _MenuRow(
      leading: leading,
      trailing: checked ? _indicator : null,
      disabled: disabled,
      role: SemanticsRole.menuItemRadio,
      checked: checked,
      focusNode: focusNode,
      onActivate: (keyboard) {
        group?.onChange?.call(value);
        if (closeOnClick) _MenuScope.of(context)?.closeAll(instant: keyboard);
      },
      child: child,
    );
  }
}

/// A group label (`floatingGroupLabelClassName`: `px-3 pb-0.5 pt-1 system-xs-medium-uppercase text-text-tertiary`).
class DifyMenuGroupLabel extends StatelessWidget {
  const DifyMenuGroupLabel(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 4, 12, 2),
    child: DifyTextLine(
      difyTransform(DifyType.systemXsMediumUppercase, text),
      style: difyTextStyle(DifyType.systemXsMediumUppercase, DifyColors.textTertiary),
    ),
  );
}

/// A separator (`floatingSeparatorClassName`: `my-1 h-px bg-divider-subtle`).
class DifyMenuSeparator extends StatelessWidget {
  const DifyMenuSeparator({super.key});

  @override
  Widget build(BuildContext context) =>
      Container(height: 1, margin: const EdgeInsets.symmetric(vertical: 4), color: DifyColors.dividerSubtle);
}
