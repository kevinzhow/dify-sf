/// The Start node's input field dialog (app/configuration/config-var/config-modal: index.tsx, form-fields.tsx,
/// type-select.tsx, utils.ts, config.ts, field.tsx; config-select, config-string; nodes/_base/components
/// file-upload-setting.tsx, file-type-item.tsx and base/tag-input).
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../cards/card_kit.dart';
import '../../../../design/dify_icon.dart';
import '../../../../design/dify_tokens.g.dart';
import '../../../../design/widgets/widgets.dart';
import '../../../../i18n/dify_i18n.dart';
import '../../../../workflow/dify_json.dart';
import '../../../../workflow/output_vars.dart' show inputVarTypeToVarType;
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
                  child: const ColoredBox(color: DifyColors.backgroundOverlay),
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
              trailing: Infotip(
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
              child: Text(m[1]!, style: const TextStyle(color: DifyColors.textAccent)),
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
        const RemixIcon('upload-cloud-2-line', size: 16, color: DifyColors.textQuaternary),
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

/// dify-ui's Checkbox (16 px, `rounded-[4px]`): blue with a white check when [checked].
class DifyCheckbox extends StatelessWidget {
  const DifyCheckbox({super.key, required this.checked, this.onChanged, this.disabled = false, this.label});
  final bool checked, disabled;
  final ValueChanged<bool>? onChanged;
  final String? label;

  @override
  Widget build(BuildContext context) => Semantics(
    checked: checked,
    label: label,
    child: DifyPressable(
      disabled: disabled,
      onPressed: onChanged == null ? null : () => onChanged!(!checked),
      builder: (context, hovered, focused) {
        final Color bg, border;
        if (disabled) {
          bg = checked ? DifyColors.componentsCheckboxBgDisabledChecked : DifyColors.componentsCheckboxBgDisabled;
          border = checked ? const Color(0x00000000) : DifyColors.componentsCheckboxBorderDisabled;
        } else if (checked) {
          bg = hovered ? DifyColors.componentsCheckboxBgHover : DifyColors.componentsCheckboxBg;
          border = const Color(0x00000000);
        } else {
          bg = DifyColors.componentsCheckboxBgUnchecked;
          border = hovered ? DifyColors.componentsCheckboxBorderHover : DifyColors.componentsCheckboxBorder;
        }
        return Container(
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            color: bg,
            border: Border.all(color: border),
            borderRadius: BorderRadius.circular(4),
            boxShadow: focused ? const [BoxShadow(color: DifyColors.stateAccentSolid, spreadRadius: 2)] : null,
          ),
          child: checked
              ? RemixIcon(
                  'check-line',
                  size: 12,
                  color: disabled ? DifyColors.componentsCheckboxIconDisabled : DifyColors.componentsCheckboxIcon,
                )
              : null,
        );
      },
    ),
  );
}

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

/// dify-ui's Textarea (medium): `min-h-20 rounded-lg px-3 py-2 system-sm-regular` on the input colours.
class DifyTextarea extends StatefulWidget {
  const DifyTextarea({super.key, required this.value, this.onChanged, this.placeholder, this.semanticLabel});
  final String value;
  final ValueChanged<String>? onChanged;
  final String? placeholder, semanticLabel;

  @override
  State<DifyTextarea> createState() => _DifyTextareaState();
}

class _DifyTextareaState extends State<DifyTextarea> {
  late final _controller = TextEditingController(text: widget.value);
  final _focus = FocusNode(debugLabel: 'textarea');
  bool _hovered = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() {}));
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
    final focused = _focus.hasFocus;
    final style = difyTextStyle(DifyType.systemSmRegular, DifyColors.componentsInputTextFilled);
    return Semantics(
      label: widget.semanticLabel,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Container(
          constraints: const BoxConstraints(minHeight: 80),
          decoration: BoxDecoration(
            color: focused
                ? DifyColors.componentsInputBgActive
                : _hovered
                ? DifyColors.componentsInputBgHover
                : DifyColors.componentsInputBgNormal,
            borderRadius: BorderRadius.circular(DifyRadius.lg),
            border: Border.all(
              color: focused
                  ? DifyColors.componentsInputBorderActive
                  : _hovered
                  ? DifyColors.componentsInputBorderHover
                  : const Color(0x00000000),
            ),
            boxShadow: focused ? DifyShadows.xs : null,
          ),
          child: TextField(
            controller: _controller,
            focusNode: _focus,
            onChanged: widget.onChanged,
            minLines: 3,
            maxLines: null,
            style: style,
            cursorColor: const Color(0xFF155EEF),
            cursorWidth: 1,
            decoration: InputDecoration(
              isCollapsed: true,
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              hintText: widget.placeholder,
              hintStyle: style.copyWith(color: DifyColors.componentsInputTextPlaceholder),
            ),
          ),
        ),
      ),
    );
  }
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

// ---- file-upload-setting.tsx -------------------------------------------------------------------------------------

/// `FILE_EXTS` (prompt-editor/constants.tsx).
const fileExts = {
  'image': ['JPG', 'JPEG', 'PNG', 'GIF', 'WEBP', 'SVG'],
  'document': [
    'TXT', 'MD', 'MDX', 'MARKDOWN', 'PDF', 'HTML', 'XLSX', 'XLS', 'DOC', 'DOCX', 'CSV', 'EML', 'MSG', 'PPTX', //
    'PPT', 'XML', 'EPUB',
  ],
  'audio': ['MP3', 'M4A', 'WAV', 'AMR', 'MPGA'],
  'video': ['MP4', 'MOV', 'MPEG', 'WEBM'],
};

/// `formatFileSize` (utils/format.ts).
String formatFileSize(num size) {
  const units = ['', 'K', 'M', 'G', 'T', 'P'];
  var i = 0;
  var s = size.toDouble();
  while (s >= 1024 && i < units.length) {
    s /= 1024;
    i++;
  }
  return i == 0 ? '${s.toStringAsFixed(2)} bytes' : '${s.toStringAsFixed(2)} ${units[i]}B';
}

/// FileUploadSetting (not in the features panel): the supported file types, the upload method and, for lists, the
/// maximum number of uploads.
class FileUploadSetting extends StatelessWidget {
  const FileUploadSetting({
    super.key,
    required this.payload,
    required this.isMultiple,
    required this.onChange,
    this.maxFileUploadLimit = 10,
    this.validationError,
    this.sizeLimits = const (img: 10 << 20, doc: 15 << 20, audio: 50 << 20, video: 100 << 20),
  });

  final Map<String, Object?> payload;
  final bool isMultiple;
  final ValueChanged<Map<String, Object?>> onChange;
  final int maxFileUploadLimit;
  final ({String field, String message})? validationError;

  /// `useFileSizeLimit`'s limits in bytes (the file upload config's, else Dify's fallbacks).
  final ({int img, int doc, int audio, int video}) sizeLimits;

  List<String> _strings(String key) => [for (final v in jsList(payload[key])) jsKey(v)];

  /// handleSupportFileTypeChange: custom excludes the others.
  void _toggleType(String type) {
    var types = _strings('allowed_file_types');
    if (type == 'custom') {
      types = types.contains('custom') ? types.where((v) => v != type).toList() : ['custom'];
    } else {
      types = types.where((v) => v != 'custom').toList();
      types = types.contains(type) ? types.where((v) => v != type).toList() : [...types, type];
    }
    onChange({...payload, 'allowed_file_types': types});
  }

  @override
  Widget build(BuildContext context) {
    String ad(String key, [Map<String, Object?> p = const {}]) => DifyI18n.tr('app-debug', key, p);
    final types = _strings('allowed_file_types');
    final methods = _strings('allowed_file_upload_methods');
    final selectedMethod = methods.contains('local_file')
        ? (methods.contains('remote_url') ? 'all' : 'local_file')
        : (methods.contains('remote_url') ? 'remote_url' : null);
    final max = payload['max_length'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        ModalField(
          title: ad('variableConfig.file.supportFileTypes'),
          errorMessage: validationError?.message,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 4,
            children: [
              for (final t in const ['document', 'image', 'audio', 'video'])
                _FileTypeItem(type: t, selected: types.contains(t), onToggle: _toggleType),
              _FileTypeItem(
                type: 'custom',
                selected: types.contains('custom'),
                onToggle: _toggleType,
                customFileTypes: _strings('allowed_file_extensions'),
                onCustomFileTypesChange: (v) => onChange({...payload, 'allowed_file_extensions': v}),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        SizedBox(
          height: 32,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              ad('variableConfig.uploadFileTypes'),
              style: difyTextStyle(DifyType.systemSmSemibold, DifyColors.textSecondary),
            ),
          ),
        ),
        Row(
          spacing: 8,
          children: [
            for (final (value, label) in [
              ('local_file', ad('variableConfig.localUpload')),
              ('remote_url', 'URL'),
              ('all', ad('variableConfig.both')),
            ])
              Expanded(
                child: OptionCard(
                  title: label,
                  selected: selectedMethod == value,
                  onSelect: () => onChange({
                    ...payload,
                    'allowed_file_upload_methods': value == 'all' ? ['local_file', 'remote_url'] : [value],
                  }),
                ),
              ),
          ],
        ),
        if (isMultiple) ...[
          const SizedBox(height: 16),
          ModalField(
            title: ad('variableConfig.maxNumberOfUploads'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    ad('variableConfig.maxNumberTip', {
                      'imgLimit': formatFileSize(sizeLimits.img),
                      'docLimit': formatFileSize(sizeLimits.doc),
                      'audioLimit': formatFileSize(sizeLimits.audio),
                      'videoLimit': formatFileSize(sizeLimits.video),
                    }),
                    style: difyTextStyle(DifyType.bodyXsRegular, DifyColors.textTertiary),
                  ),
                ),
                _NumberWithSlider(
                  label: ad('variableConfig.maxNumberOfUploads'),
                  value: max is num ? max.toInt() : 1,
                  max: maxFileUploadLimit,
                  onChange: (v) => onChange({...payload, 'max_length': v.clamp(1, maxFileUploadLimit)}),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// InputNumberWithSlider: a 48 px number input beside a slider, 1..[max].
class _NumberWithSlider extends StatelessWidget {
  const _NumberWithSlider({required this.label, required this.value, required this.max, required this.onChange});
  final String label;
  final int value, max;
  final ValueChanged<int> onChange;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 32,
    child: Row(
      spacing: 8,
      children: [
        SizedBox(
          width: 48,
          child: DifyNumberField(
            value: value,
            min: 1,
            max: max,
            semanticLabel: label,
            onChanged: (v) => onChange((v ?? 1).toInt()),
          ),
        ),
        Expanded(
          child: DifySlider(value: value.clamp(1, max), min: 1, max: max, semanticLabel: label, onChanged: onChange),
        ),
      ],
    ),
  );
}

/// file-type-item.tsx: an option card with the file type's icon, name, extensions and checkbox; the custom type,
/// when selected, edits its extensions in a tag input.
class _FileTypeItem extends StatefulWidget {
  const _FileTypeItem({
    required this.type,
    required this.selected,
    required this.onToggle,
    this.customFileTypes = const [],
    this.onCustomFileTypesChange,
  });
  final String type;
  final bool selected;
  final ValueChanged<String> onToggle;
  final List<String> customFileTypes;
  final ValueChanged<List<String>>? onCustomFileTypesChange;

  @override
  State<_FileTypeItem> createState() => _FileTypeItemState();
}

class _FileTypeItemState extends State<_FileTypeItem> {
  bool _hovered = false;

  static const _icons = {
    'image': ('file-image-fill', Color(0xFF00B2EA)),
    'document': ('file-text-fill', Color(0xFF6F8BB5)),
    'audio': ('file-music-fill', Color(0xFFFF3093)),
    'video': ('file-video-fill', Color(0xFF844FDA)),
    'custom': ('file-3-fill', Color(0xFFBCC0D1)),
  };

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final name = DifyI18n.tr('app-debug', 'variableConfig.file.${w.type}.name');
    final (icon, color) = _icons[w.type]!;
    final customSelected = w.type == 'custom' && w.selected;
    final head = Row(
      children: [
        RemixIcon(icon, size: 20, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DifyText(name, DifyType.systemSmMedium, color: DifyColors.textPrimary),
              if (!customSelected)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: DifyText(
                    w.type == 'custom'
                        ? DifyI18n.tr('app-debug', 'variableConfig.file.custom.description')
                        : fileExts[w.type]!.join(', '),
                    DifyType.system2xsRegularUppercase,
                    color: DifyColors.textTertiary,
                    maxLines: null,
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        ExcludeFocus(
          child: DifyCheckbox(checked: w.selected, label: name, onChanged: (_) => w.onToggle(w.type)),
        ),
      ],
    );
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => w.onToggle(w.type),
        child: Container(
          padding: customSelected ? null : const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: w.selected
                ? DifyColors.componentsOptionCardOptionSelectedBg
                : _hovered
                ? DifyColors.componentsOptionCardOptionBgHover
                : DifyColors.componentsOptionCardOptionBg,
            borderRadius: BorderRadius.circular(DifyRadius.lg),
            border: Border.all(
              color: w.selected
                  ? DifyColors.componentsOptionCardOptionSelectedBorder
                  : _hovered
                  ? DifyColors.componentsOptionCardOptionBorderHover
                  : DifyColors.componentsOptionCardOptionBorder,
              width: w.selected ? 1.5 : 1,
            ),
          ),
          child: !customSelected
              ? head
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                      decoration: const BoxDecoration(
                        border: Border(bottom: BorderSide(color: DifyColors.dividerSubtle)),
                      ),
                      child: head,
                    ),
                    GestureDetector(
                      onTap: () {}, // e.stopPropagation()
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: TagInput(
                          items: w.customFileTypes,
                          label: DifyI18n.tr('app-debug', 'variableConfig.file.custom.name'),
                          placeholder: DifyI18n.tr('app-debug', 'variableConfig.file.custom.createPlaceholder'),
                          onChange: (v) => w.onCustomFileTypesChange?.call(v),
                        ),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

/// base/tag-input: the tags with remove buttons, then a dashed box adding a tag on Enter or blur (trimmed, unique,
/// at most 20 characters).
class TagInput extends StatefulWidget {
  const TagInput({super.key, required this.items, required this.onChange, this.placeholder, this.label});
  final List<String> items;
  final ValueChanged<List<String>> onChange;
  final String? placeholder, label;

  @override
  State<TagInput> createState() => _TagInputState();
}

class _TagInputState extends State<TagInput> {
  final _controller = TextEditingController();
  final _focus = FocusNode(debugLabel: 'tag input');

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _add();
      setState(() {});
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _add() {
    final v = _controller.text.trim();
    if (v.isEmpty || widget.items.contains(v) || v.length > 20) return;
    widget.onChange([...widget.items, v]);
    _controller.clear();
  }

  @override
  Widget build(BuildContext context) {
    final style = difyTextStyle(DifyType.systemXsRegular, DifyColors.textPrimary);
    return Wrap(
      children: [
        for (final (i, item) in widget.items.indexed)
          Container(
            margin: const EdgeInsets.only(top: 4, right: 4),
            padding: const EdgeInsets.fromLTRB(6, 4, 4, 4),
            decoration: BoxDecoration(
              color: DifyColors.componentsBadgeWhiteToDark,
              borderRadius: BorderRadius.circular(DifyRadius.md),
              border: Border.all(color: DifyColors.dividerDeep),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                DifyText(item, DifyType.systemXsRegular, color: DifyColors.textSecondary),
                DifyPressable(
                  semanticLabel: '${DifyI18n.tr('common', 'operation.remove')} $item',
                  onPressed: () => widget.onChange([...widget.items]..removeAt(i)),
                  builder: (context, hovered, focused) => const Padding(
                    padding: EdgeInsets.only(left: 2),
                    child: RemixIcon('close-line', size: 14, color: DifyColors.textTertiary),
                  ),
                ),
              ],
            ),
          ),
        Container(
          margin: const EdgeInsets.only(top: 4),
          padding: const EdgeInsets.symmetric(horizontal: 6),
          constraints: const BoxConstraints(maxWidth: 300),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(DifyRadius.md),
            border: Border.all(color: DifyColors.dividerDeep),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            spacing: 2,
            children: [
              if (!_focus.hasFocus) const RemixIcon('add-line', size: 14, color: DifyColors.textPlaceholder),
              IntrinsicWidth(
                child: Semantics(
                  label: widget.label,
                  child: TextField(
                    controller: _controller,
                    focusNode: _focus,
                    style: style,
                    onSubmitted: (_) {
                      _add();
                      _focus.requestFocus();
                    },
                    cursorColor: const Color(0xFF295EFF),
                    cursorWidth: 1,
                    decoration: InputDecoration(
                      isCollapsed: true,
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(vertical: 4),
                      hintText: widget.placeholder,
                      hintStyle: style.copyWith(color: DifyColors.textPlaceholder),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
