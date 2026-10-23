/// The environment variable modal (panel/env-panel/variable-modal.tsx) and its model field
/// (llm-environment-variable.ts, llm-environment-variable-value-field.tsx).
library;

import 'package:flutter/material.dart';

import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';
import '../node_panel/bodies/llm/group_host.dart';
import '../../workflow/model_catalog.dart';
import '../node_panel/bodies/llm/model_parameter_modal.dart';
import '../panel_fields/var_list.dart' show varNameFormatter;
import '../panel_fields/var_picker_model.dart' show checkKeys;
import '../prompt_editor/config_prompt.dart' show uuid4;
import '../store/store.dart';
import 'app_variables.dart';
import 'panel_kit.dart';

/// `isLLMEnvironmentVariableValue`: `{provider, name, mode: chat | completion, completion_params?: object}` with a
/// provider and a name.
bool isLLMEnvironmentVariableValue(Object? value) {
  if (value is! Map) return false;
  final provider = value['provider'], name = value['name'], mode = value['mode'], params = value['completion_params'];
  return provider is String &&
      provider.trim().isNotEmpty &&
      name is String &&
      name.trim().isNotEmpty &&
      (mode == 'chat' || mode == 'completion') &&
      (params == null || params is Map);
}

/// The value types of an environment variable, in the modal's order.
const envValueTypes = ['string', 'number', 'secret', 'llm'];

/// VariableModal: "Add Environment Variable", or "Edit Environment Variable" for [env]; [onSave] gets Dify's
/// variable (`{id, value_type, name, value, description}`), then the modal closes.
class EnvVariableModal extends StatefulWidget {
  const EnvVariableModal({super.key, this.env, required this.onClose, required this.onSave});
  final DifyVariable? env;
  final VoidCallback onClose;
  final ValueChanged<DifyVariable> onSave;

  @override
  State<EnvVariableModal> createState() => _EnvVariableModalState();
}

class _EnvVariableModalState extends State<EnvVariableModal> {
  String _type = 'string';
  String _name = '';
  Object? _value;
  String _description = '';
  final _nameFocus = FocusNode(debugLabel: 'env name');

  DifyVariable? get _env => widget.env;

  String? get _originalLLMMode {
    final env = _env;
    if (env?['value_type'] != 'llm' || !isLLMEnvironmentVariableValue(env?['value'])) return null;
    return (env!['value']! as Map)['mode'] as String?;
  }

  bool _isTypeChangeDisabled(String next) => _env != null && (_env!['value_type'] == 'llm') != (next == 'llm');

  @override
  void initState() {
    super.initState();
    final env = _env;
    if (env != null) {
      _type = '${env['value_type'] ?? 'string'}';
      _name = '${env['name'] ?? ''}';
      _value = _type == 'secret'
          ? WorkflowStoreScope.of(context).envSecrets.value[env['id']] ?? env['value']
          : env['value'];
      _description = '${env['description'] ?? ''}';
    }
    _nameFocus.addListener(() {
      if (!_nameFocus.hasFocus) _checkVariableName(_name);
    });
  }

  @override
  void dispose() {
    _nameFocus.dispose();
    super.dispose();
  }

  void _toast(String message) => toastError(context, message);

  String _keyError(String error) => DifyI18n.tr('app-debug', 'varKeyError.$error', {'key': tw('env.modal.name')});

  bool _checkVariableName(String value) {
    final bad = checkKeys([value]);
    if (bad == null) return true;
    _toast(_keyError(bad.error));
    return false;
  }

  void _handleVarNameChange(String value) {
    if (value.isNotEmpty && !_checkVariableName(value)) {
      setState(() {}); // the field shows the last valid name again
      return;
    }
    setState(() => _name = value);
  }

  void _handleTypeChange(String next) {
    if (_isTypeChangeDisabled(next)) return;
    setState(() {
      _type = next;
      final value = _value;
      if (next == 'llm') {
        if (!isLLMEnvironmentVariableValue(value)) _value = null;
        return;
      }
      if (isLLMEnvironmentVariableValue(value)) {
        _value = '';
        return;
      }
      if (next == 'number') {
        if (value == null || value == '' || _number(value) == null) _value = '';
        return;
      }
      if (value is num) _value = '$value';
    });
  }

  /// JavaScript's `Number(value)`, null for NaN.
  static num? _number(Object? value) => value is num ? value : num.tryParse('$value'.trim());

  void _handleSave() {
    if (!_checkVariableName(_name)) return;
    final value = _value;
    if (value == null || value == '' || (_type == 'llm' && !isLLMEnvironmentVariableValue(value))) {
      return _toast(tw('env.modal.valueRequired'));
    }
    final number = _type == 'number' ? _number(value) : null;
    if (_type == 'number' && number == null) return _toast(tw('env.modal.valueRequired'));
    final envList = WorkflowStoreScope.of(context).environmentVariables.value;
    final env = _env;
    if ((env == null || env['name'] != _name) && envList.any((e) => e['name'] == _name)) {
      return _toast(_keyError('keyAlreadyExists'));
    }
    widget.onSave({
      'id': env == null ? uuid4() : env['id'],
      'value_type': _type,
      'name': _name,
      'value': number ?? value,
      'description': _description,
    });
    widget.onClose();
  }

  @override
  Widget build(BuildContext context) {
    final value = _value;
    final text = value is String || value is num ? '$value' : '';
    return VariableModalSurface(
      title: tw(_env == null ? 'env.modal.title' : 'env.modal.editTitle'),
      onClose: widget.onClose,
      onSave: _handleSave,
      close: DifyIconButton(
        label: tc('operation.close'),
        onPressed: widget.onClose,
        icon: const RemixIcon('close-line', size: 16),
      ),
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ModalSectionTitle(tw('env.modal.type')),
            Semantics(
              container: true,
              label: tw('env.modal.type'),
              child: Row(
                spacing: 8,
                children: [
                  for (final t in envValueTypes)
                    Expanded(
                      child: _TypeCard(
                        label: t == 'llm' ? tw('blocks.llm') : capitalize(t),
                        selected: _type == t,
                        disabled: _isTypeChangeDisabled(t),
                        tip: t == 'secret' ? tw('env.modal.secretTip') : null,
                        onPressed: () => _handleTypeChange(t),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            ModalSectionTitle(tw('env.modal.name')),
            DifyInput(
              value: _name,
              placeholder: tw('env.modal.namePlaceholder'),
              formatters: [varNameFormatter],
              focusNode: _nameFocus,
              onChanged: _handleVarNameChange,
            ),
            const SizedBox(height: 16),
            ModalSectionTitle(_type == 'llm' ? tc('modelProvider.model') : tw('env.modal.value')),
            if (_type == 'llm')
              LLMEnvironmentVariableValueField(
                value: isLLMEnvironmentVariableValue(value) ? (value! as Map).cast<String, Object?>() : null,
                requiredMode: _originalLLMMode,
                onChange: (v) => setState(() => _value = v),
              )
            else if (_type != 'number')
              PlainTextarea(
                value: text,
                placeholder: tw('env.modal.valuePlaceholder'),
                onChanged: (v) => setState(() => _value = v),
              )
            else
              DifyInput(
                value: text,
                placeholder: tw('env.modal.valuePlaceholder'),
                keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                onChanged: (v) => setState(() => _value = v),
              ),
            const SizedBox(height: 16),
            ModalSectionTitle(tw('env.modal.description')),
            PlainTextarea(
              value: _description,
              placeholder: tw('env.modal.descriptionPlaceholder'),
              onChanged: (v) => setState(() => _description = v),
            ),
          ],
        ),
      ),
    );
  }
}

/// A type option of the modal (`flex min-w-0 items-center justify-center rounded-lg border p-2 system-sm-regular
/// text-text-secondary` on the option card colours, hover highlighted; selected `border-[1.5px]` in the selected
/// colours, `font-medium text-text-primary shadow-xs`). [tip] adds the Secret infotip at its right (`pr-5`).
class _TypeCard extends StatelessWidget {
  const _TypeCard({
    required this.label,
    required this.selected,
    required this.disabled,
    required this.onPressed,
    this.tip,
  });
  final String label;
  final bool selected, disabled;
  final VoidCallback onPressed;
  final String? tip;

  @override
  Widget build(BuildContext context) {
    final card = Semantics(
      toggled: selected,
      child: DifyPressable(
        semanticLabel: label,
        disabled: disabled,
        onPressed: onPressed,
        builder: (context, hovered, focused) {
          final hover = hovered && !disabled;
          return Container(
            height: 32,
            padding: EdgeInsets.fromLTRB(8, 0, tip == null ? 8 : 20, 0),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected
                  ? DifyColors.componentsOptionCardOptionSelectedBg
                  : hover
                  ? DifyColors.componentsOptionCardOptionBgHover
                  : DifyColors.componentsOptionCardOptionBg,
              border: Border.all(
                color: selected
                    ? DifyColors.componentsOptionCardOptionSelectedBorder
                    : hover
                    ? DifyColors.componentsOptionCardOptionBorderHover
                    : DifyColors.componentsOptionCardOptionBorder,
                width: selected ? 1.5 : 1,
              ),
              borderRadius: BorderRadius.circular(DifyRadius.lg),
              boxShadow: selected || hover ? DifyShadows.xs : null,
            ),
            child: DifyText(
              label,
              selected ? DifyType.systemSmMedium : DifyType.systemSmRegular,
              color: selected ? DifyColors.textPrimary : DifyColors.textSecondary,
            ),
          );
        },
      ),
    );
    if (tip == null) return card;
    return Stack(
      alignment: Alignment.centerRight,
      children: [
        card,
        Positioned(
          right: 4,
          child: DifyInfotip(label: tip!, width: 240, content: DifyTextLine(tip!)),
        ),
      ],
    );
  }
}

/// LLMEnvironmentVariableValueField: the model of an `llm` environment variable, chosen with the model parameter
/// modal over the workspace's active text generation models (only those of [requiredMode] when set: an existing
/// variable keeps its mode), with the model's parameters.
class LLMEnvironmentVariableValueField extends StatelessWidget {
  const LLMEnvironmentVariableValueField({
    super.key,
    required this.value,
    required this.onChange,
    this.requiredMode,
    this.disabled = false,
  });

  final Map<String, Object?>? value;
  final ValueChanged<Map<String, Object?>> onChange;
  final String? requiredMode;
  final bool disabled;

  @override
  Widget build(BuildContext context) {
    final services = LlmGroupScope.of(context);
    final active = services.models.activeTextGenerationModelList;
    final selectable = requiredMode == null
        ? active
        : [
            for (final p in active)
              if (p.models.any((m) => m.modelProperties['mode'] == requiredMode))
                ProviderWithModels(
                  provider: p.provider,
                  label: p.label,
                  iconSmall: p.iconSmall,
                  iconSmallDark: p.iconSmallDark,
                  status: p.status,
                  models: [
                    for (final m in p.models)
                      if (m.modelProperties['mode'] == requiredMode) m,
                  ],
                ),
          ];
    final v = value;
    final params = v?['completion_params'];
    return ModelParameterModal(
      provider: '${v?['provider'] ?? ''}',
      modelId: '${v?['name'] ?? ''}',
      completionParams: params is Map ? params.cast<String, Object?>() : const {},
      modelList: selectable,
      popupWidth: 328,
      isAdvancedMode: true,
      readonly: disabled,
      modelSelectorReadonly: disabled,
      onModelChange: (m) {
        final target = active
            .where((p) => p.provider == m.provider)
            .firstOrNull
            ?.models
            .where((model) => model.model == m.modelId)
            .firstOrNull;
        final mode = target?.modelProperties['mode'];
        if (mode is! String) return;
        if (requiredMode != null && mode != requiredMode) {
          return toastError(context, tc('modelProvider.selector.incompatibleTip'));
        }
        final keep = v?['provider'] == m.provider && v?['name'] == m.modelId;
        onChange({
          'completion_params': keep && params is Map ? params.cast<String, Object?>() : <String, Object?>{},
          'mode': mode,
          'name': m.modelId,
          'provider': m.provider,
        });
      },
      onCompletionParamsChange: (p) {
        if (v == null) return;
        onChange({...v, 'completion_params': p});
      },
    );
  }
}
