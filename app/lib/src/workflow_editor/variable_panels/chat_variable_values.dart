/// The value editors of the conversation variable modal (chat-variable-panel/components: variable-type-select.tsx,
/// array-value-list.tsx, object-value-list.tsx, object-value-item.tsx; BoolValue and ArrayBoolList are shared, in
/// panel_fields).
library;

import 'package:flutter/material.dart';

import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../workflow/dify_json.dart';
import '../panel_fields/field.dart' show RemoveButton;
import 'app_variables.dart';
import 'chat_variable_state.dart';
import 'panel_kit.dart';

/// Tailwind's gray-100 / gray-200.
const _gray100 = Color(0xFFF2F4F7);
const _gray200 = Color(0xFFEAECF0);

/// VariableTypeSelector: the type select of the modal (a select on the input colours, its popup [popupWidth]
/// wide), or [inCell] the compact one of an object row (`py-0.5 px-2`, `system-xs-regular text-text-secondary`,
/// hover `bg-state-base-hover`).
class VariableTypeSelector extends StatelessWidget {
  const VariableTypeSelector({
    super.key,
    required this.value,
    required this.list,
    required this.onSelect,
    this.inCell = false,
    this.popupWidth,
  });
  final String value;
  final List<String> list;
  final ValueChanged<String> onSelect;
  final bool inCell;
  final double? popupWidth;

  @override
  Widget build(BuildContext context) {
    final options = [for (final t in list) (value: t, label: t)];
    if (!inCell) return DifySelect<String>(value: value, options: options, onChanged: onSelect, popupWidth: popupWidth);
    return DifyDropdownMenu(
      placement: DifyPlacement.bottomStart,
      width: popupWidth,
      builder: (context, c) => DifyPressable(
        semanticLabel: value,
        onPressed: c.toggle,
        builder: (context, hovered, focused) => Container(
          height: 27,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          color: hovered || c.isOpen ? DifyColors.stateBaseHover : null,
          child: Row(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: DifyText(value, DifyType.systemXsRegular, color: DifyColors.textSecondary),
                ),
              ),
              Padding(
                padding: EdgeInsets.only(left: 2),
                child: RemixIcon('arrow-down-s-line', size: 16, color: DifyColors.textQuaternary),
              ),
            ],
          ),
        ),
      ),
      children: [
        DifyMenuRadioGroup<String>(
          value: value,
          onValueChange: onSelect,
          children: [
            for (final o in options)
              DifyMenuRadioItem<String>(value: o.value, closeOnClick: true, child: Text(o.label)),
          ],
        ),
      ],
    );
  }
}

/// The remove button of the array rows (RemoveButton with `bg-gray-100! p-2! hover:bg-gray-200!`).
class _RowRemoveButton extends StatefulWidget {
  const _RowRemoveButton({required this.onPressed});
  final VoidCallback onPressed;

  @override
  State<_RowRemoveButton> createState() => _RowRemoveButtonState();
}

class _RowRemoveButtonState extends State<_RowRemoveButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => setState(() => _hovered = true),
    onExit: (_) => setState(() => _hovered = false),
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: _hovered ? _gray200 : _gray100,
        borderRadius: BorderRadius.circular(DifyRadius.lg),
      ),
      child: RemoveButton(onPressed: widget.onPressed),
    ),
  );
}

/// The full-width "Add Value" button under the arrays (`Button variant=tertiary w-full`, `RiAddLine size-4`).
class _AddValueButton extends StatelessWidget {
  const _AddValueButton({required this.onPressed});
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: double.infinity,
    child: DifyButton(
      variant: DifyButtonVariant.tertiary,
      onPressed: onPressed,
      leading: const RemixIcon('add-line', size: 16),
      child: Text(tw('chatVariable.modal.addArrayValue')),
    ),
  );
}

/// ArrayValueList: an input per element ("Value 1", ...; numbers in a number field that may be empty) with its
/// remove button, and "Add Value" (appends an empty element).
class ArrayValueList extends StatelessWidget {
  const ArrayValueList({super.key, required this.isString, required this.list, required this.onChange});
  final bool isString;
  final List<Object?> list;
  final ValueChanged<List<Object?>> onChange;

  @override
  Widget build(BuildContext context) {
    final label = tw('chatVariable.modal.arrayValue');
    return Column(
      spacing: 8,
      children: [
        for (final (i, item) in list.indexed)
          Row(
            spacing: 4,
            children: [
              Expanded(
                child: isString
                    ? DifyInput(
                        semanticLabel: '$label ${i + 1}',
                        placeholder: label,
                        value: item is String ? item : '',
                        onChanged: (v) => onChange([...list]..[i] = v),
                      )
                    : OptionalNumberField(
                        semanticLabel: '$label ${i + 1}',
                        placeholder: label,
                        value: item is num ? item : null,
                        onChanged: (v) => onChange([...list]..[i] = v),
                      ),
              ),
              _RowRemoveButton(onPressed: () => onChange([...list]..removeAt(i))),
            ],
          ),
        _AddValueButton(onPressed: () => onChange([...list, null])),
      ],
    );
  }
}

/// dify-ui's NumberField as the modal uses it (`maximumSignificantDigits: 21`, no grouping): the number typed, or
/// null while the field is empty (it stays empty rather than showing 0); text that is no number is ignored and
/// reverts on blur.
class OptionalNumberField extends StatefulWidget {
  const OptionalNumberField({
    super.key,
    required this.value,
    required this.onChanged,
    this.placeholder,
    this.semanticLabel,
  });
  final num? value;
  final ValueChanged<num?> onChanged;
  final String? placeholder, semanticLabel;

  @override
  State<OptionalNumberField> createState() => _OptionalNumberFieldState();
}

class _OptionalNumberFieldState extends State<OptionalNumberField> {
  late String _text = _format(widget.value);
  final _focus = FocusNode(debugLabel: 'number');

  static String _format(num? v) => v == null ? '' : jsKey(v);

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus && _parse(_text) != widget.value) setState(() => _text = _format(widget.value));
    });
  }

  @override
  void didUpdateWidget(OptionalNumberField old) {
    super.didUpdateWidget(old);
    if (widget.value != _parse(_text)) _text = _format(widget.value);
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  static num? _parse(String t) => num.tryParse(t.trim());

  void _onChanged(String t) {
    _text = t;
    if (t.trim().isEmpty) return widget.onChanged(null);
    final n = _parse(t);
    if (n != null) widget.onChanged(n);
  }

  @override
  Widget build(BuildContext context) => DifyInput(
    value: _text,
    focusNode: _focus,
    placeholder: widget.placeholder,
    semanticLabel: widget.semanticLabel,
    keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
    onChanged: _onChanged,
  );
}

/// ObjectValueList: the object form, a table (`rounded-lg border border-gray-200`) with Key / Type / Default Value
/// headers (`h-7 system-xs-medium-uppercase text-text-tertiary`) and a row per member.
class ObjectValueList extends StatelessWidget {
  const ObjectValueList({super.key, required this.list, required this.onChange});
  final List<ObjectValueItem> list;
  final ValueChanged<List<ObjectValueItem>> onChange;

  @override
  Widget build(BuildContext context) {
    Widget head(String key, double width, {bool last = false}) => Container(
      width: width,
      height: 28,
      padding: EdgeInsets.only(left: 8, right: last ? 4 : 0),
      alignment: Alignment.centerLeft,
      decoration: last
          ? null
          : const BoxDecoration(
              border: Border(right: BorderSide(color: _gray200)),
            ),
      child: DifyText(tw(key), DifyType.systemXsMediumUppercase, color: DifyColors.textTertiary),
    );
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        border: Border.all(color: _gray200),
        borderRadius: BorderRadius.circular(DifyRadius.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              head('chatVariable.modal.objectKey', 120),
              head('chatVariable.modal.objectType', 96),
              Expanded(child: head('chatVariable.modal.objectValue', 230, last: true)),
            ],
          ),
          for (var i = 0; i < list.length; i++)
            ObjectValueItemRow(key: ValueKey(i), index: i, list: list, onChange: onChange),
        ],
      ),
    );
  }
}

/// ObjectValueItem: a member's key (letters, digits and `_` only), type (string / number) and value; focusing the
/// last row's value adds a row; rows (when there are several) have a delete button while their value is not
/// focused.
class ObjectValueItemRow extends StatefulWidget {
  const ObjectValueItemRow({super.key, required this.index, required this.list, required this.onChange});
  final int index;
  final List<ObjectValueItem> list;
  final ValueChanged<List<ObjectValueItem>> onChange;

  @override
  State<ObjectValueItemRow> createState() => _ObjectValueItemRowState();
}

class _ObjectValueItemRowState extends State<ObjectValueItemRow> {
  final _valueFocus = FocusNode(debugLabel: 'object value');
  bool _isFocus = false;

  ObjectValueItem get _item => widget.list[widget.index];

  @override
  void initState() {
    super.initState();
    _valueFocus.addListener(() {
      if (_valueFocus.hasFocus == _isFocus) return;
      setState(() => _isFocus = _valueFocus.hasFocus);
      if (_isFocus && widget.index == widget.list.length - 1) widget.onChange([...widget.list, defaultObjectValue]);
    });
  }

  @override
  void dispose() {
    _valueFocus.dispose();
    super.dispose();
  }

  void _replace(ObjectValueItem item) => widget.onChange([...widget.list]..[widget.index] = item);

  void _handleKeyChange(String v) {
    if (!RegExp(r'^\w+$').hasMatch(v)) {
      toastError(context, tw('chatVariable.modal.objectKeyPatternError'));
      setState(() {}); // the field shows the last valid key again
      return;
    }
    _replace((key: v, type: _item.type, value: _item.value));
  }

  void _handleTypeChange(String type) {
    final v = _item.value;
    _replace((
      key: _item.key,
      type: type,
      value: type == ChatVarType.number ? _jsNumber(v) : (_truthy(v) ? jsKey(v) : null),
    ));
  }

  /// `Number.isNaN(Number(v)) ? undefined : Number(v)`.
  static num? _jsNumber(Object? v) => switch (v) {
    null => null,
    final num n => n,
    final String s => s.trim().isEmpty ? 0 : num.tryParse(s.trim()),
    _ => null,
  };

  static bool _truthy(Object? v) => !(v == null || v == '' || v == 0);

  void _handleValueChange(String v) => _replace((
    key: _item.key,
    type: _item.type,
    value: _item.type == ChatVarType.string ? v : _jsNumber(v),
  ));

  @override
  Widget build(BuildContext context) {
    final item = _item;
    return Container(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: _gray200)),
      ),
      child: Row(
        children: [
          Container(
            width: 120,
            decoration: const BoxDecoration(
              border: Border(right: BorderSide(color: _gray200)),
            ),
            child: _CellInput(
              value: item.key,
              placeholder: tw('chatVariable.modal.objectKey'),
              onChanged: _handleKeyChange,
            ),
          ),
          Container(
            width: 96,
            decoration: const BoxDecoration(
              border: Border(right: BorderSide(color: _gray200)),
            ),
            child: VariableTypeSelector(
              inCell: true,
              value: item.type,
              list: const [ChatVarType.string, ChatVarType.number],
              popupWidth: 120,
              onSelect: _handleTypeChange,
            ),
          ),
          Expanded(
            child: Stack(
              children: [
                _CellInput(
                  value: item.value == null ? '' : jsKey(item.value),
                  placeholder: tw('chatVariable.modal.objectValue'),
                  focusNode: _valueFocus,
                  number: item.type == ChatVarType.number,
                  paddingRight: 36,
                  onChanged: _handleValueChange,
                ),
                if (widget.list.length > 1 && !_isFocus)
                  Positioned(
                    top: 2,
                    right: 4,
                    child: DifyIconButton(
                      label: tc('operation.remove'),
                      tone: DifyButtonTone.destructive,
                      onPressed: () => widget.onChange([...widget.list]..removeAt(widget.index)),
                      icon: const RemixIcon('delete-bin-line', size: 16),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// An object row's input: `block h-7 w-full px-2 system-xs-regular text-text-secondary`, hover
/// `bg-state-base-hover`, focus `bg-components-input-bg-active`.
class _CellInput extends StatefulWidget {
  const _CellInput({
    required this.value,
    required this.placeholder,
    required this.onChanged,
    this.focusNode,
    this.number = false,
    this.paddingRight = 8,
  });
  final String value, placeholder;
  final ValueChanged<String> onChanged;
  final FocusNode? focusNode;
  final bool number;
  final double paddingRight;

  @override
  State<_CellInput> createState() => _CellInputState();
}

class _CellInputState extends State<_CellInput> {
  late final _text = TextEditingController(text: widget.value);
  FocusNode? _own;
  FocusNode get _focus => widget.focusNode ?? (_own ??= FocusNode());
  bool _hovered = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_rebuild);
  }

  void _rebuild() => setState(() {});

  @override
  void didUpdateWidget(_CellInput old) {
    super.didUpdateWidget(old);
    if (_text.text != widget.value) {
      _text.value = TextEditingValue(
        text: widget.value,
        selection: TextSelection.collapsed(offset: widget.value.length),
      );
    }
  }

  @override
  void dispose() {
    _focus.removeListener(_rebuild);
    _own?.dispose();
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = difyTextStyle(DifyType.systemXsRegular, DifyColors.textSecondary);
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Container(
        height: 28,
        alignment: Alignment.centerLeft,
        color: _focus.hasFocus
            ? DifyColors.componentsInputBgActive
            : _hovered
            ? DifyColors.stateBaseHover
            : null,
        child: TextField(
          controller: _text,
          focusNode: _focus,
          onChanged: widget.onChanged,
          keyboardType: widget.number ? const TextInputType.numberWithOptions(decimal: true, signed: true) : null,
          style: style,
          maxLines: 1,
          cursorColor: const Color(0xFF155EEF),
          cursorWidth: 1,
          decoration: InputDecoration(
            isCollapsed: true,
            border: InputBorder.none,
            contentPadding: EdgeInsets.fromLTRB(8, 6, widget.paddingRight, 6),
            hintText: widget.placeholder,
            hintStyle: style.copyWith(color: DifyColors.componentsInputTextPlaceholder),
          ),
        ),
      ),
    );
  }
}
