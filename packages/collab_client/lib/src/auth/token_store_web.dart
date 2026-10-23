import 'dart:convert';

import 'package:web/web.dart' as web;

import 'account.dart';
import 'token_store.dart';

TokenStore platformTokenStore({String? directory}) => LocalStorageTokenStore();

/// [AuthTokens] in the browser's `localStorage`, one key per server (see [TokenStore] for the trade-off against Dify's
/// HttpOnly cookies).
class LocalStorageTokenStore implements TokenStore {
  LocalStorageTokenStore({this.prefix = 'dify-sf/tokens/'});

  final String prefix;

  @override
  Future<AuthTokens?> read(String server) async {
    final raw = web.window.localStorage.getItem('$prefix$server');
    if (raw == null) return null;
    try {
      return AuthTokens.fromJson(jsonDecode(raw));
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> write(String server, AuthTokens tokens) async =>
      web.window.localStorage.setItem('$prefix$server', jsonEncode(tokens.toJson()));

  @override
  Future<void> clear(String server) async => web.window.localStorage.removeItem('$prefix$server');
}

/// Not in the browser.
class FileTokenStore implements TokenStore {
  FileTokenStore(this.directory);

  final String directory;

  static Never _io() => throw UnsupportedError('files are not available in the browser');

  @override
  Future<AuthTokens?> read(String server) async => _io();

  @override
  Future<void> write(String server, AuthTokens tokens) async => _io();

  @override
  Future<void> clear(String server) async => _io();
}
