import 'dart:convert';

import 'package:crypto/crypto.dart';

/// A native client connects to a server origin, never a console/API path or a URL carrying credentials.
enum ServerAddressProblem { empty, invalidOrigin }

/// Android installations start with a connection picker unless the distributor sets an origin at build time.
String nativeDefaultServer({
  required bool android,
  String configured = const String.fromEnvironment('DIFYSF_SERVER_URL'),
}) => configured.trim().isNotEmpty
    ? configured.trim()
    : android
    ? ''
    : 'http://localhost:8080';

class ServerAddressException implements Exception {
  const ServerAddressException(this.problem);
  final ServerAddressProblem problem;

  @override
  String toString() => 'Invalid server address (${problem.name})';
}

String normalizeServerAddress(String value) {
  final text = value.trim();
  if (text.isEmpty) throw const ServerAddressException(ServerAddressProblem.empty);
  final uri = Uri.tryParse(text);
  if (uri == null ||
      RegExp(r'\s').hasMatch(text) ||
      !const ['http', 'https'].contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      (uri.path.isNotEmpty && uri.path != '/') ||
      uri.hasQuery ||
      uri.hasFragment ||
      uri.port < 1 ||
      uri.port > 65535) {
    throw const ServerAddressException(ServerAddressProblem.invalidOrigin);
  }
  return uri.origin;
}

/// Bounded, file-safe and collision-resistant namespace for a server origin.
/// Paths and default ports never create a second identity for the same origin.
String serverStorageKey(String server) => 'origin-${sha256.convert(utf8.encode(Uri.parse(server).origin))}';

/// Android starts with server-scoped journals. Existing desktop/browser journal
/// locations remain intact so this new platform does not strand their outboxes.
String androidJournalNamespace(String server, String accountKey) => '${serverStorageKey(server)}/$accountKey';
