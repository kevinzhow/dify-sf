/// Declared `file` outputs: the model gives a workspace-relative path in
/// `final_output`; the service checks it, uploads the file through
/// `/inner/agent/files/upload-request` and puts
/// `{"upload_id", "filename", "mime_type", "size"}` into the candidate.
///
/// A declared file output is any schema node carrying the `x-dify-sf-file`
/// keyword — a top-level property, a property of an object output at any
/// depth, or the `items` of an array — e.g.
/// `{"type": "string", "x-dify-sf-file": {"extensions": ["csv"],
/// "mime_types": ["text/csv"]}}`; both constraint lists are optional.
library;

import 'output_tool.dart';

const fileOutputKeyword = 'x-dify-sf-file';

/// Largest file uploaded as a declared output.
const maxOutputFileBytes = 64 * 1024 * 1024;

class FileOutputSpec {
  FileOutputSpec({required this.extensions, required this.mimeTypes});

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

FileOutputSpec? _spec(Object? node) {
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
    extensions: list(decl is Map ? decl['extensions'] : null, ext: true),
    mimeTypes: list(decl is Map ? decl['mime_types'] : null),
  );
}

/// One place in a candidate where the schema declares a file.
class FileSite {
  FileSite(this.path, this.spec, this.value);

  /// Keys (String) and list indexes (int) from the candidate root.
  final List<Object> path;
  final FileOutputSpec spec;

  /// The model's value at [path] (expected: a workspace path).
  final Object? value;

  /// The top-level property, as used for `candidate_errors`.
  String get field => path.first as String;

  /// `report.files[1]`.
  String get label {
    final b = StringBuffer();
    for (final p in path) {
      if (p is int) {
        b.write('[$p]');
      } else {
        if (b.isNotEmpty) b.write('.');
        b.write(p);
      }
    }
    return b.toString();
  }
}

/// Every file the schema declares that [candidate] produced, walking object
/// properties and array items at any depth. Missing or null values are not
/// produced and give no site.
List<FileSite> fileSites(
  Map<String, Object?> schema,
  Map<String, Object?> candidate,
) {
  final sites = <FileSite>[];
  void walk(Object? node, Object? value, List<Object> path, int depth) {
    if (node is! Map || value == null || depth > 32) return;
    final spec = _spec(node);
    if (spec != null) {
      sites.add(FileSite(List.unmodifiable(path), spec, value));
      return;
    }
    final props = node['properties'];
    if (props is Map && value is Map) {
      props.forEach((k, child) {
        if (value.containsKey(k)) {
          walk(child, value[k], [...path, k as String], depth + 1);
        }
      });
    }
    final items = node['items'];
    if (items is Map && value is List) {
      for (var i = 0; i < value.length; i++) {
        walk(items, value[i], [...path, i], depth + 1);
      }
    }
  }

  walk(inlineLocalDefs(schema), candidate, const [], 0);
  return sites;
}

/// A copy of [root] with the value at [path] replaced by [value].
Object? replaceAt(Object? root, List<Object> path, Object? value) {
  if (path.isEmpty) return value;
  final head = path.first;
  final rest = path.sublist(1);
  if (head is String && root is Map) {
    return {
      ...root.cast<String, Object?>(),
      head: replaceAt(root[head], rest, value),
    };
  }
  if (head is int && root is List) {
    return [
      for (var i = 0; i < root.length; i++)
        i == head ? replaceAt(root[i], rest, value) : root[i],
    ];
  }
  return root;
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
