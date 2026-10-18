/// nodes/_base/components/before-run-form: the inputs of a run — FormItem (one input variable by type), Form (a
/// labelled group of them), BeforeRunForm (a single run's "Test Run (node)" overlay with Start Run) and its helpers —
/// plus base/chat's getProcessedInputs and checkInputsForm, which the run inputs panel uses.
library;

import 'dart:convert';

import 'package:flutter/widgets.dart';

import '../../../cards/card_kit.dart';
import '../../../design/dify_icon.dart';
import '../../../design/dify_tokens.g.dart';
import '../../../design/widgets/widgets.dart';
import '../../../i18n/dify_i18n.dart';
import '../../code_editor/code_editor.dart';
import '../../panel_fields/controls.dart' show DifyInput;
import '../../panel_fields/field.dart' show PanelSplit;
import '../../panel_fields/form_controls.dart' show DifyCheckbox, DifyTextarea;
import '../../panel_fields/selectors.dart' show DifySelect;
import '../../store/workflow_store.dart' show DifyJson;
import '../../store/workflow_store_scope.dart';

String _tw(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('workflow', key, params);

/// `InputVarType` (workflow/types.ts).
abstract final class InputVarType {
  static const textInput = 'text-input';
  static const paragraph = 'paragraph';
  static const select = 'select';
  static const number = 'number';
  static const url = 'url';
  static const files = 'files';
  static const json = 'json';
  static const jsonObject = 'json_object';
  static const contexts = 'contexts';
  static const iterator = 'iterator';
  static const singleFile = 'file';
  static const multiFiles = 'file-list';
  static const loop = 'loop';
  static const checkbox = 'checkbox';
}

/// `TransferMethod`.
abstract final class TransferMethod {
  static const localFile = 'local_file';
  static const remoteUrl = 'remote_url';
}

/// before-run-form/form.tsx Props: a group of inputs with their values.
class RunFormProps {
  const RunFormProps({this.label, required this.inputs, required this.values, required this.onChange});
  final String? label;

  /// InputVar JSON.
  final List<DifyJson> inputs;
  final Map<String, Object?> values;
  final ValueChanged<Map<String, Object?>> onChange;
}

String _labelText(Object? label) => label is Map ? '${label['variable'] ?? ''}' : '${label ?? ''}';

// ----- helpers.ts -----

/// getProcessedFiles: FileEntity JSON → the request's file objects (still-failed uploads dropped).
List<DifyJson> getProcessedFiles(List<Object?> files) => [
  for (final f in files.whereType<Map>())
    if (f['progress'] != -1)
      {
        'type': f['supportFileType'],
        'transfer_method': f['transferMethod'],
        'url': f['url'] ?? '',
        'upload_file_id': f['uploadedId'] ?? '',
      },
];

/// formatValue: an input's value as the run expects it (numbers parsed, JSON decoded, files processed). Throws on
/// invalid JSON, as Dify's JSON.parse does.
Object? formatValue(Object? value, String type) {
  if (type == InputVarType.checkbox) return value != null && value != false && value != '' && value != 0;
  if (value == null) return null;
  if (type == InputVarType.number) return num.tryParse('$value') ?? double.nan;
  if (type == InputVarType.json) return jsonDecode('$value');
  if (type == InputVarType.contexts) return [for (final i in value as List) jsonDecode('$i')];
  if (type == InputVarType.multiFiles) return getProcessedFiles(value as List);
  if (type == InputVarType.singleFile) {
    if (value is List) return getProcessedFiles(value);
    if (value == '' || value == false) return null; // `undefined`
    return getProcessedFiles([value]).firstOrNull;
  }
  return value;
}

/// isFilesLoaded: false while a `#files#` upload is still going on.
bool isFilesLoaded(List<RunFormProps> forms) {
  if (forms.isEmpty) return true;
  final form = forms.where((f) => f.values['#files#'] != null && f.values['#files#'] != '').firstOrNull;
  if (form == null) return true;
  final files = form.values['#files#'];
  return !(files is List &&
      files.any(
        (i) => i is Map && i['transfer_method'] == TransferMethod.localFile && (i['upload_file_id'] ?? '') == '',
      ));
}

/// getFormErrorMessage: the first required field without a value ("{{field}} is required"), or "wait for the file
/// upload"; empty when all is well. Values already held as inspect variables ([existVarValuesInForms]) count as set.
String getFormErrorMessage(
  List<RunFormProps> forms,
  List<Map<String, Object?>> existVarValuesInForms, [
  String Function(String ns, String key, Map<String, Object?> params)? t,
]) {
  final tr = t ?? DifyI18n.tr;
  var errMsg = '';
  for (final (index, form) in forms.indexed) {
    final exist = index < existVarValuesInForms.length ? existVarValuesInForms[index] : const <String, Object?>{};
    for (final input in form.inputs) {
      final variable = '${input['variable']}';
      final type = input['type'];
      final value = form.values[variable];
      final isFileType =
          type == InputVarType.files || type == InputVarType.multiFiles || type == InputVarType.singleFile;
      final missing =
          input['required'] == true &&
          type != InputVarType.checkbox &&
          !exist.containsKey(variable) &&
          (value == '' || value == null || (isFileType && value is List && value.isEmpty));
      if (errMsg.isEmpty && missing) {
        errMsg = tr('workflow', 'errorMsg.fieldRequired', {'field': _labelText(input['label'])});
        continue;
      }
      if (errMsg.isEmpty &&
          (type == InputVarType.singleFile || type == InputVarType.multiFiles) &&
          value != null &&
          value != '') {
        bool uploading(Object? i) =>
            i is Map && i['transferMethod'] == TransferMethod.localFile && (i['uploadedId'] ?? '') == '';
        if (value is List ? value.any(uploading) : uploading(value)) {
          errMsg = tr('app-debug', 'errorMessage.waitForFileUpload', const <String, Object?>{});
        }
      }
    }
  }
  return errMsg;
}

/// buildSubmitData: every form's values formatted; the last field whose JSON did not parse.
({Map<String, Object?> submitData, String parseErrorJsonField}) buildSubmitData(List<RunFormProps> forms) {
  final submitData = <String, Object?>{};
  var parseErrorJsonField = '';
  for (final form in forms) {
    for (final input in form.inputs) {
      final variable = '${input['variable']}';
      try {
        submitData[variable] = formatValue(form.values[variable], '${input['type']}');
      } on FormatException {
        parseErrorJsonField = variable;
      } on TypeError {
        parseErrorJsonField = variable;
      }
    }
  }
  return (submitData: submitData, parseErrorJsonField: parseErrorJsonField);
}

bool shouldAutoRunBeforeRunForm(List<RunFormProps> filteredExistVarForms, bool isHumanInput) =>
    filteredExistVarForms.isEmpty && !isHumanInput;

bool shouldAutoShowGeneratedForm(List<RunFormProps> filteredExistVarForms, bool isHumanInput) =>
    filteredExistVarForms.isEmpty && isHumanInput;

// ----- base/chat/chat/utils.ts, check-input-forms-hooks.ts -----

/// getProcessedInputs: checkboxes as booleans, files processed, JSON objects parsed when valid.
Map<String, Object?> getProcessedInputs(Map<String, Object?> inputs, List<DifyJson> inputsForm) {
  final processed = {...inputs};
  for (final item in inputsForm) {
    final variable = '${item['variable']}';
    final value = inputs[variable];
    final type = item['type'];
    if (type == InputVarType.checkbox) {
      processed[variable] = value != null && value != false && value != '' && value != 0;
      continue;
    }
    if (value == null) continue;
    if (type == InputVarType.singleFile) {
      processed[variable] = value is Map && value.containsKey('transfer_method')
          ? value
          : getProcessedFiles([value]).firstOrNull;
    } else if (type == InputVarType.multiFiles && value is List && value.isNotEmpty) {
      processed[variable] = value.first is Map && (value.first as Map).containsKey('transfer_method')
          ? value
          : getProcessedFiles(value);
    } else if (type == InputVarType.jsonObject) {
      try {
        final v = value is String ? jsonDecode(value) : value;
        processed[variable] = v is Map ? v : value;
      } on FormatException {
        processed[variable] = value;
      }
    }
  }
  return processed;
}

/// useCheckInputsForms' checkInputsForm: false after toasting the first empty required input; null (after an info
/// toast) while a file uploads; true otherwise.
bool? checkInputsForm(
  Map<String, Object?> inputs,
  List<DifyJson> inputsForm, {
  void Function(DifyToastType type, String message)? toast,
}) {
  final show = toast ?? difyToast;
  var hasEmptyInput = '';
  var fileIsUploading = false;
  for (final item in inputsForm) {
    if (item['required'] != true || item['type'] == InputVarType.checkbox) continue;
    if (hasEmptyInput.isNotEmpty || fileIsUploading) break;
    final value = inputs['${item['variable']}'];
    final empty = value == null || value == '' || value == false || value == 0;
    if (empty) hasEmptyInput = _labelText(item['label']);
    if ((item['type'] == InputVarType.singleFile || item['type'] == InputVarType.multiFiles) && !empty) {
      bool uploading(Object? i) =>
          i is Map && i['transferMethod'] == TransferMethod.localFile && (i['uploadedId'] ?? '') == '';
      fileIsUploading = value is List ? value.any(uploading) : uploading(value);
    }
  }
  if (hasEmptyInput.isNotEmpty) {
    show(DifyToastType.error, DifyI18n.tr('app-debug', 'errorMessage.valueOfVarRequired', {'key': hasEmptyInput}));
    return false;
  }
  if (fileIsUploading) {
    show(DifyToastType.info, DifyI18n.tr('app-debug', 'errorMessage.waitForFileUpload'));
    return null;
  }
  return true;
}

// ----- form-item.tsx, bool-input.tsx -----

/// Picks files for a file input (the app's uploader); null: the upload buttons are disabled (no uploads in dify-sf).
typedef RunFilePicker = Future<DifyJson?> Function(String transferMethod);

/// FormItem: the label (with "Optional" / "Optional & hidden") over the input of [payload]'s type.
class RunFormItem extends StatelessWidget {
  const RunFormItem({
    super.key,
    required this.payload,
    required this.value,
    required this.onChange,
    this.autoFocus = false,
    this.inStepRun = false,
    this.pickFile,
  });

  final DifyJson payload;
  final Object? value;
  final ValueChanged<Object?> onChange;
  final bool autoFocus;
  final bool inStepRun;
  final RunFilePicker? pickFile;

  String get _type => '${payload['type']}';
  String get _placeholder => _labelText(payload['label']);

  Widget _nodeKey() {
    final label = payload['label'] as Map;
    final isChatVar = label['isChatVar'] == true;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!isChatVar) ...[
          Padding(
            padding: const EdgeInsets.all(1),
            child: VarBlockIcon(type: '${label['nodeType'] ?? 'start'}'),
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 150),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: DifyText('${label['nodeName'] ?? ''}', DifyType.systemXsMedium, color: DifyColors.textSecondary),
            ),
          ),
          const Padding(
            padding: EdgeInsets.only(right: 2),
            child: DifyIcon('public/common/line-3', size: 12, color: DifyColors.dividerDeep),
          ),
        ],
        isChatVar
            ? const DifyIcon('vender/line/others/bubble-x', size: 14, color: DifyColors.utilColorsTealTeal700)
            : const DifyIcon('vender/solid/development/variable-02', size: 14, color: DifyColors.textAccent),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 150),
          child: Padding(
            padding: const EdgeInsets.only(left: 2),
            child: DifyText(
              '${label['variable'] ?? ''}',
              DifyType.systemXsMedium,
              color: isChatVar ? DifyColors.textSecondary : DifyColors.textAccent,
            ),
          ),
        ),
      ],
    );
  }

  List<Object?> get _list => value is List ? value! as List : const [];

  @override
  Widget build(BuildContext context) {
    final type = _type;
    final isBoolean = type == InputVarType.checkbox;
    final isArrayLike = type == InputVarType.contexts || type == InputVarType.iterator;
    final isIteratorItemFile = type == InputVarType.iterator && payload['isFileItem'] == true;
    final text = value == null ? '' : '$value';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!isArrayLike && !isBoolean)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: SizedBox(
              height: 24,
              child: Row(
                spacing: 4,
                children: [
                  Flexible(
                    child: payload['label'] is Map
                        ? _nodeKey()
                        : DifyText(_placeholder, DifyType.systemSmSemibold, color: DifyColors.textSecondary),
                  ),
                  if (payload['hide'] == true)
                    Flexible(
                      child: DifyText(
                        _tw('panel.optional_and_hidden'),
                        DifyType.systemXsRegular,
                        color: DifyColors.textTertiary,
                      ),
                    )
                  else if (payload['required'] != true)
                    Flexible(
                      child: DifyText(_tw('panel.optional'), DifyType.systemXsRegular, color: DifyColors.textTertiary),
                    ),
                ],
              ),
            ),
          ),
        if (type == InputVarType.textInput || type == InputVarType.url)
          _AutoFocus(
            enabled: autoFocus,
            builder: (focus) => DifyInput(
              value: text,
              focusNode: focus,
              placeholder: _placeholder,
              onChanged: onChange,
              semanticLabel: _placeholder,
            ),
          ),
        if (type == InputVarType.number)
          _AutoFocus(
            enabled: autoFocus,
            builder: (focus) => DifyInput(
              value: text,
              focusNode: focus,
              placeholder: _placeholder,
              keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
              onChanged: onChange,
              semanticLabel: _placeholder,
            ),
          ),
        if (type == InputVarType.paragraph)
          DifyTextarea(value: text, placeholder: _placeholder, semanticLabel: _placeholder, onChanged: onChange),
        if (type == InputVarType.select)
          DifySelect<String>(
            value: (value as String?)?.isNotEmpty == true ? value as String : payload['default'] as String?,
            placeholder: DifyI18n.tr('common', 'placeholder.select'),
            semanticLabel: _placeholder,
            options: [
              for (final o in (payload['options'] as List? ?? const [])) (value: '$o', label: '$o'),
            ],
            onChanged: onChange,
          ),
        if (isBoolean)
          RunBoolInput(
            name: _placeholder,
            value: value == true,
            required: payload['required'] == true,
            onChange: onChange,
          ),
        if (type == InputVarType.json)
          DifyCodeEditor(
            value: text,
            title: 'JSON',
            language: CodeLanguage.json,
            onChange: onChange,
          ),
        if (type == InputVarType.jsonObject)
          Container(
            height: 80,
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: DifyColors.componentsInputBgNormal,
              borderRadius: BorderRadius.circular(10),
            ),
            child: DifyCodeEditor(
              value: text,
              language: CodeLanguage.json,
              onChange: onChange,
              noWrapper: true,
              isExpand: true,
              placeholder: switch (payload['json_schema']) {
                final String s => s,
                null => null,
                final Object o => const JsonEncoder.withIndent('  ').convert(o),
              },
            ),
          ),
        if (type == InputVarType.files)
          RunImageUploader(
            files: _list.whereType<DifyJson>().toList(),
            pickFile: pickFile,
            onChange: onChange,
          ),
        if (type == InputVarType.singleFile || type == InputVarType.multiFiles || isIteratorItemFile)
          RunFileInput(
            files: [
              if (type == InputVarType.singleFile && payload['variable'] != '#files#')
                ?(value is Map ? value as DifyJson : null)
              else
                ..._list.whereType<DifyJson>(),
            ],
            limit: type == InputVarType.singleFile
                ? 1
                : (inStepRun || isIteratorItemFile ? 5 : (payload['max_length'] as num?)?.toInt() ?? 5),
            pickFile: pickFile,
            onChange: (files) {
              if (type == InputVarType.singleFile && payload['variable'] != '#files#') {
                onChange(files.firstOrNull);
              } else {
                onChange(files);
              }
            },
          ),
        if (type == InputVarType.contexts)
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 8,
            children: [
              for (final (i, item) in _list.indexed)
                DifyCodeEditor(
                  key: ValueKey('ctx-$i'),
                  value: item,
                  title: 'JSON',
                  language: CodeLanguage.json,
                  headerRight: _list.length > 1 ? _removeButton(i) : null,
                  onChange: (v) => onChange([..._list]..[i] = v),
                ),
            ],
          ),
        if (type == InputVarType.iterator && !isIteratorItemFile)
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 8,
            children: [
              for (final (i, item) in _list.indexed)
                _IteratorItem(
                  key: ValueKey('it-$i'),
                  title: '${DifyI18n.tr('app-debug', 'variableConfig.content')} ${i + 1} ',
                  value: '${item ?? ''}',
                  headerRight: _list.length > 1 ? _removeButton(i) : null,
                  onChange: (v) => onChange([..._list]..[i] = v),
                ),
            ],
          ),
      ],
    );
  }

  Widget _removeButton(int i) => Padding(
    padding: const EdgeInsets.only(right: 4),
    child: GestureDetector(
      onTap: () => onChange([..._list]..removeAt(i)),
      child: const MouseRegion(
        cursor: SystemMouseCursors.click,
        child: RemixIcon('delete-bin-line', size: 14, color: DifyColors.textTertiary),
      ),
    ),
  );
}

/// TextEditor `isInNode` for an iterator item: the titled box with a borderless textarea.
class _IteratorItem extends StatelessWidget {
  const _IteratorItem({super.key, required this.title, required this.value, required this.onChange, this.headerRight});
  final String title;
  final String value;
  final ValueChanged<String> onChange;
  final Widget? headerRight;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: DifyColors.componentsInputBgNormal,
      borderRadius: BorderRadius.circular(DifyRadius.lg),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 28,
          child: Padding(
            padding: const EdgeInsets.only(left: 12, right: 8, top: 4),
            child: Row(
              children: [
                Expanded(child: DifyText(title, DifyType.systemXsSemiboldUppercase, color: DifyColors.textSecondary)),
                ?headerRight,
              ],
            ),
          ),
        ),
        DifyTextarea(value: value, onChanged: onChange, minHeight: 56),
      ],
    ),
  );
}

/// Gives [builder] a focus node focused on mount when [enabled] (`autoFocus`).
class _AutoFocus extends StatefulWidget {
  const _AutoFocus({required this.enabled, required this.builder});
  final bool enabled;
  final Widget Function(FocusNode focus) builder;

  @override
  State<_AutoFocus> createState() => _AutoFocusState();
}

class _AutoFocusState extends State<_AutoFocus> {
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    if (widget.enabled) WidgetsBinding.instance.addPostFrameCallback((_) => mounted ? _focus.requestFocus() : null);
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(_focus);
}

/// BoolInput: a checkbox with the name and "(Optional)".
class RunBoolInput extends StatelessWidget {
  const RunBoolInput({
    super.key,
    required this.name,
    required this.value,
    required this.onChange,
    this.required = false,
    this.readonly = false,
  });
  final String name;
  final bool value;
  final bool required;
  final bool readonly;
  final ValueChanged<bool> onChange;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 24,
    child: GestureDetector(
      onTap: readonly ? null : () => onChange(!value),
      child: Row(
        spacing: 8,
        children: [
          DifyCheckbox(checked: value, disabled: readonly, label: name, onChanged: onChange),
          Flexible(child: DifyText(name, DifyType.systemSmMedium, color: DifyColors.textSecondary)),
          if (!required) DifyText(_tw('panel.optional'), DifyType.systemXsRegular, color: DifyColors.textTertiary),
        ],
      ),
    ),
  );
}

/// FileUploaderInAttachmentWrapper: "Upload from computer" and "Paste file link" (disabled at the limit or without a
/// [pickFile]), then the files with remove buttons.
class RunFileInput extends StatelessWidget {
  const RunFileInput({super.key, required this.files, required this.limit, required this.onChange, this.pickFile});
  final List<DifyJson> files;
  final int limit;
  final ValueChanged<List<DifyJson>> onChange;
  final RunFilePicker? pickFile;

  @override
  Widget build(BuildContext context) {
    final full = files.length >= limit;
    Widget option(String method, String icon, String label) => Expanded(
      child: DifyButton(
        variant: DifyButtonVariant.tertiary,
        disabled: full || pickFile == null,
        onPressed: () async {
          final file = await pickFile?.call(method);
          if (file != null) onChange([...files, file]);
        },
        leading: RemixIcon(icon, size: 16),
        child: Text(DifyI18n.tr('common', label), overflow: TextOverflow.ellipsis),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          spacing: 4,
          children: [
            option(TransferMethod.localFile, 'upload-cloud-2-line', 'fileUploader.uploadFromComputer'),
            option(TransferMethod.remoteUrl, 'link', 'fileUploader.pasteFileLink'),
          ],
        ),
        for (final f in files)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Container(
              height: 48,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: DifyColors.componentsPanelOnPanelItemBg,
                borderRadius: BorderRadius.circular(DifyRadius.lg),
                border: Border.all(color: DifyColors.componentsPanelBorder, width: 0.5),
                boxShadow: DifyShadows.xs,
              ),
              child: Row(
                children: [
                  const Padding(
                    padding: EdgeInsets.only(right: 12),
                    child: RemixIcon('file-3-fill', size: 24, color: Color(0xFFBCC0D1)),
                  ),
                  Expanded(
                    child: DifyText(
                      '${f['name'] ?? f['url'] ?? ''}',
                      DifyType.systemXsMedium,
                      color: DifyColors.textSecondary,
                    ),
                  ),
                  DifyIconButton(
                    label: DifyI18n.tr('common', 'operation.remove'),
                    icon: const RemixIcon('delete-bin-line', size: 16),
                    onPressed: () => onChange([...files]..remove(f)),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// TextGenerationImageUploader (the `files` input, the app's image upload feature): the images, then "Upload from
/// computer" (with [pickFile]) and "Paste image link" (a link input with OK, in a popover) per allowed transfer
/// method; the value is the run's file list (`{type: image, transfer_method, url, upload_file_id}`).
class RunImageUploader extends StatefulWidget {
  const RunImageUploader({super.key, required this.files, required this.onChange, this.pickFile});
  final List<DifyJson> files;
  final ValueChanged<List<DifyJson>> onChange;
  final RunFilePicker? pickFile;

  @override
  State<RunImageUploader> createState() => _RunImageUploaderState();
}

class _RunImageUploaderState extends State<RunImageUploader> {
  bool _open = false;
  String _link = '';

  @override
  Widget build(BuildContext context) {
    final features = context.getInheritedWidgetOfExactType<WorkflowStoreScope>()?.store.features.value ?? const {};
    final upload = features['file_upload'] as Map?;
    final image = upload?['image'] as Map?;
    final methods = [
      for (final m
          in ((image?['transfer_methods'] ?? upload?['allowed_file_upload_methods']) as List? ??
              const [TransferMethod.localFile, TransferMethod.remoteUrl]))
        '$m',
    ];
    final limit = ((image?['number_limits'] ?? upload?['number_limits']) as num?)?.toInt() ?? 3;
    final full = widget.files.length >= limit;
    Widget face(String icon, String label, {required bool disabled, VoidCallback? onTap}) => DifyPressable(
      semanticLabel: label,
      disabled: disabled,
      onPressed: onTap,
      builder: (context, hovered, focused) => Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: hovered && !disabled
              ? DifyColors.componentsButtonTertiaryBgHover
              : DifyColors.componentsButtonTertiaryBg,
          borderRadius: BorderRadius.circular(DifyRadius.lg),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: DifyIcon(icon, size: 16, color: DifyColors.textTertiary),
            ),
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: DifyColors.textTertiary),
              ),
            ),
          ],
        ),
      ),
    );
    final local = face(
      'vender/line/images/image-plus',
      DifyI18n.tr('common', 'imageUploader.uploadFromComputer'),
      disabled: full || widget.pickFile == null,
      onTap: () async {
        final f = await widget.pickFile?.call(TransferMethod.localFile);
        if (f != null) widget.onChange([...widget.files, f]);
      },
    );
    final url = DifyPopover(
      open: _open,
      onOpenChange: (o) {
        if (!full) setState(() => _open = o);
      },
      placement: DifyPlacement.topStart,
      sideOffset: 0,
      surface: false,
      builder: (context, c) => face(
        'vender/line/general/link-03',
        DifyI18n.tr('common', 'imageUploader.pasteImageLink'),
        disabled: full,
        onTap: c.toggle,
      ),
      content: Container(
        width: 320,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: DifyColors.componentsPanelBg,
          borderRadius: BorderRadius.circular(DifyRadius.lg),
          border: Border.all(color: DifyColors.componentsPanelBorder, width: 0.5),
          boxShadow: DifyShadows.lg,
        ),
        child: Row(
          spacing: 2,
          children: [
            Expanded(
              child: DifyInput(
                value: _link,
                height: 32,
                placeholder: DifyI18n.tr('common', 'imageUploader.pasteImageLinkInputPlaceholder'),
                onChanged: (v) => setState(() => _link = v),
              ),
            ),
            DifyButton(
              size: DifyButtonSize.small,
              variant: DifyButtonVariant.primary,
              disabled: _link.isEmpty,
              onPressed: () {
                final ok = RegExp(r'^(https?|ftp)://').hasMatch(_link);
                setState(() {
                  _open = false;
                  if (ok) {
                    widget.onChange([
                      ...widget.files,
                      {
                        'type': 'image',
                        'transfer_method': TransferMethod.remoteUrl,
                        'url': _link,
                        'upload_file_id': '',
                      },
                    ]);
                  }
                  _link = '';
                });
              },
              child: Text(DifyI18n.tr('common', 'operation.ok')),
            ),
          ],
        ),
      ),
    );
    final buttons = [
      for (final m in methods)
        if (m == TransferMethod.localFile) local else if (m == TransferMethod.remoteUrl) url,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.files.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                for (final f in widget.files)
                  Container(
                    height: 32,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    decoration: BoxDecoration(
                      color: DifyColors.componentsPanelOnPanelItemBg,
                      borderRadius: BorderRadius.circular(DifyRadius.lg),
                      border: Border.all(color: DifyColors.componentsPanelBorder, width: 0.5),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 160),
                          child: DifyText(
                            '${f['url'] ?? ''}',
                            DifyType.systemXsRegular,
                            color: DifyColors.textSecondary,
                          ),
                        ),
                        DifyIconButton(
                          label: DifyI18n.tr('common', 'operation.remove'),
                          size: DifyIconButtonSize.sm,
                          icon: const RemixIcon('close-line', size: 14),
                          onPressed: () => widget.onChange([...widget.files]..remove(f)),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        if (buttons.length == 2)
          Row(spacing: 4, children: [for (final b in buttons) Expanded(child: b)])
        else
          ...buttons,
      ],
    );
  }
}

// ----- form.tsx -----

/// Form: the group's label (with "+" for contexts and iterator lists) over its [RunFormItem]s; editing an input
/// updates every input of the same value selector.
class RunForm extends StatelessWidget {
  const RunForm({super.key, required this.props, this.pickFile});
  final RunFormProps props;
  final RunFilePicker? pickFile;

  ValueChanged<Object?> _handleChange(String key) {
    final selector = props.inputs.where((i) => i['variable'] == key).firstOrNull?['value_selector'];
    final keys = selector is List
        ? [
            for (final i in props.inputs)
              if (i['value_selector'] is List && (i['value_selector'] as List).join('.') == selector.join('.'))
                '${i['variable']}',
          ]
        : [key];
    return (value) => props.onChange({...props.values, for (final k in keys) k: value});
  }

  @override
  Widget build(BuildContext context) {
    final first = props.inputs.firstOrNull;
    final isArrayLike = first?['type'] == InputVarType.contexts || first?['type'] == InputVarType.iterator;
    final isIteratorItemFile = first?['type'] == InputVarType.iterator && first?['isFileItem'] == true;
    final isContext = first?['type'] == InputVarType.contexts;
    final label = props.label;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        if (label != null && label.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 24,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: DifyText(label, DifyType.systemXsMediumUppercase, color: DifyColors.textTertiary),
                    ),
                  ),
                ),
                if (isArrayLike && !isIteratorItemFile)
                  DifyIconButton(
                    label: '${DifyI18n.tr('common', 'operation.add')} $label',
                    icon: const RemixIcon('add-line', size: 16, color: DifyColors.textTertiary),
                    onPressed: () {
                      final key = '${first!['variable']}';
                      final list = [...(props.values[key] as List? ?? const [])];
                      list.add(isContext ? _retrievalOutputStruct : '');
                      props.onChange({...props.values, key: list});
                    },
                  ),
              ],
            ),
          ),
        for (final input in props.inputs)
          RunFormItem(
            inStepRun: true,
            payload: input,
            value: props.values['${input['variable']}'],
            onChange: _handleChange('${input['variable']}'),
            pickFile: pickFile,
          ),
      ],
    );
  }
}

/// `RETRIEVAL_OUTPUT_STRUCT` (workflow/constants.ts) as the context editor's new item.
const _retrievalOutputStruct = '''{
  "content": "",
  "title": "",
  "url": "",
  "icon": "",
  "metadata": {
    "dataset_id": "",
    "dataset_name": "",
    "document_id": [],
    "document_name": "",
    "document_data_source_type": "",
    "segment_id": "",
    "segment_position": "",
    "segment_word_count": "",
    "segment_hit_count": "",
    "segment_index_node_hash": "",
    "score": ""
  }
}''';

// ----- panel-wrap.tsx, index.tsx -----

/// PanelWrap: the overlay over the node panel (`absolute inset-0 rounded-2xl bg-background-overlay-alt`) with "Test
/// Run (node)" and a close button.
class RunPanelWrap extends StatelessWidget {
  const RunPanelWrap({super.key, required this.nodeName, required this.onHide, required this.child});
  final String nodeName;
  final VoidCallback onHide;
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: DifyColors.backgroundOverlayAlt,
      borderRadius: BorderRadius.circular(DifyRadius.xxl),
    ),
    child: Container(
      decoration: BoxDecoration(
        color: DifyColors.componentsPanelBg,
        borderRadius: BorderRadius.circular(DifyRadius.xxl),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 12, 0),
            child: SizedBox(
              height: 20,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${_tw('singleRun.testRun')} $nodeName',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 16,
                        height: 24 / 16,
                        fontWeight: FontWeight.w600,
                        color: DifyColors.textPrimary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  DifyPressable(
                    semanticLabel: DifyI18n.tr('common', 'operation.close'),
                    onPressed: onHide,
                    builder: (context, h, f) => const Padding(
                      padding: EdgeInsets.all(4),
                      child: RemixIcon('close-line', size: 16, color: DifyColors.textTertiary),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(child: child),
        ],
      ),
    ),
  );
}

/// BeforeRunForm: the forms still needing values and Start Run (the human input node's "generate form" step is not
/// ported); with nothing to fill it runs at once and shows nothing.
class BeforeRunForm extends StatefulWidget {
  const BeforeRunForm({
    super.key,
    required this.nodeName,
    this.nodeType,
    required this.onHide,
    required this.onRun,
    required this.forms,
    required this.existVarValuesInForms,
    required this.filteredExistVarForms,
    this.pickFile,
    this.toast,
    this.handleShowGeneratedForm,
  });

  final String nodeName;
  final String? nodeType;

  /// A human input node's "generate the form" step (its form view itself is not ported).
  final ValueChanged<Map<String, Object?>>? handleShowGeneratedForm;
  final VoidCallback onHide;
  final ValueChanged<Map<String, Object?>> onRun;
  final List<RunFormProps> forms;
  final List<Map<String, Object?>> existVarValuesInForms;
  final List<RunFormProps> filteredExistVarForms;
  final RunFilePicker? pickFile;
  final void Function(DifyToastType type, String message)? toast;

  @override
  State<BeforeRunForm> createState() => _BeforeRunFormState();
}

class _BeforeRunFormState extends State<BeforeRunForm> {
  bool get _isHumanInput => widget.nodeType == 'human-input';

  @override
  void initState() {
    super.initState();
    if (shouldAutoRunBeforeRunForm(widget.filteredExistVarForms, _isHumanInput)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onRun(const {});
      });
    }
    if (shouldAutoShowGeneratedForm(widget.filteredExistVarForms, _isHumanInput)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.handleShowGeneratedForm?.call(const {});
      });
    }
  }

  void _run() {
    final toast = widget.toast ?? difyToast;
    final err = getFormErrorMessage(widget.forms, widget.existVarValuesInForms);
    if (err.isNotEmpty) {
      toast(DifyToastType.error, err);
      return;
    }
    final r = buildSubmitData(widget.forms);
    if (r.parseErrorJsonField.isNotEmpty) {
      toast(DifyToastType.error, _tw('errorMsg.invalidJson', {'field': r.parseErrorJsonField}));
      return;
    }
    if (_isHumanInput) {
      widget.handleShowGeneratedForm?.call(r.submitData);
    } else {
      widget.onRun(r.submitData);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (shouldAutoRunBeforeRunForm(widget.filteredExistVarForms, _isHumanInput)) return const SizedBox.shrink();
    final forms = widget.filteredExistVarForms;
    return RunPanelWrap(
      nodeName: widget.nodeName,
      onHide: widget.onHide,
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 16,
                children: [
                  for (final (i, form) in forms.indexed)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: EdgeInsets.only(bottom: i < widget.forms.length - 1 ? 16 : 0),
                          child: RunForm(props: form, pickFile: widget.pickFile),
                        ),
                        if (i < widget.forms.length - 1) const PanelSplit(),
                      ],
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: SizedBox(
                width: double.infinity,
                child: DifyButton(
                  variant: DifyButtonVariant.primary,
                  disabled: !isFilesLoaded(widget.forms),
                  onPressed: _run,
                  child: Text(_isHumanInput ? _tw('nodes.humanInput.singleRun.button') : _tw('singleRun.startRun')),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
