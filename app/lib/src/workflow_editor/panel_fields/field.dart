/// Panel layout pieces (nodes/_base/components: field.tsx, split.tsx, collapse/, layout/, output-vars.tsx,
/// info-panel.tsx, option-card.tsx, input-var-type-icon.tsx, remove-button.tsx, add-button.tsx, help-link.tsx,
/// toggle-expand-btn.tsx, variable/object-child-tree-panel/tree-indent-line.tsx).
library;

import 'package:flutter/material.dart';

import '../../cards/card_kit.dart';
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';
import 'controls.dart';

/// The title text of a [Field]: `system-sm-semibold-uppercase text-text-secondary`, or for a sub-title
/// `system-xs-medium-uppercase text-text-tertiary`; [required] adds a destructive `*`, [warningDot] a 5 px warning
/// dot 9 px to the left.
class _FieldTitleText extends StatelessWidget {
  const _FieldTitleText(this.title, {this.isSubTitle = false, this.required = false, this.warningDot = false});
  final String title;
  final bool isSubTitle, required, warningDot;

  @override
  Widget build(BuildContext context) {
    final style = isSubTitle ? DifyType.systemXsMediumUppercase : DifyType.systemSmSemiboldUppercase;
    final color = isSubTitle ? DifyColors.textTertiary : DifyColors.textSecondary;
    Widget text = Text.rich(
      TextSpan(
        text: difyTransform(style, title),
        children: [
          if (required)
            const TextSpan(
              text: ' *',
              style: TextStyle(color: DifyColors.textDestructive),
            ),
        ],
      ),
      style: difyStyle(style, color),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    if (warningDot) text = _WarningDot(child: text);
    return text;
  }
}

/// `absolute top-1/2 -left-2.25 size-1.25 -translate-y-1/2 rounded-full bg-text-warning-secondary`.
class _WarningDot extends StatelessWidget {
  const _WarningDot({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Stack(
    clipBehavior: Clip.none,
    alignment: Alignment.centerLeft,
    children: [
      child,
      Positioned(
        left: -9,
        child: Container(
          key: const Key('warning-dot'),
          width: 5,
          height: 5,
          decoration: const BoxDecoration(color: DifyColors.textWarningSecondary, shape: BoxShape.circle),
        ),
      ),
    ],
  );
}

/// Field (field.tsx): a 24 px title row (title, `*` when [required], an [Infotip] for [tooltip]) with [operations]
/// on the right, and [child] 4 px below. [supportFold] makes the row toggle the child (folded at first) with a
/// chevron; [inline] puts the child beside the title.
class Field extends StatefulWidget {
  const Field({
    super.key,
    required this.title,
    this.child,
    this.tooltip,
    this.isSubTitle = false,
    this.supportFold = false,
    this.operations,
    this.inline = false,
    this.required = false,
    this.warningDot = false,
  });

  final String title;
  final Widget? child;
  final String? tooltip;
  final bool isSubTitle, supportFold, inline, required, warningDot;
  final Widget? operations;

  @override
  State<Field> createState() => _FieldState();
}

class _FieldState extends State<Field> {
  bool _fold = true;

  @override
  Widget build(BuildContext context) {
    final w = widget;
    Widget header = Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Flexible(
          child: SizedBox(
            height: 24,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: _FieldTitleText(
                    w.title,
                    isSubTitle: w.isSubTitle,
                    required: w.required,
                    warningDot: w.warningDot,
                  ),
                ),
                if (w.tooltip != null && w.tooltip!.isNotEmpty) ...[
                  const SizedBox(width: 4),
                  Infotip(label: w.tooltip!, content: Text(w.tooltip!)),
                ],
              ],
            ),
          ),
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ?w.operations,
            if (w.supportFold)
              AnimatedRotation(
                turns: _fold ? -0.25 : 0,
                duration: difyTransitionDuration,
                child: const RemixIcon('arrow-down-s-line', size: 16, color: DifyColors.textTertiary),
              ),
          ],
        ),
      ],
    );
    if (w.supportFold) {
      header = MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _fold = !_fold),
          child: header,
        ),
      );
    }
    final showChild = w.child != null && (!w.supportFold || !_fold);
    if (w.inline) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(child: header),
          if (showChild) w.child!,
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        header,
        if (showChild) Padding(padding: const EdgeInsets.only(top: 4), child: w.child),
      ],
    );
  }
}

/// Split (split.tsx, `PanelSplit` beside Flutter's Split curve): `h-[0.5px] bg-divider-subtle`, with the call site's margin.
class PanelSplit extends StatelessWidget {
  const PanelSplit({super.key, this.margin = EdgeInsets.zero});
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) => Container(margin: margin, height: 0.5, color: DifyColors.dividerSubtle);
}

/// CollapseIndicator: `arrow-down-round-fill` 16 px in `text-text-quaternary` (secondary on hover), turned 270 deg
/// while closed.
class CollapseIndicator extends StatelessWidget {
  const CollapseIndicator({super.key, required this.open, this.hovered = false});
  final bool open, hovered;

  @override
  Widget build(BuildContext context) => AnimatedRotation(
    turns: open ? 0 : 0.75,
    duration: MediaQuery.maybeDisableAnimationsOf(context) ?? false ? Duration.zero : difyTransitionDuration,
    child: DifyIcon(
      'vender/solid/general/arrow-down-round-fill',
      size: 16,
      color: hovered ? DifyColors.textSecondary : DifyColors.textQuaternary,
    ),
  );
}

/// Collapse (collapse/index.tsx on dify-ui's Collapsible): a header whose trigger (the [title] in
/// `system-sm-semibold-uppercase text-text-secondary`, `ml-4 h-6`, and the indicator) toggles [child]. Closed at
/// first; with [collapsed] set it is controlled and a click only asks [onCollapse]. [disabled] ignores clicks.
/// [afterTrigger] sits right of the trigger (an infotip), [actions] at the end (`ml-auto`).
class PanelCollapse extends StatefulWidget {
  const PanelCollapse({
    super.key,
    required this.title,
    required this.child,
    this.collapsed,
    this.onCollapse,
    this.disabled = false,
    this.indicator = true,
    this.afterTrigger,
    this.actions,
  });

  final String title;
  final Widget child;
  final bool? collapsed;
  final ValueChanged<bool>? onCollapse;
  final bool disabled;

  /// Shows the CollapseIndicator.
  final bool indicator;
  final Widget? afterTrigger;
  final Widget? actions;

  @override
  State<PanelCollapse> createState() => _PanelCollapseState();
}

class _PanelCollapseState extends State<PanelCollapse> {
  bool _open = false, _hovered = false;

  bool get _isOpen => widget.collapsed == null ? _open : !widget.collapsed!;

  void _toggle() {
    if (widget.disabled) return;
    final open = !_isOpen;
    if (widget.collapsed == null) setState(() => _open = open);
    widget.onCollapse?.call(!open);
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final trigger = Semantics(
      button: true,
      expanded: _isOpen,
      enabled: !w.disabled,
      onTap: w.disabled ? null : _toggle,
      child: MouseRegion(
        cursor: w.disabled ? SystemMouseCursors.forbidden : SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          excludeFromSemantics: true,
          onTap: _toggle,
          child: Container(
            height: 24,
            margin: const EdgeInsets.only(left: 16),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: DifyText(
                    w.title,
                    DifyType.systemSmSemiboldUppercase,
                    color: w.disabled ? DifyColors.textSecondary : DifyColors.textSecondary,
                  ),
                ),
                if (w.indicator) CollapseIndicator(open: _isOpen, hovered: _hovered && !w.disabled),
              ],
            ),
          ),
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: Row(
                children: [
                  Flexible(child: trigger),
                  ?w.afterTrigger,
                ],
              ),
            ),
            if (w.actions != null)
              Flexible(
                child: Align(alignment: Alignment.centerRight, child: w.actions),
              ),
          ],
        ),
        if (_isOpen) w.child,
      ],
    );
  }
}

/// FieldCollapse: a [PanelCollapse] in `py-4` with its content in `px-4`.
class FieldCollapse extends StatelessWidget {
  const FieldCollapse({
    super.key,
    required this.title,
    required this.child,
    this.collapsed,
    this.onCollapse,
    this.actions,
  });

  final String title;
  final Widget child;
  final bool? collapsed;
  final ValueChanged<bool>? onCollapse;
  final Widget? actions;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 16),
    child: PanelCollapse(
      title: title,
      collapsed: collapsed,
      onCollapse: onCollapse,
      actions: actions,
      child: Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: child),
    ),
  );
}

/// FieldTitle (layout/field-title.tsx): a `py-1` row with the title (`system-sm-semibold-uppercase`), an arrow when
/// [showArrow] (turned while collapsed), an infotip for [tooltip] and [operation] at the end; [subTitle] below.
/// Collapsed at first unless [collapsed] controls it; clicks report [onCollapse] unless [disabled].
class FieldTitle extends StatefulWidget {
  const FieldTitle({
    super.key,
    this.title,
    this.operation,
    this.subTitle,
    this.tooltip,
    this.warningDot = false,
    this.showArrow = false,
    this.disabled = false,
    this.collapsed,
    this.onCollapse,
  });

  final String? title;
  final Widget? operation;
  final Widget? subTitle;
  final String? tooltip;
  final bool warningDot, showArrow, disabled;
  final bool? collapsed;
  final ValueChanged<bool>? onCollapse;

  @override
  State<FieldTitle> createState() => _FieldTitleState();
}

class _FieldTitleState extends State<FieldTitle> {
  bool _collapsed = true, _hovered = false;

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final collapsed = w.collapsed ?? _collapsed;
    return Padding(
      padding: EdgeInsets.only(bottom: w.subTitle != null ? 4 : 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          MouseRegion(
            onEnter: (_) => setState(() => _hovered = true),
            onExit: (_) => setState(() => _hovered = false),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                if (w.disabled) return;
                setState(() => _collapsed = !collapsed);
                w.onCollapse?.call(!collapsed);
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Flexible(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(child: _FieldTitleText(w.title ?? '', warningDot: w.warningDot)),
                          if (w.showArrow)
                            Transform.rotate(
                              key: const Key('field-title-arrow'),
                              angle: collapsed ? 4.71238898 : 0,
                              child: DifyIcon(
                                'vender/solid/general/arrow-down-round-fill',
                                size: 16,
                                color: _hovered ? DifyColors.textSecondary : DifyColors.textQuaternary,
                              ),
                            ),
                          if (w.tooltip != null) ...[
                            const SizedBox(width: 4),
                            Infotip(label: w.tooltip!, content: Text(w.tooltip!)),
                          ],
                        ],
                      ),
                    ),
                    ?w.operation,
                  ],
                ),
              ),
            ),
          ),
          ?w.subTitle,
        ],
      ),
    );
  }
}

/// Field (layout/field.tsx): a [FieldTitle] over [child]; with [supportCollapse] the title toggles it (open at
/// first).
class LayoutField extends StatefulWidget {
  const LayoutField({
    super.key,
    this.title,
    this.operation,
    this.subTitle,
    this.tooltip,
    this.warningDot = false,
    this.child,
    this.supportCollapse = false,
    this.disabled = false,
  });

  final String? title;
  final Widget? operation;
  final Widget? subTitle;
  final String? tooltip;
  final bool warningDot;
  final Widget? child;
  final bool supportCollapse, disabled;

  @override
  State<LayoutField> createState() => _LayoutFieldState();
}

class _LayoutFieldState extends State<LayoutField> {
  bool _collapsed = false;

  @override
  Widget build(BuildContext context) {
    final w = widget;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        FieldTitle(
          title: w.title,
          operation: w.operation,
          subTitle: w.subTitle,
          tooltip: w.tooltip,
          warningDot: w.warningDot,
          collapsed: _collapsed,
          onCollapse: (v) => setState(() => _collapsed = v),
          showArrow: w.supportCollapse,
          disabled: w.disabled,
        ),
        if (w.child != null && (!w.supportCollapse || !_collapsed)) w.child!,
      ],
    );
  }
}

/// Box (`py-2`) and Group (`px-4 py-2`) of layout/, each optionally with a `border-b border-divider-subtle`.
class PanelBox extends StatelessWidget {
  const PanelBox({super.key, required this.child, this.withBorderBottom = false, this.group = false});

  /// A Group (`px-4 py-2`) rather than a Box (`py-2`).
  const PanelBox.group({super.key, required this.child, this.withBorderBottom = false}) : group = true;

  final Widget child;
  final bool withBorderBottom, group;

  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.symmetric(horizontal: group ? 16 : 0, vertical: 8),
    decoration: withBorderBottom
        ? const BoxDecoration(
            border: Border(bottom: BorderSide(color: DifyColors.dividerSubtle)),
          )
        : null,
    child: child,
  );
}

/// BoxGroup: a Box around a Group.
class BoxGroup extends StatelessWidget {
  const BoxGroup({super.key, required this.child, this.boxBorderBottom = false, this.groupBorderBottom = false});
  final Widget child;
  final bool boxBorderBottom, groupBorderBottom;

  @override
  Widget build(BuildContext context) => PanelBox(
    withBorderBottom: boxBorderBottom,
    child: PanelBox.group(withBorderBottom: groupBorderBottom, child: child),
  );
}

/// BoxGroupField: a [BoxGroup] around a [LayoutField].
class BoxGroupField extends StatelessWidget {
  const BoxGroupField({super.key, required this.field, this.boxBorderBottom = false, this.groupBorderBottom = false});
  final LayoutField field;
  final bool boxBorderBottom, groupBorderBottom;

  @override
  Widget build(BuildContext context) =>
      BoxGroup(boxBorderBottom: boxBorderBottom, groupBorderBottom: groupBorderBottom, child: field);
}

/// TreeIndentLine: [depth] 1 px lines in `divider-regular`, each with 10 px either side, as tall as the row.
class TreeIndentLine extends StatelessWidget {
  const TreeIndentLine({super.key, this.depth = 1});
  final int depth;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (var i = 0; i < depth; i++)
        Container(width: 1, margin: const EdgeInsets.symmetric(horizontal: 10), color: DifyColors.dividerRegular),
    ],
  );
}

/// OutputVars (output-vars.tsx): a [FieldCollapse] titled "Output Variables" unless [title] is given.
class OutputVars extends StatelessWidget {
  const OutputVars({super.key, this.title, required this.child, this.operations, this.collapsed, this.onCollapse});
  final String? title;
  final Widget child;
  final Widget? operations;
  final bool? collapsed;
  final ValueChanged<bool>? onCollapse;

  @override
  Widget build(BuildContext context) => FieldCollapse(
    title: title ?? DifyI18n.tr('workflow', 'nodes.common.outputVars'),
    actions: operations,
    collapsed: collapsed,
    onCollapse: onCollapse,
    child: child,
  );
}

/// VarItem (output-vars.tsx): the name (`code-sm-semibold text-text-secondary`), its type (`ml-2 system-xs-regular
/// text-text-tertiary`) and description below, with [subItems] indented behind a `border-l border-gray-200`.
class VarItem extends StatelessWidget {
  const VarItem({
    super.key,
    required this.name,
    required this.type,
    this.description = '',
    this.subItems,
    this.isIndent = false,
  });

  final String name, type, description;
  final List<({String name, String type, String description})>? subItems;
  final bool isIndent;

  @override
  Widget build(BuildContext context) {
    final tertiary = difyStyle(DifyType.systemXsRegular, DifyColors.textTertiary);
    Widget item = Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 18,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(child: DifyText(name, DifyType.codeSmSemibold, color: DifyColors.textSecondary)),
                const SizedBox(width: 8),
                DifyText(type, DifyType.systemXsRegular, color: DifyColors.textTertiary),
              ],
            ),
          ),
          const SizedBox(height: 2),
          if (description.isNotEmpty) Text(description, style: tertiary),
          if (subItems != null)
            Container(
              margin: const EdgeInsets.only(left: 8),
              padding: const EdgeInsets.only(left: 8),
              decoration: const BoxDecoration(
                border: Border(left: BorderSide(color: DifyColors.utilColorsGrayGray200)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final s in subItems!) VarItem(name: s.name, type: s.type, description: s.description),
                ],
              ),
            ),
        ],
      ),
    );
    if (!isIndent) return item;
    return Transform.translate(
      offset: const Offset(-7, 0),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const TreeIndentLine(),
            Expanded(child: item),
          ],
        ),
      ),
    );
  }
}

/// InfoPanel (info-panel.tsx): `flex flex-col gap-y-0.5 rounded-md bg-workflow-block-parma-bg px-1.25 py-0.75`, the
/// [title] in `system-2xs-semibold-uppercase text-text-secondary` over [content] (`system-xs-regular
/// text-text-tertiary`).
class InfoPanel extends StatelessWidget {
  const InfoPanel({super.key, required this.title, required this.content});
  final String title;
  final Widget content;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
    decoration: BoxDecoration(
      color: DifyColors.workflowBlockParmaBg,
      borderRadius: BorderRadius.circular(DifyRadius.md),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      spacing: 2,
      children: [
        DifyText(title, DifyType.system2xsSemiboldUppercase, color: DifyColors.textSecondary),
        DefaultTextStyle.merge(
          style: difyStyle(DifyType.systemXsRegular, DifyColors.textTertiary),
          child: content,
        ),
      ],
    ),
  );
}

/// OptionCard (option-card.tsx): a 32 px `rounded-md border` option; selected `border-[1.5px]` in the selected
/// colours with `system-sm-medium`; unselected ones highlight on hover and call [onSelect].
class OptionCard extends StatefulWidget {
  const OptionCard({
    super.key,
    required this.title,
    required this.onSelect,
    required this.selected,
    this.disabled = false,
    this.align = MainAxisAlignment.center,
    this.tooltip,
  });

  final String title;
  final VoidCallback onSelect;
  final bool selected, disabled;
  final MainAxisAlignment align;
  final String? tooltip;

  @override
  State<OptionCard> createState() => _OptionCardState();
}

class _OptionCardState extends State<OptionCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final interactive = !w.selected && !w.disabled;
    final hovered = _hovered && interactive;
    final selected = w.selected && !w.disabled;
    return Semantics(
      button: true,
      selected: w.selected,
      enabled: !w.disabled,
      child: MouseRegion(
        cursor: interactive ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: interactive ? w.onSelect : null,
          child: Container(
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: selected
                  ? DifyColors.componentsOptionCardOptionSelectedBg
                  : hovered
                  ? DifyColors.componentsOptionCardOptionBgHover
                  : DifyColors.componentsOptionCardOptionBg,
              borderRadius: BorderRadius.circular(DifyRadius.md),
              border: Border.all(
                color: selected
                    ? DifyColors.componentsOptionCardOptionSelectedBorder
                    : hovered
                    ? DifyColors.componentsOptionCardOptionBorderHover
                    : DifyColors.componentsOptionCardOptionBorder,
                width: selected ? 1.5 : 1,
              ),
              boxShadow: selected || hovered ? DifyShadows.xs : null,
            ),
            child: Row(
              mainAxisAlignment: w.align,
              children: [
                DifyText(
                  w.title,
                  selected ? DifyType.systemSmMedium : DifyType.systemSmRegular,
                  color: w.disabled ? DifyColors.textDisabled : DifyColors.textSecondary,
                ),
                if (w.tooltip != null) Infotip(label: w.tooltip!, width: 240, content: Text(w.tooltip!)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// InputVarTypeIcon (input-var-type-icon.tsx): the Remix icon of a Start input type.
class InputVarTypeIcon extends StatelessWidget {
  const InputVarTypeIcon({super.key, required this.type, this.size = 14, this.color = DifyColors.textTertiary});
  final String type;
  final double size;
  final Color color;

  static String iconOf(String type) => switch (type) {
    'paragraph' => 'align-left',
    'select' => 'checkbox-multiple-line',
    'number' => 'hashtag',
    'checkbox' => 'checkbox-line',
    'json_object' => 'braces-line',
    'file' => 'file-list-2-line',
    'file-list' => 'file-copy-2-line',
    _ => 'text-snippet',
  };

  @override
  Widget build(BuildContext context) => RemixIcon(iconOf(type), size: size, color: color);
}

/// RemoveButton (remove-button.tsx): a destructive 32 px icon button with `i-ri-delete-bin-line`, labelled "Remove".
class RemoveButton extends StatelessWidget {
  const RemoveButton({super.key, required this.onPressed, this.focusNode});
  final VoidCallback? onPressed;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) => DifyIconButton(
    label: DifyI18n.tr('common', 'operation.remove'),
    size: DifyIconButtonSize.lg,
    tone: DifyButtonTone.destructive,
    focusNode: focusNode,
    onPressed: onPressed,
    icon: const RemixIcon('delete-bin-line', size: 16),
  );
}

/// AddButton (add-button.tsx): a full-width tertiary medium button with `RiAddLine` 14 px and [text].
class AddButton extends StatelessWidget {
  const AddButton({super.key, required this.text, required this.onPressed});
  final String text;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: double.infinity,
    child: DifyButton(
      variant: DifyButtonVariant.tertiary,
      onPressed: onPressed,
      leading: const RemixIcon('add-line', size: 14),
      child: Text(text),
    ),
  );
}

/// HelpLink (help-link.tsx): a 24 px book icon opening the node's docs ([onOpen] with [link]); nothing without a
/// link. Tooltip "Help Center".
class HelpLink extends StatelessWidget {
  const HelpLink({super.key, required this.link, required this.onOpen});
  final String? link;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    if (link == null || link!.isEmpty) return const SizedBox.shrink();
    final label = DifyI18n.tr('common', 'userProfile.helpCenter');
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: DifyTooltip(
        content: Text(label),
        child: DifyIconButton(
          label: label,
          onPressed: () => onOpen(link!),
          icon: const RemixIcon('book-open-line', size: 16, color: DifyColors.utilColorsGrayGray500),
        ),
      ),
    );
  }
}

/// ToggleExpandBtn (toggle-expand-btn.tsx): the expand / collapse diagonal icon button.
class ToggleExpandBtn extends StatelessWidget {
  const ToggleExpandBtn({super.key, required this.isExpand, required this.onExpandChange});
  final bool isExpand;
  final ValueChanged<bool> onExpandChange;

  @override
  Widget build(BuildContext context) => DifyIconButton(
    label: DifyI18n.tr('share', isExpand ? 'chat.collapse' : 'chat.expand'),
    onPressed: () => onExpandChange(!isExpand),
    icon: RemixIcon(isExpand ? 'collapse-diagonal-line' : 'expand-diagonal-line', size: 16),
  );
}
