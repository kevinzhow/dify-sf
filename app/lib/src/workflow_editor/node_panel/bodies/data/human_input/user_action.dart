/// The User Actions rows (components/user-action.tsx, button-style-dropdown.tsx) and the Timeout input
/// (components/timeout.tsx).
library;

import 'package:flutter/material.dart';

import '../../../../../cards/card_kit.dart';
import '../../../../../design/dify_icon.dart';
import '../../../../../design/dify_tokens.g.dart';
import '../../../../../design/widgets/widgets.dart';
import '../../../../panel_fields/panel_fields.dart';
import '../data_common.dart';
import 'human_input_kit.dart';
import 'human_input_model.dart';

/// `getButtonStyle` (human-input-content/utils.ts): the button variant of a user action style.
DifyButtonVariant buttonVariantOf(String? style) => switch (style) {
  UserActionButtonType.primary => DifyButtonVariant.primary,
  UserActionButtonType.defaultStyle => DifyButtonVariant.secondary,
  UserActionButtonType.accent => DifyButtonVariant.secondaryAccent,
  _ => DifyButtonVariant.ghost,
};

/// UserActionItem: the action's ID (`w-30`, "Action Name") and title ("Action Value") inputs, the style dropdown and
/// a delete button (`lg tertiary`). IDs are sanitised as typed (spaces become `_`, other invalid characters reject
/// the edit with a toast, more than 20 characters are cut with a toast); titles are cut at 100 characters. Typed
/// text is a draft committed on blur ([onChange] with the version it began on).
class UserActionItem extends StatefulWidget {
  const UserActionItem({
    super.key,
    required this.data,
    required this.onChange,
    required this.onDelete,
    this.readonly = false,
    this.version,
  });

  final Map<String, Object?> data;
  final void Function(Map<String, Object?> action, int? base) onChange;
  final ValueChanged<String> onDelete;
  final bool readonly;
  final int Function()? version;

  @override
  State<UserActionItem> createState() => _UserActionItemState();
}

class _UserActionItemState extends State<UserActionItem> {
  late final _idFocus = FocusNode(debugLabel: 'action id')..addListener(_blurred);
  late final _titleFocus = FocusNode(debugLabel: 'action title')..addListener(_blurred);
  late final _draft = TextDraft(widget.version);
  late String _id = _str('id'), _title = _str('title');

  String _str(String key) => '${widget.data[key] ?? ''}';

  @override
  void didUpdateWidget(UserActionItem old) {
    super.didUpdateWidget(old);
    if (!_draft.isOpen) {
      _id = _str('id');
      _title = _str('title');
    }
  }

  @override
  void dispose() {
    _commit();
    _idFocus.dispose();
    _titleFocus.dispose();
    super.dispose();
  }

  void _blurred() {
    if (!_idFocus.hasFocus && !_titleFocus.hasFocus) _commit();
  }

  void _commit() {
    final d = _draft.take();
    if (d == null || (_id == _str('id') && _title == _str('title'))) return;
    widget.onChange({...widget.data, 'id': _id, 'title': _title}, d.base);
  }

  void _onId(String value) {
    final r = sanitizeActionId(value);
    if (r.error != null) {
      final params = r.error == 'actionIdTooLong' ? {'maxLength': actionIdMaxLength} : const <String, Object?>{};
      showDataToast(context, DataToastType.error, hi('userActions.${r.error}', params));
    }
    if (r.id != null) {
      _draft.touch();
      _id = r.id!;
    }
    // A rejected or rewritten edit shows the kept ID again.
    setState(() {});
  }

  void _onTitle(String value) {
    final r = sanitizeActionTitle(value);
    if (r.tooLong) {
      showDataToast(
        context,
        DataToastType.error,
        hi('userActions.buttonTextTooLong', {'maxLength': actionValueMaxLength}),
      );
    }
    _draft.touch();
    setState(() => _title = r.title);
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final idLabel = hi('userActions.actionNamePlaceholder'), titleLabel = hi('userActions.buttonTextPlaceholder');
    return Row(
      spacing: 4,
      children: [
        SizedBox(
          width: 120,
          child: DifyInput(
            value: _id,
            focusNode: _idFocus,
            placeholder: idLabel,
            semanticLabel: idLabel,
            disabled: w.readonly,
            onChanged: _onId,
            onSubmitted: (_) => _commit(),
          ),
        ),
        Expanded(
          child: DifyInput(
            value: _title,
            focusNode: _titleFocus,
            placeholder: titleLabel,
            semanticLabel: titleLabel,
            disabled: w.readonly,
            onChanged: _onTitle,
            onSubmitted: (_) => _commit(),
          ),
        ),
        ButtonStyleDropdown(
          text: _title,
          value: '${w.data['button_style'] ?? ''}',
          readonly: w.readonly,
          onChange: (style) => w.onChange({...w.data, 'id': _id, 'title': _title, 'button_style': style}, null),
        ),
        if (!w.readonly)
          DifyIconButton(
            label: cm('operation.delete'),
            size: DifyIconButtonSize.lg,
            variant: DifyButtonVariant.tertiary,
            onPressed: () => w.onDelete(_str('id')),
            icon: const RemixIcon('delete-bin-line', size: 16),
          ),
      ],
    );
  }
}

/// ButtonStyleDropdown: a tertiary box (`rounded-lg p-1`) around a small button in the current style with
/// `RiFontSize`; opens (not when [readonly]) "Choose a button style" with four 160 x 80 tiles previewing [text] as
/// Primary, Default, Accent and Ghost buttons, the current one outlined.
class ButtonStyleDropdown extends StatefulWidget {
  const ButtonStyleDropdown({
    super.key,
    required this.text,
    required this.value,
    required this.onChange,
    this.readonly = false,
  });

  final String text, value;
  final ValueChanged<String> onChange;
  final bool readonly;

  @override
  State<ButtonStyleDropdown> createState() => _ButtonStyleDropdownState();
}

class _ButtonStyleDropdownState extends State<ButtonStyleDropdown> {
  final _popup = DifyFloatingController();

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final text = w.text.isEmpty ? 'Button Text' : w.text;
    return DifyFloating(
      controller: _popup,
      placement: DifyPlacement.bottomEnd,
      sideOffset: 4,
      alignOffset: 44,
      builder: (context, c) => DifyPressable(
        semanticLabel: hi('userActions.chooseStyle'),
        onPressed: w.readonly ? null : c.toggle,
        builder: (context, hovered, _) => Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: (hovered && !w.readonly) || c.isOpen
                ? DifyColors.componentsButtonTertiaryBgHover
                : DifyColors.componentsButtonTertiaryBg,
            borderRadius: BorderRadius.circular(DifyRadius.lg),
          ),
          child: IgnorePointer(
            child: DifyButton(
              size: DifyButtonSize.small,
              paddingX: 4,
              variant: buttonVariantOf(w.value),
              onPressed: () {},
              child: const RemixIcon('font-size', size: 16),
            ),
          ),
        ),
      ),
      popupBuilder: (context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: DifyColors.componentsPanelBgBlur,
          borderRadius: BorderRadius.circular(DifyRadius.xl),
          border: Border.all(color: DifyColors.componentsPanelBorder, width: 0.5),
          boxShadow: DifyShadows.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DifyText(hi('userActions.chooseStyle'), DifyType.systemMdMedium, color: DifyColors.textPrimary),
            const SizedBox(height: 8),
            SizedBox(
              width: 324,
              child: Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [
                  for (final style in const [
                    UserActionButtonType.primary,
                    UserActionButtonType.defaultStyle,
                    UserActionButtonType.accent,
                    UserActionButtonType.ghost,
                  ])
                    _StyleTile(
                      text: text,
                      style: style,
                      selected: w.value == style,
                      onTap: () => w.onChange(style),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StyleTile extends StatelessWidget {
  const _StyleTile({required this.text, required this.style, required this.selected, required this.onTap});
  final String text, style;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => DifyPressable(
    semanticLabel: text,
    onPressed: onTap,
    builder: (context, hovered, _) => Container(
      width: 160,
      height: 80,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: hovered ? DifyColors.backgroundSectionBurn : DifyColors.backgroundSection,
        borderRadius: BorderRadius.circular(DifyRadius.lg),
        border: Border.all(
          color: selected ? DifyColors.componentsOptionCardOptionSelectedBorder : const Color(0x00000000),
          width: 1.5,
        ),
      ),
      child: IgnorePointer(
        child: ExcludeSemantics(
          child: DifyButton(variant: buttonVariantOf(style), onPressed: () {}, child: Text(text)),
        ),
      ),
    ),
  );
}

/// TimeoutInput: a 64 px number field (min 1; cleared gives 1) and the Days / Hours segmented control.
class TimeoutInput extends StatelessWidget {
  const TimeoutInput({
    super.key,
    required this.timeout,
    required this.unit,
    required this.onChange,
    this.readonly = false,
  });

  final num timeout;
  final String unit;
  final void Function(num timeout, String unit) onChange;
  final bool readonly;

  @override
  Widget build(BuildContext context) {
    final label = hi('timeout.title');
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 4,
      children: [
        SizedBox(
          width: 64,
          child: DifyNumberField(
            value: timeout,
            min: 1,
            semanticLabel: label,
            disabled: readonly,
            onChanged: (v) => onChange(v ?? 1, unit),
          ),
        ),
        DifySegmentedControl<String>(
          value: unit,
          disabled: readonly,
          onChanged: (u) => onChange(timeout, u),
          itemPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          textColor: DifyColors.textTertiary,
          segments: [
            for (final (value, key) in const [('day', 'timeout.days'), ('hour', 'timeout.hours')])
              (
                value: value,
                label: hi(key),
                child: Padding(padding: const EdgeInsets.all(2), child: Text(hi(key))),
              ),
          ],
        ),
      ],
    );
  }
}

/// The `+` icon button of a section header (`common.operation.add`).
class HiAddButton extends StatelessWidget {
  const HiAddButton({super.key, required this.onPressed, this.label});
  final VoidCallback onPressed;
  final String? label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 4),
    child: DifyIconButton(
      label: label ?? cm('operation.add'),
      onPressed: onPressed,
      icon: const RemixIcon('add-line', size: 16),
    ),
  );
}
