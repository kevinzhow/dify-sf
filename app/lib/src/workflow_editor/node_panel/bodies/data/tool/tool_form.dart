/// The tool form (nodes/tool/components/tool-form: index.tsx, item.tsx), its field control FormInputItem
/// (nodes/_base/components/form-input-item.tsx with .sections.tsx, form-input-boolean.tsx), the mixed text input
/// (tool/components/mixed-variable-text-input) and base/checkbox-list.
library;

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../../../design/dify_icon.dart';
import '../../../../../design/dify_tokens.g.dart';
import '../../../../../design/widgets/widgets.dart';
import '../../../../../i18n/dify_i18n.dart';
import '../../../../../workflow/dify_json.dart';
import '../../../../code_editor/code_editor.dart';
import '../../../../panel_fields/panel_fields.dart';
import '../../../../prompt_editor/prompt_editor.dart';
import '../../../../store/store.dart';
import '../data_common.dart';
import 'tool_date_pickers.dart';
import 'tool_host.dart';
import 'tool_model.dart';
import 'tool_schema_view.dart';

/// A form's new value (all its entries); typed text passes the version its draft began on.
typedef ToolFormChange = void Function(JsonMap value, [int? base]);

/// What the form's controls need from the panel: the variables in reach ([scope]; [mixedVars] for the text
/// inputs, string / number / secret), the nodes they come from, the document version for drafts, and the tool and
/// provider (dynamic selects).
class ToolFormEnv {
  const ToolFormEnv({
    this.scope = const VarScope(),
    this.mixedVars = const [],
    this.nodesMap = const {},
    this.version,
    this.currentTool,
    this.currentProvider,
    this.extraParams,
  });

  final VarScope scope;
  final List<VarGroup> mixedVars;
  final Map<String, WorkflowNodeInfo> nodesMap;
  final int Function()? version;
  final JsonMap? currentTool, currentProvider;
  final Map<String, Object?>? extraParams;
}

/// ToolForm: one [ToolFormItem] per [schema] field (`space-y-1`).
class ToolForm extends StatelessWidget {
  const ToolForm({
    super.key,
    required this.readOnly,
    required this.schema,
    required this.value,
    required this.onChange,
    this.env = const ToolFormEnv(),
    this.showManageInputField = false,
    this.onManageInputField,
  });

  final bool readOnly;
  final List<JsonMap> schema;
  final JsonMap value;
  final ToolFormChange onChange;
  final ToolFormEnv env;
  final bool showManageInputField;
  final VoidCallback? onManageInputField;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    spacing: 4,
    children: [
      for (final s in schema)
        ToolFormItem(
          readOnly: readOnly,
          schema: s,
          value: value,
          onChange: onChange,
          env: env,
          showManageInputField: showManageInputField,
          onManageInputField: onManageInputField,
        ),
    ],
  );
}

/// ToolFormItem (`space-y-0.5 py-1`): the label row (label, `*` when required, an infotip for the tooltip of
/// non-text fields, "· JSON Schema" for object / array fields), the tooltip as a description with linked URLs for
/// text / number / secret / date fields, then the [FormInputItem].
class ToolFormItem extends StatelessWidget {
  const ToolFormItem({
    super.key,
    required this.readOnly,
    required this.schema,
    required this.value,
    required this.onChange,
    this.env = const ToolFormEnv(),
    this.showManageInputField = false,
    this.onManageInputField,
  });

  final bool readOnly;
  final JsonMap schema;
  final JsonMap value;
  final ToolFormChange onChange;
  final ToolFormEnv env;
  final bool showManageInputField;
  final VoidCallback? onManageInputField;

  static const _descriptionTypes = {
    FormType.textInput,
    FormType.textNumber,
    FormType.secretInput,
    FormType.date,
    FormType.dateRange,
  };

  @override
  Widget build(BuildContext context) {
    final language = ToolPanelHost.of(context).language;
    final type = jsStr(schema['type']);
    final showSchemaButton = type == FormType.object || type == FormType.array;
    final showDescription = _descriptionTypes.contains(type);
    final tooltip = schema['tooltip'] == null ? '' : i18nText(schema['tooltip'], language);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 2,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 24),
                child: Row(
                  children: [
                    Flexible(
                      child: DifyTextLine(
                        i18nText(schema['label'], language),
                        style: difyStyle(DifyType.systemSmMedium, DifyColors.textSecondary),
                      ),
                    ),
                    if (schema['required'] == true)
                      Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: DifyText('*', DifyType.systemXsRegular, color: DifyColors.textDestructiveSecondary),
                      ),
                    if (!showDescription && tooltip.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: DifyInfotip(label: tooltip, width: 200, content: DifyTextLine(tooltip)),
                      ),
                    if (showSchemaButton) ...[
                      Padding(
                        padding: EdgeInsets.only(left: 4, right: 2),
                        child: DifyText('·', DifyType.systemXsRegular, color: DifyColors.textQuaternary),
                      ),
                      DifyButton(
                        variant: DifyButtonVariant.ghost,
                        size: DifyButtonSize.small,
                        semanticLabel: 'JSON Schema',
                        onPressed: () => showToolSchemaModal(
                          context,
                          rootName: jsKey(schema['name']),
                          schema: schema['input_schema'],
                        ),
                        leading: RemixIcon('braces-line', size: 14, color: DifyColors.textTertiary),
                        child: DifyText('JSON Schema', DifyType.systemXsRegular, color: DifyColors.textTertiary),
                      ),
                    ],
                  ],
                ),
              ),
              if (showDescription && tooltip.isNotEmpty) _Description(tooltip),
            ],
          ),
          FormInputItem(
            readOnly: readOnly,
            schema: schema,
            value: value,
            onChange: onChange,
            env: env,
            showManageInputField: showManageInputField,
            onManageInputField: onManageInputField,
          ),
        ],
      ),
    );
  }
}

/// The description below the label (`pb-0.5 body-xs-regular text-text-tertiary`), URLs as `text-text-accent` links
/// opened through the host.
class _Description extends StatelessWidget {
  const _Description(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final open = DataPanelHost.of(context).openUrl;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: DifyTextLine.rich(
        TextSpan(
          children: [
            for (final p in descriptionParts(text))
              p.isLink
                  ? TextSpan(
                      text: p.text,
                      style: TextStyle(color: DifyColors.textAccent),
                      semanticsLabel: p.text,
                      recognizer: TapGestureRecognizer()..onTap = () => open?.call(p.text),
                      mouseCursor: SystemMouseCursors.click,
                    )
                  : TextSpan(text: p.text),
          ],
        ),
        style: difyStyle(DifyType.bodyXsRegular, DifyColors.textTertiary),
      ),
    );
  }
}

/// FormInputItem: the field's control by schema type (see [FormInputState]): the variable / constant switch for
/// number, boolean, object, array, select and date fields; a mixed text input, a number input, a date or date range
/// picker, a checkbox list, True / False, a select (single, multiple or dynamic), a JSON editor, the host's app or
/// model selector; the variable picker for files and variable-mode values. Every change writes the field's entry
/// (`{...entry, type, value}`) into the form's [value].
class FormInputItem extends StatefulWidget {
  const FormInputItem({
    super.key,
    required this.readOnly,
    required this.schema,
    required this.value,
    required this.onChange,
    this.env = const ToolFormEnv(),
    this.showManageInputField = false,
    this.onManageInputField,
    this.disableVariableInsertion = false,
  });

  final bool readOnly;
  final JsonMap schema;
  final JsonMap value;
  final ToolFormChange onChange;
  final ToolFormEnv env;
  final bool showManageInputField;
  final VoidCallback? onManageInputField;
  final bool disableVariableInsertion;

  @override
  State<FormInputItem> createState() => _FormInputItemState();
}

class _FormInputItemState extends State<FormInputItem> {
  List<JsonMap>? _dynamicOptions;
  bool _loadingOptions = false;
  Object? _fetchKey;

  FormInputState get _state => FormInputState(widget.schema, widget.value[jsKey(widget.schema['variable'])]);
  JsonMap get _varInput => ConfigMap.of(widget.value[_state.variable]);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _fetchOptions();
  }

  @override
  void didUpdateWidget(FormInputItem old) {
    super.didUpdateWidget(old);
    _fetchOptions();
  }

  /// Dynamic selects fetch their options whenever the tool, provider, field or extra params change.
  void _fetchOptions() {
    final s = _state, env = widget.env;
    final fetch = ToolPanelHost.of(context).fetchDynamicOptions;
    if (!s.isDynamicSelect || env.currentTool == null || env.currentProvider == null || fetch == null) return;
    final key = (jsStr(env.currentTool!['name']), jsStr(env.currentProvider!['name']), s.variable, env.extraParams);
    if (key == _fetchKey) return;
    _fetchKey = key;
    _loadingOptions = true;
    unawaited(
      fetch(
        pluginId: jsStr(env.currentProvider!['plugin_id']) ?? '',
        provider: jsStr(env.currentProvider!['name']) ?? '',
        tool: jsStr(env.currentTool!['name']) ?? '',
        parameter: s.variable,
        extraParams: env.extraParams,
      ).then<List<JsonMap>>((o) => o, onError: (_) => const <JsonMap>[]).then((options) {
        if (!mounted || _fetchKey != key) return;
        setState(() {
          _dynamicOptions = options;
          _loadingOptions = false;
        });
      }),
    );
  }

  void _write(JsonMap entry, [int? base]) => widget.onChange({...widget.value, _state.variable: entry}, base);

  void _typeChange(VarKindType kind) => _write({
    ..._varInput,
    'type': kind == VarKindType.variable ? ToolVarKind.variable : ToolVarKind.constant,
    'value': kind == VarKindType.variable ? '' : _state.defaultValue,
  });

  void _valueChange(Object? v, [int? base]) {
    final s = _state;
    final type = getVarKindType(s) ?? jsStr(_varInput['type']) ?? ToolVarKind.constant;
    _write({..._varInput, 'type': type, 'value': s.isNumber ? jsonNumber(parseFloatJs(v)) : v}, base);
  }

  void _selectorChange(List<String> selector) =>
      _write({..._varInput, 'type': ToolVarKind.variable, 'value': normalizeVariableSelectorValue(selector)});

  @override
  Widget build(BuildContext context) {
    final w = widget, s = _state, host = ToolPanelHost.of(context), language = host.language;
    final varInput = _varInput;
    final value = varInput['value'];
    final placeholder = s.placeholder == null ? null : i18nText(s.placeholder, language);
    final visibleOptions = filterVisibleOptions(s.options, w.value);
    final visibleDynamic = filterVisibleOptions(_dynamicOptions ?? s.options, w.value);
    final staticItems = mapSelectItems(visibleOptions, language);
    final dynamicItems = mapSelectItems(visibleDynamic, language);
    final selectedList = value is List ? value : null;
    final selectedLabel = getSelectedLabels(
      selectedList,
      s.isDynamicSelect ? visibleDynamic : visibleOptions,
      language,
    );
    final controls = <Widget>[
      if (s.isString)
        MixedVariableTextInput(
          readOnly: w.readOnly,
          value: jsStr(value) ?? '',
          onChange: (t, base) => _valueChange(t, base),
          vars: w.env.mixedVars,
          nodesMap: w.env.nodesMap,
          version: w.env.version,
          showManageInputField: w.showManageInputField,
          onManageInputField: w.onManageInputField,
          disableVariableInsertion: w.disableVariableInsertion,
        ),
      if (s.isNumber && s.isConstant)
        _NumberInput(
          value: getNumberInputValue(value),
          placeholder: placeholder,
          readOnly: w.readOnly,
          onCommit: _valueChange,
          version: w.env.version,
        ),
      if (s.isDate && s.isConstant)
        ToolDatePicker(value: value, onChange: _valueChange, readOnly: w.readOnly, placeholder: placeholder),
      if (s.isDateRange && jsStr(varInput['type']) != ToolVarKind.variable)
        ToolDateRangePicker(value: value, onChange: _valueChange, readOnly: w.readOnly),
      if (s.isCheckbox && s.isConstant)
        DifyCheckboxList(
          title: i18nText(w.schema['label'], language).isNotEmpty ? i18nText(w.schema['label'], language) : s.variable,
          options: getCheckboxListOptions(visibleOptions, language),
          value: getCheckboxListValue(value, s.defaultValue, visibleOptions),
          disabled: w.readOnly,
          maxHeight: 200,
          onChange: (v) => _write({..._varInput, 'type': ToolVarKind.constant, 'value': v}),
        ),
      if (s.isBoolean && s.isConstant) FormInputBoolean(value: value == true, onChange: _valueChange),
      if (s.isSelect && s.isConstant && !s.isMultipleSelect)
        _SingleSelect(
          items: staticItems,
          value: jsStr(value),
          placeholder: placeholder,
          disabled: w.readOnly,
          onChanged: _valueChange,
        ),
      if (s.isSelect && s.isConstant && s.isMultipleSelect)
        MultiSelectField(
          disabled: w.readOnly,
          value: [for (final v in selectedList ?? const []) jsKey(v)],
          items: staticItems,
          onChange: _valueChange,
          placeholder: placeholder,
          selectedLabel: selectedLabel,
        ),
      if (s.isDynamicSelect && !s.isMultipleSelect)
        _SingleSelect(
          items: dynamicItems,
          value: jsStr(value),
          placeholder: _loadingOptions ? 'Loading...' : placeholder,
          disabled: w.readOnly || _loadingOptions,
          onChanged: _valueChange,
        ),
      if (s.isDynamicSelect && s.isMultipleSelect)
        MultiSelectField(
          disabled: w.readOnly || _loadingOptions,
          isLoading: _loadingOptions,
          value: [for (final v in selectedList ?? const []) jsKey(v)],
          items: dynamicItems,
          onChange: _valueChange,
          placeholder: placeholder,
          selectedLabel: selectedLabel,
        ),
      if (s.isShowJSONEditor && s.isConstant)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: DifyCodeEditor(
            title: 'JSON',
            value: jsStr(value) ?? '',
            language: CodeLanguage.json,
            isInNode: true,
            readOnly: w.readOnly,
            placeholder: placeholder,
            onChange: _valueChange,
          ),
        ),
      if (s.isAppSelector)
        host.appSelector?.call(
              context,
              value: value,
              readOnly: w.readOnly,
              scope: s.scope ?? 'all',
              onSelect: (v) => _write({
                ..._varInput,
                'type': getVarKindType(s) ?? jsStr(_varInput['type']) ?? ToolVarKind.constant,
                'value': v,
              }),
            ) ??
            const SizedBox.shrink(),
      if (s.isModelSelector && s.isConstant)
        host.modelSelector?.call(
              context,
              value: value,
              readOnly: w.readOnly,
              scope: s.scope,
              onSelect: (v) => _write({
                ..._varInput,
                'type': getVarKindType(s) ?? jsStr(_varInput['type']) ?? ToolVarKind.constant,
                'value': v,
              }),
            ) ??
            const SizedBox.shrink(),
      if (s.showVariableSelector)
        VarReferencePicker(
          readonly: w.readOnly,
          value: [for (final v in value is List ? value : const []) jsKey(v)],
          onChange: (sel, _) => _selectorChange(sel),
          scope: w.env.scope,
          filterVar: getFilterVar(s),
          valueTypePlaceHolder: getTargetVarType(s),
          isFilterFileVar: s.isBoolean,
        ),
    ];
    final typeSwitch = s.showTypeSwitch
        ? FormInputTypeSwitch(
            value: jsStr(varInput['type']) == ToolVarKind.variable ? VarKindType.variable : VarKindType.constant,
            onChanged: _typeChange,
          )
        : null;
    if (s.isShowJSONEditor && s.isConstant) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 4,
        children: [
          if (typeSwitch != null) Align(alignment: Alignment.centerLeft, child: typeSwitch),
          ...controls,
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 4,
      children: [
        ?typeSwitch,
        for (final c in controls) Expanded(child: c),
      ],
    );
  }
}

/// The constant number (`Input type=number h-8 grow`): a draft committed on blur or Enter.
class _NumberInput extends StatefulWidget {
  const _NumberInput({
    required this.value,
    required this.onCommit,
    this.placeholder,
    this.readOnly = false,
    this.version,
  });
  final String value;
  final void Function(Object? text, [int? base]) onCommit;
  final String? placeholder;
  final bool readOnly;
  final int Function()? version;

  @override
  State<_NumberInput> createState() => _NumberInputState();
}

class _NumberInputState extends State<_NumberInput> {
  late final _focus = FocusNode(debugLabel: 'tool number')..addListener(_focusChanged);
  late final _draft = TextDraft(widget.version);
  late String _text = widget.value;

  @override
  void didUpdateWidget(_NumberInput old) {
    super.didUpdateWidget(old);
    if (!_draft.isOpen) _text = widget.value;
  }

  void _focusChanged() {
    if (!_focus.hasFocus) _commit();
  }

  void _commit() {
    final d = _draft.take();
    if (d != null && _text != widget.value) widget.onCommit(_text, d.base);
  }

  @override
  void dispose() {
    _commit();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => DifyInput(
    value: _text,
    focusNode: _focus,
    height: 32,
    readOnly: widget.readOnly,
    placeholder: widget.placeholder,
    keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
    onChanged: (v) {
      _draft.touch();
      _text = v;
    },
    onSubmitted: (_) => _commit(),
  );
}

/// The single select (`SelectTrigger h-8 min-w-0 grow`), showing [placeholder] while nothing is chosen.
class _SingleSelect extends StatelessWidget {
  const _SingleSelect({
    required this.items,
    required this.value,
    required this.placeholder,
    required this.disabled,
    required this.onChanged,
  });
  final List<ToolSelectItem> items;
  final String? value;
  final String? placeholder;
  final bool disabled;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => DifySelect<String>(
    value: items.any((i) => i.value == value) ? value : null,
    options: [for (final i in items) (value: i.value, label: i.name)],
    placeholder: placeholder,
    disabled: disabled,
    onChanged: onChanged,
    optionLeading: (v) => switch (items.where((i) => i.value == v).firstOrNull?.icon) {
      final icon? when icon.isNotEmpty => ToolOptionIcon(icon),
      _ => null,
    },
  );
}

/// An option's icon (`<img src={icon} className="mr-2 size-4 shrink-0">`): the image at the URL, nothing when it
/// cannot be loaded.
class ToolOptionIcon extends StatelessWidget {
  const ToolOptionIcon(this.url, {super.key});
  final String url;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 16,
    height: 16,
    child: url.toLowerCase().endsWith('.svg')
        ? SvgPicture.network(url, width: 16, height: 16, errorBuilder: (_, _, _) => const SizedBox.shrink())
        : Image.network(url, width: 16, height: 16, errorBuilder: (_, _, _) => const SizedBox.shrink()),
  );
}

/// FormInputBoolean: two `h-8` option cards, True and False.
class FormInputBoolean extends StatelessWidget {
  const FormInputBoolean({super.key, required this.value, required this.onChange});
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

/// MultiSelectField: a select whose trigger shows [selectedLabel] (or the placeholder, "Select options", "Loading…"
/// with a spinner) and whose list (`max-h-60`) checks any number of [items].
class MultiSelectField extends StatelessWidget {
  const MultiSelectField({
    super.key,
    required this.disabled,
    required this.items,
    required this.onChange,
    required this.selectedLabel,
    required this.value,
    this.isLoading = false,
    this.placeholder,
  });

  final bool disabled, isLoading;
  final List<ToolSelectItem> items;
  final ValueChanged<List<String>> onChange;
  final String? placeholder;
  final String selectedLabel;
  final List<String> value;

  @override
  Widget build(BuildContext context) {
    final label = isLoading
        ? 'Loading…'
        : selectedLabel.isNotEmpty
        ? selectedLabel
        : placeholder != null && placeholder!.isNotEmpty
        ? placeholder!
        : 'Select options';
    final filled = !isLoading && value.isNotEmpty;
    return LayoutBuilder(
      builder: (context, c) => DifyDropdownMenu(
        placement: DifyPlacement.bottomStart,
        width: c.maxWidth.isFinite ? c.maxWidth : null,
        semanticLabel: placeholder ?? (selectedLabel.isNotEmpty ? selectedLabel : 'Options'),
        builder: (context, controller) => DifyPressable(
          disabled: disabled || isLoading,
          onPressed: controller.toggle,
          semanticLabel: placeholder ?? (selectedLabel.isNotEmpty ? selectedLabel : 'Options'),
          builder: (context, hovered, focused) => Container(
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: disabled
                  ? DifyColors.componentsInputBgDisabled
                  : hovered || controller.isOpen
                  ? DifyColors.stateBaseHoverAlt
                  : DifyColors.componentsInputBgNormal,
              borderRadius: BorderRadius.circular(DifyRadius.lg),
            ),
            child: Row(
              children: [
                if (isLoading)
                  Padding(
                    padding: EdgeInsets.only(right: 4),
                    child: RemixIcon('loader-4-line', size: 14, color: DifyColors.textSecondary),
                  ),
                Expanded(
                  child: DifyText(
                    label,
                    DifyType.systemSmRegular,
                    color: filled ? DifyColors.componentsInputTextFilled : DifyColors.componentsInputTextPlaceholder,
                  ),
                ),
                RemixIcon('arrow-down-s-line', size: 16, color: DifyColors.textQuaternary),
              ],
            ),
          ),
        ),
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 240),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final i in items)
                    DifyMenuCheckboxItem(
                      leading: i.icon == null || i.icon!.isEmpty ? null : ToolOptionIcon(i.icon!),
                      checked: value.contains(i.value),
                      onCheckedChange: (on) => onChange(
                        on
                            ? [...value, i.value]
                            : [
                                for (final v in value)
                                  if (v != i.value) v,
                              ],
                      ),
                      child: DifyTextLine(i.name),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// MixedVariableTextInput: a prompt editor in `min-h-8 rounded-lg border border-transparent
/// bg-components-input-bg-normal px-2 py-1` (hover / focus borders) where `/` inserts a variable from [vars]
/// (none with [disableVariableInsertion]); while empty the placeholder "Type or press [/] insert variable" with a
/// "String" badge shows, and its "insert variable" types the `/`. Remounted when the store's
/// `controlPromptEditorRerenderKey` changes. Typed text is committed on blur.
class MixedVariableTextInput extends StatefulWidget {
  const MixedVariableTextInput({
    super.key,
    this.readOnly = false,
    this.vars = const [],
    this.nodesMap = const {},
    this.value = '',
    this.onChange,
    this.showManageInputField = false,
    this.onManageInputField,
    this.disableVariableInsertion = false,
    this.version,
  });

  final bool readOnly;
  final List<VarGroup> vars;
  final Map<String, WorkflowNodeInfo> nodesMap;
  final String value;
  final TextCommit? onChange;
  final bool showManageInputField;
  final VoidCallback? onManageInputField;
  final bool disableVariableInsertion;
  final int Function()? version;

  @override
  State<MixedVariableTextInput> createState() => _MixedVariableTextInputState();
}

class _MixedVariableTextInputState extends State<MixedVariableTextInput> {
  var _editorKey = GlobalKey<DifyPromptEditorState>();
  int? _rerenderKey;
  late final _focus = FocusNode(debugLabel: 'mixed variable input')..addListener(_focusChanged);
  late final _draft = TextDraft(widget.version);
  late String _text = widget.value;
  bool _focused = false, _hovered = false;

  @override
  void didUpdateWidget(MixedVariableTextInput old) {
    super.didUpdateWidget(old);
    if (!_draft.isOpen) _text = widget.value;
  }

  void _focusChanged() {
    if (_focus.hasFocus == _focused) return;
    setState(() => _focused = _focus.hasFocus);
    if (!_focused) _commit();
  }

  void _commit() {
    final d = _draft.take();
    if (d != null && _text != widget.value) widget.onChange?.call(_text, d.base);
  }

  @override
  void dispose() {
    _commit();
    _focus.dispose();
    super.dispose();
  }

  /// Placeholder's `handleInsert`: [text] at the caret, then the focus.
  void _insert(String text) {
    _focus.requestFocus();
    final controller = _editorKey.currentState?.controller;
    if (text.isEmpty || controller == null) return;
    final v = controller.value;
    final at = v.selection.isValid ? v.selection.extentOffset : v.text.length;
    controller.value = TextEditingValue(
      text: v.text.replaceRange(at, at, text),
      selection: TextSelection.collapsed(offset: at + text.length),
    );
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final rerender = context.getInheritedWidgetOfExactType<WorkflowStoreScope>()?.store.controlPromptEditorRerenderKey;
    Widget editor(int key) {
      // A new key remounts the editor (Dify keys it on controlPromptEditorRerenderKey).
      if (key != _rerenderKey) {
        _rerenderKey = key;
        _editorKey = GlobalKey<DifyPromptEditorState>();
      }
      return DifyPromptEditor(
        key: _editorKey,
        value: _text,
        focusNode: _focus,
        editable: !w.readOnly,
        placeholder: const SizedBox.shrink(),
        onChange: (v) {
          if (v == _text) return;
          _draft.touch();
          setState(() => _text = v);
        },
        workflowVariableBlock: WorkflowVariableBlockConfig(
          show: !w.disableVariableInsertion,
          variables: w.vars,
          workflowNodesMap: w.nodesMap,
          showManageInputField: w.showManageInputField,
          onManageInputField: w.onManageInputField,
        ),
      );
    }

    final empty = _text.isEmpty;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Container(
        constraints: const BoxConstraints(minHeight: 32),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: _focused
              ? DifyColors.componentsInputBgActive
              : _hovered
              ? DifyColors.componentsInputBgHover
              : DifyColors.componentsInputBgNormal,
          borderRadius: BorderRadius.circular(DifyRadius.lg),
          border: Border.all(
            color: _focused
                ? DifyColors.componentsInputBorderActive
                : _hovered
                ? DifyColors.componentsInputBorderHover
                : Colors.transparent,
          ),
          boxShadow: _focused ? DifyShadows.xs : null,
        ),
        child: Stack(
          children: [
            rerender == null
                ? editor(0)
                : ValueListenableBuilder<int>(valueListenable: rerender, builder: (context, k, _) => editor(k)),
            if (empty)
              Positioned.fill(
                child: MixedInputPlaceholder(
                  disableVariableInsertion: w.disableVariableInsertion,
                  onInsert: w.readOnly ? null : _insert,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The mixed input's placeholder (placeholder.tsx): "Type or press", a `/` key and the dotted-underlined "insert
/// variable" (unless [disableVariableInsertion]), and a "String" badge (unless [hideBadge]); a click on it calls
/// [onInsert] with '' (focus), on "insert variable" with '/'.
class MixedInputPlaceholder extends StatelessWidget {
  const MixedInputPlaceholder({
    super.key,
    this.disableVariableInsertion = false,
    this.hideBadge = false,
    this.onInsert,
  });

  final bool disableVariableInsertion, hideBadge;
  final ValueChanged<String>? onInsert;

  @override
  Widget build(BuildContext context) {
    final style = difyStyle(DifyType.systemSmRegular, DifyColors.componentsInputTextPlaceholder);
    return MouseRegion(
      cursor: SystemMouseCursors.text,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onInsert == null ? null : () => onInsert!(''),
        child: Padding(
          padding: EdgeInsets.only(left: 8, right: 8, top: hideBadge ? 4 : 0, bottom: hideBadge ? 4 : 0),
          child: Row(
            crossAxisAlignment: hideBadge ? CrossAxisAlignment.start : CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: DifyTextLine(
                        DifyI18n.tr('workflow', 'nodes.tool.insertPlaceholder1'),
                        style: style,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (!disableVariableInsertion) ...[
                      Padding(
                        padding: EdgeInsets.symmetric(horizontal: 2),
                        child: DifyKbd('/', textColor: DifyColors.textPlaceholder),
                      ),
                      Flexible(
                        child: MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: GestureDetector(
                            onTap: onInsert == null ? null : () => onInsert!('/'),
                            child: DifyTextLine(
                              DifyI18n.tr('workflow', 'nodes.tool.insertPlaceholder2'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: style.copyWith(
                                decoration: TextDecoration.underline,
                                decorationStyle: TextDecorationStyle.dotted,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (!hideBadge) const DifyBadge('String', uppercase: false),
            ],
          ),
        ),
      ),
    );
  }
}
