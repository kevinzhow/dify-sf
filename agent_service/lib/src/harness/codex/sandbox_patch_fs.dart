/// The file system `apply_patch` works on in the `codex` style: the
/// execution's sandbox, through bounded shellctl control commands (as the
/// sandbox's own file operations do). Paths are absolute; the sandbox's
/// Landlock rules decide what may be written, as for any shell command.
library;

import 'dart:convert';

import '../../sandbox/paths.dart' show shellQuote;
import 'apply_patch.dart';

/// Runs a control script and returns its exit code and output (stdout and
/// stderr merged).
typedef ControlRunner = Future<({int? exitCode, String output})> Function(
  String script,
);

/// Largest file `apply_patch` reads or writes here.
const patchFileMaxBytes = 16 * 1024 * 1024;

const _writeChunk = 192 * 1024;

class SandboxPatchFileSystem implements PatchFileSystem {
  SandboxPatchFileSystem(this.control);
  final ControlRunner control;

  Future<String> _status(String script) async {
    final r = await control(script);
    final first = const LineSplitter().convert(r.output).firstOrNull?.trim();
    return first ?? '';
  }

  static PatchIoError _error(String status) => switch (status) {
    'missing' => PatchIoError.missing,
    'dir' => PatchIoError.isDirectory,
    'denied' => const PatchIoError('Permission denied (os error 13)'),
    'large' => const PatchIoError(
      'File too large for apply_patch here (more than $patchFileMaxBytes bytes)',
    ),
    _ => PatchIoError('I/O error: $status'),
  };

  @override
  Future<PatchMetadata> metadata(String path) async {
    final s = await _status('''
p=${shellQuote(path)}
if [ -L "\$p" ]; then l=1; else l=0; fi
if [ -d "\$p" ]; then echo "dir \$l"
elif [ -f "\$p" ]; then echo "file \$l"
elif [ -e "\$p" ]; then echo "other \$l"
else echo missing; fi''');
    final parts = s.split(' ');
    if (parts.first == 'missing') throw PatchIoError.missing;
    if (parts.length != 2) throw PatchIoError('I/O error: $s');
    return (
      isFile: parts[0] == 'file',
      isDirectory: parts[0] == 'dir',
      isSymlink: parts[1] == '1',
    );
  }

  @override
  Future<String> readText(String path) async {
    final r = await control('''
p=${shellQuote(path)}
[ -e "\$p" ] || { echo missing; exit 0; }
[ -d "\$p" ] && { echo dir; exit 0; }
[ -r "\$p" ] || { echo denied; exit 0; }
[ "\$(stat -L -c %s -- "\$p")" -le $patchFileMaxBytes ] || { echo large; exit 0; }
echo ok
base64 -w0 < "\$p"''');
    final lines = const LineSplitter().convert(r.output);
    final status = lines.firstOrNull?.trim() ?? '';
    if (status != 'ok') throw _error(status);
    final b64 = lines.skip(1).join().trim();
    try {
      return utf8.decode(base64.decode(b64));
    } on FormatException {
      throw const PatchIoError('stream did not contain valid UTF-8');
    }
  }

  @override
  Future<void> writeText(String path, String contents) async {
    final bytes = utf8.encode(contents);
    if (bytes.length > patchFileMaxBytes) throw _error('large');
    final q = shellQuote(path);
    var first = true;
    var i = 0;
    do {
      final chunk = bytes.sublist(i, (i + _writeChunk).clamp(0, bytes.length));
      final b64 = base64.encode(chunk);
      final lines = [
        for (var j = 0; j < b64.length; j += 76)
          b64.substring(j, (j + 76).clamp(0, b64.length)),
      ];
      final s = await _status('''
p=$q
d=\$(dirname -- "\$p")
[ -d "\$d" ] || { echo missing; exit 0; }
[ -d "\$p" ] && { echo dir; exit 0; }
base64 -d ${first ? '>' : '>>'} "\$p" 2>/dev/null <<'DIFYSF_EOF' || { echo denied; exit 0; }
${lines.join('\n')}
DIFYSF_EOF
echo ok''');
      if (s != 'ok') throw _error(s);
      first = false;
      i += _writeChunk;
    } while (i < bytes.length);
  }

  @override
  Future<void> createDirectories(String path) async {
    final s = await _status(
      'mkdir -p -- ${shellQuote(path)} 2>/dev/null && echo ok || echo denied',
    );
    if (s != 'ok') throw _error(s);
  }

  @override
  Future<void> remove(String path) async {
    final s = await _status('''
p=${shellQuote(path)}
[ -e "\$p" ] || [ -L "\$p" ] || { echo missing; exit 0; }
[ -d "\$p" ] && [ ! -L "\$p" ] && { echo dir; exit 0; }
rm -f -- "\$p" 2>/dev/null && echo ok || echo denied''');
    if (s != 'ok') throw _error(s);
  }
}
