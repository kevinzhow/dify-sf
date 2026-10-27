// Portions derived from OpenAI Codex (https://github.com/openai/codex,
// rust-v0.163.0, codex-rs/apply-patch/src/{parser,streaming_parser,
// seek_sequence,text_file,file_update,invocation,lib}.rs), Copyright 2025
// OpenAI, licensed under the Apache License 2.0. Modified for dify-sf: ported
// to Dart over an abstract file system (the sandbox through shellctl); the
// streaming events, delta bookkeeping and unified diffs are not ported. See
// third_party/codex/PATCHES.md.

/// Codex's `apply_patch`: the patch grammar, the lenient parser, the fuzzy
/// context matching and the file updates, with Codex's messages.
library;

// ---- parser ---------------------------------------------------------------

const beginPatchMarker = '*** Begin Patch';
const endPatchMarker = '*** End Patch';
const addFileMarker = '*** Add File: ';
const deleteFileMarker = '*** Delete File: ';
const updateFileMarker = '*** Update File: ';
const moveToMarker = '*** Move to: ';
const eofMarker = '*** End of File';
const changeContextMarker = '@@ ';
const emptyChangeContextMarker = '@@';
const _environmentIdMarker = '*** Environment ID:';

/// `ParseError`: `invalid patch: …` or `invalid hunk at line N, …`.
class PatchParseError implements Exception {
  const PatchParseError.patch(this.message) : lineNumber = null;
  const PatchParseError.hunk(this.message, this.lineNumber);

  final String message;

  /// Set for an invalid hunk.
  final int? lineNumber;

  @override
  String toString() => lineNumber == null
      ? 'invalid patch: $message'
      : 'invalid hunk at line $lineNumber, $message';

  @override
  bool operator ==(Object other) =>
      other is PatchParseError &&
      other.message == message &&
      other.lineNumber == lineNumber;

  @override
  int get hashCode => Object.hash(message, lineNumber);
}

sealed class Hunk {
  const Hunk(this.path);

  /// The path named after the hunk marker.
  final String path;

  /// The path the summary reports (`Hunk::path`): the move target of an
  /// update that moves, else [path].
  String get affectedPath => path;
}

class AddFileHunk extends Hunk {
  AddFileHunk(super.path, [this.contents = '']);
  String contents;

  @override
  bool operator ==(Object other) =>
      other is AddFileHunk && other.path == path && other.contents == contents;
  @override
  int get hashCode => Object.hash(path, contents);
  @override
  String toString() => 'AddFile($path, ${_q(contents)})';
}

class DeleteFileHunk extends Hunk {
  const DeleteFileHunk(super.path);
  @override
  bool operator ==(Object other) =>
      other is DeleteFileHunk && other.path == path;
  @override
  int get hashCode => path.hashCode;
  @override
  String toString() => 'DeleteFile($path)';
}

class UpdateFileHunk extends Hunk {
  UpdateFileHunk(super.path, {this.movePath, List<UpdateFileChunk>? chunks})
    : chunks = chunks ?? [];
  String? movePath;
  final List<UpdateFileChunk> chunks;

  @override
  String get affectedPath => movePath ?? path;

  @override
  bool operator ==(Object other) =>
      other is UpdateFileHunk &&
      other.path == path &&
      other.movePath == movePath &&
      _listEq(other.chunks, chunks);
  @override
  int get hashCode => Object.hash(path, movePath, chunks.length);
  @override
  String toString() => 'UpdateFile($path, move: $movePath, $chunks)';
}

class UpdateFileChunk {
  UpdateFileChunk({
    this.changeContext,
    List<String>? oldLines,
    List<String>? newLines,
    List<(int, int)>? contextLineIndices,
    this.isEndOfFile = false,
  }) : oldLines = oldLines ?? [],
       newLines = newLines ?? [],
       contextLineIndices = contextLineIndices ?? [];

  /// The `@@ <context>` line, if any.
  String? changeContext;
  final List<String> oldLines;
  final List<String> newLines;

  /// `(old index, new index)` of each context line (in both lists).
  final List<(int, int)> contextLineIndices;
  bool isEndOfFile;

  void _pushContextLine(String line) {
    contextLineIndices.add((oldLines.length, newLines.length));
    oldLines.add(line);
    newLines.add(line);
  }

  @override
  bool operator ==(Object other) =>
      other is UpdateFileChunk &&
      other.changeContext == changeContext &&
      _listEq(other.oldLines, oldLines) &&
      _listEq(other.newLines, newLines) &&
      _listEq(other.contextLineIndices, contextLineIndices) &&
      other.isEndOfFile == isEndOfFile;
  @override
  int get hashCode => Object.hash(changeContext, oldLines.length, isEndOfFile);
  @override
  String toString() =>
      'Chunk(ctx: $changeContext, old: $oldLines, new: $newLines, '
      'ctxIdx: $contextLineIndices, eof: $isEndOfFile)';
}

bool _listEq<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

String _q(String s) => s.replaceAll('\n', r'\n');

/// The parsed patch: its hunks and the text without a heredoc wrapper.
class ApplyPatchArgs {
  ApplyPatchArgs(this.patch, this.hunks, {this.environmentId});
  final String patch;
  final List<Hunk> hunks;
  final String? environmentId;
}

// Rust's `char::is_whitespace` (Unicode White_Space); Dart's `trim` also
// strips U+FEFF, which Rust does not.
bool _isRustWhitespace(int c) =>
    (c >= 0x09 && c <= 0x0d) ||
    c == 0x20 ||
    c == 0x85 ||
    c == 0xa0 ||
    c == 0x1680 ||
    (c >= 0x2000 && c <= 0x200a) ||
    c == 0x2028 ||
    c == 0x2029 ||
    c == 0x202f ||
    c == 0x205f ||
    c == 0x3000;

/// Rust's `str::trim`.
String rustTrim(String s) => rustTrimEnd(_rustTrimStart(s));

String _rustTrimStart(String s) {
  var i = 0;
  while (i < s.length && _isRustWhitespace(s.codeUnitAt(i))) {
    i++;
  }
  return s.substring(i);
}

/// Rust's `str::trim_end`.
String rustTrimEnd(String s) {
  var end = s.length;
  while (end > 0 && _isRustWhitespace(s.codeUnitAt(end - 1))) {
    end--;
  }
  return s.substring(0, end);
}

/// Rust's `str::lines`: split on `\n`, one trailing `\r` removed per line,
/// no empty last line for a trailing newline.
List<String> _rustLines(String s) {
  if (s.isEmpty) return const [];
  final parts = s.split('\n');
  if (parts.last.isEmpty) parts.removeLast();
  return [
    for (final p in parts) p.endsWith('\r') ? p.substring(0, p.length - 1) : p,
  ];
}

/// `parse_patch`: lenient mode (a `<<EOF … EOF` heredoc wrapper is
/// accepted).
ApplyPatchArgs parsePatch(String patch) {
  final lines = _rustLines(rustTrim(patch));
  final patchLines = _checkBoundariesLenient(lines);
  final text = patchLines.join('\n');
  final parser = StreamingPatchParser()..pushDelta(text);
  final hunks = parser.finish();
  return ApplyPatchArgs(text, hunks, environmentId: parser.environmentId);
}

List<String> _checkBoundariesStrict(List<String> lines) {
  final first = lines.isEmpty ? null : rustTrim(lines.first);
  final last = lines.isEmpty ? null : rustTrim(lines.last);
  if (first == beginPatchMarker && last == endPatchMarker) return lines;
  if (first != null && first != beginPatchMarker) {
    throw const PatchParseError.patch(
      "The first line of the patch must be '*** Begin Patch'",
    );
  }
  throw const PatchParseError.patch(
    "The last line of the patch must be '*** End Patch'",
  );
}

List<String> _checkBoundariesLenient(List<String> lines) {
  try {
    return _checkBoundariesStrict(lines);
  } on PatchParseError {
    if (lines.length >= 2) {
      final first = lines.first;
      if ((first == '<<EOF' || first == "<<'EOF'" || first == '<<"EOF"') &&
          lines.last.endsWith('EOF') &&
          lines.length >= 4) {
        return _checkBoundariesStrict(lines.sublist(1, lines.length - 1));
      }
    }
    rethrow;
  }
}

enum _Mode { notStarted, startedPatch, addFile, deleteFile, updateFile, ended }

String _invalidHeader(String trimmed) =>
    "'$trimmed' is not a valid hunk header. Valid hunk headers: "
    "'*** Add File: {path}', '*** Delete File: {path}', "
    "'*** Update File: {path}'";

String _unexpectedLine(String line) =>
    "Unexpected line found in update hunk: '$line'. Every line should start "
    "with ' ' (context line), '+' (added line), or '-' (removed line)";

/// `StreamingPatchParser`: consumes the patch text line by line.
class StreamingPatchParser {
  final StringBuffer _line = StringBuffer();
  _Mode _mode = _Mode.notStarted;
  int _hunkLineNumber = 0;
  int _lineNumber = 0;
  final List<Hunk> hunks = [];
  String? environmentId;

  void _ensureUpdateHunkIsNotEmpty(String line) {
    final last = hunks.isEmpty ? null : hunks.last;
    if (last is UpdateFileHunk) {
      if (last.chunks.isEmpty && _mode == _Mode.updateFile) {
        throw PatchParseError.hunk(
          "Update file hunk for path '${last.path}' is empty",
          _hunkLineNumber,
        );
      }
      final c = last.chunks.isEmpty ? null : last.chunks.last;
      if (c != null && c.oldLines.isEmpty && c.newLines.isEmpty) {
        if (line == endPatchMarker) {
          throw PatchParseError.hunk(
            'Update hunk does not contain any lines',
            _lineNumber,
          );
        }
        throw PatchParseError.hunk(_unexpectedLine(line), _lineNumber);
      }
    }
  }

  bool _handleHeadersAndEnd(String trimmed) {
    if (_mode == _Mode.startedPatch &&
        trimmed.startsWith(_environmentIdMarker)) {
      if (environmentId != null) {
        throw const PatchParseError.patch(
          'apply_patch environment_id cannot be specified more than once',
        );
      }
      final id = rustTrim(trimmed.substring(_environmentIdMarker.length));
      if (id.isEmpty) {
        throw const PatchParseError.patch(
          'apply_patch environment_id cannot be empty',
        );
      }
      environmentId = id;
      return true;
    }
    if (trimmed == endPatchMarker) {
      _ensureUpdateHunkIsNotEmpty(trimmed);
      _mode = _Mode.ended;
      return true;
    }
    if (trimmed.startsWith(addFileMarker)) {
      _ensureUpdateHunkIsNotEmpty(trimmed);
      hunks.add(AddFileHunk(trimmed.substring(addFileMarker.length)));
      _mode = _Mode.addFile;
      return true;
    }
    if (trimmed.startsWith(deleteFileMarker)) {
      _ensureUpdateHunkIsNotEmpty(trimmed);
      hunks.add(DeleteFileHunk(trimmed.substring(deleteFileMarker.length)));
      _mode = _Mode.deleteFile;
      return true;
    }
    if (trimmed.startsWith(updateFileMarker)) {
      _ensureUpdateHunkIsNotEmpty(trimmed);
      hunks.add(UpdateFileHunk(trimmed.substring(updateFileMarker.length)));
      _mode = _Mode.updateFile;
      _hunkLineNumber = _lineNumber;
      return true;
    }
    return false;
  }

  void pushDelta(String delta) {
    var start = 0;
    while (true) {
      final nl = delta.indexOf('\n', start);
      if (nl < 0) {
        _line.write(delta.substring(start));
        return;
      }
      _line.write(delta.substring(start, nl));
      start = nl + 1;
      var line = _line.toString();
      _line.clear();
      if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
      _lineNumber++;
      _processLine(line);
    }
  }

  List<Hunk> finish() {
    if (_line.isNotEmpty) {
      final line = _line.toString();
      _line.clear();
      _lineNumber++;
      if (rustTrim(line) == endPatchMarker) {
        _ensureUpdateHunkIsNotEmpty(rustTrim(line));
        _mode = _Mode.ended;
      } else {
        _processLine(line);
      }
    }
    if (_mode != _Mode.ended) {
      throw const PatchParseError.patch(
        "The last line of the patch must be '*** End Patch'",
      );
    }
    return hunks;
  }

  void _processLine(String line) {
    final trimmed = rustTrim(line);
    switch (_mode) {
      case _Mode.notStarted:
        if (trimmed == beginPatchMarker) {
          _mode = _Mode.startedPatch;
          return;
        }
        throw const PatchParseError.patch(
          "The first line of the patch must be '*** Begin Patch'",
        );
      case _Mode.startedPatch:
        if (_handleHeadersAndEnd(trimmed)) return;
        throw PatchParseError.hunk(_invalidHeader(trimmed), _lineNumber);
      case _Mode.addFile:
        if (_handleHeadersAndEnd(trimmed)) return;
        final last = hunks.last;
        if (line.startsWith('+') && last is AddFileHunk) {
          last.contents += '${line.substring(1)}\n';
          return;
        }
        throw PatchParseError.hunk(_invalidHeader(trimmed), _lineNumber);
      case _Mode.deleteFile:
        if (_handleHeadersAndEnd(trimmed)) return;
        throw PatchParseError.hunk(_invalidHeader(trimmed), _lineNumber);
      case _Mode.updateFile:
        _processUpdateLine(line);
      case _Mode.ended:
        if (trimmed.isEmpty) return;
        throw const PatchParseError.patch(
          "The last line of the patch must be '*** End Patch'",
        );
    }
  }

  void _processUpdateLine(String line) {
    final updateLine = rustTrimEnd(line);
    if (_handleHeadersAndEnd(updateLine)) return;
    final hunk = hunks.last;
    if (hunk is UpdateFileHunk) {
      final chunks = hunk.chunks;
      UpdateFileChunk? lastChunk() => chunks.isEmpty ? null : chunks.last;
      bool lastEmpty() {
        final c = lastChunk();
        return c != null && c.oldLines.isEmpty && c.newLines.isEmpty;
      }

      final isContextMarker =
          updateLine == emptyChangeContextMarker ||
          updateLine.startsWith(changeContextMarker);
      if (lastChunk()?.isEndOfFile ?? false) {
        if (updateLine.isEmpty) return;
        if (!isContextMarker) {
          throw PatchParseError.hunk(
            "Expected update hunk to start with a @@ context marker, got: "
            "'$line'",
            _lineNumber,
          );
        }
      }
      if (chunks.isEmpty &&
          hunk.movePath == null &&
          updateLine.startsWith(moveToMarker)) {
        hunk.movePath = updateLine.substring(moveToMarker.length);
        return;
      }
      if (isContextMarker && lastEmpty()) {
        throw PatchParseError.hunk(_unexpectedLine(line), _lineNumber);
      }
      if (updateLine == emptyChangeContextMarker) {
        chunks.add(UpdateFileChunk());
        return;
      }
      if (updateLine.startsWith(changeContextMarker)) {
        chunks.add(
          UpdateFileChunk(
            changeContext: updateLine.substring(changeContextMarker.length),
          ),
        );
        return;
      }
      if (updateLine == eofMarker) {
        if (lastEmpty()) {
          throw PatchParseError.hunk(
            'Update hunk does not contain any lines',
            _lineNumber,
          );
        }
        lastChunk()?.isEndOfFile = true;
        return;
      }
      UpdateFileChunk current() {
        if (chunks.isEmpty) chunks.add(UpdateFileChunk());
        return chunks.last;
      }

      if (line.isEmpty) {
        current()._pushContextLine('');
        return;
      }
      if (line.startsWith(' ')) {
        current()._pushContextLine(line.substring(1));
        return;
      }
      if (line.startsWith('+')) {
        current().newLines.add(line.substring(1));
        return;
      }
      if (line.startsWith('-')) {
        current().oldLines.add(line.substring(1));
        return;
      }
      final c = lastChunk();
      if (c != null && (c.oldLines.isNotEmpty || c.newLines.isNotEmpty)) {
        throw PatchParseError.hunk(
          "Expected update hunk to start with a @@ context marker, got: "
          "'$line'",
          _lineNumber,
        );
      }
    }
    throw PatchParseError.hunk(_unexpectedLine(line), _lineNumber);
  }
}

// ---- seek_sequence ----------------------------------------------------------

String _normalise(String s) {
  final out = StringBuffer();
  for (final r in rustTrim(s).runes) {
    switch (r) {
      case 0x2010 || 0x2011 || 0x2012 || 0x2013 || 0x2014 || 0x2015 || 0x2212:
        out.write('-');
      case 0x2018 || 0x2019 || 0x201a || 0x201b:
        out.write("'");
      case 0x201c || 0x201d || 0x201e || 0x201f:
        out.write('"');
      case 0x00a0 ||
          0x2002 ||
          0x2003 ||
          0x2004 ||
          0x2005 ||
          0x2006 ||
          0x2007 ||
          0x2008 ||
          0x2009 ||
          0x200a ||
          0x202f ||
          0x205f ||
          0x3000:
        out.write(' ');
      default:
        out.writeCharCode(r);
    }
  }
  return out.toString();
}

/// `seek_sequence`: the first index at or after [start] where [pattern]
/// matches [lines] exactly, then ignoring trailing whitespace, then
/// ignoring surrounding whitespace, then after normalising typographic
/// punctuation. With [eof], the search starts where the pattern would end
/// the file.
int? seekSequence(
  List<String> lines,
  List<String> pattern,
  int start, {
  required bool eof,
}) {
  if (pattern.isEmpty) return start;
  if (pattern.length > lines.length) return null;
  final searchStart = eof && lines.length >= pattern.length
      ? (lines.length - pattern.length > start
            ? lines.length - pattern.length
            : start)
      : start;
  final lastStart = lines.length - pattern.length;
  int? find(bool Function(String a, String b) same) {
    for (var i = searchStart; i <= lastStart; i++) {
      var ok = true;
      for (var p = 0; p < pattern.length; p++) {
        if (!same(lines[i + p], pattern[p])) {
          ok = false;
          break;
        }
      }
      if (ok) return i;
    }
    return null;
  }

  return find((a, b) => a == b) ??
      find((a, b) => rustTrimEnd(a) == rustTrimEnd(b)) ??
      find((a, b) => rustTrim(a) == rustTrim(b)) ??
      find((a, b) => _normalise(a) == _normalise(b));
}

// ---- text_file ----------------------------------------------------------------

typedef Replacement = (int start, int oldLen, List<String> newLines);

class _SourceLine {
  _SourceLine(this.text, this.ending);
  final String text;
  String? ending;
}

/// `SourceFile`: lines with their own endings (LF, CRLF or CR); inserted
/// lines take the first ending of the file (LF without one).
class SourceFile {
  SourceFile._(this._lines, this._preferred);

  factory SourceFile.parse(String contents) {
    final lines = <_SourceLine>[];
    String? preferred;
    var lineStart = 0;
    var i = 0;
    while (i < contents.length) {
      final c = contents.codeUnitAt(i);
      String? ending;
      if (c == 0x0d) {
        ending = i + 1 < contents.length && contents.codeUnitAt(i + 1) == 0x0a
            ? '\r\n'
            : '\r';
      } else if (c == 0x0a) {
        ending = '\n';
      }
      if (ending == null) {
        i++;
        continue;
      }
      preferred ??= ending;
      lines.add(_SourceLine(contents.substring(lineStart, i), ending));
      i += ending.length;
      lineStart = i;
    }
    if (lineStart < contents.length) {
      lines.add(_SourceLine(contents.substring(lineStart), null));
    }
    return SourceFile._(lines, preferred ?? '\n');
  }

  List<_SourceLine> _lines;
  final String _preferred;

  List<String> get lineTexts => [for (final l in _lines) l.text];

  void applyReplacements(List<Replacement> replacements) {
    final out = <_SourceLine>[];
    var source = 0;
    for (final (start, oldLen, segment) in replacements) {
      out.addAll(_lines.sublist(source, start));
      for (final t in segment) {
        out.add(_SourceLine(t, _preferred));
      }
      source = start + oldLen;
    }
    out.addAll(_lines.sublist(source.clamp(0, _lines.length)));
    for (final l in out) {
      l.ending ??= _preferred;
    }
    _lines = out;
  }

  String get contents {
    final b = StringBuffer();
    for (final l in _lines) {
      b.write(l.text);
      if (l.ending != null) b.write(l.ending);
    }
    return b.toString();
  }
}

// ---- file_update --------------------------------------------------------------

/// `ApplyPatchError::ComputeReplacements` and the I/O errors of a patch.
class ApplyPatchError implements Exception {
  ApplyPatchError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// `compute_replacements`.
List<Replacement> computeReplacements(
  List<String> originalLines,
  String path,
  List<UpdateFileChunk> chunks,
) {
  final replacements = <Replacement>[];
  var lineIndex = 0;
  for (final chunk in chunks) {
    final ctx = chunk.changeContext;
    if (ctx != null) {
      final idx = seekSequence(originalLines, [ctx], lineIndex, eof: false);
      if (idx == null) {
        throw ApplyPatchError("Failed to find context '$ctx' in $path");
      }
      lineIndex = idx + 1;
    }
    if (chunk.oldLines.isEmpty) {
      replacements.add((originalLines.length, 0, List.of(chunk.newLines)));
      continue;
    }
    var pattern = chunk.oldLines;
    var newSlice = chunk.newLines;
    var found = seekSequence(
      originalLines,
      pattern,
      lineIndex,
      eof: chunk.isEndOfFile,
    );
    if (found == null && pattern.isNotEmpty && pattern.last.isEmpty) {
      pattern = pattern.sublist(0, pattern.length - 1);
      if (newSlice.isNotEmpty && newSlice.last.isEmpty) {
        newSlice = newSlice.sublist(0, newSlice.length - 1);
      }
      found = seekSequence(
        originalLines,
        pattern,
        lineIndex,
        eof: chunk.isEndOfFile,
      );
    }
    if (found == null) {
      throw ApplyPatchError(
        'Failed to find expected lines in $path:\n${chunk.oldLines.join('\n')}',
      );
    }
    final startIdx = found;
    var oldStart = 0;
    var newStart = 0;
    for (final (oldCtx, newCtx) in chunk.contextLineIndices) {
      if (oldCtx >= pattern.length || newCtx >= newSlice.length) break;
      if (oldStart != oldCtx || newStart != newCtx) {
        replacements.add((
          startIdx + oldStart,
          oldCtx - oldStart,
          newSlice.sublist(newStart, newCtx),
        ));
      }
      oldStart = oldCtx + 1;
      newStart = newCtx + 1;
    }
    if (oldStart != pattern.length || newStart != newSlice.length) {
      replacements.add((
        startIdx + oldStart,
        pattern.length - oldStart,
        newSlice.sublist(newStart),
      ));
    }
    lineIndex = startIdx + pattern.length;
  }
  // A stable sort by start index (Rust's `sort_by_key` is stable).
  final indexed = [
    for (var i = 0; i < replacements.length; i++) (i, replacements[i]),
  ];
  indexed.sort((a, b) {
    final c = a.$2.$1.compareTo(b.$2.$1);
    return c != 0 ? c : a.$1.compareTo(b.$1);
  });
  return [for (final e in indexed) e.$2];
}

/// The new contents of [original] after [chunks] (`derive_new_contents_from_chunks`
/// without the read).
String applyChunks(String original, String path, List<UpdateFileChunk> chunks) {
  final source = SourceFile.parse(original);
  final replacements = computeReplacements(source.lineTexts, path, chunks);
  source.applyReplacements(replacements);
  return source.contents;
}

// ---- file system and application ------------------------------------------

/// An I/O failure, with Rust's `std::io::Error` text (for example
/// `No such file or directory (os error 2)`).
class PatchIoError implements Exception {
  const PatchIoError(this.message, {this.notFound = false});
  final String message;
  final bool notFound;

  static const missing = PatchIoError(
    'No such file or directory (os error 2)',
    notFound: true,
  );
  static const isDirectory = PatchIoError('Is a directory (os error 21)');

  @override
  String toString() => message;
}

/// What `get_metadata` reports.
typedef PatchMetadata = ({bool isFile, bool isDirectory, bool isSymlink});

/// The file operations `apply_patch` needs (Codex's `ExecutorFileSystem`,
/// following symlinks). Paths are absolute.
abstract class PatchFileSystem {
  /// Throws [PatchIoError] (`notFound` for a missing path).
  Future<PatchMetadata> metadata(String path);

  /// The UTF-8 text of a file; throws [PatchIoError].
  Future<String> readText(String path);

  /// Writes (creates or truncates) a file; a missing parent directory is a
  /// [PatchIoError] with `notFound`.
  Future<void> writeText(String path, String contents);

  /// `create_dir_all`.
  Future<void> createDirectories(String path);

  /// Removes a file (not recursive).
  Future<void> remove(String path);
}

/// `cwd.join(path)` for POSIX paths: absolute paths stand alone; `.` and
/// `..` segments are resolved lexically.
String resolvePatchPath(String cwd, String path) {
  final joined = path.startsWith('/') ? path : '$cwd/$path';
  final out = <String>[];
  for (final seg in joined.split('/')) {
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') {
      if (out.isNotEmpty) out.removeLast();
      continue;
    }
    out.add(seg);
  }
  return '/${out.join('/')}';
}

String _parent(String path) {
  final i = path.lastIndexOf('/');
  return i <= 0 ? '/' : path.substring(0, i);
}

/// stdout, stderr and exit status of one application.
typedef PatchRun = ({int exitCode, String stdout, String stderr});

/// The `apply_patch` executable (`standalone_executable.rs`): parses and
/// applies [patch] in [cwd]; a failure after some hunks leaves their
/// changes. Codex's scenario fixtures are specified against this.
Future<PatchRun> applyPatchStandalone(
  String patch,
  String cwd,
  PatchFileSystem fs,
) async {
  final List<Hunk> hunks;
  try {
    hunks = parsePatch(patch).hunks;
  } on PatchParseError catch (e) {
    final text = e.lineNumber == null
        ? 'Invalid patch: ${e.message}\n'
        : 'Invalid patch hunk on line ${e.lineNumber}: ${e.message}\n';
    return (exitCode: 1, stdout: '', stderr: text);
  }
  return applyHunks(hunks, cwd, fs);
}

/// `apply_hunks`: applies [hunks] in order; prints the git-style summary or
/// the first error.
Future<PatchRun> applyHunks(
  List<Hunk> hunks,
  String cwd,
  PatchFileSystem fs,
) async {
  try {
    final summary = await _applyHunksToFiles(hunks, cwd, fs);
    return (exitCode: 0, stdout: summary, stderr: '');
  } on ApplyPatchError catch (e) {
    return (exitCode: 1, stdout: '', stderr: '${e.message}\n');
  }
}

Future<void> _ensureNotDirectory(
  PatchFileSystem fs,
  String path,
  String context,
) async {
  try {
    final m = await fs.metadata(path);
    if (m.isDirectory) throw ApplyPatchError(context);
  } on PatchIoError {
    throw ApplyPatchError(context);
  }
}

Future<void> _writeWithParentRetry(
  PatchFileSystem fs,
  String path,
  String contents,
) async {
  try {
    await fs.writeText(path, contents);
  } on PatchIoError catch (e) {
    if (!e.notFound) throw ApplyPatchError('Failed to write file $path');
    try {
      await fs.createDirectories(_parent(path));
    } on PatchIoError {
      throw ApplyPatchError('Failed to create parent directories for $path');
    }
    try {
      await fs.writeText(path, contents);
    } on PatchIoError {
      throw ApplyPatchError('Failed to write file $path');
    }
  }
}

/// Reads the file to update and applies the chunks
/// (`derive_new_contents_from_chunks`).
Future<({String original, String updated})> deriveNewContents(
  PatchFileSystem fs,
  String path,
  List<UpdateFileChunk> chunks,
) async {
  final String original;
  try {
    original = await fs.readText(path);
  } on PatchIoError catch (e) {
    throw ApplyPatchError('Failed to read file to update $path: $e');
  }
  return (original: original, updated: applyChunks(original, path, chunks));
}

Future<String> _applyHunksToFiles(
  List<Hunk> hunks,
  String cwd,
  PatchFileSystem fs,
) async {
  if (hunks.isEmpty) throw ApplyPatchError('No files were modified.');
  final added = <String>[];
  final modified = <String>[];
  final deleted = <String>[];
  for (final hunk in hunks) {
    final path = resolvePatchPath(cwd, hunk.path);
    switch (hunk) {
      case AddFileHunk(:final contents):
        await _writeWithParentRetry(fs, path, contents);
        added.add(hunk.affectedPath);
      case DeleteFileHunk():
        final context = 'Failed to delete file $path';
        await _ensureNotDirectory(fs, path, context);
        try {
          await fs.remove(path);
        } on PatchIoError {
          throw ApplyPatchError(context);
        }
        deleted.add(hunk.affectedPath);
      case UpdateFileHunk(:final movePath, :final chunks):
        final updated = (await deriveNewContents(fs, path, chunks)).updated;
        if (movePath != null) {
          final dest = resolvePatchPath(cwd, movePath);
          await _writeWithParentRetry(fs, dest, updated);
          final context = 'Failed to remove original $path';
          await _ensureNotDirectory(fs, path, context);
          try {
            await fs.remove(path);
          } on PatchIoError {
            throw ApplyPatchError(context);
          }
        } else {
          try {
            await fs.writeText(path, updated);
          } on PatchIoError {
            throw ApplyPatchError('Failed to write file $path');
          }
        }
        modified.add(hunk.affectedPath);
    }
  }
  final b = StringBuffer('Success. Updated the following files:\n');
  for (final p in added) {
    b.write('A $p\n');
  }
  for (final p in modified) {
    b.write('M $p\n');
  }
  for (final p in deleted) {
    b.write('D $p\n');
  }
  return b.toString();
}

/// `verify_apply_patch_args`: every hunk is checked against the files
/// before anything is written (deletes and updates read their file, updates
/// must match). Throws [ApplyPatchError] or [PatchParseError].
Future<void> verifyPatch(
  ApplyPatchArgs args,
  String cwd,
  PatchFileSystem fs,
) async {
  final seen = <String>{};
  for (final hunk in args.hunks) {
    final path = resolvePatchPath(cwd, hunk.path);
    if (!seen.add(path)) {
      throw PatchParseError.patch('multiple operations target $path');
    }
    switch (hunk) {
      case AddFileHunk():
        break;
      case DeleteFileHunk():
        try {
          await fs.readText(path);
        } on PatchIoError catch (e) {
          throw ApplyPatchError('Failed to read $path: $e');
        }
      case UpdateFileHunk(:final chunks):
        await deriveNewContents(fs, path, chunks);
    }
  }
}

/// The `apply_patch` tool of Codex's core: verification first (a patch
/// that does not apply changes nothing), then the application, whose
/// output is formatted like an exec (`format_exec_output_for_model`).
/// Returns the text for the model and whether it is a tool error
/// (`RespondToModel`, no exec header).
Future<({String text, bool error})> runApplyPatchTool(
  String input,
  String cwd,
  PatchFileSystem fs, {
  required String Function(PatchRun run, Duration wallTime) format,
}) async {
  final watch = Stopwatch()..start();
  final ApplyPatchArgs args;
  try {
    args = parsePatch(input);
  } on PatchParseError catch (e) {
    return (text: 'apply_patch verification failed: $e', error: true);
  }
  try {
    await verifyPatch(args, cwd, fs);
  } on PatchParseError catch (e) {
    return (text: 'apply_patch verification failed: $e', error: true);
  } on ApplyPatchError catch (e) {
    return (text: 'apply_patch verification failed: $e', error: true);
  }
  final run = await applyHunks(args.hunks, cwd, fs);
  return (text: format(run, watch.elapsed), error: false);
}
