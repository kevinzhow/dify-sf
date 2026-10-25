/// Declared `file` outputs: the model gives a workspace-relative path in
/// `final_output`; the service checks it, uploads the file through
/// `/inner/agent/files/upload-request` and puts
/// `{"upload_id", "filename", "mime_type", "size"}` into the candidate.
///
/// A declared file output is a top-level property (or an array of them)
/// carrying the `x-dify-sf-file` keyword, e.g.
/// `{"type": "string", "x-dify-sf-file": {"extensions": ["csv"],
/// "mime_types": ["text/csv"]}}`; both constraint lists are optional.
library;

import 'output_tool.dart';

const fileOutputKeyword = 'x-dify-sf-file';

/// Largest file uploaded as a declared output.
const maxOutputFileBytes = 64 * 1024 * 1024;

class FileOutputSpec {
  FileOutputSpec({
    required this.isArray,
    required this.extensions,
    required this.mimeTypes,
  });

  final bool isArray;

  /// Lower case, without the leading dot; empty = any.
  final List<String> extensions;

  /// Exact types or `type/*`; empty = any.
  final List<String> mimeTypes;

  /// Why [filename] / [mimeType] do not satisfy the declaration, or null.
  String? violation(String filename, String mimeType) {
    final dot = filename.lastIndexOf('.');
    final ext = dot <= 0 ? '' : filename.substring(dot + 1).toLowerCase();
    if (extensions.isNotEmpty && !extensions.contains(ext)) {
      return '$filename: extension must be one of ${extensions.join(', ')}';
    }
    final mime = mimeType.toLowerCase();
    if (mimeTypes.isNotEmpty &&
        !mimeTypes.any(
          (m) => m.endsWith('/*')
              ? mime.startsWith(m.substring(0, m.length - 1))
              : m == mime,
        )) {
      return '$filename: MIME type $mimeType is not one of ${mimeTypes.join(', ')}';
    }
    return null;
  }
}

FileOutputSpec? _spec(Object? node, {required bool isArray}) {
  if (node is! Map) return null;
  final decl = node[fileOutputKeyword];
  if (decl == null) return null;
  List<String> list(Object? v, {bool ext = false}) => [
    if (v is List)
      for (final e in v)
        if (e is String && e.trim().isNotEmpty)
          ext
              ? e.trim().toLowerCase().replaceFirst(RegExp(r'^\.'), '')
              : e.trim().toLowerCase(),
  ];
  return FileOutputSpec(
    isArray: isArray,
    extensions: list(decl is Map ? decl['extensions'] : null, ext: true),
    mimeTypes: list(decl is Map ? decl['mime_types'] : null),
  );
}

/// The declared file outputs of [schema], by top-level property.
Map<String, FileOutputSpec> fileOutputFields(Map<String, Object?> schema) {
  final inlined = inlineLocalDefs(schema);
  final props = inlined['properties'];
  final out = <String, FileOutputSpec>{};
  if (props is! Map) return out;
  props.forEach((name, node) {
    final direct = _spec(node, isArray: false);
    if (direct != null) {
      out[name as String] = direct;
    } else if (node is Map && node['items'] is Map) {
      final item = _spec(node['items'], isArray: true);
      if (item != null) out[name as String] = item;
    }
  });
  return out;
}

/// [schema] without the `x-dify-sf-file` keyword, as the model sees it; a file
/// property without a description says that it takes a workspace path.
Map<String, Object?> modelFacingSchema(Map<String, Object?> schema) {
  Object? walk(Object? node) {
    if (node is Map) {
      final out = <String, Object?>{};
      node.forEach((k, v) {
        if (k == fileOutputKeyword) return;
        out[k as String] = walk(v);
      });
      if (node.containsKey(fileOutputKeyword) && out['description'] == null) {
        out['description'] =
            'Path of a file in the shell workspace, relative to the workspace.';
      }
      return out;
    }
    if (node is List) return [for (final v in node) walk(v)];
    return node;
  }

  return (walk(schema) as Map).cast<String, Object?>();
}

/// MIME types by extension; `file --mime-type` decides for the rest.
const _mimeByExtension = {
  'txt': 'text/plain',
  'md': 'text/markdown',
  'csv': 'text/csv',
  'tsv': 'text/tab-separated-values',
  'html': 'text/html',
  'htm': 'text/html',
  'css': 'text/css',
  'js': 'text/javascript',
  'json': 'application/json',
  'xml': 'application/xml',
  'yaml': 'application/yaml',
  'yml': 'application/yaml',
  'pdf': 'application/pdf',
  'zip': 'application/zip',
  'png': 'image/png',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'gif': 'image/gif',
  'webp': 'image/webp',
  'svg': 'image/svg+xml',
  'mp3': 'audio/mpeg',
  'wav': 'audio/wav',
  'mp4': 'video/mp4',
  'docx':
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
};

/// The MIME type of an output file: by extension, else [detected].
String outputMimeType(String filename, String detected) {
  final dot = filename.lastIndexOf('.');
  final ext = dot <= 0 ? '' : filename.substring(dot + 1).toLowerCase();
  return _mimeByExtension[ext] ?? detected;
}
