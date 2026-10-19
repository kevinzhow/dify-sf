/// The Start node's input field dialog (app/configuration/config-var/config-modal: index.tsx, form-fields.tsx,
/// type-select.tsx, utils.ts, config.ts, field.tsx; config-select, config-string; nodes/_base/components
/// file-upload-setting.tsx, file-type-item.tsx and base/tag-input).
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../design/dify_icon.dart';
import '../../../../design/dify_tokens.g.dart';
import '../../../../design/widgets/widgets.dart';
import '../../../../i18n/dify_i18n.dart';
import '../../../../workflow/dify_json.dart';
import '../../../code_editor/code_editor.dart';
import '../../../panel_fields/panel_fields.dart';

/// Dify's `t(key, { ns, ...params })`.
typedef StartTranslate = String Function(String ns, String key, [Map<String, Object?> params]);

String _ad(StartTranslate t, String key, [Map<String, Object?> params = const {}]) => t('app-debug', key, params);

// ---- MoreInfo ----------------------------------------------------------------------------------------------------

/// Dify's `MoreInfo`: a variable renamed (`changeVarName`) or removed (`remove`), with its key before and after.
@immutable
class VarChange {
  const VarChange(this.type, {this.beforeKey, this.afterKey});
  const VarChange.rename(String before, String after) : this('changeVarName', beforeKey: before, afterKey: after);
  const VarChange.remove(String before) : this('remove', beforeKey: before);

  final String type;
  final String? beforeKey, afterKey;

  bool get isRename => type == 'changeVarName';
  bool get isRemove => type == 'remove';

  @override
  bool operator ==(Object other) =>
      other is VarChange && other.type == type && other.beforeKey == beforeKey && other.afterKey == afterKey;
  @override
  int get hashCode => Object.hash(type, beforeKey, afterKey);
  @override
  String toString() => 'VarChange($type, $beforeKey -> $afterKey)';
}

// ---- config-modal/utils.ts ---------------------------------------------------------------------------------------

/// `TEXT_MAX_LENGTH`.
const textMaxLength = 256;

/// `DEFAULT_FILE_UPLOAD_SETTING` (workflow/constants.ts).
const defaultFileUploadSetting = <String, Object?>{
  'allowed_file_upload_methods': ['local_file', 'remote_url'],
  'max_length': 5,
  'allowed_file_types': ['image'],
  'allowed_file_extensions': <Object?>[],
};

/// `getNewVarInWorkflow('')` (utils/var.ts, VAR_ITEM_TEMPLATE_IN_WORKFLOW).
Map<String, Object?> newVarInWorkflow([String key = '']) => {
  'variable': key,
  'label': key,
  'type': 'text-input',
  'required': true,
  'options': <Object?>[],
};

/// `jsonConfigPlaceHolder` (config-modal/config.ts).
final jsonConfigPlaceHolder = const JsonEncoder.withIndent('  ').convert({
  'type': 'object',
  'properties': {
    'foo': {'type': 'string'},
    'bar': {
      'type': 'object',
      'properties': {
        'sub': {'type': 'number'},
      },
      'required': <Object?>[],
      'additionalProperties': true,
    },
  },
  'required': <Object?>[],
  'additionalProperties': true,
});

bool isStringInputType(Object? type) => type == 'text-input' || type == 'paragraph';
bool _isFileType(Object? type) => type == 'file' || type == 'file-list';

/// `getCheckboxDefaultSelectValue`.
String checkboxDefaultSelectValue(Object? value) => switch (value) {
  final bool b => b ? 'true' : 'false',
  final String s => s.toLowerCase() == 'true' ? 'true' : 'false',
  _ => 'false',
};

/// `normalizeSelectDefaultValue`.
Map<String, Object?> normalizeSelectDefaultValue(Map<String, Object?> v) =>
    v['type'] == 'select' && v['default'] == '' ? ({...v}..remove('default')) : v;

/// `getJsonSchemaEditorValue`.
String jsonSchemaEditorValue(Object? type, Object? schema) {
  if (type != 'json_object' || !jsTruthy(schema)) return '';
  return schema is String ? schema : const JsonEncoder.withIndent('  ').convert(schema);
}

/// `isJsonSchemaEmpty`.
bool isJsonSchemaEmpty(Object? v) => v == null || (v is String && v.trim().isEmpty);

/// `updatePayloadField`: also drops a select default that is no longer an option.
Map<String, Object?> updatePayloadField(Map<String, Object?> payload, String key, Object? value) {
  final next = {...payload, key: value};
  if (value == null) next.remove(key);
  if (key == 'options' && jsTruthy(payload['default'])) {
    final options = value is List ? value : const [];
    if (!options.contains(payload['default'])) next.remove('default');
  }
  return next;
}

/// `createPayloadForType`.
Map<String, Object?> createPayloadForType(Map<String, Object?> payload, String type) {
  final next = {...payload, 'type': type};
  if (type == 'select') next.remove('default');
  if (_isFileType(type)) {
    next['hide'] = false;
    for (final e in defaultFileUploadSetting.entries) {
      if (e.key != 'max_length') next[e.key] = e.value is List ? [...e.value! as List] : e.value;
    }
    if (type == 'file-list') next['max_length'] = defaultFileUploadSetting['max_length'];
  }
  return next;
}

/// `buildSelectOptions`: the field types offered.
List<({String value, String name})> buildSelectOptions({
  required bool isBasicApp,
  bool supportFile = false,
  StartTranslate t = DifyI18n.tr,
}) => [
  for (final v in ['text-input', 'paragraph', 'select', 'number', 'checkbox'])
    (value: v, name: _ad(t, 'variableConfig.$v')),
  if (supportFile) ...[
    (value: 'file', name: _ad(t, 'variableConfig.single-file')),
    (value: 'file-list', name: _ad(t, 'variableConfig.multi-files')),
  ],
  if (!isBasicApp) (value: 'json_object', name: _ad(t, 'variableConfig.json')),
];

/// What [validateConfigModalPayload] found: the payload to save with its [moreInfo], or the field in error.
typedef ConfigModalValidation = ({
  Map<String, Object?>? payloadToSave,
  VarChange? moreInfo,
  String? errorMessage,
  String? errorField,
});

/// `validateConfigModalPayload`.
ConfigModalValidation validateConfigModalPayload({
  required Map<String, Object?> tempPayload,
  Map<String, Object?>? payload,
  int? maxFileUploadLimit,
  StartTranslate t = DifyI18n.tr,
}) {
  ConfigModalValidation error(String field, String message) =>
      (payloadToSave: null, moreInfo: null, errorMessage: message, errorField: field);
  final type = tempPayload['type'];
  var normalized = tempPayload;
  if (_isFileType(type)) {
    normalized = {...tempPayload, 'hide': false};
    if (type == 'file-list') {
      final max = tempPayload['max_length'];
      normalized['max_length'] = max is num && max.isFinite
          ? math.min(math.max(max, 1), maxFileUploadLimit ?? double.infinity).toInt()
          : 1;
    }
  }
  final schemaEmpty = isJsonSchemaEmpty(tempPayload['json_schema']);
  final toSave = normalized['type'] == 'json_object' && schemaEmpty
      ? ({...normalized}..remove('json_schema'))
      : normalized;
  final variable = jsStr(normalized['variable']) ?? '';
  final moreInfo = variable == payload?['variable']
      ? null
      : VarChange.rename(jsStr(payload?['variable']) ?? '', variable);

  final bad = checkKeys([variable]);
  if (bad != null) {
    return error('variable', _ad(t, 'varKeyError.${bad.error}', {'key': _ad(t, 'variableConfig.varName')}));
  }
  if (!jsTruthy(normalized['label'])) return error('label', _ad(t, 'variableConfig.errorMsg.labelNameRequired'));
  if (normalized['type'] == 'select') {
    final options = jsList(normalized['options']);
    if (options.isEmpty) return error('options', _ad(t, 'variableConfig.errorMsg.atLeastOneOption'));
    if (options.toSet().length != options.length) {
      return error('options', _ad(t, 'variableConfig.errorMsg.optionRepeat'));
    }
  }
  if (_isFileType(normalized['type'])) {
    final types = jsList(normalized['allowed_file_types']);
    if (types.isEmpty) {
      return error(
        'allowed_file_types',
        t('workflow', 'errorMsg.fieldRequired', {'field': _ad(t, 'variableConfig.file.supportFileTypes')}),
      );
    }
    if (types.contains('custom') && jsList(normalized['allowed_file_extensions']).isEmpty) {
      return error(
        'allowed_file_extensions',
        t('workflow', 'errorMsg.fieldRequired', {'field': _ad(t, 'variableConfig.file.custom.name')}),
      );
    }
  }
  final schema = tempPayload['json_schema'];
  if (normalized['type'] == 'json_object' && !schemaEmpty && schema is String) {
    try {
      if (jsGet(jsonDecode(schema), 'type') != 'object') {
        return error('json_schema', _ad(t, 'variableConfig.errorMsg.jsonSchemaMustBeObject'));
      }
    } on FormatException {
      return error('json_schema', _ad(t, 'variableConfig.errorMsg.jsonSchemaInvalid'));
    }
  }
  return (payloadToSave: toSave, moreInfo: moreInfo, errorMessage: null, errorField: null);
}

// ---- the dialog --------------------------------------------------------------------------------------------------

/// Confirms an input field; true closes the dialog (Dify keeps it open when the panel refuses, e.g. a duplicate).
typedef ConfigVarConfirm = bool Function(Map<String, Object?> payload, VarChange? moreInfo);

/// Opens ConfigModal over the screen: "Add Input Field" ([isCreate]) or "Edit Input Field" for [payload].
void showConfigVarModal(
  BuildContext context, {
  bool isCreate = false,
  Map<String, Object?>? payload,
  required ConfigVarConfirm onConfirm,
  bool supportFile = false,
  bool showHiddenField = true,
  bool isBasicApp = false,
  int? maxFileUploadLimit,
  ValueChanged<String>? toastError,
  ValueChanged<String>? onOpenUrl,
}) {
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => ConfigVarModal(
      isCreate: isCreate,
      payload: payload,
      supportFile: supportFile,
      showHiddenField: showHiddenField,
      isBasicApp: isBasicApp,
      maxFileUploadLimit: maxFileUploadLimit,
      toastError: toastError,
      onOpenUrl: onOpenUrl,
      onClose: () => entry.remove(),
      onConfirm: (p, m) {
        final ok = onConfirm(p, m);
        if (ok) entry.remove();
        return ok;
      },
    ),
  );
  Overlay.of(context, rootOverlay: true).insert(entry);
}

/// ConfigModal: dify-ui's Dialog (`w-120 rounded-2xl`, backdrop) with the title, the form fields and Cancel / Save.
class ConfigVarModal extends StatefulWidget {
  const ConfigVarModal({
    super.key,
    this.isCreate = false,
    this.payload,
    required this.onClose,
    required this.onConfirm,
    this.supportFile = false,
    this.showHiddenField = true,
    this.isBasicApp = false,
    this.maxFileUploadLimit,
    this.toastError,
    this.onOpenUrl,
  });

  final bool isCreate;
  final Map<String, Object?>? payload;
  final VoidCallback onClose;
  final ConfigVarConfirm onConfirm;
  final bool supportFile, showHiddenField, isBasicApp;
  final int? maxFileUploadLimit;
  final ValueChanged<String>? toastError;
  final ValueChanged<String>? onOpenUrl;

  @override
  State<ConfigVarModal> createState() => _ConfigVarModalState();
}

class _ConfigVarModalState extends State<ConfigVarModal> {
  late Map<String, Object?> _temp = normalizeSelectDefaultValue(widget.payload ?? newVarInWorkflow());
  ({String field, String message})? _error;
  final _focus = FocusNode(debugLabel: 'config var modal');
  final _nameFocus = FocusNode(debugLabel: 'config var name');

  @override
  void initState() {
    super.initState();
    _nameFocus.addListener(_onNameBlur);
  }

  @override
  void dispose() {
    _focus.dispose();
    _nameFocus.dispose();
    super.dispose();
  }

  void _toast(String m) => widget.toastError?.call(m);

  void _set(String key, Object? value) => setState(() {
    _temp = updatePayloadField(_temp, key, value);
    if (_error?.field == key) _error = null;
  });

  void _onNameChanged(String value) {
    final bad = checkKeys([value], canBeEmpty: true);
    if (bad != null) {
      _toast(DifyI18n.tr('app-debug', 'varKeyError.${bad.error}', {'key': bad.key}));
      setState(() {}); // the field shows the last valid name again
      return;
    }
    _set('variable', value);
  }

  /// handleVarKeyBlur: an empty label takes the name.
  void _onNameBlur() {
    if (_nameFocus.hasFocus) return;
    final name = jsStr(_temp['variable']) ?? '';
    final bad = checkKeys([name], canBeEmpty: true);
    if (bad != null) {
      _toast(
        DifyI18n.tr('app-debug', 'varKeyError.${bad.error}', {
          'key': DifyI18n.tr('app-debug', 'variableConfig.varName'),
        }),
      );
      return;
    }
    if (jsTruthy(_temp['label'])) return;
    setState(() {
      if (_error?.field == 'label') _error = null;
      _temp = {..._temp, 'label': name};
    });
  }

  void _onJsonSchema(String value) {
    if (value.trim().isEmpty) return _set('json_schema', null);
    try {
      _set('json_schema', const JsonEncoder.withIndent('  ').convert(jsonDecode(value)));
    } on FormatException {
      _set('json_schema', value);
    }
  }

  void _confirm() {
    final r = validateConfigModalPayload(
      tempPayload: _temp,
      payload: widget.payload,
      maxFileUploadLimit: widget.maxFileUploadLimit,
    );
    if (r.errorMessage != null && r.errorField != null) {
      setState(() => _error = (field: r.errorField!, message: r.errorMessage!));
      _toast(r.errorMessage!);
      return;
    }
    if (r.payloadToSave != null) {
      setState(() => _error = null);
      widget.onConfirm(r.payloadToSave!, r.moreInfo);
    }
  }

  String? _errorOf(String field) => _error?.field == field ? _error!.message : null;

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.sizeOf(context).height - 32;
    return Material(
      type: MaterialType.transparency,
      child: CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.escape): widget.onClose},
        child: Focus(
          focusNode: _focus,
          autofocus: true,
          child: Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  onTap: widget.onClose,
                  child: ColoredBox(color: DifyColors.backgroundOverlay),
                ),
              ),
              Center(
                child: Semantics(
                  scopesRoute: true,
                  namesRoute: true,
                  explicitChildNodes: true,
                  label: _ad(DifyI18n.tr, 'variableConfig.${widget.isCreate ? 'addModalTitle' : 'editModalTitle'}'),
                  child: Container(
                    key: const Key('config-var-modal'),
                    width: 480,
                    constraints: BoxConstraints(maxHeight: maxHeight),
                    decoration: BoxDecoration(
                      color: DifyColors.componentsPanelBg,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: DifyColors.componentsPanelBorder, width: 0.5),
                      boxShadow: DifyShadows.xl,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
                          child: Text(
                            _ad(
                              DifyI18n.tr,
                              'variableConfig.${widget.isCreate ? 'addModalTitle' : 'editModalTitle'}',
                            ),
                            style: difyTextStyle(DifyType.title2xlSemiBold, DifyColors.textPrimary),
                          ),
                        ),
                        Flexible(
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
                            child: _fields(),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            spacing: 8,
                            children: [
                              Flexible(
                                child: DifyButton(
                                  onPressed: widget.onClose,
                                  child: Text(DifyI18n.tr('common', 'operation.cancel')),
                                ),
                              ),
                              Flexible(
                                child: DifyButton(
                                  variant: DifyButtonVariant.primary,
                                  onPressed: _confirm,
                                  child: Text(DifyI18n.tr('common', 'operation.save')),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _fields() {
    String ad(String key) => DifyI18n.tr('app-debug', key);
    final type = jsStr(_temp['type']) ?? 'text-input';
    final isFile = _isFileType(type);
    final placeholder = ad('variableConfig.inputPlaceholder');
    final options = [for (final o in jsList(_temp['options'])) jsKey(o)];
    final def = _temp['default'];
    final w = widget;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        ModalField(
          title: ad('variableConfig.fieldType'),
          child: InputTypeSelect(
            value: type,
            items: buildSelectOptions(isBasicApp: w.isBasicApp, supportFile: w.supportFile),
            onSelect: (v) => setState(() {
              _temp = createPayloadForType(_temp, v);
              _error = null;
            }),
          ),
        ),
        ModalField(
          title: ad('variableConfig.varName'),
          errorMessage: _errorOf('variable'),
          child: DifyInput(
            value: jsStr(_temp['variable']) ?? '',
            semanticLabel: ad('variableConfig.varName'),
            placeholder: placeholder,
            invalid: _errorOf('variable') != null,
            focusNode: _nameFocus,
            formatters: [varNameFormatter],
            onChanged: _onNameChanged,
          ),
        ),
        ModalField(
          title: ad('variableConfig.labelName'),
          errorMessage: _errorOf('label'),
          child: DifyInput(
            value: jsStr(_temp['label']) ?? '',
            semanticLabel: ad('variableConfig.labelName'),
            placeholder: placeholder,
            invalid: _errorOf('label') != null,
            onChanged: (v) => _set('label', v),
          ),
        ),
        if (isStringInputType(type))
          ModalField(
            title: ad('variableConfig.maxLength'),
            child: ConfigString(
              value: _temp['max_length'] is num ? (_temp['max_length']! as num).toInt() : null,
              maxLength: type == 'text-input' ? textMaxLength : null,
              onChange: (v) => _set('max_length', v),
            ),
          ),
        if (type == 'text-input' || type == 'number')
          ModalField(
            title: ad('variableConfig.defaultValue'),
            child: DifyInput(
              value: def is String || def is num ? '$def' : '',
              semanticLabel: ad('variableConfig.defaultValue'),
              placeholder: placeholder,
              keyboardType: type == 'number'
                  ? const TextInputType.numberWithOptions(decimal: true, signed: true)
                  : null,
              formatters: type == 'number' ? [FilteringTextInputFormatter.allow(RegExp(r'[0-9eE.+-]'))] : null,
              onChanged: (v) => _set('default', v.isEmpty ? null : v),
            ),
          ),
        if (type == 'paragraph')
          ModalField(
            title: ad('variableConfig.defaultValue'),
            child: DifyTextarea(
              value: def == null ? '' : '$def',
              semanticLabel: ad('variableConfig.defaultValue'),
              placeholder: placeholder,
              onChanged: (v) => _set('default', v.isEmpty ? null : v),
            ),
          ),
        if (type == 'checkbox')
          ModalField(
            title: ad('variableConfig.defaultValue'),
            child: ModalSelect<String>(
              value: checkboxDefaultSelectValue(def),
              placeholder: ad('variableConfig.selectDefaultValue'),
              options: [
                (value: 'true', label: ad('variableConfig.startChecked')),
                (value: 'false', label: ad('variableConfig.noDefaultSelected')),
              ],
              onChanged: (v) => _set('default', v == 'true'),
            ),
          ),
        if (type == 'select') ...[
          ModalField(
            title: ad('variableConfig.options'),
            errorMessage: _errorOf('options'),
            child: ConfigSelect(
              options: options,
              invalid: _errorOf('options') != null,
              onChange: (v) => _set('options', v),
            ),
          ),
          if (options.isNotEmpty)
            ModalField(
              title: ad('variableConfig.defaultValue'),
              child: ModalSelect<String>(
                value: def is String ? def : _emptySelect,
                placeholder: ad('variableConfig.selectDefaultValue'),
                options: [
                  (value: _emptySelect, label: ad('variableConfig.noDefaultValue')),
                  for (final o in options)
                    if (o.trim().isNotEmpty) (value: o, label: o),
                ],
                onChanged: (v) => _set('default', v == _emptySelect ? null : v),
              ),
            ),
        ],
        if (isFile) ...[
          FileUploadSetting(
            payload: _temp,
            isMultiple: type == 'file-list',
            maxFileUploadLimit: w.maxFileUploadLimit ?? 10,
            validationError: _error != null && _error!.field.startsWith('allowed_file_') ? _error : null,
            onChange: (next) => setState(() {
              final e = _error;
              if (e != null &&
                  e.field.startsWith('allowed_file_') &&
                  (!jsonEquals(next[e.field], _temp[e.field]) ||
                      !jsonEquals(next['allowed_file_types'], _temp['allowed_file_types']))) {
                _error = null;
              }
              _temp = next;
            }),
          ),
          ModalField(
            title: ad('variableConfig.defaultValue'),
            // FileUploaderInAttachmentWrapper uploads to Dify's file service, which the app has no access to.
            child: const _FileDefaultPlaceholder(),
          ),
        ],
        if (type == 'json_object')
          ModalField(
            title: ad('variableConfig.jsonSchema'),
            isOptional: true,
            errorMessage: _errorOf('json_schema'),
            child: Container(
              height: 80,
              padding: const EdgeInsets.all(4),
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: DifyColors.componentsInputBgNormal,
                borderRadius: BorderRadius.circular(10),
              ),
              child: SingleChildScrollView(
                child: DifyCodeEditor(
                  value: jsonSchemaEditorValue(type, _temp['json_schema']),
                  language: CodeLanguage.json,
                  noWrapper: true,
                  onChange: _onJsonSchema,
                  placeholderWidget: Text(jsonConfigPlaceHolder),
                ),
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: _CheckRow(
            label: ad('variableConfig.required'),
            checked: _temp['required'] == true,
            disabled: !isFile && _temp['hide'] == true,
            onChanged: (v) => _set('required', v),
          ),
        ),
        if (w.showHiddenField && !isFile)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: _CheckRow(
              label: ad('variableConfig.hidden'),
              checked: _temp['hide'] == true,
              disabled: _temp['required'] == true,
              onChanged: (v) => _set('hide', v),
              trailing: DifyInfotip(
                label: ad('variableConfig.hiddenDescription').replaceAll(RegExp(r'<[^>]+>'), ''),
                width: 300,
                content: _HiddenDescription(onOpenUrl: w.onOpenUrl),
              ),
            ),
          ),
      ],
    );
  }
}

const _emptySelect = '__empty__';

/// `variableConfig.hiddenDescription` with its `<docLink>` to the user-input docs.
class _HiddenDescription extends StatelessWidget {
  const _HiddenDescription({this.onOpenUrl});
  final ValueChanged<String>? onOpenUrl;

  @override
  Widget build(BuildContext context) {
    final text = DifyI18n.tr('app-debug', 'variableConfig.hiddenDescription');
    final m = RegExp(r'<docLink>(.*?)</docLink>').firstMatch(text);
    if (m == null) return Text(text);
    final language = switch (DifyI18n.current) {
      DifyI18n(:final language) => language,
      _ => DifyI18n.fallbackLanguage,
    };
    final docLanguage = const {'zh-Hans': 'zh', 'ja-JP': 'ja'}[language] ?? 'en';
    final url = 'https://docs.dify.ai/$docLanguage/self-host/use-dify/nodes/user-input#hide-and-pre-fill-input-fields';
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: text.substring(0, m.start)),
          WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: GestureDetector(
              onTap: () => onOpenUrl?.call(url),
              child: Text(m[1]!, style: TextStyle(color: DifyColors.textAccent)),
            ),
          ),
          TextSpan(text: text.substring(m.end)),
        ],
      ),
    );
  }
}

/// The file default value: Dify uploads files to its file service here; without one the field says so.
class _FileDefaultPlaceholder extends StatelessWidget {
  const _FileDefaultPlaceholder();

  @override
  Widget build(BuildContext context) => Container(
    height: 32,
    alignment: Alignment.centerLeft,
    padding: const EdgeInsets.symmetric(horizontal: 12),
    decoration: BoxDecoration(
      color: DifyColors.componentsInputBgDisabled,
      borderRadius: BorderRadius.circular(DifyRadius.lg),
    ),
    child: Row(
      spacing: 4,
      children: [
        RemixIcon('upload-cloud-2-line', size: 16, color: DifyColors.textQuaternary),
        Flexible(
          child: DifyText(
            DifyI18n.tr('common', 'fileUploader.uploadFromComputer'),
            DifyType.systemSmRegular,
            color: DifyColors.textQuaternary,
          ),
        ),
      ],
    ),
  );
}

// ---- small form parts --------------------------------------------------------------------------------------------

/// A `label` row: the checkbox and its `system-sm-semibold` text (a tap on either toggles), `h-6 space-x-2`.
class _CheckRow extends StatelessWidget {
  const _CheckRow({
    required this.label,
    required this.checked,
    required this.onChanged,
    this.disabled = false,
    this.trailing,
  });
  final String label;
  final bool checked, disabled;
  final ValueChanged<bool> onChanged;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 24,
    child: Row(
      spacing: 8,
      children: [
        DifyCheckbox(checked: checked, disabled: disabled, label: label, onChanged: onChanged),
        Flexible(
          child: GestureDetector(
            onTap: disabled ? null : () => onChanged(!checked),
            child: ExcludeSemantics(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: difyTextStyle(DifyType.systemSmSemibold, DifyColors.textSecondary),
              ),
            ),
          ),
        ),
        ?trailing,
      ],
    ),
  );
}

/// config-string: the max length, a number input clamped to 1..[maxLength] (none for paragraphs).
class ConfigString extends StatefulWidget {
  const ConfigString({super.key, required this.value, required this.maxLength, required this.onChange});
  final int? value;
  final int? maxLength;
  final ValueChanged<int?> onChange;

  @override
  State<ConfigString> createState() => _ConfigStringState();
}

class _ConfigStringState extends State<ConfigString> {
  @override
  void didUpdateWidget(ConfigString old) {
    super.didUpdateWidget(old);
    _clamp();
  }

  @override
  void initState() {
    super.initState();
    _clamp();
  }

  /// The useEffect: a value over the maximum becomes the maximum.
  void _clamp() {
    final v = widget.value, max = widget.maxLength;
    if (v != null && max != null && v > max) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onChange(max);
      });
    }
  }

  @override
  Widget build(BuildContext context) => DifyInput(
    value: widget.value == null || widget.value == 0 ? '' : '${widget.value}',
    semanticLabel: DifyI18n.tr('app-debug', 'variableConfig.maxLength'),
    keyboardType: TextInputType.number,
    formatters: [FilteringTextInputFormatter.digitsOnly],
    onChanged: (s) {
      var v = int.tryParse(s);
      if (v != null) {
        final max = widget.maxLength;
        if (max != null && v > max) {
          v = max;
        } else if (v < 1) {
          v = 1;
        }
      }
      widget.onChange(v);
    },
  );
}
