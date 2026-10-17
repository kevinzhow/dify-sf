/// The list operator's controls: filter-condition.tsx, sub-variable-picker.tsx, extract-input.tsx, limit-config.tsx,
/// and lean copies of what they borrow from elsewhere in Dify: if-else's ConditionOperator, the chat-variable
/// panel's BoolValue and `_base/components/input-number-with-slider.tsx`.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../../cards/card_kit.dart';
import '../../../../../design/dify_icon.dart';
import '../../../../../design/dify_tokens.g.dart';
import '../../../../../design/widgets/widgets.dart';
import '../../../../../workflow/dify_json.dart';
import '../../../../panel_fields/panel_fields.dart';
import '../../../../prompt_editor/prompt_editor.dart' show WorkflowNodeInfo;
import '../data_common.dart';
import 'list_operator_model.dart';

/// ConditionOperator (if-else/components/condition-list/condition-operator.tsx) with the list operator's
/// `h-8 bg-components-input-bg-normal`: a ghost small button showing the operator (symbols as they are, the rest
/// `nodes.ifElse.comparisonOperator.*`; "Select" at half opacity when none), opening the operators of [varType] (or
/// of the file attribute [fileKey]) at `bottom-end`.
class ConditionOperator extends StatelessWidget {
  const ConditionOperator({
    super.key,
    required this.varType,
    required this.value,
    required this.onSelect,
    this.fileKey,
    this.disabled = false,
  });

  final String varType;
  final String? fileKey;
  final Object? value;
  final ValueChanged<String> onSelect;
  final bool disabled;

  static String labelOf(String op) =>
      isComparisonOperatorNeedTranslate(op) ? wf('nodes.ifElse.comparisonOperator.$op') : op;

  @override
  Widget build(BuildContext context) {
    final options = getOperators(varType, fileKey: fileKey);
    final current = value is List ? (value as List).firstOrNull : value;
    final selected = options.where((o) => o == current).firstOrNull;
    return DifyDropdownMenu(
      placement: DifyPlacement.bottomEnd,
      sideOffset: 4,
      builder: (context, c) => Opacity(
        opacity: selected == null ? 0.5 : 1,
        child: DifyPressable(
          disabled: disabled,
          onPressed: c.toggle,
          builder: (context, hovered, focused) {
            final color = disabled
                ? DifyColors.componentsButtonGhostTextDisabled
                : DifyColors.componentsButtonGhostText;
            return Container(
              height: 32,
              padding: const EdgeInsets.symmetric(horizontal: 9),
              decoration: BoxDecoration(
                color: hovered && !disabled
                    ? DifyColors.componentsButtonGhostBgHover
                    : DifyColors.componentsInputBgNormal,
                borderRadius: BorderRadius.circular(DifyRadius.md),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                spacing: 4,
                children: [
                  Flexible(
                    child: Text(
                      selected == null ? wf('nodes.ifElse.select') : labelOf(selected),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, height: 16 / 12, fontWeight: FontWeight.w500, color: color),
                    ),
                  ),
                  RemixIcon('arrow-down-s-line', size: 14, color: color),
                ],
              ),
            );
          },
        ),
      ),
      children: [
        DifyMenuRadioGroup<String>(
          value: selected,
          onValueChange: onSelect,
          children: [
            for (final o in options)
              DifyMenuRadioItem<String>(
                value: o,
                closeOnClick: true,
                child: Text(
                  labelOf(o),
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: DifyColors.textSecondary),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// SubVariablePicker: a file attribute (SUB_VARIABLES). The trigger is `h-8 rounded-lg bg-components-input-bg-normal
/// pl-1` (hover `bg-state-base-hover-alt`) with the chosen attribute as an accent chip, or `Variable02` and "Please
/// select"; the list (`w-41.25`, `h-8` rows with an accent `Variable02`) opens below.
class SubVariablePicker extends StatelessWidget {
  const SubVariablePicker({super.key, required this.value, required this.onChange, this.disabled = false});
  final String value;
  final ValueChanged<String> onChange;
  final bool disabled;

  @override
  Widget build(BuildContext context) {
    final selected = subVariables.contains(value) ? value : null;
    return DifyDropdownMenu(
      placement: DifyPlacement.bottomStart,
      sideOffset: 4,
      width: 165,
      builder: (context, c) => DifyPressable(
        disabled: disabled,
        onPressed: c.toggle,
        semanticLabel: selected ?? cm('placeholder.select'),
        builder: (context, hovered, focused) => Container(
          height: 32,
          padding: const EdgeInsets.only(left: 4),
          alignment: Alignment.centerLeft,
          decoration: BoxDecoration(
            color: hovered ? DifyColors.stateBaseHoverAlt : DifyColors.componentsInputBgNormal,
            borderRadius: BorderRadius.circular(DifyRadius.lg),
          ),
          child: selected != null
              ? Container(
                  height: 24,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  decoration: BoxDecoration(
                    color: DifyColors.componentsBadgeWhiteToDark,
                    borderRadius: BorderRadius.circular(DifyRadius.md),
                    border: Border.all(color: DifyColors.componentsPanelBorderSubtle, width: 0.5),
                    boxShadow: DifyShadows.xs,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const DifyIcon('vender/solid/development/variable-02', size: 14, color: DifyColors.textAccent),
                      const SizedBox(width: 2),
                      Flexible(child: DifyText(selected, DifyType.systemXsMedium, color: DifyColors.textAccent)),
                    ],
                  ),
                )
              : Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Row(
                    children: [
                      DifyIcon(
                        'vender/solid/development/variable-02',
                        size: 16,
                        color: hovered ? DifyColors.textTertiary : DifyColors.componentsInputTextPlaceholder,
                      ),
                      const SizedBox(width: 4),
                      DifyText(
                        cm('placeholder.select'),
                        DifyType.systemSmRegular,
                        color: hovered ? DifyColors.textTertiary : DifyColors.componentsInputTextPlaceholder,
                      ),
                    ],
                  ),
                ),
        ),
      ),
      children: [
        for (final o in subVariables)
          DifyMenuItem(
            onSelect: () => onChange(o),
            leading: const DifyIcon('vender/solid/development/variable-02', size: 14, color: DifyColors.textAccent),
            child: DifyText(o, DifyType.systemSmMedium, color: DifyColors.textSecondary),
          ),
      ],
    );
  }
}

/// LIMIT_SIZE_MIN / MAX / DEFAULT.
const limitSizeMin = 1, limitSizeMax = 20, limitSizeDefault = 10;

/// LimitConfig: the "Top N" field with its switch; when on, the size (1..20, 10 by default) as a number with slider.
class LimitConfig extends StatelessWidget {
  const LimitConfig({super.key, required this.config, required this.onChange, this.readonly = false});

  /// `{enabled, size}` (Dify's LIMIT_DEFAULT when null).
  final Map<String, Object?>? config;
  final ValueChanged<Map<String, Object?>> onChange;
  final bool readonly;

  @override
  Widget build(BuildContext context) {
    final c = config ?? const {'enabled': false, 'size': limitSizeDefault};
    final enabled = jsTruthy(c['enabled']);
    final size = c['size'] is num && c['size'] != 0 ? (c['size']! as num).round() : limitSizeDefault;
    final label = wf('nodes.listFilter.limit');
    return Field(
      title: label,
      operations: DifySwitch(
        checked: enabled,
        disabled: readonly,
        onCheckedChange: (v) => onChange({...c, 'enabled': v}),
      ),
      child: enabled
          ? InputNumberWithSlider(
              label: label,
              value: size,
              min: limitSizeMin,
              max: limitSizeMax,
              readonly: readonly || !enabled,
              onChange: (v) => onChange({...c, 'size': v.isFinite ? v.round() : limitSizeDefault}),
            )
          : null,
    );
  }
}

/// ExtractInput: the 1-based index of the item to extract, typed or a number variable (`/`); placeholder
/// `nodes.http.extractListPlaceholder` unless read-only.
class ExtractInput extends StatelessWidget {
  const ExtractInput({
    super.key,
    required this.value,
    required this.onChange,
    this.scope = const VarScope(),
    this.nodesMap = const {},
    this.readOnly = false,
    this.version,
  });

  final String value;
  final TextCommit onChange;

  /// The node's available variables (the number ones are offered).
  final VarScope scope;
  final Map<String, WorkflowNodeInfo> nodesMap;
  final bool readOnly;
  final int Function()? version;

  @override
  Widget build(BuildContext context) => VarInput(
    value: value,
    onChange: onChange,
    vars: scope.filtered((v, _) => v.type == 'number').vars,
    nodesMap: nodesMap,
    readOnly: readOnly,
    version: version,
    placeholder: readOnly ? '' : wf('nodes.http.extractListPlaceholder'),
  );
}

/// Commits a filter condition; [base] is the version a typed value's draft began on.
typedef ConditionChange = void Function(Map<String, Object?> condition, int? base);

/// FilterCondition: for file arrays ([hasSubVariable]) the attribute picker, then the operator and the value: a
/// select for in / not in / all of (file types or transfer methods, stored as `[value]` for `type` and
/// `transfer_method`), True / False for booleans, a variable-capable input where the value has a type (filtered to
/// it), else a plain input; nothing for operators without a value. [scope] is the node's available variables.
class FilterCondition extends StatelessWidget {
  const FilterCondition({
    super.key,
    required this.condition,
    required this.varType,
    required this.onChange,
    required this.hasSubVariable,
    this.scope = const VarScope(),
    this.nodesMap = const {},
    this.readOnly = false,
    this.version,
  });

  /// Null: Dify's default `{key: '', comparison_operator: '=', value: ''}`.
  final Map<String, Object?>? condition;
  final String varType;
  final ConditionChange onChange;
  final bool hasSubVariable;
  final VarScope scope;
  final Map<String, WorkflowNodeInfo> nodesMap;
  final bool readOnly;
  final int Function()? version;

  static const _default = {'key': '', 'comparison_operator': Op.equal, 'value': ''};

  @override
  Widget build(BuildContext context) {
    final c = condition ?? _default;
    final key = jsStr(c['key']) ?? '';
    final expected = expectedVarType(c, varType);
    final op = jsStr(c['comparison_operator']);
    final isArrayValue = key == 'transfer_method' || key == 'type';

    void set(String field, Object? value, [int? base]) => onChange({
      ...c,
      field: isArrayValue && field == 'value' ? [value] : value,
    }, base);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (hasSubVariable)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: SubVariablePicker(
              value: key,
              disabled: readOnly,
              onChange: (k) {
                final ops = getOperators(expected ?? 'string', fileKey: k);
                onChange({'key': k, 'comparison_operator': ops.isNotEmpty ? ops.first : Op.equal, 'value': ''}, null);
              },
            ),
          ),
        LayoutBuilder(
          builder: (context, box) => Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 4,
            children: [
              // shrink-0 in Dify; a label wider than 40 % of the row is cut rather than overflowing.
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: box.maxWidth * 0.4),
                child: ConditionOperator(
                  varType: expected ?? varType,
                  fileKey: hasSubVariable ? key : null,
                  value: c['comparison_operator'],
                  disabled: readOnly,
                  onSelect: (v) => set('comparison_operator', v),
                ),
              ),
              if (!comparisonOperatorNotRequireValue(op))
                Expanded(child: _value(context, c, op, isArrayValue, expected, set)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _value(
    BuildContext context,
    Map<String, Object?> c,
    String? op,
    bool isArrayValue,
    String? expected,
    void Function(String field, Object? value, [int? base]) set,
  ) {
    if (isSelectOperator(op)) {
      final options = selectOptionsOf(c);
      final value = isArrayValue ? jsGet(c['value'], '0') : c['value'];
      return DifySelect<String>(
        value: options.any((o) => o.$1 == value) ? value! as String : null,
        options: [for (final (v, k) in options) (value: v, label: wf('nodes.ifElse.optionName.$k'))],
        placeholder: 'Select value',
        disabled: readOnly,
        textStyle: const TextStyle(fontSize: 13, height: 16 / 13),
        onChanged: (v) => set('value', v),
      );
    }
    if (varType == 'boolean') {
      return BoolValue(value: c['value'] == true, disabled: readOnly, onChange: (v) => set('value', v));
    }
    if (expected != null) {
      return VarInput(
        value: conditionValueAsString(c['value']),
        onChange: (text, base) => set('value', text, base),
        vars: scope.filtered((v, _) => v.type == expected).vars,
        nodesMap: nodesMap,
        readOnly: readOnly,
        version: version,
        placeholder: readOnly ? '' : wf('nodes.http.insertVarPlaceholder'),
      );
    }
    return PlainConditionInput(
      value: conditionValueAsString(c['value']),
      number: fallbackInputIsNumber(hasSubVariable: hasSubVariable, condition: c, varType: varType),
      readOnly: readOnly,
      version: version,
      onChange: (text, base) => set('value', text, base),
    );
  }
}

/// The plain `<input>` for values without a type (`grow rounded-lg border border-components-input-border-hover
/// bg-components-input-bg-normal px-3 py-1.5`), a number input when [number]; typed text commits on blur or Enter.
class PlainConditionInput extends StatefulWidget {
  const PlainConditionInput({
    super.key,
    required this.value,
    required this.onChange,
    this.number = false,
    this.readOnly = false,
    this.version,
  });

  final String value;
  final TextCommit onChange;
  final bool number, readOnly;
  final int Function()? version;

  @override
  State<PlainConditionInput> createState() => _PlainConditionInputState();
}

class _PlainConditionInputState extends State<PlainConditionInput> {
  late final _text = TextEditingController(text: widget.value);
  late final _focus = FocusNode()..addListener(_focusChanged);
  late final _draft = TextDraft(widget.version);

  @override
  void didUpdateWidget(PlainConditionInput old) {
    super.didUpdateWidget(old);
    if (!_draft.isOpen && _text.text != widget.value) _text.text = widget.value;
  }

  void _focusChanged() {
    if (!_focus.hasFocus) _commit();
  }

  void _commit() {
    final d = _draft.take();
    if (d != null && _text.text != widget.value) widget.onChange(_text.text, d.base);
  }

  @override
  void dispose() {
    _commit();
    _focus.dispose();
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = difyStyle(DifyType.systemSmRegular, DifyColors.componentsInputTextFilled);
    return Container(
      height: 32,
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        color: DifyColors.componentsInputBgNormal,
        borderRadius: BorderRadius.circular(DifyRadius.lg),
        border: Border.all(color: DifyColors.componentsInputBorderHover),
      ),
      child: TextField(
        controller: _text,
        focusNode: _focus,
        readOnly: widget.readOnly,
        style: style,
        maxLines: 1,
        keyboardType: widget.number ? const TextInputType.numberWithOptions(decimal: true, signed: true) : null,
        inputFormatters: widget.number ? [FilteringTextInputFormatter.allow(RegExp(r'[0-9eE.+-]'))] : null,
        onChanged: (_) => _draft.touch(),
        onSubmitted: (_) => _commit(),
        cursorWidth: 1,
        decoration: const InputDecoration(
          isCollapsed: true,
          border: InputBorder.none,
          contentPadding: EdgeInsets.symmetric(horizontal: 11, vertical: 6),
        ),
      ),
    );
  }
}
