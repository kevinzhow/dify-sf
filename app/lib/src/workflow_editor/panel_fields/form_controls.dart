/// The small form controls more than one node panel group uses: dify-ui's Checkbox and Textarea, base/tag-input,
/// base/checkbox-list, ListNoDataPlaceholder, BoolValue / ArrayBoolList (chat-variable-panel), InputNumberWithSlider,
/// VariableTag, and the config-var modal's parts (config-modal/field.tsx, type-select.tsx, config-select).
library;

import 'package:collab_client/collab_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../cards/card_kit.dart';
import '../../design/css_metrics.dart';
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';
import '../../workflow/output_vars.dart' show inputVarTypeToVarType;
import 'controls.dart';
import 'field.dart';
import 'selectors.dart' show SelectOption;
import 'var_picker_model.dart' show VarScope;
import 'var_reference_picker.dart' show isExceptionVariable;

// ---- Checkbox ----------------------------------------------------------------------------------------------------

/// dify-ui's Checkbox box (16 px, `rounded-[4px] shadow-xs`): the accent background with a white check (or a dash
/// when [indeterminate]) when checked; the hover and disabled colours. Only the look: [DifyCheckbox] is the control.
class DifyCheckboxBox extends StatelessWidget {
  const DifyCheckboxBox({
    super.key,
    required this.checked,
    this.indeterminate = false,
    this.disabled = false,
    this.hovered = false,
    this.focused = false,
  });

  final bool checked, indeterminate, disabled, hovered, focused;

  @override
  Widget build(BuildContext context) {
    final on = checked || indeterminate;
    final Color bg, border;
    if (disabled) {
      bg = on ? DifyColors.componentsCheckboxBgDisabledChecked : DifyColors.componentsCheckboxBgDisabled;
      border = on ? const Color(0x00000000) : DifyColors.componentsCheckboxBorderDisabled;
    } else if (on) {
      bg = hovered ? DifyColors.componentsCheckboxBgHover : DifyColors.componentsCheckboxBg;
      border = const Color(0x00000000);
    } else {
      bg = hovered ? DifyColors.componentsCheckboxBgUncheckedHover : DifyColors.componentsCheckboxBgUnchecked;
      border = hovered ? DifyColors.componentsCheckboxBorderHover : DifyColors.componentsCheckboxBorder;
    }
    final icon = disabled ? DifyColors.componentsCheckboxIconDisabled : DifyColors.componentsCheckboxIcon;
    return Container(
      width: 16,
      height: 16,
      decoration: BoxDecoration(
        color: bg,
        border: Border.all(color: border),
        borderRadius: BorderRadius.circular(4),
        boxShadow: focused
            ? const [BoxShadow(color: DifyColors.stateAccentSolid, spreadRadius: 2)]
            : const [BoxShadow(color: DifyColors.shadowShadow3, offset: Offset(0, 1), blurRadius: 2)],
      ),
      child: !on
          ? null
          : indeterminate
          ? Center(child: Container(width: 8, height: 1.5, color: icon))
          : RemixIcon('check-line', size: 12, color: icon),
    );
  }
}

/// dify-ui's Checkbox: a [DifyCheckboxBox] that toggles on a click (or Space / Enter), named [label].
class DifyCheckbox extends StatelessWidget {
  const DifyCheckbox({
    super.key,
    required this.checked,
    this.onChanged,
    this.disabled = false,
    this.indeterminate = false,
    this.label,
  });

  final bool checked, disabled, indeterminate;
  final ValueChanged<bool>? onChanged;
  final String? label;

  @override
  Widget build(BuildContext context) => Semantics(
    checked: checked,
    label: label,
    child: DifyPressable(
      disabled: disabled,
      onPressed: onChanged == null ? null : () => onChanged!(!checked),
      builder: (context, hovered, focused) => DifyCheckboxBox(
        checked: checked,
        indeterminate: indeterminate,
        disabled: disabled,
        hovered: hovered,
        focused: focused,
      ),
    ),
  );
}

// ---- Textarea ----------------------------------------------------------------------------------------------------

/// dify-ui's Textarea (medium): `min-h-20 rounded-lg px-3 py-2 system-sm-regular` on the input colours (hover and
/// focus borders, `shadow-xs` while focused). [minHeight] and [verticalPadding] follow the call site's classes.
class DifyTextarea extends StatefulWidget {
  const DifyTextarea({
    super.key,
    required this.value,
    this.onChanged,
    this.onFocusChange,
    this.placeholder,
    this.semanticLabel,
    this.disabled = false,
    this.minHeight = 80,
    this.verticalPadding = 8,
  });

  /// The text shown; a different value replaces what is typed.
  final String value;
  final ValueChanged<String>? onChanged;
  final ValueChanged<bool>? onFocusChange;
  final String? placeholder, semanticLabel;
  final bool disabled;
  final double minHeight, verticalPadding;

  @override
  State<DifyTextarea> createState() => _DifyTextareaState();
}

class _DifyTextareaState extends State<DifyTextarea> {
  late final _controller = TextEditingController(text: widget.value);
  final _focus = FocusNode(debugLabel: 'textarea');
  bool _hovered = false, _focused = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (_focus.hasFocus == _focused) return;
      setState(() => _focused = _focus.hasFocus);
      widget.onFocusChange?.call(_focused);
    });
  }

  @override
  void didUpdateWidget(DifyTextarea old) {
    super.didUpdateWidget(old);
    if (_controller.text != widget.value) _controller.text = widget.value;
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final focused = _focused && !w.disabled, hovered = _hovered && !w.disabled;
    final style = difyTextStyle(
      DifyType.systemSmRegular,
      w.disabled ? DifyColors.componentsInputTextFilledDisabled : DifyColors.componentsInputTextFilled,
    );
    return Semantics(
      label: w.semanticLabel,
      textField: true,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Container(
          constraints: BoxConstraints(minHeight: w.minHeight),
          decoration: BoxDecoration(
            color: w.disabled
                ? DifyColors.componentsInputBgDisabled
                : focused
                ? DifyColors.componentsInputBgActive
                : hovered
                ? DifyColors.componentsInputBgHover
                : DifyColors.componentsInputBgNormal,
            borderRadius: BorderRadius.circular(DifyRadius.lg),
            border: Border.all(
              color: focused
                  ? DifyColors.componentsInputBorderActive
                  : hovered
                  ? DifyColors.componentsInputBorderHover
                  : const Color(0x00000000),
            ),
            boxShadow: focused ? DifyShadows.xs : null,
          ),
          child: Material(
            type: MaterialType.transparency,
            child: TextField(
              controller: _controller,
              focusNode: _focus,
              enabled: !w.disabled,
              onChanged: w.onChanged,
              minLines: w.minHeight >= 80 ? 3 : null,
              maxLines: null,
              keyboardType: TextInputType.multiline,
              style: style,
              cursorColor: const Color(0xFF155EEF),
              cursorWidth: 1,
              decoration: InputDecoration(
                isCollapsed: true,
                border: InputBorder.none,
                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: w.verticalPadding),
                hintText: w.placeholder,
                hintStyle: style.copyWith(color: DifyColors.componentsInputTextPlaceholder),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---- TagInput ----------------------------------------------------------------------------------------------------

String _docs(String key) => DifyI18n.tr('dataset-documents', key);

/// base/tag-input: the [items] as chips with a remove button each, then a dashed "+" field that adds its trimmed
/// text on [customizedConfirmKey] (Enter) or blur. Empty text is ignored (an error when [required]); duplicates and
/// tags over 20 characters are refused with [onError] (Dify's `toast.error`). With Tab as the confirm key (the stop
/// sequences) the whole input is the `rounded-lg bg-components-input-bg-normal` box and Enter types `↵`.
class TagInput extends StatefulWidget {
  const TagInput({
    super.key,
    required this.items,
    required this.onChange,
    this.placeholder,
    this.label,
    this.disableAdd = false,
    this.disableRemove = false,
    this.required = false,
    this.isInWorkflow = false,
    this.customizedConfirmKey = LogicalKeyboardKey.enter,
    this.onError,
  });

  final List<String> items;
  final ValueChanged<List<String>> onChange;
  final String? placeholder;

  /// The input's accessible name.
  final String? label;
  final bool disableAdd, disableRemove, required, isInWorkflow;
  final LogicalKeyboardKey customizedConfirmKey;

  /// `toast.error` with the message; none: refused tags are dropped silently.
  final ValueChanged<String>? onError;

  @override
  State<TagInput> createState() => _TagInputState();
}

class _TagInputState extends State<TagInput> {
  final _text = TextEditingController();
  late final _focus = FocusNode(debugLabel: 'TagInput', onKeyEvent: _onKey)..addListener(_onFocus);
  bool _focused = false;

  bool get _special => widget.customizedConfirmKey == LogicalKeyboardKey.tab;

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onFocus() {
    if (_focus.hasFocus == _focused) return;
    setState(() => _focused = _focus.hasFocus);
    if (!_focus.hasFocus) _newTag(_text.text);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    if (_special && e.logicalKey == LogicalKeyboardKey.enter) {
      _text.text = '${_text.text}↵';
      return KeyEventResult.handled;
    }
    if (e.logicalKey == widget.customizedConfirmKey && e.logicalKey != LogicalKeyboardKey.enter) {
      _newTag(_text.text);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// `handleNewTag`.
  void _newTag(String value) {
    final w = widget;
    final v = value.trim();
    if (v.isEmpty) {
      if (w.required) w.onError?.call(_docs('segment.keywordEmpty'));
      return;
    }
    if (w.items.contains(v)) {
      w.onError?.call(_docs('segment.keywordDuplicate'));
      return;
    }
    if (v.length > 20) {
      w.onError?.call(_docs('segment.keywordError'));
      return;
    }
    w.onChange([...w.items, v]);
    _text.clear();
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final placeholder =
        w.placeholder ??
        (_special ? DifyI18n.tr('common', 'model.params.stop_sequencesPlaceholder') : _docs('segment.addKeyWord'));
    final style = difyStyle(DifyType.systemXsRegular, DifyColors.textPrimary);
    final hintStyle = style.copyWith(color: DifyColors.textPlaceholder);
    Widget input = ListenableBuilder(
      listenable: _text,
      builder: (context, _) {
        final shown = _text.text.isEmpty ? placeholder : _text.text;
        final p = TextPainter(
          text: TextSpan(text: shown, style: style),
          textDirection: TextDirection.ltr,
          maxLines: 1,
        )..layout();
        final width = p.width.ceilToDouble() + 2;
        p.dispose();
        return SizedBox(
          width: width.clamp(0, w.isInWorkflow ? 146 : 300),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: TextField(
              controller: _text,
              focusNode: _focus,
              style: style,
              cursorColor: const Color(0xFF295EFF),
              cursorWidth: 1,
              decoration: InputDecoration.collapsed(hintText: placeholder, hintStyle: hintStyle),
              // Enter adds the tag and keeps the focus (no blur, which would add again).
              onEditingComplete: () {},
              onSubmitted: (v) {
                if (!_special) _newTag(v);
              },
            ),
          ),
        );
      },
    );
    if (w.label != null) input = Semantics(label: w.label, child: input);
    return Container(
      constraints: BoxConstraints(minWidth: w.isInWorkflow ? 0 : 200),
      padding: _special ? const EdgeInsets.only(left: 4, bottom: 4) : EdgeInsets.zero,
      decoration: _special
          ? BoxDecoration(color: DifyColors.componentsInputBgNormal, borderRadius: BorderRadius.circular(DifyRadius.lg))
          : null,
      child: Wrap(
        children: [
          for (final (i, item) in w.items.indexed)
            Container(
              margin: const EdgeInsets.only(top: 4, right: 4),
              padding: const EdgeInsets.fromLTRB(6, 4, 4, 4),
              decoration: BoxDecoration(
                color: DifyColors.componentsBadgeWhiteToDark,
                border: Border.all(color: DifyColors.dividerDeep),
                borderRadius: BorderRadius.circular(DifyRadius.md),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DifyText(item, DifyType.systemXsRegular, color: DifyColors.textSecondary),
                  if (!w.disableRemove)
                    DifyPressable(
                      semanticLabel: '${DifyI18n.tr('common', 'operation.remove')} $item',
                      onPressed: () => w.onChange([...w.items]..removeAt(i)),
                      builder: (context, hovered, focused) => const SizedBox(
                        width: 16,
                        height: 16,
                        child: Center(child: RemixIcon('close-line', size: 14, color: DifyColors.textTertiary)),
                      ),
                    ),
                ],
              ),
            ),
          if (!w.disableAdd)
            Container(
              margin: const EdgeInsets.only(top: 4),
              padding: const EdgeInsets.symmetric(horizontal: 6),
              decoration: _special
                  ? BoxDecoration(
                      borderRadius: BorderRadius.circular(DifyRadius.md),
                      border: Border.all(color: _focused ? DifyColors.dividerDeep : const Color(0x00000000)),
                    )
                  : null,
              foregroundDecoration: _special ? null : const _DashedBorder(),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                spacing: 2,
                children: [
                  if (!_focused && !_special) const RemixIcon('add-line', size: 14, color: DifyColors.textPlaceholder),
                  Flexible(child: input),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// `rounded-md border border-dashed border-divider-deep`.
class _DashedBorder extends Decoration {
  const _DashedBorder();

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) => _DashedPainter();
}

class _DashedPainter extends BoxPainter {
  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final size = configuration.size!;
    final rect = (offset & size).deflate(0.5);
    final path = Path()..addRRect(RRect.fromRectAndRadius(rect, const Radius.circular(DifyRadius.md)));
    final paint = Paint()
      ..color = DifyColors.dividerDeep
      ..style = PaintingStyle.stroke
      ..strokeWidth = Css.hairline * 2;
    for (final m in path.computeMetrics()) {
      for (var d = 0.0; d < m.length; d += 6) {
        canvas.drawPath(m.extractPath(d, d + 3), paint);
      }
    }
  }
}

// ---- CheckboxList ------------------------------------------------------------------------------------------------

/// base/checkbox-list: a bordered box with a header (select-all checkbox, [title], the selected count, a search
/// input; each part optional) over the options (`p-1`, at most [maxHeight] tall), each a checkbox and its label.
class CheckboxList extends StatefulWidget {
  const CheckboxList({
    super.key,
    required this.options,
    required this.value,
    required this.onChange,
    this.title = '',
    this.disabled = false,
    this.maxHeight,
    this.showSelectAll = true,
    this.showCount = true,
    this.showSearch = true,
  });

  final List<SelectOption<String>> options;
  final List<String> value;
  final ValueChanged<List<String>> onChange;
  final String title;
  final bool disabled, showSelectAll, showCount, showSearch;
  final double? maxHeight;

  @override
  State<CheckboxList> createState() => _CheckboxListState();
}

class _CheckboxListState extends State<CheckboxList> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final q = _query.trim().toLowerCase();
    final shown = q.isEmpty
        ? w.options
        : [
            for (final o in w.options)
              if (o.label.toLowerCase().contains(q) || o.value.toLowerCase().contains(q)) o,
          ];
    final all = [for (final o in w.options) o.value];
    final allChecked = all.isNotEmpty && all.every(w.value.contains);
    final some = !allChecked && w.value.isNotEmpty;
    Widget list = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (shown.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 24),
            child: Text(
              q.isEmpty
                  ? DifyI18n.tr('common', 'noData')
                  : DifyI18n.tr('common', 'operation.noSearchResults', {'content': w.title}),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14, color: DifyColors.textTertiary),
            ),
          ),
        for (final o in shown)
          _CheckRow(
            label: o.label,
            checked: w.value.contains(o.value),
            disabled: w.disabled,
            onChanged: (on) => w.onChange(
              on
                  ? [...w.value, o.value]
                  : [
                      for (final v in w.value)
                        if (v != o.value) v,
                    ],
            ),
          ),
      ],
    );
    list = Padding(padding: const EdgeInsets.all(4), child: list);
    if (w.maxHeight != null) {
      list = ConstrainedBox(
        constraints: BoxConstraints(maxHeight: w.maxHeight!),
        child: SingleChildScrollView(child: list),
      );
    }
    final header = w.showSelectAll || w.showSearch || w.title.isNotEmpty || (w.showCount && w.value.isNotEmpty);
    return Container(
      decoration: BoxDecoration(
        color: DifyColors.componentsPanelBg,
        borderRadius: BorderRadius.circular(DifyRadius.lg),
        border: Border.all(color: DifyColors.componentsPanelBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (header)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: DifyColors.dividerSubtle)),
              ),
              child: Row(
                spacing: 8,
                children: [
                  if (w.showSelectAll && q.isEmpty)
                    DifyCheckbox(
                      checked: allChecked,
                      indeterminate: some,
                      disabled: w.disabled,
                      label: DifyI18n.tr('common', 'operation.selectAll'),
                      onChanged: (on) => w.onChange(on ? all : const []),
                    ),
                  Expanded(
                    child: Row(
                      spacing: 4,
                      children: [
                        if (w.title.isNotEmpty)
                          Flexible(
                            child: DifyText(
                              w.title,
                              DifyType.systemXsSemiboldUppercase,
                              color: DifyColors.textSecondary,
                            ),
                          ),
                        if (w.showCount && w.value.isNotEmpty)
                          DifyBadge(DifyI18n.tr('common', 'operation.selectCount', {'count': w.value.length})),
                      ],
                    ),
                  ),
                  if (w.showSearch)
                    SizedBox(
                      width: 160,
                      child: DifyInput(
                        value: _query,
                        height: 28,
                        placeholder: DifyI18n.tr('common', 'placeholder.search'),
                        onChanged: (v) => setState(() => _query = v),
                      ),
                    ),
                ],
              ),
            ),
          list,
        ],
      ),
    );
  }
}

class _CheckRow extends StatelessWidget {
  const _CheckRow({required this.label, required this.checked, required this.disabled, required this.onChanged});
  final String label;
  final bool checked, disabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Opacity(
    opacity: disabled ? 0.5 : 1,
    child: DifyPressable(
      disabled: disabled,
      onPressed: () => onChanged(!checked),
      builder: (context, hovered, focused) => Semantics(
        checked: checked,
        label: label,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: hovered ? DifyColors.stateBaseHover : null,
            borderRadius: BorderRadius.circular(DifyRadius.md),
          ),
          child: Row(
            spacing: 8,
            children: [
              DifyCheckboxBox(checked: checked, disabled: disabled),
              Expanded(child: DifyText(label, DifyType.systemSmMedium, color: DifyColors.textSecondary)),
            ],
          ),
        ),
      ),
    ),
  );
}

// ---- small parts -------------------------------------------------------------------------------------------------

/// ListNoDataPlaceholder (list-no-data-placeholder.tsx): `flex min-h-10.5 w-full items-center justify-center
/// rounded-[10px] bg-background-section system-xs-regular text-text-tertiary`.
class ListNoDataPlaceholder extends StatelessWidget {
  const ListNoDataPlaceholder(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(minHeight: 42),
    alignment: Alignment.center,
    decoration: BoxDecoration(color: DifyColors.backgroundSection, borderRadius: BorderRadius.circular(10)),
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textTertiary),
    ),
  );
}

/// BoolValue (panel/chat-variable-panel/components/bool-value.tsx): "True" / "False" option cards side by side.
class BoolValue extends StatelessWidget {
  const BoolValue({super.key, required this.value, required this.onChange, this.disabled = false});
  final bool value;
  final ValueChanged<bool> onChange;
  final bool disabled;

  @override
  Widget build(BuildContext context) => Row(
    spacing: 4,
    children: [
      Expanded(
        child: OptionCard(title: 'True', selected: value, disabled: disabled, onSelect: () => onChange(true)),
      ),
      Expanded(
        child: OptionCard(title: 'False', selected: !value, disabled: disabled, onSelect: () => onChange(false)),
      ),
    ],
  );
}

/// ArrayBoolList (chat-variable-panel/components/array-bool-list.tsx): a [BoolValue] and a remove button per item,
/// then "Add value".
class ArrayBoolList extends StatelessWidget {
  const ArrayBoolList({super.key, required this.list, required this.onChange});
  final List<bool> list;
  final ValueChanged<List<bool>> onChange;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    spacing: 8,
    children: [
      for (final (i, item) in list.indexed)
        Row(
          spacing: 4,
          children: [
            Expanded(
              child: BoolValue(value: item, onChange: (v) => onChange([...list]..[i] = v)),
            ),
            RemoveButton(onPressed: () => onChange([...list]..removeAt(i))),
          ],
        ),
      DifyButton(
        variant: DifyButtonVariant.tertiary,
        onPressed: () => onChange([...list, false]),
        leading: const RemixIcon('add-line', size: 16),
        child: Text(DifyI18n.tr('workflow', 'chatVariable.modal.addArrayValue')),
      ),
    ],
  );
}

/// InputNumberWithSlider (nodes/_base/components/input-number-with-slider.tsx): a `h-8 w-12` number input (`rounded-lg bg-components-input-bg-normal pl-3 text-[13px]`)
/// beside a growing slider, 8 px apart. Typing reports `parseFloat` of the text (NaN when it is none); on blur a
/// NaN goes back to [defaultValue] and a value outside [min]..[max] is clamped.
class InputNumberWithSlider extends StatefulWidget {
  const InputNumberWithSlider({
    super.key,
    required this.label,
    required this.value,
    required this.onChange,
    this.defaultValue = 0,
    this.min,
    this.max,
    this.readonly = false,
  });

  final String label;
  final num value;
  final ValueChanged<num> onChange;
  final num defaultValue;
  final int? min, max;
  final bool readonly;

  @override
  State<InputNumberWithSlider> createState() => _InputNumberWithSliderState();
}

class _InputNumberWithSliderState extends State<InputNumberWithSlider> {
  late final _text = TextEditingController(text: _format(widget.value));
  late final _focus = FocusNode()..addListener(_onFocus);

  static String _format(num v) => v.isNaN ? '' : (v == v.roundToDouble() ? '${v.round()}' : '$v');

  @override
  void didUpdateWidget(InputNumberWithSlider old) {
    super.didUpdateWidget(old);
    final parsed = num.tryParse(_text.text);
    if (parsed != widget.value && !(parsed == null && widget.value.isNaN)) _text.text = _format(widget.value);
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onFocus() {
    if (_focus.hasFocus) return;
    final w = widget, v = w.value;
    if (v.isNaN) {
      w.onChange(w.defaultValue);
    } else if (w.max != null && v > w.max!) {
      w.onChange(w.max!);
    } else if (w.min != null && v < w.min!) {
      w.onChange(w.min!);
    }
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final min = w.min ?? 0, max = w.max ?? 100;
    final slider = w.value.isFinite ? w.value.round() : min;
    return SizedBox(
      height: 32,
      child: Row(
        spacing: 8,
        children: [
          Container(
            width: 48,
            height: 32,
            padding: const EdgeInsets.only(left: 12),
            alignment: Alignment.centerLeft,
            decoration: BoxDecoration(
              color: DifyColors.componentsInputBgNormal,
              borderRadius: BorderRadius.circular(DifyRadius.lg),
            ),
            child: Semantics(
              label: w.label,
              textField: true,
              child: TextField(
                controller: _text,
                focusNode: _focus,
                enabled: !w.readonly,
                keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.eE+-]'))],
                style: const TextStyle(fontSize: 13, color: DifyColors.componentsInputTextFilled),
                cursorWidth: 1,
                decoration: const InputDecoration(isCollapsed: true, border: InputBorder.none),
                onChanged: (s) => w.onChange(double.tryParse(s.trim()) ?? double.nan),
              ),
            ),
          ),
          Expanded(
            child: DifySlider(
              value: slider.clamp(min, max),
              min: min,
              max: max,
              disabled: w.readonly,
              semanticLabel: w.label,
              onChanged: w.onChange,
            ),
          ),
        ],
      ),
    );
  }
}

/// VariableTag (nodes/_base/components/variable-tag.tsx): [valueSelector] as a variable label (its node from
/// [lookup], the Start node [start] for system variables; the type unless [isShort]; "Invalid variable" when neither
/// a node nor a special variable defines it).
class VariableTag extends StatelessWidget {
  const VariableTag({
    super.key,
    required this.valueSelector,
    required this.varType,
    required this.lookup,
    this.start,
    this.isShort = false,
  });

  /// The tag over [scope]'s nodes.
  VariableTag.inScope({
    Key? key,
    required List<String> valueSelector,
    String? varType,
    required VarScope scope,
    bool isShort = false,
  }) : this(
         key: key,
         valueSelector: valueSelector,
         varType: varType,
         lookup: scope.lookup,
         start: scope.start,
         isShort: isShort,
       );

  final List<String> valueSelector;
  final String? varType;
  final Node? Function(String id) lookup;
  final Node? start;
  final bool isShort;

  @override
  Widget build(BuildContext context) {
    final v = valueSelector;
    final isRag = isRagVariableVar(v);
    final node = isSystemVar(v)
        ? start
        : v.isEmpty
        ? null
        : lookup(isRag && v.length > 1 ? v[1] : v[0]);
    final valid = node != null || isEnvVar(v) || isConversationVar(v) || isRag || isGlobalVar(v);
    final name = (isSystemVar(v) ? v : v.skip(1)).join('.');
    return VariableLabel(
      variables: v,
      nodeType: node?.type,
      nodeTitle: node?.title,
      variableType: isShort ? null : varType,
      errorMsg: valid ? null : DifyI18n.tr('workflow', 'errorMsg.invalidVariable'),
      isExceptionVariable: isExceptionVariable(name, node?.type),
    );
  }
}

// ---- the config-var modal's parts --------------------------------------------------------------------------------

/// config-modal/field.tsx: the title (`system-sm-semibold leading-8 text-text-secondary`, "(optional)"), the control
/// and the error message (`mt-1 system-xs-regular text-text-destructive`).
class ModalField extends StatelessWidget {
  const ModalField({super.key, required this.title, required this.child, this.isOptional = false, this.errorMessage});
  final String title;
  final Widget child;
  final bool isOptional;
  final String? errorMessage;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      SizedBox(
        height: 32,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text.rich(
            TextSpan(
              text: title,
              children: [
                if (isOptional)
                  TextSpan(
                    text: ' (${DifyI18n.tr('app-debug', 'variableConfig.optional')})',
                    style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textTertiary),
                  ),
              ],
            ),
            style: difyTextStyle(DifyType.systemSmSemibold, DifyColors.textSecondary),
          ),
        ),
      ),
      child,
      if (errorMessage != null)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(errorMessage!, style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textDestructive)),
        ),
    ],
  );
}

/// The select trigger box: input colours (hover `bg-state-base-hover-alt`), [content], a chevron.
class _SelectBox extends StatelessWidget {
  const _SelectBox({required this.content, required this.open, required this.onTap, this.large = true, this.label});
  final Widget content;
  final bool open, large;
  final VoidCallback onTap;
  final String? label;

  @override
  Widget build(BuildContext context) => DifyPressable(
    semanticLabel: label,
    onPressed: onTap,
    builder: (context, hovered, focused) => Container(
      height: 36,
      padding: EdgeInsets.symmetric(horizontal: large ? 16 : 8),
      decoration: BoxDecoration(
        color: hovered || open || focused ? DifyColors.stateBaseHoverAlt : DifyColors.componentsInputBgNormal,
        borderRadius: BorderRadius.circular(large ? 10 : 8),
        boxShadow: focused ? const [BoxShadow(color: DifyColors.stateAccentSolid, spreadRadius: 2)] : null,
      ),
      child: Row(
        spacing: 2,
        children: [
          Expanded(child: content),
          RemixIcon(
            'arrow-down-s-line',
            size: 16,
            color: hovered || open ? DifyColors.textSecondary : DifyColors.textQuaternary,
          ),
        ],
      ),
    ),
  );
}

/// dify-ui's Select with a `large` trigger (`h-9 rounded-[10px] px-4 system-md-regular`).
class ModalSelect<T> extends StatelessWidget {
  const ModalSelect({super.key, required this.value, required this.options, required this.onChanged, this.placeholder});
  final T? value;
  final List<SelectOption<T>> options;
  final ValueChanged<T> onChanged;
  final String? placeholder;

  @override
  Widget build(BuildContext context) {
    final selected = options.where((o) => o.value == value).firstOrNull;
    return LayoutBuilder(
      builder: (context, c) => DifyDropdownMenu(
        placement: DifyPlacement.bottomStart,
        width: c.maxWidth,
        builder: (context, controller) => _SelectBox(
          open: controller.isOpen,
          onTap: controller.toggle,
          label: selected?.label ?? placeholder,
          content: Text(
            selected?.label ?? placeholder ?? '',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: difyTextStyle(
              DifyType.systemMdRegular,
              selected == null ? DifyColors.componentsInputTextPlaceholder : DifyColors.componentsInputTextFilled,
            ),
          ),
        ),
        children: [
          DifyMenuRadioGroup<T>(
            value: value,
            onValueChange: onChanged,
            children: [
              for (final o in options) DifyMenuRadioItem<T>(value: o.value, closeOnClick: true, child: Text(o.label)),
            ],
          ),
        ],
      ),
    );
  }
}

/// type-select.tsx: the field type with its icon and VarType badge, in the trigger (`h-9 rounded-lg px-2 text-sm`)
/// and in each option.
class InputTypeSelect extends StatelessWidget {
  const InputTypeSelect({super.key, required this.value, required this.items, required this.onSelect});
  final String value;
  final List<({String value, String name})> items;
  final ValueChanged<String> onSelect;

  Widget _row(({String value, String name}) item, {bool trigger = false}) => Row(
    children: [
      InputVarTypeIcon(type: item.value, size: 16, color: DifyColors.textSecondary),
      SizedBox(width: trigger ? 6 : 8),
      Expanded(
        child: Text(
          item.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: trigger
              ? const TextStyle(fontSize: 14, height: 20 / 14, color: DifyColors.componentsInputTextFilled)
              : null,
        ),
      ),
      const SizedBox(width: 8),
      DifyBadge(inputVarTypeToVarType(item.value), uppercase: false),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final selected = items.where((i) => i.value == value).firstOrNull;
    return LayoutBuilder(
      builder: (context, c) => DifyDropdownMenu(
        placement: DifyPlacement.bottomStart,
        width: c.maxWidth,
        builder: (context, controller) => _SelectBox(
          large: false,
          open: controller.isOpen,
          onTap: controller.toggle,
          label: selected?.name,
          content: selected == null ? const SizedBox.shrink() : _row(selected, trigger: true),
        ),
        children: [
          DifyMenuRadioGroup<String>(
            value: value,
            onValueChange: onSelect,
            children: [
              for (final i in items) DifyMenuRadioItem<String>(value: i.value, closeOnClick: true, child: _row(i)),
            ],
          ),
        ],
      ),
    );
  }
}

/// config-select: the options editor, rows of a drag handle, an `h-9` input and a delete button, then "Add option".
class ConfigSelect extends StatefulWidget {
  const ConfigSelect({super.key, required this.options, required this.onChange, this.invalid = false});
  final List<String> options;
  final ValueChanged<List<String>> onChange;
  final bool invalid;

  @override
  State<ConfigSelect> createState() => _ConfigSelectState();
}

class _ConfigSelectState extends State<ConfigSelect> {
  int? _focusId, _deletingId;

  @override
  Widget build(BuildContext context) {
    final options = widget.options;
    final label = DifyI18n.tr('app-debug', 'variableConfig.options');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (options.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: ReorderableList(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: options.length,
              proxyDecorator: (child, _, _) => Opacity(opacity: 0.5, child: child),
              onReorderItem: (from, to) {
                if (from == to) return;
                final next = [...options]..insert(to, options[from]);
                next.removeAt(from < to ? from : from + 1);
                widget.onChange(next);
              },
              itemBuilder: (context, i) {
                final focused = _focusId == i, deleting = _deletingId == i;
                return Padding(
                  key: ValueKey('option-$i'),
                  padding: EdgeInsets.only(top: i == 0 ? 0 : 4),
                  child: Container(
                    padding: const EdgeInsets.only(left: 10),
                    decoration: BoxDecoration(
                      color: deleting
                          ? DifyColors.stateDestructiveHover
                          : focused
                          ? DifyColors.componentsInputBgActive
                          : DifyColors.componentsPanelOnPanelItemBg,
                      borderRadius: BorderRadius.circular(DifyRadius.lg),
                      border: Border.all(
                        color: deleting
                            ? DifyColors.componentsInputBorderDestructive
                            : focused
                            ? DifyColors.componentsInputBorderActive
                            : DifyColors.componentsPanelBorderSubtle,
                      ),
                    ),
                    child: Row(
                      children: [
                        ReorderableDragStartListener(
                          index: i,
                          child: const MouseRegion(
                            cursor: SystemMouseCursors.grab,
                            child: SizedBox.square(
                              dimension: 24,
                              child: Center(child: RemixIcon('draggable', size: 16, color: DifyColors.textQuaternary)),
                            ),
                          ),
                        ),
                        Expanded(
                          child: Focus(
                            onFocusChange: (f) => setState(() => _focusId = f ? i : null),
                            child: _OptionInput(
                              value: options[i],
                              label: '$label ${i + 1}',
                              onChanged: (v) => widget.onChange([for (final (j, o) in options.indexed) j == i ? v : o]),
                            ),
                          ),
                        ),
                        MouseRegion(
                          onEnter: (_) => setState(() => _deletingId = i),
                          onExit: (_) => setState(() => _deletingId = null),
                          child: Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: DifyIconButton(
                              label: DifyI18n.tr('common', 'operation.delete'),
                              tone: DifyButtonTone.destructive,
                              size: DifyIconButtonSize.md,
                              onPressed: () {
                                widget.onChange([
                                  for (final (j, o) in options.indexed)
                                    if (j != i) o,
                                ]);
                                setState(() => _deletingId = null);
                              },
                              icon: const RemixIcon('delete-bin-line', size: 14),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        SizedBox(
          height: 36,
          child: DifyButton(
            variant: DifyButtonVariant.tertiary,
            onPressed: () => widget.onChange([...options, '']),
            leading: const RemixIcon('add-line', size: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                DifyI18n.tr('app-debug', 'variableConfig.addOption'),
                style: difyTextStyle(DifyType.systemSmMedium, DifyColors.textSecondary).copyWith(fontSize: 13),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// An option's bare input (`h-9 bg-transparent pl-1.5 text-sm/9 text-text-secondary`).
class _OptionInput extends StatefulWidget {
  const _OptionInput({required this.value, required this.label, required this.onChanged});
  final String value, label;
  final ValueChanged<String> onChanged;

  @override
  State<_OptionInput> createState() => _OptionInputState();
}

class _OptionInputState extends State<_OptionInput> {
  late final _controller = TextEditingController(text: widget.value);

  @override
  void didUpdateWidget(_OptionInput old) {
    super.didUpdateWidget(old);
    if (_controller.text != widget.value) _controller.text = widget.value;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: widget.label,
    child: SizedBox(
      height: 36,
      child: Center(
        child: TextField(
          controller: _controller,
          onChanged: widget.onChanged,
          style: const TextStyle(fontSize: 14, height: 20 / 14, color: DifyColors.textSecondary),
          cursorColor: const Color(0xFF155EEF),
          cursorWidth: 1,
          decoration: const InputDecoration(
            isCollapsed: true,
            border: InputBorder.none,
            contentPadding: EdgeInsets.only(left: 6, right: 8),
          ),
        ),
      ),
    ),
  );
}
