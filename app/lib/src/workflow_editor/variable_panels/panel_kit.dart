/// The pieces the variable panels share: the panel shell (`w-105 rounded-l-2xl border bg-components-panel-bg-alt`),
/// its header, the variable card of the lists, the modals' surface and their plain textarea.
library;

import 'package:flutter/material.dart';

import '../../cards/card_kit.dart';
import '../../design/css_metrics.dart';
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';

String tw(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('workflow', key, params);
String tc(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('common', key, params);

/// es-toolkit's `capitalize`: the first character upper-cased, the rest lower-cased.
String capitalize(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1).toLowerCase();

/// `relative flex h-full w-105 flex-col rounded-l-2xl border border-components-panel-border
/// bg-components-panel-bg-alt`, with the header (`p-4 pb-0 system-xl-semibold`: [title] and [actions]) on top.
class VariablePanelShell extends StatelessWidget {
  const VariablePanelShell({super.key, required this.title, required this.actions, required this.children});
  final String title;
  final List<Widget> actions;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Container(
    width: 420,
    decoration: BoxDecoration(
      color: DifyColors.componentsPanelBgAlt,
      border: Border.all(color: DifyColors.componentsPanelBorder),
      borderRadius: const BorderRadius.horizontal(left: Radius.circular(DifyRadius.xxl)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Row(
            children: [
              Expanded(child: DifyText(title, DifyType.systemXlSemibold)),
              Row(mainAxisSize: MainAxisSize.min, spacing: 4, children: actions),
            ],
          ),
        ),
        ...children,
      ],
    ),
  );
}

/// The header's close control: `flex size-6 items-center justify-center` with `RiCloseLine size-4 text-text-tertiary`.
class PanelCloseButton extends StatelessWidget {
  const PanelCloseButton({super.key, required this.onPressed});
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => DifyPressable(
    semanticLabel: tc('operation.close'),
    onPressed: onPressed,
    builder: (context, hovered, focused) => const SizedBox.square(
      dimension: 24,
      child: Center(child: RemixIcon('close-line', size: 16, color: DifyColors.textTertiary)),
    ),
  );
}

/// The panel's description line (`shrink-0 px-4 py-1 system-sm-regular text-text-tertiary`).
class PanelDescription extends StatelessWidget {
  const PanelDescription(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    child: DifyText(text, DifyType.systemSmRegular, color: DifyColors.textTertiary, maxLines: null),
  );
}

/// The add button of a list (`Button variant=primary` with `RiAddLine size-4` and a `system-sm-medium` label).
class AddVariableButton extends StatelessWidget {
  const AddVariableButton({super.key, required this.label, required this.onPressed});
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: DifyButton(
      variant: DifyButtonVariant.primary,
      onPressed: onPressed,
      leading: const RemixIcon('add-line', size: 16),
      child: Text(label),
    ),
  );
}

/// The lists' "Add Variable" button with a variable modal in a popover to its left (`placement=left-start
/// sideOffset=8`, [alignOffset]; the modal draws its own surface). Each opening (or a change of [modalKey], the
/// variable edited) builds a fresh modal; a closing one keeps its content while it fades.
class VariableModalTrigger extends StatefulWidget {
  const VariableModalTrigger({
    super.key,
    required this.open,
    required this.onOpenChange,
    required this.label,
    required this.alignOffset,
    required this.modalBuilder,
    this.modalKey,
  });
  final bool open;
  final ValueChanged<bool> onOpenChange;
  final String label;
  final double alignOffset;
  final WidgetBuilder modalBuilder;
  final Object? modalKey;

  @override
  State<VariableModalTrigger> createState() => _VariableModalTriggerState();
}

class _VariableModalTriggerState extends State<VariableModalTrigger> {
  int _opening = 0;
  bool _wasOpen = false;
  Object? _key;
  Widget _modal = const SizedBox.shrink();

  @override
  Widget build(BuildContext context) {
    final w = widget;
    if (w.open) {
      if (!_wasOpen || w.modalKey != _key) _opening++;
      _key = w.modalKey;
      _modal = KeyedSubtree(key: ValueKey(_opening), child: w.modalBuilder(context));
    }
    _wasOpen = w.open;
    return Align(
      alignment: Alignment.centerLeft,
      child: DifyPopover(
        open: w.open,
        onOpenChange: w.onOpenChange,
        placement: DifyPlacement.leftStart,
        sideOffset: 8,
        alignOffset: w.alignOffset,
        surface: false,
        builder: (context, c) => AddVariableButton(label: w.label, onPressed: c.toggle),
        content: _modal,
      ),
    );
  }
}

/// A variable's card in a panel list (env-item.tsx, variable-item.tsx, global-variable-panel/item.tsx): `mb-1
/// rounded-lg border border-components-panel-border-subtle bg-components-panel-on-panel-item-bg shadow-xs` (hover
/// `-hover`), the icon, [name], [type] and [badge] in a row with the edit and delete actions, [body] below (`px-2.5
/// py-2` around both), and a [footer] strip under a divider. Hovering delete turns the card destructive
/// (`border-state-destructive-border`, hover `bg-state-destructive-hover`); [footerBuilder] gets that state.
class VariableItemCard extends StatefulWidget {
  const VariableItemCard({
    super.key,
    required this.icon,
    required this.name,
    required this.type,
    this.badge,
    this.body,
    this.footerBuilder,
    this.onEdit,
    this.onDelete,
  });

  final Widget icon;
  final Widget name;
  final String type;
  final Widget? badge;
  final Widget? body;
  final Widget Function(bool hovered, bool destructive)? footerBuilder;
  final VoidCallback? onEdit, onDelete;

  @override
  State<VariableItemCard> createState() => _VariableItemCardState();
}

class _VariableItemCardState extends State<VariableItemCard> {
  bool _hovered = false, _destructive = false;

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final footer = w.footerBuilder?.call(_hovered, _destructive);
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Container(
        margin: const EdgeInsets.only(bottom: 4),
        decoration: BoxDecoration(
          color: _hovered
              ? (_destructive ? DifyColors.stateDestructiveHover : DifyColors.componentsPanelOnPanelItemBgHover)
              : DifyColors.componentsPanelOnPanelItemBg,
          border: Border.all(
            color: _destructive ? DifyColors.stateDestructiveBorder : DifyColors.componentsPanelBorderSubtle,
          ),
          borderRadius: BorderRadius.circular(DifyRadius.lg),
          boxShadow: DifyShadows.xs,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Row(
                          spacing: 4,
                          children: [
                            w.icon,
                            Flexible(child: w.name),
                            DifyText(w.type, DifyType.systemXsMedium, color: DifyColors.textTertiary),
                            ?w.badge,
                          ],
                        ),
                      ),
                      if (w.onEdit != null || w.onDelete != null)
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          spacing: 4,
                          children: [
                            if (w.onEdit != null)
                              _ItemAction(icon: 'edit-line', label: tc('operation.edit'), onPressed: w.onEdit!),
                            if (w.onDelete != null)
                              _ItemAction(
                                icon: 'delete-bin-line',
                                label: tc('operation.delete'),
                                destructive: true,
                                onHover: (v) => setState(() => _destructive = v),
                                onPressed: w.onDelete!,
                              ),
                          ],
                        ),
                    ],
                  ),
                  ?w.body,
                ],
              ),
            ),
            if (footer != null) ...[
              Container(height: Css.hairline, color: DifyColors.dividerSubtle),
              footer,
            ],
          ],
        ),
      ),
    );
  }
}

/// An item action: `cursor-pointer rounded-lg p-1` with a 16 px icon in `text-text-tertiary`; hover
/// `bg-state-base-hover text-text-secondary`, or for delete `bg-state-destructive-hover text-text-destructive`.
class _ItemAction extends StatelessWidget {
  const _ItemAction({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.destructive = false,
    this.onHover,
  });
  final String icon, label;
  final VoidCallback onPressed;
  final bool destructive;
  final ValueChanged<bool>? onHover;

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => onHover?.call(true),
    onExit: (_) => onHover?.call(false),
    child: DifyPressable(
      semanticLabel: label,
      onPressed: onPressed,
      builder: (context, hovered, focused) => Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: hovered ? (destructive ? DifyColors.stateDestructiveHover : DifyColors.stateBaseHover) : null,
          borderRadius: BorderRadius.circular(DifyRadius.lg),
        ),
        child: RemixIcon(
          icon,
          size: 16,
          color: hovered
              ? (destructive ? DifyColors.textDestructive : DifyColors.textSecondary)
              : DifyColors.textTertiary,
        ),
      ),
    ),
  );
}

/// The variable modals' surface (`flex w-90 flex-col rounded-2xl border-[0.5px] border-components-panel-border
/// bg-components-panel-bg shadow-2xl`): the title row (`mb-3 p-4 pb-0 system-xl-semibold` with the close control),
/// [body] and the Cancel / Save row (`flex-row-reverse p-4 pt-2`, `gap-2`).
class VariableModalSurface extends StatelessWidget {
  const VariableModalSurface({
    super.key,
    required this.title,
    required this.body,
    required this.onClose,
    required this.onSave,
    this.width = 360,
    this.close,
  });

  final String title;
  final Widget body;
  final VoidCallback onClose, onSave;
  final double width;

  /// The close control; a [PanelCloseButton] by default.
  final Widget? close;

  @override
  Widget build(BuildContext context) => Material(
    type: MaterialType.transparency,
    child: Container(
      width: width,
      decoration: BoxDecoration(
        color: DifyColors.componentsPanelBg,
        border: Border.all(color: DifyColors.componentsPanelBorder, width: Css.hairline),
        borderRadius: BorderRadius.circular(DifyRadius.xxl),
        boxShadow: DifyShadows.n2xl,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Row(
              children: [
                Expanded(child: DifyText(title, DifyType.systemXlSemibold)),
                close ?? PanelCloseButton(onPressed: onClose),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Flexible(child: body),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              spacing: 8,
              children: [
                Flexible(
                  child: DifyButton(onPressed: onClose, child: Text(tc('operation.cancel'))),
                ),
                Flexible(
                  child: DifyButton(
                    variant: DifyButtonVariant.primary,
                    onPressed: onSave,
                    child: Text(tc('operation.save')),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

/// A modal section's title (`mb-1 flex h-6 items-center system-sm-semibold text-text-secondary`), with [trailing]
/// at the end.
class ModalSectionTitle extends StatelessWidget {
  const ModalSectionTitle(this.title, {super.key, this.trailing});
  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Container(
    height: 24,
    margin: const EdgeInsets.only(bottom: 4),
    child: Row(
      children: [
        Expanded(child: DifyText(title, DifyType.systemSmSemibold, color: DifyColors.textSecondary)),
        if (trailing != null) Flexible(child: trailing!),
      ],
    ),
  );
}

/// The modals' plain `<textarea>`: `block h-20 w-full resize-none rounded-lg border border-transparent
/// bg-components-input-bg-normal p-2 system-sm-regular text-components-input-text-filled`, hover
/// `border-components-input-border-hover bg-components-input-bg-hover`, focus `border-components-input-border-active
/// bg-components-input-bg-active shadow-xs`.
class PlainTextarea extends StatefulWidget {
  const PlainTextarea({super.key, required this.value, required this.onChanged, this.placeholder});
  final String value;
  final ValueChanged<String> onChanged;
  final String? placeholder;

  @override
  State<PlainTextarea> createState() => _PlainTextareaState();
}

class _PlainTextareaState extends State<PlainTextarea> {
  late final _text = TextEditingController(text: widget.value);
  final _focus = FocusNode(debugLabel: 'textarea');
  bool _hovered = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() {}));
  }

  @override
  void didUpdateWidget(PlainTextarea old) {
    super.didUpdateWidget(old);
    if (_text.text != widget.value) _text.text = widget.value;
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final focused = _focus.hasFocus;
    final style = difyTextStyle(DifyType.systemSmRegular, DifyColors.componentsInputTextFilled);
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Container(
        height: 80,
        decoration: BoxDecoration(
          color: focused
              ? DifyColors.componentsInputBgActive
              : _hovered
              ? DifyColors.componentsInputBgHover
              : DifyColors.componentsInputBgNormal,
          borderRadius: BorderRadius.circular(DifyRadius.lg),
          border: Border.all(
            color: focused
                ? DifyColors.componentsInputBorderActive
                : _hovered
                ? DifyColors.componentsInputBorderHover
                : const Color(0x00000000),
          ),
          boxShadow: focused ? DifyShadows.xs : null,
        ),
        child: TextField(
          controller: _text,
          focusNode: _focus,
          onChanged: widget.onChanged,
          expands: true,
          maxLines: null,
          textAlignVertical: TextAlignVertical.top,
          style: style,
          cursorColor: const Color(0xFF155EEF),
          cursorWidth: 1,
          decoration: InputDecoration(
            isCollapsed: true,
            border: InputBorder.none,
            contentPadding: const EdgeInsets.all(7),
            hintText: widget.placeholder,
            hintStyle: style.copyWith(color: DifyColors.componentsInputTextPlaceholder),
          ),
        ),
      ),
    );
  }
}
