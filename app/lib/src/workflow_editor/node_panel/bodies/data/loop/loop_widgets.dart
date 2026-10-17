/// Small controls the Loop panel uses that dify-sf has no shared form of yet: BoolValue and ArrayBoolList
/// (panel/chat-variable-panel/components), InputNumberWithSlider (nodes/_base/components) and VariableTag
/// (nodes/_base/components/variable-tag.tsx).
library;

import 'package:collab_client/collab_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../../cards/card_kit.dart';
import '../../../../../design/dify_icon.dart';
import '../../../../../design/dify_tokens.g.dart';
import '../../../../../design/widgets/widgets.dart';
import '../../../../panel_fields/panel_fields.dart';
import '../data_common.dart';

/// BoolValue: "True" / "False" option cards side by side.
class BoolValue extends StatelessWidget {
  const BoolValue({super.key, required this.value, required this.onChange});
  final bool value;
  final ValueChanged<bool> onChange;

  @override
  Widget build(BuildContext context) => Row(
    spacing: 4,
    children: [
      Expanded(
        child: OptionCard(title: 'True', selected: value, onSelect: () => onChange(true)),
      ),
      Expanded(
        child: OptionCard(title: 'False', selected: !value, onSelect: () => onChange(false)),
      ),
    ],
  );
}

/// ArrayBoolList: a [BoolValue] and a remove button per item, then "Add value".
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
        child: Text(wf('chatVariable.modal.addArrayValue')),
      ),
    ],
  );
}

/// InputNumberWithSlider: a `h-8 w-12` number input (`rounded-lg bg-components-input-bg-normal pl-3 text-[13px]`)
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

/// VariableTag: [valueSelector] as a variable label (the node from [lookup], the Start node for system variables;
/// the type unless [isShort]; "invalid variable" when neither node nor special variable).
class VariableTag extends StatelessWidget {
  const VariableTag({
    super.key,
    required this.valueSelector,
    required this.varType,
    required this.lookup,
    this.start,
    this.isShort = false,
  });

  final List<String> valueSelector;
  final String? varType;
  final Node? Function(String id) lookup;
  final Node? start;
  final bool isShort;

  @override
  Widget build(BuildContext context) {
    final v = valueSelector;
    final isRag = isRagVariableVar(v);
    final node = isSystemVar(v) && start != null ? start : (v.isEmpty ? null : lookup(isRag ? v[1] : v[0]));
    final valid = node != null || isEnvVar(v) || isConversationVar(v) || isRag || isGlobalVar(v);
    final name = isSystemVar(v) ? v.join('.') : v.skip(1).join('.');
    return VariableLabel(
      variables: v,
      nodeType: node?.type,
      nodeTitle: node?.title,
      variableType: isShort ? null : varType,
      errorMsg: valid ? null : wf('errorMsg.invalidVariable'),
      isExceptionVariable: isExceptionVariable(name, node?.type),
    );
  }
}
