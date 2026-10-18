/// variable-inspect/value-content.helpers.ts, utils.tsx and types.ts: which editor a variable gets, its files as the
/// file list shows them, and the JSON checks before an edited value is kept.
library;

import 'dart:convert';

import '../node_panel/bodies/llm/llm_config.dart'
    show checkJsonSchemaDepth, getValidationErrorMessage, jsonSchemaMaxDepth, validateSchemaAgainstDraft7;
import '../store/store.dart' show DifyJson;
import 'inspect_vars.dart' show VarInInspectType;

/// `CHUNK_SCHEMA_TYPES`.
const chunkSchemaTypes = ['general_structure', 'parent_child_structure', 'qa_structure'];

/// `ViewMode`.
enum ViewMode { code, preview }

/// `PreviewType`.
enum PreviewType { markdown, chunks }

/// `getValueEditorState`.
typedef ValueEditorState = ({
  bool showTextEditor,
  bool showBoolEditor,
  bool showBoolArrayEditor,
  bool isSysFiles,
  bool showJSONEditor,
  bool showFileEditor,
  bool textEditorDisabled,
  bool jsonEditorDisabled,
  bool hasChunks,
});

ValueEditorState getValueEditorState(DifyJson currentVar) {
  final valueType = '${currentVar['value_type']}', value = currentVar['value'];
  final type = currentVar['type'], name = currentVar['name'];
  final isSysFiles = type == VarInInspectType.system && name == 'files';
  final schemaType = currentVar['schemaType'];
  return (
    showTextEditor: const ['secret', 'string', 'number'].contains(valueType),
    showBoolEditor: value is bool,
    showBoolArrayEditor: value is List && value.every((v) => v is bool),
    isSysFiles: isSysFiles,
    showJSONEditor:
        !isSysFiles &&
        const ['object', 'array[string]', 'array[number]', 'array[object]', 'array[any]', 'llm'].contains(valueType),
    showFileEditor: isSysFiles || valueType == 'file' || valueType == 'array[file]',
    textEditorDisabled:
        type == VarInInspectType.environment || (type == VarInInspectType.system && name != 'query' && name != 'files'),
    jsonEditorDisabled: valueType == 'array[any]' || valueType == 'llm',
    hasChunks: schemaType is String && schemaType.isNotEmpty && chunkSchemaTypes.contains(schemaType),
  );
}

/// `getProcessedFilesFromResponse`: Dify's file responses as the file list's entries (FileEntity).
List<DifyJson> getProcessedFilesFromResponse(List<Object?> files) => [
  for (final f in files.whereType<Map>())
    {
      'id': f['related_id'],
      'name': f['filename'],
      'size': f['size'] ?? 0,
      'type': f['mime_type'],
      'progress': 100,
      'transferMethod': f['transfer_method'],
      'supportFileType': f['type'],
      'uploadedId': f['upload_file_id'] ?? f['related_id'],
      'url': f['url'] ?? f['remote_url'],
    },
];

/// `getProcessedFiles`: the file list's entries as the value saved (failed uploads left out).
List<DifyJson> getProcessedFiles(List<DifyJson> files) => [
  for (final f in files)
    if (f['progress'] != -1)
      {
        'type': f['supportFileType'],
        'transfer_method': f['transferMethod'],
        'url': f['url'] ?? '',
        'upload_file_id': f['uploadedId'] ?? '',
      },
];

/// `formatInspectFileValue`.
List<DifyJson> formatInspectFileValue(DifyJson currentVar) {
  final value = currentVar['value'];
  if (currentVar['value_type'] == 'file') return value == null ? const [] : getProcessedFilesFromResponse([value]);
  if (currentVar['value_type'] == 'array[file]' ||
      (currentVar['type'] == VarInInspectType.system && currentVar['name'] == 'files')) {
    return value is List && value.isNotEmpty ? getProcessedFilesFromResponse(value) : const [];
  }
  return const [];
}

/// `isFileValueUploaded`.
bool isFileValueUploaded(List<DifyJson> files) => files.every((f) {
  final id = f['upload_file_id'];
  return id is String && id.isNotEmpty;
});

/// `validateJSONSchema` (zod): whether [value] fits [type]; `array[string]`, `array[number]`, `object` (any JSON)
/// and `array[object]` (an array of JSON) are checked, other types pass. The error is zod's message (its issues as
/// JSON).
({bool success, String? error}) validateJSONSchema(Object? value, String type) {
  String issue(String expected, Object? got, List<Object> path) => const JsonEncoder.withIndent('  ').convert([
    {
      'expected': expected,
      'code': 'invalid_type',
      'path': path,
      'message': 'Invalid input: expected $expected, received ${_typeName(got)}',
    },
  ]);
  ({bool success, String? error}) every(bool Function(Object?) ok, String expected) {
    if (value is! List) return (success: false, error: issue('array', value, const []));
    for (final (i, v) in value.indexed) {
      if (!ok(v)) return (success: false, error: issue(expected, v, [i]));
    }
    return (success: true, error: null);
  }

  return switch (type) {
    'array[string]' => every((v) => v is String, 'string'),
    'array[number]' => every((v) => v is num, 'number'),
    'array[object]' => every((_) => true, 'json'),
    // Whatever JSON parses to is JSON.
    _ => (success: true, error: null),
  };
}

String _typeName(Object? v) => switch (v) {
  null => 'null',
  String() => 'string',
  num() => 'number',
  bool() => 'boolean',
  List() => 'array',
  _ => 'object',
};

/// `validateInspectJsonValue`: [text] parsed and checked for [type]; objects (and arrays of them) must also be no
/// deeper than `JSON_SCHEMA_MAX_DEPTH` and pass Draft-07 as a schema, as in Dify.
({bool success, String validationError, FormatException? parseError}) validateInspectJsonValue(
  String text,
  String type,
) {
  final Object? json;
  try {
    json = jsonDecode(text);
  } on FormatException catch (e) {
    // Worded like the browser's JSON.parse errors.
    final at = e.offset;
    final message = at == null || at >= text.trimRight().length
        ? 'Unexpected end of JSON input'
        : '${e.message} in JSON at position $at';
    return (success: false, validationError: '', parseError: FormatException(message, text, at));
  }
  final result = validateJSONSchema(json, type);
  if (!result.success) return (success: false, validationError: result.error ?? '', parseError: null);
  if (type == 'object' || type == 'array[object]') {
    if (checkJsonSchemaDepth(json) > jsonSchemaMaxDepth) {
      return (
        success: false,
        validationError: 'Schema exceeds maximum depth of $jsonSchemaMaxDepth.',
        parseError: null,
      );
    }
    final errors = validateSchemaAgainstDraft7(json);
    if (errors.isNotEmpty) {
      return (success: false, validationError: getValidationErrorMessage(errors), parseError: null);
    }
  }
  return (success: true, validationError: '', parseError: null);
}
