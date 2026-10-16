import '../client/store.dart';
import 'file_store.dart';

DurableStore create({required String name, String? directory}) {
  if (directory == null) throw ArgumentError.notNull('directory');
  return FileStore('$directory/$name.json');
}

Future<JournalSlot> acquireJournal({required String docId, String? directory}) {
  if (directory == null) throw ArgumentError.notNull('directory');
  return FileJournalDirectory(directory).acquire(docId);
}
