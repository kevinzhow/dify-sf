import 'dart:convert';
import 'dart:math';

import 'package:web/web.dart' as web;

import '../client/durable.dart';
import '../client/store.dart';

/// A [DurableStore] backed by the browser's `localStorage` (synchronous, so the write has reached the
/// browser's storage layer when [save] completes; survives reloads and tab crashes). Quota is a few MB,
/// plenty for an outbox of small ops.
class LocalStorageStore implements DurableStore {
  LocalStorageStore(this.key);

  final String key;

  @override
  Future<ClientDurable?> load() async {
    final raw = web.window.localStorage.getItem(key);
    return raw == null ? null : ClientDurable.fromJson(jsonDecode(raw));
  }

  @override
  Future<void> save(ClientDurable state) async {
    web.window.localStorage.setItem(key, jsonEncode(state.toJson()));
  }
}

/// One journal per browser tab: the slot id lives in `sessionStorage` (it survives a reload of the same tab,
/// and is not shared with other tabs), the journal in `localStorage`. A duplicated tab copies the
/// `sessionStorage` and would share the slot; the server then answers `clientIdInUse` and the client moves to
/// a new id (protocol 1.1). A journal left by a closed tab is not adopted by others (a Web Locks based
/// scheme could; see docs/client.md).
Future<JournalSlot> acquireTabJournal(String docId) async {
  final key = 'dify-sf/$docId/slot';
  var slot = web.window.sessionStorage.getItem(key);
  if (slot == null) {
    slot = List.generate(12, (_) => Random.secure().nextInt(16).toRadixString(16)).join();
    web.window.sessionStorage.setItem(key, slot);
  }
  return _TabSlot('dify-sf/$docId/$slot');
}

class _TabSlot extends LocalStorageStore implements JournalSlot {
  _TabSlot(super.key);

  @override
  String get description => 'localStorage[$key]';

  @override
  Future<void> release() async {}
}
