/// The variable inspect panel's value editors: value-content.tsx with value-content-sections.tsx,
/// display-content.tsx, large-data-alert.tsx and the JSON SchemaEditor (json-schema-config-modal/schema-editor.tsx
/// and code-editor.tsx with `hideTopMenu`).
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../cards/card_kit.dart';
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';
import '../code_editor/editor_view.dart';
import '../code_editor/language.dart';
import '../node_panel/bodies/llm/llm_json_schema.dart' show SchemaErrorMessage;
import '../panel_fields/controls.dart' show DifySegmentedControl;
import '../panel_fields/file_upload_setting.dart' show formatFileSize;
import '../panel_fields/form_controls.dart' show BoolValue;
import '../store/store.dart';
import 'inspect_vars.dart';
import 'value_content_helpers.dart';

String _tw(String key) => DifyI18n.tr('workflow', key);

/// LargeDataAlert: `flex h-8 items-center rounded-lg border-[0.5px] border-components-panel-border
/// bg-components-panel-bg-blur px-2 shadow-xs`, the info icon and the message, and "EXPORT" with a [downloadUrl].
class LargeDataAlert extends StatelessWidget {
  const LargeDataAlert({super.key, this.textHasNoExport = false, this.downloadUrl});
  final bool textHasNoExport;
  final String? downloadUrl;

  @override
  Widget build(BuildContext context) {
    final text = _tw(textHasNoExport ? 'debug.variableInspect.largeDataNoExport' : 'debug.variableInspect.largeData');
    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: DifyColors.componentsPanelBgBlur,
        borderRadius: BorderRadius.circular(DifyRadius.lg),
        border: Border.all(color: DifyColors.componentsPanelBorder, width: 0.5),
        boxShadow: DifyShadows.xs,
      ),
      child: Row(
        children: [
          const RemixIcon('information-2-fill', size: 16, color: DifyColors.textAccent),
          const SizedBox(width: 4),
          Expanded(
            child: Tooltip(
              message: text,
              waitDuration: const Duration(milliseconds: 600),
              child: DifyText(text, DifyType.systemXsRegular),
            ),
          ),
          if (downloadUrl != null && downloadUrl!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: DifyText(
                _tw('debug.variableInspect.export'),
                DifyType.systemXsMediumUppercase,
                color: DifyColors.textAccent,
              ),
            ),
        ],
      ),
    );
  }
}

/// dify-ui's Textarea as the inspect panel uses it, filling its box: the medium textarea (`rounded-lg px-3 py-2
/// system-sm-regular`, disabled on `components-input-bg-disabled`), or [bare] (DisplayContent's `border-none
/// bg-transparent p-0 text-text-secondary`). [inputFormatters] keep the value a controlled textarea would keep.
class InspectTextarea extends StatefulWidget {
  const InspectTextarea({
    super.key,
    required this.value,
    required this.label,
    this.onChanged,
    this.disabled = false,
    this.bare = false,
    this.topPadding,
    this.inputFormatters,
    this.onFocusChange,
  });

  final String value;
  final String label;
  final ValueChanged<String>? onChanged;
  final bool disabled, bare;
  final double? topPadding;
  final List<TextInputFormatter>? inputFormatters;
  final ValueChanged<bool>? onFocusChange;

  @override
  State<InspectTextarea> createState() => _InspectTextareaState();
}

class _InspectTextareaState extends State<InspectTextarea> {
  late final _text = TextEditingController(text: widget.value);
  final _focus = FocusNode(debugLabel: 'inspect-textarea');
  bool _hovered = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      setState(() {});
      widget.onFocusChange?.call(_focus.hasFocus);
    });
  }

  @override
  void didUpdateWidget(InspectTextarea old) {
    super.didUpdateWidget(old);
    if (_text.text != widget.value) _text.text = widget.value;
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final focused = _focus.hasFocus && !w.disabled, hovered = _hovered && !w.disabled && !w.bare;
    final color = w.disabled
        ? DifyColors.componentsInputTextFilledDisabled
        : w.bare
        ? DifyColors.textSecondary
        : DifyColors.componentsInputTextFilled;
    final style = difyTextStyle(DifyType.systemSmRegular, color);
    final Color? background = w.disabled
        ? DifyColors.componentsInputBgDisabled
        : w.bare
        ? null
        : focused
        ? DifyColors.componentsInputBgActive
        : hovered
        ? DifyColors.componentsInputBgHover
        : DifyColors.componentsInputBgNormal;
    return Semantics(
      label: w.label,
      textField: true,
      child: MouseRegion(
        cursor: w.disabled ? SystemMouseCursors.forbidden : MouseCursor.defer,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Container(
          constraints: const BoxConstraints(minHeight: 80),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(DifyRadius.lg),
            border: w.bare
                ? null
                : Border.all(
                    color: focused
                        ? DifyColors.componentsInputBorderActive
                        : hovered
                        ? DifyColors.componentsInputBorderHover
                        : const Color(0x00000000),
                  ),
            boxShadow: focused && !w.bare ? DifyShadows.xs : null,
          ),
          child: Material(
            type: MaterialType.transparency,
            child: TextField(
              controller: _text,
              focusNode: _focus,
              enabled: !w.disabled,
              onChanged: w.onChanged,
              inputFormatters: w.inputFormatters,
              expands: true,
              maxLines: null,
              textAlignVertical: TextAlignVertical.top,
              keyboardType: TextInputType.multiline,
              style: style,
              cursorColor: const Color(0xFF155EEF),
              cursorWidth: 1,
              decoration: InputDecoration(
                isCollapsed: true,
                border: InputBorder.none,
                contentPadding: w.bare
                    ? EdgeInsets.only(top: w.topPadding ?? 0)
                    : EdgeInsets.fromLTRB(12, w.topPadding ?? 8, 12, 8),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// SchemaEditor (`hideTopMenu`): the JSON code editor on the input background (`rounded-xl pt-2`), with the large
/// data alert over it when [isTruncated]. [transparent] is DisplayContent's `bg-transparent`.
class InspectJsonEditor extends StatefulWidget {
  const InspectJsonEditor({
    super.key,
    required this.schema,
    required this.onUpdate,
    this.readonly = false,
    this.isTruncated = false,
    this.transparent = false,
    this.onFocusChange,
  });

  final String schema;
  final ValueChanged<String> onUpdate;
  final bool readonly, isTruncated, transparent;
  final ValueChanged<bool>? onFocusChange;

  @override
  State<InspectJsonEditor> createState() => _InspectJsonEditorState();
}

class _InspectJsonEditorState extends State<InspectJsonEditor> {
  final _focus = FocusNode(debugLabel: 'inspect-json');

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => widget.onFocusChange?.call(_focus.hasFocus));
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Container(
    clipBehavior: Clip.antiAlias,
    padding: const EdgeInsets.only(top: 8),
    decoration: BoxDecoration(
      color: widget.transparent ? null : DifyColors.componentsInputBgNormal,
      borderRadius: BorderRadius.circular(DifyRadius.xl),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // `mx-1 -mt-1 mb-3`.
        if (widget.isTruncated)
          Transform.translate(
            offset: const Offset(0, -4),
            child: const Padding(
              padding: EdgeInsets.fromLTRB(4, 0, 4, 8),
              child: LargeDataAlert(),
            ),
          ),
        Expanded(
          child: CodeEditorView(
            value: widget.schema,
            language: CodeLanguage.json,
            readOnly: widget.readonly,
            onChanged: widget.onUpdate,
            focusNode: _focus,
          ),
        ),
      ],
    ),
  );
}

/// DisplayContent: a box with the preview type ("MARKDOWN", or the value type and schema type of chunks) and the
/// Code / Preview switch over the textarea or the JSON editor, or their preview.
class DisplayContent extends StatefulWidget {
  const DisplayContent({
    super.key,
    required this.previewType,
    required this.varType,
    this.schemaType,
    this.mdString,
    this.jsonString,
    required this.readonly,
    this.handleTextChange,
    this.handleEditorChange,
    this.topPadding = 0,
  });

  final PreviewType previewType;
  final String varType;
  final String? schemaType, mdString, jsonString;
  final bool readonly;
  final ValueChanged<String>? handleTextChange, handleEditorChange;

  /// The call site's `pt-9` (under the large data alert).
  final double topPadding;

  @override
  State<DisplayContent> createState() => _DisplayContentState();
}

class _DisplayContentState extends State<DisplayContent> {
  ViewMode _mode = ViewMode.code;
  bool _focused = false;

  void _focus(bool f) => setState(() => _focused = f);

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final markdown = w.previewType == PreviewType.markdown;
    final title = markdown
        ? 'MARKDOWN'
        : '${w.varType.toUpperCase()}${w.schemaType == null || w.schemaType!.isEmpty ? '' : '(${w.schemaType})'}';
    Widget segment(String icon, String label) => Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 3,
      children: [
        RemixIcon(icon, size: 16),
        Padding(
          padding: const EdgeInsets.fromLTRB(2, 2, 4, 2),
          child: Text(label),
        ),
      ],
    );
    final Widget body = switch ((_mode, markdown)) {
      (ViewMode.code, true) => InspectTextarea(
        value: w.mdString ?? '',
        label: _tw('debug.variableInspect.markdownContent'),
        disabled: w.readonly,
        bare: true,
        onChanged: w.handleTextChange,
        onFocusChange: _focus,
      ),
      (ViewMode.code, false) => InspectJsonEditor(
        schema: w.jsonString ?? '',
        onUpdate: (v) => w.handleEditorChange?.call(v),
        readonly: w.readonly,
        transparent: true,
        onFocusChange: _focus,
      ),
      // dify-sf has no Markdown renderer or chunk cards yet: the preview shows the text as it is.
      (ViewMode.preview, _) => SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: SelectableText(
          markdown ? w.mdString ?? '' : _prettyJson(w.jsonString),
          style: difyTextStyle(DifyType.bodyMdRegular, DifyColors.textPrimary),
        ),
      ),
    };
    return Container(
      padding: EdgeInsets.only(top: w.topPadding),
      decoration: BoxDecoration(
        color: _focused ? DifyColors.componentsInputBgActive : DifyColors.componentsInputBgNormal,
        borderRadius: BorderRadius.circular(DifyRadius.container),
      ),
      foregroundDecoration: _focused
          ? BoxDecoration(
              border: Border.all(color: DifyColors.componentsInputBorderActive),
              borderRadius: BorderRadius.circular(DifyRadius.container),
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(4),
            child: Row(
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    child: DifyText(title, DifyType.systemXsSemiboldUppercase, color: DifyColors.textSecondary),
                  ),
                ),
                Semantics(
                  label: _tw('common.preview'),
                  child: DifySegmentedControl<ViewMode>(
                    value: _mode,
                    onChanged: (m) => setState(() => _mode = m),
                    height: 24,
                    padding: 1,
                    radius: DifyRadius.md,
                    itemRadius: DifyRadius.md,
                    itemPadding: const EdgeInsets.fromLTRB(6, 1, 2, 1),
                    textColor: DifyColors.textTertiary,
                    segments: [
                      (
                        value: ViewMode.code,
                        label: _tw('nodes.templateTransform.code'),
                        child: segment('braces-line', _tw('nodes.templateTransform.code')),
                      ),
                      (
                        value: ViewMode.preview,
                        label: _tw('common.preview'),
                        child: segment('eye-line', _tw('common.preview')),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ClipRRect(
              borderRadius: const BorderRadius.vertical(bottom: Radius.circular(DifyRadius.container)),
              child: Padding(padding: const EdgeInsets.only(left: 12, right: 4), child: body),
            ),
          ),
        ],
      ),
    );
  }
}

String _prettyJson(String? json) {
  try {
    return const JsonEncoder.withIndent('  ').convert(jsonDecode(json ?? ''));
  } on FormatException {
    return json ?? '';
  }
}

/// TextEditorSection: strings in a Markdown [DisplayContent], numbers and secrets in a textarea; the large data
/// alert above either when [isTruncated].
class TextEditorSection extends StatelessWidget {
  const TextEditorSection({
    super.key,
    required this.currentVar,
    required this.value,
    required this.textEditorDisabled,
    required this.isTruncated,
    required this.onTextChange,
  });

  final DifyJson currentVar;
  final Object? value;
  final bool textEditorDisabled, isTruncated;
  final ValueChanged<String> onTextChange;

  @override
  Widget build(BuildContext context) {
    final text = value is String ? value! as String : '${value ?? ''}';
    final editor = currentVar['value_type'] == 'string'
        ? DisplayContent(
            previewType: PreviewType.markdown,
            varType: 'string',
            mdString: text,
            readonly: textEditorDisabled,
            handleTextChange: onTextChange,
            topPadding: isTruncated ? 36 : 0,
          )
        : InspectTextarea(
            value: text,
            label: _tw('errorMsg.fields.variableValue'),
            disabled: textEditorDisabled || isTruncated,
            topPadding: isTruncated ? 48 : null,
            onChanged: onTextChange,
            // A number field keeps only what parses as one (handleTextChange sets nothing else).
            inputFormatters: currentVar['value_type'] == 'number' ? [_numberInput] : null,
          );
    if (!isTruncated) return editor;
    return Stack(
      fit: StackFit.expand,
      children: [
        editor,
        const Positioned(left: 12, right: 12, top: 4, child: LargeDataAlert()),
      ],
    );
  }
}

final _numberInput = TextInputFormatter.withFunction(
  (old, next) => RegExp(r'^-?\d+(\.)?(\d+)?$').hasMatch(next.text) ? next : old,
);

/// BoolArraySection: a [BoolValue] per item (`w-73.75 space-y-1`).
class BoolArraySection extends StatelessWidget {
  const BoolArraySection({super.key, required this.values, required this.onChange});
  final List<bool> values;
  final ValueChanged<List<bool>> onChange;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topLeft,
    child: SizedBox(
      width: 295,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        spacing: 4,
        children: [
          for (final (i, v) in values.indexed)
            BoolValue(value: v, onChange: (next) => onChange([...values]..[i] = next)),
        ],
      ),
    ),
  );
}

/// JsonEditorSection: chunks in a [DisplayContent], other JSON in the editor (read-only when truncated).
class JsonEditorSection extends StatelessWidget {
  const JsonEditorSection({
    super.key,
    required this.hasChunks,
    this.schemaType,
    required this.valueType,
    required this.json,
    required this.readonly,
    required this.isTruncated,
    required this.onChange,
  });

  final bool hasChunks;
  final String? schemaType;
  final String valueType, json;
  final bool readonly, isTruncated;
  final ValueChanged<String> onChange;

  @override
  Widget build(BuildContext context) => hasChunks
      ? DisplayContent(
          previewType: PreviewType.chunks,
          varType: valueType,
          schemaType: schemaType ?? '',
          jsonString: json,
          readonly: readonly,
          handleEditorChange: onChange,
        )
      : InspectJsonEditor(
          schema: json,
          onUpdate: onChange,
          readonly: readonly || isTruncated,
          isTruncated: isTruncated,
        );
}

/// FileEditorSection: FileUploaderInAttachmentWrapper (`max-w-115`): "Upload from computer" and "Paste file link"
/// (through [VariableInspectServices.uploadFile]; disabled at the limit), then the files.
class FileEditorSection extends StatelessWidget {
  const FileEditorSection({
    super.key,
    required this.currentVar,
    required this.fileValue,
    this.fileUploadConfig,
    required this.textEditorDisabled,
    required this.onChange,
  });

  final DifyJson currentVar;
  final List<DifyJson> fileValue;
  final DifyJson? fileUploadConfig;
  final bool textEditorDisabled;
  final ValueChanged<List<DifyJson>> onChange;

  int get _limit => currentVar['value_type'] == 'file'
      ? 1
      : switch (fileUploadConfig?['workflow_file_upload_limit']) {
          final num n when n > 0 => n.toInt(),
          _ => 5,
        };

  @override
  Widget build(BuildContext context) {
    final services = VariableInspectScope.maybeOf(context)?.crud.services ?? VariableInspectServices.none;
    final full = fileValue.length >= _limit;
    Widget option(String method, String icon, String label) => Expanded(
      child: DifyButton(
        variant: DifyButtonVariant.tertiary,
        disabled: full,
        onPressed: () async {
          final file = await services.uploadFile(method);
          if (file != null) onChange([...fileValue, file]);
        },
        leading: RemixIcon(icon, size: 16),
        child: Text(DifyI18n.tr('common', label), overflow: TextOverflow.ellipsis),
      ),
    );
    return Align(
      alignment: Alignment.topLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!textEditorDisabled)
              Row(
                spacing: 4,
                children: [
                  option('local_file', 'upload-cloud-2-line', 'fileUploader.uploadFromComputer'),
                  option('remote_url', 'link', 'fileUploader.pasteFileLink'),
                ],
              ),
            for (final f in fileValue)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: _FileItem(
                  file: f,
                  onRemove: textEditorDisabled ? null : () => onChange([...fileValue]..remove(f)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// FileInAttachmentItem: `flex h-12 items-center rounded-lg border-[0.5px] border-components-panel-border
/// bg-components-panel-on-panel-item-bg pr-3 shadow-xs`, the file type icon, the name over "ext • size", and remove.
class _FileItem extends StatelessWidget {
  const _FileItem({required this.file, this.onRemove});
  final DifyJson file;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final name = '${file['name'] ?? ''}';
    final dot = name.lastIndexOf('.');
    final ext = file['isRemote'] == true || dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
    final size = file['size'];
    final (icon, color) = _fileTypeIcon(ext);
    return Container(
      height: 48,
      padding: const EdgeInsets.only(right: 12),
      decoration: BoxDecoration(
        color: DifyColors.componentsPanelOnPanelItemBg,
        borderRadius: BorderRadius.circular(DifyRadius.lg),
        border: Border.all(color: DifyColors.componentsPanelBorder, width: 0.5),
        boxShadow: DifyShadows.xs,
      ),
      child: Row(
        children: [
          SizedBox.square(
            dimension: 48,
            child: Center(child: RemixIcon(icon, size: 24, color: color)),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: DifyText(name, DifyType.systemXsMedium, color: DifyColors.textSecondary),
                  ),
                  DifyText(
                    [if (ext.isNotEmpty) ext, if (size is num && size > 0) formatFileSize(size)].join(' • '),
                    DifyType.system2xsMediumUppercase,
                    color: DifyColors.textTertiary,
                  ),
                ],
              ),
            ),
          ),
          if (onRemove != null)
            DifyIconButton(
              label: '${DifyI18n.tr('common', 'operation.remove')} $name',
              icon: const RemixIcon('delete-bin-line', size: 16),
              onPressed: onRemove,
            ),
        ],
      ),
    );
  }
}

/// FileTypeIcon's icon and colour for an extension (getFileAppearanceType).
(String, Color) _fileTypeIcon(String ext) {
  const image = ['jpg', 'jpeg', 'png', 'webp', 'svg'], video = ['mp4', 'mov', 'mpeg', 'webm'];
  const audio = ['mp3', 'm4a', 'wav', 'amr', 'mpga'];
  return switch (ext) {
    'gif' => ('file-gif-fill', const Color(0xFF00B2EA)),
    _ when image.contains(ext) => ('file-image-fill', const Color(0xFF00B2EA)),
    _ when video.contains(ext) => ('file-video-fill', const Color(0xFF844FDA)),
    _ when audio.contains(ext) => ('file-music-fill', const Color(0xFFFF3093)),
    'html' => ('file-code-fill', const Color(0xFFBCC0D1)),
    'pdf' => ('file-pdf-2-fill', const Color(0xFFEA3434)),
    'md' || 'markdown' || 'mdx' => ('markdown-fill', const Color(0xFF309BEC)),
    'xlsx' || 'xls' => ('file-excel-fill', const Color(0xFF01AC49)),
    'docx' || 'doc' => ('file-word-fill', const Color(0xFF2684FF)),
    'pptx' || 'ppt' => ('file-ppt-2-fill', const Color(0xFFFF650F)),
    'txt' || 'csv' || 'eml' || 'msg' || 'xml' || 'epub' || 'htm' || 'properties' => (
      'file-text-fill',
      const Color(0xFF6F8BB5),
    ),
    _ => ('file-3-fill', const Color(0xFFBCC0D1)),
  };
}

/// ErrorMessages: the parse error and the validation error, each an ErrorMessage (`mt-1`).
class ErrorMessages extends StatelessWidget {
  const ErrorMessages({super.key, this.parseError, this.validationError = ''});
  final FormatException? parseError;
  final String validationError;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (parseError != null) SchemaErrorMessage(message: parseError!.message),
      if (validationError.isNotEmpty) SchemaErrorMessage(message: validationError),
    ],
  );
}

/// ValueContent: [currentVar]'s value in the editor [getValueEditorState] picks, edits reported to
/// [handleValueChange] 500 ms after the last change (nothing while [isTruncated]); JSON is reported once it parses
/// and passes [validateInspectJsonValue], whose errors show below the editor.
class ValueContent extends StatefulWidget {
  const ValueContent({
    super.key,
    required this.currentVar,
    required this.handleValueChange,
    required this.isTruncated,
  });

  final DifyJson currentVar;
  final void Function(String varId, Object? value) handleValueChange;
  final bool isTruncated;

  @override
  State<ValueContent> createState() => _ValueContentState();
}

class _ValueContentState extends State<ValueContent> {
  late ValueEditorState _state;
  Object? _value;
  String _json = '';
  FormatException? _parseError;
  String _validationError = '';
  late List<DifyJson> _fileValue;
  Timer? _debounce;

  DifyJson get _var => widget.currentVar;
  String get _id => '${_var['id']}';

  @override
  void initState() {
    super.initState();
    _state = getValueEditorState(_var);
    _fileValue = formatInspectFileValue(_var);
    _resetValue();
  }

  @override
  void didUpdateWidget(ValueContent old) {
    super.didUpdateWidget(old);
    _state = getValueEditorState(_var);
    if (old.currentVar['id'] != _var['id'] || old.currentVar['value'] != _var['value']) _resetValue();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  /// The value shown, from the variable (on a new variable or value).
  void _resetValue() {
    final value = _var['value'];
    if (_state.showTextEditor) {
      _value = _var['value_type'] == 'number' ? jsonEncode(value) : (_truthy(value) ? value : '');
    }
    if (_state.showBoolEditor || _state.showBoolArrayEditor) _value = value;
    if (_state.showJSONEditor) {
      // The value the editor already shows (an edit coming back) keeps the text as typed.
      final same = _parsesTo(_json, value);
      if (!same) _json = value == null ? '' : const JsonEncoder.withIndent('  ').convert(value);
    }
    if (_state.showFileEditor) _fileValue = formatInspectFileValue(_var);
  }

  static bool _truthy(Object? v) => v != null && v != '' && v != 0 && v != false;

  static bool _parsesTo(String json, Object? value) {
    if (json.isEmpty) return false;
    try {
      return jsonEncode(jsonDecode(json)) == jsonEncode(value);
    } on FormatException {
      return false;
    }
  }

  void _debounceValueChange(Object? value) {
    final id = _id;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), () => widget.handleValueChange(id, value));
  }

  /// A number's text only changes to text that parses (see [TextEditorSection]); its value is `parseFloat`'s.
  void _handleTextChange(String value) {
    if (widget.isTruncated) return;
    setState(() => _value = value);
    final number = _var['value_type'] == 'number';
    _debounceValueChange(
      number ? num.parse(value.endsWith('.') ? value.substring(0, value.length - 1) : value) : value,
    );
  }

  void _handleEditorChange(String value) {
    if (widget.isTruncated) return;
    final result = validateInspectJsonValue(value, '${_var['value_type']}');
    setState(() {
      _json = value;
      _parseError = result.parseError;
      _validationError = result.validationError;
    });
    if (result.success) _debounceValueChange(jsonDecode(value));
  }

  void _handleFileChange(List<DifyJson> files) {
    setState(() => _fileValue = files);
    final value = getProcessedFiles(files);
    // Every file must be uploaded before the value changes.
    if (!isFileValueUploaded(value)) return;
    if (_var['value_type'] == 'file') _debounceValueChange(value.firstOrNull);
    if (_var['value_type'] == 'array[file]' || _state.isSysFiles) _debounceValueChange(value);
  }

  void _setBool(Object value) {
    setState(() => _value = value);
    _debounceValueChange(value);
  }

  @override
  Widget build(BuildContext context) {
    final s = _state;
    final store = WorkflowStoreScope.of(context);
    final Widget? editor;
    if (s.showTextEditor) {
      editor = TextEditorSection(
        currentVar: _var,
        value: _value,
        textEditorDisabled: s.textEditorDisabled,
        isTruncated: widget.isTruncated,
        onTextChange: _handleTextChange,
      );
    } else if (s.showBoolEditor) {
      editor = Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 295,
          child: BoolValue(value: _value == true, onChange: _setBool),
        ),
      );
    } else if (s.showBoolArrayEditor && (_value as List).isNotEmpty) {
      editor = BoolArraySection(values: [...(_value! as List).cast<bool>()], onChange: _setBool);
    } else if (s.showJSONEditor) {
      editor = JsonEditorSection(
        hasChunks: s.hasChunks,
        schemaType: _var['schemaType'] as String?,
        valueType: '${_var['value_type']}',
        json: _json,
        readonly: s.jsonEditorDisabled,
        isTruncated: widget.isTruncated,
        onChange: _handleEditorChange,
      );
    } else if (s.showFileEditor) {
      editor = ValueListenableBuilder(
        valueListenable: store.fileUploadConfig,
        builder: (context, config, _) => FileEditorSection(
          currentVar: _var,
          fileValue: _fileValue,
          fileUploadConfig: config,
          textEditorDisabled: s.textEditorDisabled,
          onChange: _handleFileChange,
        ),
      );
    } else {
      // An empty array is also an empty boolean array: Dify draws that section too, with nothing in it.
      editor = null;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: editor ?? const SizedBox.shrink()),
        ErrorMessages(parseError: _parseError, validationError: _validationError),
      ],
    );
  }
}
