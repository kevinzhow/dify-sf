/// Shared node settings sections (nodes/_base/components: memory-config.tsx, config-vision.tsx with
/// llm/components/resolution-picker.tsx, retry/retry-on-panel.tsx, error-handle/*). Values are the node's Dify data
/// as plain JSON (`memory`, `vision.configs`, `retry_config`, `error_strategy`, `default_value`).
library;

import 'package:flutter/material.dart';

import '../../cards/card_kit.dart';
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';
import '../../workflow/var_types.dart';
import 'controls.dart';
import 'field.dart';
import 'var_picker_model.dart';
import 'var_reference_picker.dart';

typedef Json = Map<String, Object?>;

String _wf(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('workflow', key, params);

// ---- memory ------------------------------------------------------------------------------------------------------

/// MEMORY_DEFAULT (memory-config.tsx).
const Json memoryDefault = {
  'window': {'enabled': false, 'size': 50},
  'query_prompt_template': '{{#sys.query#}}\n\n{{#sys.files#}}',
};

Json _json(Object? v) => v is Map<String, Object?> ? v : const {};

/// MemoryConfig: the "Memory" field with its switch (on: [defaultMemory], off: null); when on, the window switch,
/// "WINDOW SIZE" and a slider (`w-36`) with a number field (`w-12`), 1 to 100 (50 by default); with [canSetRoleName]
/// the user and assistant prefix inputs.
class MemoryConfig extends StatelessWidget {
  const MemoryConfig({
    super.key,
    required this.memory,
    required this.onChange,
    this.readonly = false,
    this.canSetRoleName = false,
    this.defaultMemory = memoryDefault,
  });

  final Json? memory;
  final ValueChanged<Json?> onChange;
  final bool readonly, canSetRoleName;
  final Json defaultMemory;

  static const _min = 1, _max = 100, _default = 50;

  Json _with(Json base, String key, Object? value) => {...base, key: value};

  void _window({bool? enabled, int? size}) {
    final base = memory ?? defaultMemory;
    final window = {..._json(base['window'])};
    window['enabled'] ??= size != null;
    window['size'] ??= _default;
    if (enabled != null) window['enabled'] = enabled;
    if (size != null) window['size'] = size;
    onChange(_with(base, 'window', window));
  }

  void _role(String role, String value) {
    final base = memory ?? defaultMemory;
    final prefix = {'user': '', 'assistant': '', ..._json(base['role_prefix'])};
    prefix[role] = value;
    onChange(_with(base, 'role_prefix', prefix));
  }

  @override
  Widget build(BuildContext context) {
    final payload = memory;
    final window = _json(payload?['window']);
    final enabled = window['enabled'] == true;
    final size = (window['size'] as num?)?.toInt() ?? _default;
    final label = _wf('nodes.common.memory.windowSize');
    final prefix = _json(payload?['role_prefix']);
    return Field(
      title: _wf('nodes.common.memory.memory'),
      tooltip: _wf('nodes.common.memory.memoryTip'),
      operations: DifySwitch(
        checked: payload != null,
        disabled: readonly,
        semanticLabel: _wf('nodes.common.memory.memory'),
        onCheckedChange: (on) => onChange(on ? defaultMemory : null),
      ),
      child: payload == null
          ? null
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Flexible(
                      child: SizedBox(
                        height: 32,
                        child: Row(
                          spacing: 8,
                          children: [
                            DifySwitch(
                              checked: enabled,
                              disabled: readonly,
                              onCheckedChange: (v) => _window(enabled: v),
                            ),
                            Flexible(
                              child: DifyText(label, DifyType.systemXsMediumUppercase, color: DifyColors.textTertiary),
                            ),
                          ],
                        ),
                      ),
                    ),
                    SizedBox(
                      height: 32,
                      child: Row(
                        spacing: 8,
                        children: [
                          SizedBox(
                            width: 144,
                            child: DifySlider(
                              value: size,
                              min: _min,
                              max: _max,
                              semanticLabel: label,
                              disabled: readonly || !enabled,
                              onChanged: (v) => _window(size: v),
                            ),
                          ),
                          SizedBox(
                            width: 48,
                            child: DifyNumberField(
                              value: size,
                              min: _min,
                              max: _max,
                              semanticLabel: label,
                              inputPaddingRight: 0,
                              disabled: readonly || !enabled,
                              onChanged: (v) {
                                if (v != null) _window(size: v.round());
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (canSetRoleName) ...[
                  const SizedBox(height: 16),
                  Text(
                    _wf('nodes.common.memory.conversationRoleName').toUpperCase(),
                    style: TextStyle(
                      fontSize: 12,
                      height: 2,
                      fontWeight: FontWeight.w500,
                      color: DifyColors.textTertiary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  _RoleItem(
                    readonly: readonly,
                    title: _wf('nodes.common.memory.user'),
                    value: '${prefix['user'] ?? ''}',
                    onChange: (v) => _role('user', v),
                  ),
                  const SizedBox(height: 8),
                  _RoleItem(
                    readonly: readonly,
                    title: _wf('nodes.common.memory.assistant'),
                    value: '${prefix['assistant'] ?? ''}',
                    onChange: (v) => _role('assistant', v),
                  ),
                ],
              ],
            ),
    );
  }
}

class _RoleItem extends StatefulWidget {
  const _RoleItem({required this.readonly, required this.title, required this.value, required this.onChange});
  final bool readonly;
  final String title, value;
  final ValueChanged<String> onChange;

  @override
  State<_RoleItem> createState() => _RoleItemState();
}

class _RoleItemState extends State<_RoleItem> {
  final _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Row(
    children: [
      GestureDetector(
        onTap: _focus.requestFocus,
        child: Text(widget.title, style: TextStyle(fontSize: 13, color: DifyColors.textSecondary)),
      ),
      Expanded(
        child: Align(
          alignment: Alignment.centerLeft,
          child: SizedBox(
            width: 200,
            child: DifyInput(
              value: widget.value,
              focusNode: _focus,
              readOnly: widget.readonly,
              semanticLabel: widget.title,
              height: 32,
              onChanged: widget.onChange,
            ),
          ),
        ),
      ),
    ],
  );
}

// ---- vision ------------------------------------------------------------------------------------------------------

/// ResolutionPicker: "RESOLUTION" with the High / Low option cards.
class ResolutionPicker extends StatelessWidget {
  const ResolutionPicker({super.key, required this.value, required this.onChange});
  final String value;
  final ValueChanged<String> onChange;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: [
      Padding(
        padding: const EdgeInsets.only(right: 8),
        child: Text(
          _wf('nodes.llm.resolution.name').toUpperCase(),
          style: TextStyle(
            fontSize: 12,
            height: 16 / 12,
            fontWeight: FontWeight.w500,
            color: DifyColors.textSecondary,
          ),
        ),
      ),
      Row(
        spacing: 4,
        children: [
          for (final r in const ['high', 'low'])
            OptionCard(title: _wf('nodes.llm.resolution.$r'), selected: value == r, onSelect: () => onChange(r)),
        ],
      ),
    ],
  );
}

/// ConfigVision: the "vision" field whose switch is off and disabled (with the "Only supports vision models" tip)
/// unless [isVisionModel]; when on, a file variable picker and the [ResolutionPicker]. [config] is
/// `vision.configs` (`{detail, variable_selector}`; high and none by default).
class ConfigVision extends StatelessWidget {
  const ConfigVision({
    super.key,
    required this.isVisionModel,
    required this.enabled,
    required this.onEnabledChange,
    required this.config,
    required this.onConfigChange,
    required this.scope,
    this.readOnly = false,
  });

  final bool isVisionModel, enabled, readOnly;
  final ValueChanged<bool> onEnabledChange;
  final Json? config;
  final ValueChanged<Json> onConfigChange;
  final VarScope scope;

  static bool _isFile(PickerVar v, List<String> _) => v.type == VarType.file || v.type == VarType.arrayFile;

  @override
  Widget build(BuildContext context) {
    final cfg = config ?? const {'detail': 'high', 'variable_selector': <String>[]};
    final selector = [for (final s in (cfg['variable_selector'] as List?) ?? const []) '$s'];
    return Field(
      title: _wf('nodes.llm.vision'),
      tooltip: DifyI18n.tr('app-debug', 'vision.description'),
      operations: DifyTooltip(
        disabled: isVisionModel,
        content: Text(DifyI18n.tr('app-debug', 'vision.onlySupportVisionModelTip')),
        child: DifySwitch(
          checked: isVisionModel && enabled,
          disabled: readOnly || !isVisionModel,
          semanticLabel: _wf('nodes.llm.vision'),
          onCheckedChange: onEnabledChange,
        ),
      ),
      child: enabled && isVisionModel
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: VarReferencePicker(
                    value: selector,
                    scope: scope,
                    readonly: readOnly,
                    filterVar: _isFile,
                    onChange: (sel, _) => onConfigChange({...cfg, 'variable_selector': sel}),
                  ),
                ),
                ResolutionPicker(
                  value: '${cfg['detail'] ?? 'high'}',
                  onChange: (r) => onConfigChange({...cfg, 'detail': r}),
                ),
              ],
            )
          : null,
    );
  }
}

// ---- retry -------------------------------------------------------------------------------------------------------

/// RetryOnPanel: "retry on failure" with its switch; when on, max retries (1 to 10, 3 by default, "times") and the
/// interval (100 to 5000 ms, 1000 by default), each a slider (`w-27`) and a number field (`w-25`); a Split below.
/// [onChange] gets the whole `retry_config`.
class RetryOnPanel extends StatelessWidget {
  const RetryOnPanel({super.key, required this.retryConfig, required this.onChange});
  final Json? retryConfig;
  final ValueChanged<Json> onChange;

  int get _max => (retryConfig?['max_retries'] as num?)?.toInt().nonZero ?? 3;
  int get _interval => (retryConfig?['retry_interval'] as num?)?.toInt().nonZero ?? 1000;

  void _set({required bool enabled, int? max, int? interval}) => onChange({
    'retry_enabled': enabled,
    'max_retries': (max ?? _max).clamp(1, 10),
    'retry_interval': (interval ?? _interval).clamp(100, 5000),
  });

  Widget _row(String label, int value, int min, int max, String unit, ValueChanged<int> set) => Row(
    children: [
      Expanded(
        child: Padding(
          padding: const EdgeInsets.only(right: 8),
          child: DifyText(label, DifyType.systemXsMediumUppercase, color: DifyColors.textSecondary),
        ),
      ),
      Padding(
        padding: const EdgeInsets.only(right: 12),
        child: SizedBox(
          width: 108,
          child: DifySlider(
            value: value,
            min: min,
            max: max,
            semanticLabel: label,
            valueText: (v) => '$v $unit',
            onChanged: set,
          ),
        ),
      ),
      SizedBox(
        width: 100,
        child: DifyNumberField(
          value: value,
          min: min,
          max: max,
          unit: unit,
          semanticLabel: label,
          onChanged: (v) => set(v?.round() ?? (min == 1 ? 3 : 1000)),
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final enabled = retryConfig?['retry_enabled'] == true;
    final label = _wf('nodes.common.retry.retryOnFailure');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 8),
        Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(child: DifyText(label, DifyType.systemSmSemiboldUppercase, color: DifyColors.textSecondary)),
              DifySwitch(
                checked: enabled,
                semanticLabel: label,
                onCheckedChange: (v) => _set(enabled: v),
              ),
            ],
          ),
        ),
        if (enabled)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              spacing: 4,
              children: [
                _row(_wf('nodes.common.retry.maxRetries'), _max, 1, 10, _wf('nodes.common.retry.times'), (v) {
                  _set(enabled: true, max: v);
                }),
                _row(_wf('nodes.common.retry.retryInterval'), _interval, 100, 5000, _wf('nodes.common.retry.ms'), (v) {
                  _set(enabled: true, interval: v);
                }),
              ],
            ),
          ),
        const PanelSplit(margin: EdgeInsets.fromLTRB(16, 8, 16, 0)),
      ],
    );
  }
}

extension on int {
  /// JavaScript's `x || fallback` for numbers: 0 counts as missing.
  int? get nonZero => this == 0 ? null : this;
}

// ---- error handling ----------------------------------------------------------------------------------------------

/// ErrorHandleTypeEnum.
enum ErrorHandleType {
  none('none'),
  failBranch('fail-branch'),
  defaultValue('default-value');

  const ErrorHandleType(this.value);
  final String value;

  static ErrorHandleType? of(Object? v) => values.where((t) => t.value == v).firstOrNull;
}

/// `getDefaultValueByType` (error-handle/utils.ts).
Object defaultValueByType(String? type) => switch (type) {
  VarType.string => '',
  VarType.number => 0,
  VarType.object => '{}',
  VarType.arrayObject || VarType.arrayString || VarType.arrayNumber || VarType.arrayFile => '[]',
  _ => '',
};

/// `getDefaultValue` (error-handle/utils.ts): the default-value forms of a node type (Code: one per output).
List<Json> errorDefaultValues(String nodeType, {Map<String, String> codeOutputs = const {}}) {
  Json form(String key, String type) => {'key': key, 'type': type, 'value': defaultValueByType(type)};
  return switch (nodeType) {
    'llm' => [form('text', VarType.string)],
    'http-request' => [
      form('body', VarType.string),
      form('status_code', VarType.number),
      form('headers', VarType.object),
    ],
    'tool' => [form('text', VarType.string), form('json', VarType.arrayObject)],
    'code' => [for (final e in codeOutputs.entries) form(e.key, e.value)],
    _ => [],
  };
}

/// `handleErrorHandleTypeChange` (error-handle/hooks.ts): the data changes choosing [value] makes (null: nothing)
/// and whether the fail-branch edges go.
({Json changes, bool deleteFailBranch})? errorStrategyChange(
  Object? current,
  ErrorHandleType value,
  String nodeType, {
  Map<String, String> codeOutputs = const {},
}) {
  if (current == value.value) return null;
  return switch (value) {
    ErrorHandleType.none => (changes: {'error_strategy': null, 'default_value': null}, deleteFailBranch: true),
    ErrorHandleType.failBranch => (
      changes: {'error_strategy': value.value, 'default_value': null},
      deleteFailBranch: false,
    ),
    ErrorHandleType.defaultValue => (
      changes: {
        'error_strategy': value.value,
        'default_value': errorDefaultValues(nodeType, codeOutputs: codeOutputs),
      },
      deleteFailBranch: true,
    ),
  };
}

/// `useDefaultValue().handleFormChange`: [defaults] with [form]'s value set (or [form] appended).
List<Json> defaultValueFormChange(List<Json>? defaults, Json form) {
  final list = defaults ?? const [];
  if (list.any((f) => f['key'] == form['key'])) {
    return [
      for (final f in list) f['key'] == form['key'] ? {...f, 'value': form['value']} : f,
    ];
  }
  return [...list, form];
}

/// ErrorHandleTypeSelector: a small button with the strategy's name and a chevron, opening (bottom-end) a `w-70`
/// list of None / Default Value / Fail Branch with their descriptions, the current one checked.
class ErrorHandleTypeSelector extends StatefulWidget {
  const ErrorHandleTypeSelector({super.key, required this.value, required this.onSelected});
  final ErrorHandleType value;
  final ValueChanged<ErrorHandleType> onSelected;

  @override
  State<ErrorHandleTypeSelector> createState() => _ErrorHandleTypeSelectorState();
}

class _ErrorHandleTypeSelectorState extends State<ErrorHandleTypeSelector> {
  final _c = DifyFloatingController();

  static String _key(ErrorHandleType t) => switch (t) {
    ErrorHandleType.none => 'none',
    ErrorHandleType.failBranch => 'failBranch',
    ErrorHandleType.defaultValue => 'defaultValue',
  };

  @override
  Widget build(BuildContext context) => DifyFloating(
    controller: _c,
    placement: DifyPlacement.bottomEnd,
    sideOffset: 4,
    collision: DifyCollision.dropdown,
    builder: (context, c) => DifyButton(
      size: DifyButtonSize.small,
      onPressed: c.toggle,
      trailing: const RemixIcon('arrow-down-s-line', size: 14),
      child: Text(_wf('nodes.common.errorHandle.${_key(widget.value)}.title')),
    ),
    popupBuilder: (context) => DifyBlurredBox(
      blur: 5,
      borderRadius: BorderRadius.circular(DifyRadius.xl),
      decoration: DifyMenuPopup.decoration,
      padding: const EdgeInsets.all(4),
      child: SizedBox(
        width: 272,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final t in ErrorHandleType.values)
              _StrategyItem(
                title: _wf('nodes.common.errorHandle.${_key(t)}.title'),
                description: _wf('nodes.common.errorHandle.${_key(t)}.desc'),
                checked: t == widget.value,
                onTap: () {
                  _c.close();
                  widget.onSelected(t);
                },
              ),
          ],
        ),
      ),
    ),
  );
}

class _StrategyItem extends StatefulWidget {
  const _StrategyItem({required this.title, required this.description, required this.checked, required this.onTap});
  final String title, description;
  final bool checked;
  final VoidCallback onTap;

  @override
  State<_StrategyItem> createState() => _StrategyItemState();
}

class _StrategyItemState extends State<_StrategyItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) => Semantics(
    checked: widget.checked,
    inMutuallyExclusiveGroup: true,
    button: true,
    child: MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(8, 8, 12, 8),
          decoration: BoxDecoration(
            color: _hovered ? DifyColors.stateBaseHover : null,
            borderRadius: BorderRadius.circular(DifyRadius.lg),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 20,
                child: widget.checked
                    ? Align(
                        alignment: Alignment.topLeft,
                        child: RemixIcon('check-line', size: 16, color: DifyColors.textAccent),
                      )
                    : null,
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    DifyText(widget.title, DifyType.systemSmSemibold, color: DifyColors.textSecondary),
                    const SizedBox(height: 2),
                    DifyText(
                      widget.description,
                      DifyType.systemXsRegular,
                      color: DifyColors.textTertiary,
                      maxLines: null,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// The docs page of error types (useDocLink).
String errorTypeDocLink({String product = 'self-host'}) {
  final language = switch (DifyI18n.current) {
    DifyI18n(:final language) => language,
    _ => DifyI18n.fallbackLanguage,
  };
  final docLanguage = const {'zh-Hans': 'zh', 'ja-JP': 'ja'}[language] ?? 'en';
  return 'https://docs.dify.ai/$docLanguage/$product/use-dify/debug/error-type';
}

/// FailBranchCard: the `bg-workflow-process-bg` card (mind-map tile, "Go to the canvas to customize the fail branch
/// logic." and the tip with a "Learn More" link to [docLink]).
class FailBranchCard extends StatelessWidget {
  const FailBranchCard({super.key, required this.onOpenLink, this.docLink});
  final ValueChanged<String> onOpenLink;
  final String? docLink;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
    child: Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(gradient: DifyGradients.workflowProcessBg, borderRadius: BorderRadius.circular(10)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 32,
            height: 32,
            margin: const EdgeInsets.only(bottom: 8),
            decoration: BoxDecoration(
              color: DifyColors.componentsCardBg,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: DifyColors.componentsCardBorder, width: 0.5),
              boxShadow: DifyShadows.lg,
            ),
            child: Center(child: RemixIcon('mind-map', size: 20, color: DifyColors.textTertiary)),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: DifyText(
              _wf('nodes.common.errorHandle.failBranch.customize'),
              DifyType.systemSmMedium,
              color: DifyColors.textSecondary,
              maxLines: null,
            ),
          ),
          Text.rich(
            TextSpan(
              text: '${_wf('nodes.common.errorHandle.failBranch.customizeTip')} ',
              children: [
                WidgetSpan(
                  child: Semantics(
                    link: true,
                    child: GestureDetector(
                      onTap: () => onOpenLink(docLink ?? errorTypeDocLink()),
                      child: MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: Text(
                          _wf('common.learnMore'),
                          style: difyStyle(DifyType.systemXsRegular, DifyColors.textAccent),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            style: difyStyle(DifyType.systemXsRegular, DifyColors.textTertiary),
          ),
        ],
      ),
    ),
  );
}

/// An editor for a JSON default value (the code editor in JSON mode); [DefaultValue] falls back to a plain field.
typedef JsonEditorBuilder = Widget Function(BuildContext context, String value, ValueChanged<String> onChange);

/// DefaultValue: the description, then per output its key and type with an input for strings and numbers (numbers
/// are reported as typed text, as Dify does) or a JSON editor for objects and arrays.
class DefaultValue extends StatelessWidget {
  const DefaultValue({super.key, required this.forms, required this.onFormChange, this.jsonEditor});
  final List<Json> forms;
  final ValueChanged<Json> onFormChange;
  final JsonEditorBuilder? jsonEditor;

  static const _jsonTypes = {
    VarType.array,
    VarType.arrayNumber,
    VarType.arrayString,
    VarType.arrayObject,
    VarType.object,
  };

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            '${_wf('nodes.common.errorHandle.defaultValue.desc')} ',
            style: difyStyle(DifyType.bodyXsRegular, DifyColors.textTertiary),
          ),
        ),
        for (final f in forms) _DefaultValueRow(form: f, onFormChange: onFormChange, jsonEditor: jsonEditor),
      ],
    ),
  );
}

class _DefaultValueRow extends StatefulWidget {
  const _DefaultValueRow({required this.form, required this.onFormChange, this.jsonEditor});
  final Json form;
  final ValueChanged<Json> onFormChange;
  final JsonEditorBuilder? jsonEditor;

  @override
  State<_DefaultValueRow> createState() => _DefaultValueRowState();
}

class _DefaultValueRowState extends State<_DefaultValueRow> {
  final _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final f = widget.form;
    final key = '${f['key']}', type = '${f['type']}';
    final isInput = type == VarType.string || type == VarType.number;
    final value = f['value'];
    void report(String v) => widget.onFormChange({'key': key, 'type': type, 'value': v});
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: [
                GestureDetector(
                  onTap: isInput ? _focus.requestFocus : null,
                  child: DifyText(key, DifyType.systemSmMedium, color: DifyColors.textPrimary),
                ),
                const SizedBox(width: 4),
                DifyText(type, DifyType.systemXsRegular, color: DifyColors.textTertiary),
              ],
            ),
          ),
          if (isInput)
            DifyInput(
              value: value == null || value == '' || value == 0 ? (type == VarType.string ? '' : '0') : '$value',
              focusNode: _focus,
              semanticLabel: key,
              placeholder: DifyI18n.tr('common', 'placeholder.input'),
              keyboardType: type == VarType.number ? const TextInputType.numberWithOptions(decimal: true) : null,
              onChanged: report,
            ),
          if (DefaultValue._jsonTypes.contains(type))
            widget.jsonEditor?.call(context, '${value ?? ''}', report) ??
                DifyInput(value: '${value ?? ''}', semanticLabel: key, onChanged: report),
        ],
      ),
    );
  }
}

/// ErrorHandleTip (the run log's note): a warning-gradient box saying which strategy handled the error; nothing
/// without [type].
class ErrorHandleTip extends StatelessWidget {
  const ErrorHandleTip({super.key, this.type});
  final ErrorHandleType? type;

  @override
  Widget build(BuildContext context) {
    final text = switch (type) {
      ErrorHandleType.failBranch => _wf('nodes.common.errorHandle.failBranch.inLog'),
      ErrorHandleType.defaultValue => _wf('nodes.common.errorHandle.defaultValue.inLog'),
      _ => null,
    };
    if (type == null) return const SizedBox.shrink();
    final r = BorderRadius.circular(DifyRadius.lg);
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 8, 52, 8),
      decoration: BoxDecoration(
        color: DifyColors.componentsPanelBgBlur,
        borderRadius: r,
        border: Border.all(color: DifyColors.componentsPanelBorder, width: 0.5),
        boxShadow: DifyShadows.xs,
      ),
      foregroundDecoration: BoxDecoration(
        borderRadius: r,
        gradient: const LinearGradient(colors: [Color(0x1AF79009), Color(0x00FFFFFF)]),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.only(right: 4),
            child: RemixIcon('alert-fill', size: 16, color: DifyColors.textWarningSecondary),
          ),
          Expanded(child: DifyText(text ?? '', DifyType.systemXsMedium, color: DifyColors.textPrimary, maxLines: null)),
        ],
      ),
    );
  }
}

/// ErrorHandleOnPanel: the "Error Handling" collapse (with its tip) and the [ErrorHandleTypeSelector] on the right;
/// open, it shows the [FailBranchCard] or the [DefaultValue] forms of [errorStrategy]. Collapsed at first when the
/// strategy is `none`; choosing none collapses it, another strategy opens it. The section only toggles while a
/// strategy is set.
class ErrorHandleOnPanel extends StatefulWidget {
  const ErrorHandleOnPanel({
    super.key,
    required this.errorStrategy,
    required this.defaultValue,
    required this.onStrategyChange,
    required this.onDefaultValueChange,
    required this.onOpenLink,
    this.jsonEditor,
  });

  /// `error_strategy` (`fail-branch`, `default-value` or null).
  final String? errorStrategy;
  final List<Json>? defaultValue;

  /// A different strategy was chosen (apply [errorStrategyChange]).
  final ValueChanged<ErrorHandleType> onStrategyChange;

  /// One default-value form changed (apply [defaultValueFormChange]).
  final ValueChanged<Json> onDefaultValueChange;
  final ValueChanged<String> onOpenLink;
  final JsonEditorBuilder? jsonEditor;

  @override
  State<ErrorHandleOnPanel> createState() => _ErrorHandleOnPanelState();
}

class _ErrorHandleOnPanelState extends State<ErrorHandleOnPanel> {
  late bool _collapsed = widget.errorStrategy == ErrorHandleType.none.value;

  void _select(ErrorHandleType t) {
    if (widget.errorStrategy == t.value) return;
    setState(() => _collapsed = t == ErrorHandleType.none);
    widget.onStrategyChange(t);
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final strategy = w.errorStrategy;
    final tip = _wf('nodes.common.errorHandle.tip');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: PanelCollapse(
        title: _wf('nodes.common.errorHandle.title'),
        disabled: strategy == null || strategy.isEmpty,
        indicator: strategy != null && strategy.isNotEmpty,
        collapsed: _collapsed,
        onCollapse: (v) => setState(() => _collapsed = v),
        afterTrigger: Infotip(label: tip, content: Text(tip)),
        // `pr-4` block around the inline trigger: its text line puts the button 1.5 px down (Chrome at 2x).
        actions: Padding(
          padding: const EdgeInsets.only(right: 16, top: 1.5),
          child: ErrorHandleTypeSelector(
            value: ErrorHandleType.of(strategy) ?? ErrorHandleType.none,
            onSelected: _select,
          ),
        ),
        child: switch (strategy) {
          _ when _collapsed => const SizedBox.shrink(),
          'fail-branch' => FailBranchCard(onOpenLink: w.onOpenLink),
          'default-value' when (w.defaultValue ?? const []).isNotEmpty => DefaultValue(
            forms: w.defaultValue!,
            onFormChange: w.onDefaultValueChange,
            jsonEditor: w.jsonEditor,
          ),
          _ => const SizedBox.shrink(),
        },
      ),
    );
  }
}
