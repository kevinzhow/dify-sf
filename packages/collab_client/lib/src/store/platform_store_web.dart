import '../client/store.dart';
import 'web_store.dart';

DurableStore create({required String name, String? directory}) => LocalStorageStore('dify-sf/$name');

Future<JournalSlot> acquireJournal({required String docId, String? directory}) => acquireTabJournal(docId);
