import 'dart:convert';
import 'dart:io';

import '../client/durable.dart';
import '../client/store.dart';

/// A [DurableStore] backed by one JSON file, written atomically (temp file, fsync, rename) so a crash leaves
/// either the old or the new state, never a torn one.
class FileStore implements DurableStore {
  FileStore(this.path);

  final String path;

  @override
  Future<ClientDurable?> load() async {
    final file = File(path);
    if (!file.existsSync()) return null;
    // A corrupt journal must not be silently ignored: that would turn "resend my edits" into "forget them".
    return ClientDurable.fromJson(jsonDecode(await file.readAsString()));
  }

  @override
  Future<void> save(ClientDurable state) async {
    final tmp = File('$path.tmp');
    await tmp.parent.create(recursive: true);
    final raf = await tmp.open(mode: FileMode.write);
    try {
      await raf.writeFrom(utf8.encode(jsonEncode(state.toJson())));
      await raf.flush(); // fsync
    } finally {
      await raf.close();
    }
    await tmp.rename(path);
  }
}

/// Hands out journal files to live client instances of one machine. Each instance claims the lowest free
/// slot `<doc>.slot-<n>.json` by holding an exclusive OS lock on `<doc>.slot-<n>.lock` for its lifetime, so
/// two windows never share a journal (and so never a client id), while a restarted window finds the journal
/// of the one that crashed: the OS drops a dead process's lock.
class FileJournalDirectory {
  FileJournalDirectory(this.directory);

  final String directory;

  /// Locks held by this process (POSIX file locks are per process, so they cannot tell two sessions of one
  /// process apart).
  static final Set<String> _heldHere = {};

  Future<JournalSlot> acquire(String docId, {int maxSlots = 256}) async {
    await Directory(directory).create(recursive: true);
    for (var n = 0; n < maxSlots; n++) {
      final base = '$directory/$docId.slot-$n';
      if (_heldHere.contains(base)) continue;
      final lock = await File('$base.lock').open(mode: FileMode.write);
      try {
        await lock.lock(FileLock.exclusive); // throws if another process holds it
      } on FileSystemException {
        await lock.close();
        continue;
      }
      _heldHere.add(base);
      return _FileSlot(base, lock);
    }
    throw StateError('no free journal slot for $docId in $directory');
  }
}

class _FileSlot extends FileStore implements JournalSlot {
  _FileSlot(this._base, this._lock) : super('$_base.json');

  final String _base;
  final RandomAccessFile _lock;

  @override
  String get description => '$_base.json';

  @override
  Future<void> release() async {
    FileJournalDirectory._heldHere.remove(_base);
    await _lock.unlock();
    await _lock.close();
  }
}
