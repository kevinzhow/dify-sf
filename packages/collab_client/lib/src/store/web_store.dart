import 'dart:convert';

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
