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
