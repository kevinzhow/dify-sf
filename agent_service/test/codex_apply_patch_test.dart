// Tests ported from OpenAI Codex rust-v0.163.0 (codex-rs/apply-patch:
// src/parser.rs, src/seek_sequence.rs and src/lib.rs unit tests, and the
// portable scenario fixtures tests/fixtures/scenarios, vendored verbatim in
// third_party/codex/), Copyright 2025 OpenAI, Apache License 2.0.

import 'dart:io';

import 'package:agent_service/src/harness/codex/apply_patch.dart';
import 'package:agent_service/src/harness/codex/sandbox_patch_fs.dart';
import 'package:test/test.dart';

import 'support.dart';

/// The local disk, as Codex's `LOCAL_FS` (for the fixtures).
class LocalPatchFs implements PatchFileSystem {
  @override
  Future<PatchMetadata> metadata(String path) async {
    final type = FileSystemEntity.typeSync(path, followLinks: true);
    if (type == FileSystemEntityType.notFound) throw PatchIoError.missing;
    return (
      isFile: type == FileSystemEntityType.file,
      isDirectory: type == FileSystemEntityType.directory,
      isSymlink: FileSystemEntity.isLinkSync(path),
    );
  }

  @override
  Future<String> readText(String path) async {
    if (Directory(path).existsSync()) throw PatchIoError.isDirectory;
    if (!File(path).existsSync()) throw PatchIoError.missing;
    return File(path).readAsStringSync();
  }

  @override
  Future<void> writeText(String path, String contents) async {
    if (!Directory(File(path).parent.path).existsSync()) {
      throw PatchIoError.missing;
    }
    if (Directory(path).existsSync()) throw PatchIoError.isDirectory;
    File(path).writeAsStringSync(contents);
  }

  @override
  Future<void> createDirectories(String path) async =>
      Directory(path).createSync(recursive: true);

  @override
  Future<void> remove(String path) async {
    if (!File(path).existsSync()) throw PatchIoError.missing;
    File(path).deleteSync();
  }
}

final scenariosDir = Directory(
  '${Directory.current.path}/../third_party/codex/upstream/codex-rs/'
  'apply-patch/tests/fixtures/scenarios',
);

Map<String, List<int>?> snapshot(Directory root) {
  final out = <String, List<int>?>{};
  if (!root.existsSync()) return out;
  for (final e in root.listSync(recursive: true)) {
    final rel = e.path.substring(root.path.length + 1);
    out[rel] = e is File ? e.readAsBytesSync() : null;
  }
  return out;
}

void copyDir(Directory from, Directory to) {
  if (!from.existsSync()) return;
  for (final e in from.listSync(recursive: true)) {
    final rel = e.path.substring(from.path.length + 1);
    if (e is Directory) {
      Directory('${to.path}/$rel').createSync(recursive: true);
    } else if (e is File) {
      File('${to.path}/$rel')
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(e.readAsBytesSync());
    }
  }
}

String wrap(String body) => '*** Begin Patch\n$body\n*** End Patch';

void main() {
  group('Codex scenario fixtures (apply_patch executable)', () {
    final scenarios = scenariosDir.listSync().whereType<Directory>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    test('all 25 are present', () => expect(scenarios, hasLength(25)));
    for (final dir in scenarios) {
      final name = dir.uri.pathSegments.where((s) => s.isNotEmpty).last;
      test(name, () async {
        final tmp = newDataDir();
        addTearDown(() => tmp.deleteSync(recursive: true));
        copyDir(Directory('${dir.path}/input'), tmp);
        final patch = File('${dir.path}/patch.txt').readAsStringSync();
        await applyPatchStandalone(patch, tmp.path, LocalPatchFs());
        final expected = snapshot(Directory('${dir.path}/expected'));
        final actual = snapshot(tmp);
        expect(actual.keys.toSet(), expected.keys.toSet());
        for (final k in expected.keys) {
          expect(actual[k], expected[k], reason: '$name: $k');
        }
      });
    }
  });

  group('parser (parser.rs tests)', () {
    test('boundaries', () {
      expect(
        () => parsePatch('bad'),
        throwsA(
          const PatchParseError.patch(
            "The first line of the patch must be '*** Begin Patch'",
          ),
        ),
      );
      expect(
        () => parsePatch('*** Begin Patch\nbad'),
        throwsA(
          const PatchParseError.patch(
            "The last line of the patch must be '*** End Patch'",
          ),
        ),
      );
      expect(
        parsePatch('*** Begin Patch \n*** Add File: foo\n+hi\n *** End Patch')
            .hunks,
        [AddFileHunk('foo', 'hi\n')],
      );
      expect(
        () => parsePatch(
          '*** Begin Patch\n*** Update File: test.py\n*** End Patch',
        ),
        throwsA(
          const PatchParseError.hunk(
            "Update file hunk for path 'test.py' is empty",
            2,
          ),
        ),
      );
      expect(parsePatch('*** Begin Patch\n*** End Patch').hunks, isEmpty);
    });

    test('all hunk kinds', () {
      expect(
        parsePatch(
          '*** Begin Patch\n*** Add File: path/add.py\n+abc\n+def\n'
          '*** Delete File: path/delete.py\n*** Update File: path/update.py\n'
          '*** Move to: path/update2.py\n@@ def f():\n-    pass\n'
          '+    return 123\n*** End Patch',
        ).hunks,
        [
          AddFileHunk('path/add.py', 'abc\ndef\n'),
          const DeleteFileHunk('path/delete.py'),
          UpdateFileHunk(
            'path/update.py',
            movePath: 'path/update2.py',
            chunks: [
              UpdateFileChunk(
                changeContext: 'def f():',
                oldLines: ['    pass'],
                newLines: ['    return 123'],
              ),
            ],
          ),
        ],
      );
    });

    test('an update hunk followed by another hunk; context lines', () {
      expect(
        parsePatch(
          '*** Begin Patch\n*** Update File: file.py\n@@\n+line\n'
          '*** Add File: other.py\n+content\n*** End Patch',
        ).hunks,
        [
          UpdateFileHunk(
            'file.py',
            chunks: [
              UpdateFileChunk(newLines: ['line']),
            ],
          ),
          AddFileHunk('other.py', 'content\n'),
        ],
      );
      expect(
        parsePatch(
          '*** Begin Patch\n*** Update File: file2.py\n import foo\n+bar\n'
          '*** End Patch',
        ).hunks,
        [
          UpdateFileHunk(
            'file2.py',
            chunks: [
              UpdateFileChunk(
                oldLines: ['import foo'],
                newLines: ['import foo', 'bar'],
                contextLineIndices: [(0, 0)],
              ),
            ],
          ),
        ],
      );
    });

    test('end-of-file marker kept', () {
      expect(
        parsePatch(
          '*** Begin Patch\n*** Update File: file.txt\n@@\n+quux\n'
          '*** End of File\n\n*** End Patch',
        ).hunks,
        [
          UpdateFileHunk(
            'file.txt',
            chunks: [
              UpdateFileChunk(newLines: ['quux'], isEndOfFile: true),
            ],
          ),
        ],
      );
    });

    test('heredoc wrapper (lenient mode)', () {
      final args = parsePatch(
        "<<'EOF'\n*** Begin Patch\n*** Add File: a\n+x\n*** End Patch\nEOF\n",
      );
      expect(args.hunks, [AddFileHunk('a', 'x\n')]);
      expect(args.patch, '*** Begin Patch\n*** Add File: a\n+x\n*** End Patch');
    });

    test('invalid hunk header message', () {
      expect(
        () => parsePatch(
          '*** Begin Patch\n*** Frobnicate File: foo\n*** End Patch',
        ),
        throwsA(
          const PatchParseError.hunk(
            "'*** Frobnicate File: foo' is not a valid hunk header. Valid hunk "
            "headers: '*** Add File: {path}', '*** Delete File: {path}', "
            "'*** Update File: {path}'",
            2,
          ),
        ),
      );
    });
  });

  group('seek_sequence (seek_sequence.rs tests)', () {
    test('exact', () {
      expect(
        seekSequence(['foo', 'bar', 'baz'], ['bar', 'baz'], 0, eof: false),
        1,
      );
    });
    test('rstrip', () {
      expect(
        seekSequence(['foo   ', 'bar\t\t'], ['foo', 'bar'], 0, eof: false),
        0,
      );
    });
    test('trim', () {
      expect(
        seekSequence(['    foo   ', '   bar\t'], ['foo', 'bar'], 0, eof: false),
        0,
      );
    });
    test('pattern longer than input', () {
      expect(
        seekSequence(
          ['just one line'],
          ['too', 'many', 'lines'],
          0,
          eof: false,
        ),
        isNull,
      );
    });
    test('unicode punctuation normalised', () {
      expect(seekSequence(['a – b “q”'], ['a - b "q"'], 0, eof: false), 0);
    });
  });

  group('application (lib.rs tests)', () {
    late Directory dir;
    final fs = LocalPatchFs();
    setUp(() => dir = newDataDir());
    tearDown(() => dir.deleteSync(recursive: true));

    test('add file: summary uses the patch spelling', () async {
      final path = '${dir.path}/add.txt';
      final r = await applyPatchStandalone(
        wrap('*** Add File: $path\n+ab\n+cd'),
        dir.path,
        fs,
      );
      expect(r.stdout, 'Success. Updated the following files:\nA $path\n');
      expect(r.stderr, '');
      expect(File(path).readAsStringSync(), 'ab\ncd\n');
    });

    test('relative and absolute paths; A, M, D order', () async {
      void w(String n, String c) => File('${dir.path}/$n').writeAsStringSync(c);
      w('relative-delete.txt', 'delete relative\n');
      w('absolute-delete.txt', 'delete absolute\n');
      w('relative-update.txt', 'relative old\n');
      w('absolute-update.txt', 'absolute old\n');
      final d = dir.path;
      final r = await applyPatchStandalone(
        wrap(
          '*** Add File: relative-add.txt\n+relative add\n'
          '*** Add File: $d/absolute-add.txt\n+absolute add\n'
          '*** Delete File: relative-delete.txt\n'
          '*** Delete File: $d/absolute-delete.txt\n'
          '*** Update File: relative-update.txt\n@@\n-relative old\n+relative new\n'
          '*** Update File: $d/absolute-update.txt\n@@\n-absolute old\n+absolute new',
        ),
        d,
        fs,
      );
      expect(
        r.stdout,
        'Success. Updated the following files:\nA relative-add.txt\n'
        'A $d/absolute-add.txt\nM relative-update.txt\nM $d/absolute-update.txt\n'
        'D relative-delete.txt\nD $d/absolute-delete.txt\n',
      );
      expect(
        File('$d/relative-update.txt').readAsStringSync(),
        'relative new\n',
      );
      expect(File('$d/absolute-delete.txt').existsSync(), isFalse);
    });

    test('move', () async {
      File('${dir.path}/src.txt').writeAsStringSync('line\n');
      final r = await applyPatchStandalone(
        wrap(
          '*** Update File: src.txt\n*** Move to: dst.txt\n@@\n-line\n+line2',
        ),
        dir.path,
        fs,
      );
      expect(r.stdout, 'Success. Updated the following files:\nM dst.txt\n');
      expect(File('${dir.path}/src.txt').existsSync(), isFalse);
      expect(File('${dir.path}/dst.txt').readAsStringSync(), 'line2\n');
    });

    test('interleaved chunks with an end-of-file addition', () async {
      final p = '${dir.path}/interleaved.txt';
      File(p).writeAsStringSync('a\nb\nc\nd\ne\nf\n');
      await applyPatchStandalone(
        wrap(
          '*** Update File: $p\n@@\n a\n-b\n+B\n@@\n c\n d\n-e\n+E\n@@\n f\n+g\n'
          '*** End of File',
        ),
        dir.path,
        fs,
      );
      expect(File(p).readAsStringSync(), 'a\nB\nc\nd\nE\nf\ng\n');
    });

    test('pure addition chunk followed by a removal', () async {
      final p = '${dir.path}/panic.txt';
      File(p).writeAsStringSync('line1\nline2\nline3\n');
      await applyPatchStandalone(
        wrap(
          '*** Update File: $p\n@@\n+after-context\n+second-line\n@@\n line1\n'
          '-line2\n-line3\n+line2-replacement',
        ),
        dir.path,
        fs,
      );
      expect(
        File(p).readAsStringSync(),
        'line1\nline2-replacement\nafter-context\nsecond-line\n',
      );
    });

    test('unicode dash in the file, ASCII in the patch', () async {
      final p = '${dir.path}/unicode.py';
      File(p).writeAsStringSync(
        'import asyncio  # local import – avoids top‑level dep\n',
      );
      await applyPatchStandalone(
        wrap(
          '*** Update File: $p\n@@\n-import asyncio  # local import - avoids '
          'top-level dep\n+import asyncio  # HELLO',
        ),
        dir.path,
        fs,
      );
      expect(File(p).readAsStringSync(), 'import asyncio  # HELLO\n');
    });

    test('a parse error goes to stderr', () async {
      final r = await applyPatchStandalone('nope', dir.path, fs);
      expect(r.exitCode, 1);
      expect(
        r.stderr,
        "Invalid patch: The first line of the patch must be '*** Begin Patch'\n",
      );
    });
  });

  group('the apply_patch tool (verification first)', () {
    late Directory dir;
    final fs = LocalPatchFs();
    setUp(() => dir = newDataDir());
    tearDown(() => dir.deleteSync(recursive: true));

    String fmt(PatchRun run, Duration _) =>
        'Exit code: ${run.exitCode}\nOutput:\n${run.stdout}${run.stderr}';

    test('success', () async {
      File('${dir.path}/a.txt').writeAsStringSync('x\n');
      final t = await runApplyPatchTool(
        wrap('*** Update File: a.txt\n@@\n-x\n+y'),
        dir.path,
        fs,
        format: fmt,
      );
      expect(t.error, isFalse);
      expect(
        t.text,
        'Exit code: 0\nOutput:\nSuccess. Updated the following files:\nM a.txt\n',
      );
    });

    test('a failing hunk changes nothing (unlike the executable)', () async {
      final t = await runApplyPatchTool(
        wrap(
          '*** Add File: created.txt\n+hello\n*** Update File: missing.txt\n@@\n-old\n+new',
        ),
        dir.path,
        fs,
        format: fmt,
      );
      expect(t.error, isTrue);
      expect(
        t.text,
        'apply_patch verification failed: Failed to read file to update '
        '${dir.path}/missing.txt: No such file or directory (os error 2)',
      );
      expect(File('${dir.path}/created.txt').existsSync(), isFalse);
    });

    test('missing context', () async {
      File('${dir.path}/a.txt').writeAsStringSync('one\ntwo\n');
      final t = await runApplyPatchTool(
        wrap('*** Update File: a.txt\n@@\n-three\n+four'),
        dir.path,
        fs,
        format: fmt,
      );
      expect(
        t.text,
        'apply_patch verification failed: Failed to find expected lines in '
        '${dir.path}/a.txt:\nthree',
      );
    });

    test('two operations on one file', () async {
      final t = await runApplyPatchTool(
        wrap('*** Add File: a.txt\n+x\n*** Add File: a.txt\n+y'),
        dir.path,
        fs,
        format: fmt,
      );
      expect(
        t.text,
        'apply_patch verification failed: invalid patch: multiple operations '
        'target ${dir.path}/a.txt',
      );
    });

    test('parse error', () async {
      final t = await runApplyPatchTool(
        '*** Begin Patch\n',
        dir.path,
        fs,
        format: fmt,
      );
      expect(
        t.text,
        "apply_patch verification failed: invalid patch: The last line of the "
        "patch must be '*** End Patch'",
      );
    });
  });

  group('SandboxPatchFileSystem scripts (run by a local bash)', () {
    late Directory dir;
    late SandboxPatchFileSystem fs;
    setUp(() {
      dir = newDataDir();
      fs = SandboxPatchFileSystem((script) async {
        // As shellctl: the script arrives in a body, not as an argument.
        final p = await Process.start('bash', ['-s']);
        p.stdin.write('{\n$script\n} 2>&1\n');
        await p.stdin.close();
        final out = await p.stdout
            .transform(const SystemEncoding().decoder)
            .join();
        await p.stderr.drain<void>();
        return (exitCode: await p.exitCode, output: out);
      });
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('read, write, create, remove, metadata', () async {
      final p = '${dir.path}/sub/f.txt';
      await expectLater(fs.readText(p), throwsA(PatchIoError.missing));
      await expectLater(
        fs.writeText(p, 'x'),
        throwsA(
          isA<PatchIoError>().having((e) => e.notFound, 'notFound', true),
        ),
      );
      await fs.createDirectories('${dir.path}/sub');
      await fs.writeText(p, 'héllo\r\nworld\n');
      expect(await fs.readText(p), 'héllo\r\nworld\n');
      expect((await fs.metadata(p)).isFile, isTrue);
      expect((await fs.metadata('${dir.path}/sub')).isDirectory, isTrue);
      await expectLater(
        fs.readText('${dir.path}/sub'),
        throwsA(PatchIoError.isDirectory),
      );
      await fs.writeText(p, '');
      expect(await fs.readText(p), '');
      await fs.remove(p);
      expect(File(p).existsSync(), isFalse);
      await expectLater(fs.remove(p), throwsA(PatchIoError.missing));
    });

    test('large content is written in chunks', () async {
      final p = '${dir.path}/big.txt';
      final text = List.generate(40000, (i) => 'line $i').join('\n');
      await fs.writeText(p, text);
      expect(File(p).readAsStringSync(), text);
      expect(await fs.readText(p), text);
    });

    test('a scenario through the scripts', () async {
      File('${dir.path}/a.txt').writeAsStringSync('one\ntwo\nthree\n');
      final r = await applyPatchStandalone(
        wrap(
          '*** Update File: a.txt\n*** Move to: moved/b.txt\n@@\n one\n-two\n+2\n'
          '*** Add File: new/c.txt\n+c',
        ),
        dir.path,
        fs,
      );
      expect(r.stderr, '');
      expect(
        File('${dir.path}/moved/b.txt').readAsStringSync(),
        'one\n2\nthree\n',
      );
      expect(File('${dir.path}/new/c.txt').readAsStringSync(), 'c\n');
      expect(File('${dir.path}/a.txt').existsSync(), isFalse);
    });
  });
}
