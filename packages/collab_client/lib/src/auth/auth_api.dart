import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../client/transport.dart';
import 'account.dart';

/// The account endpoints of a dify-sf server (docs/protocol.md section 2 "Accounts", protocol 1.8), one request per call.
///
/// Public calls ([setupStatus], [setup], [login], [refresh], [checkInvitation], [activate]) need no token; the others take
/// the caller's access token as their first argument. Apps normally use [AuthSession] instead, which keeps the tokens,
/// refreshes them and offers the same calls without token arguments.
///
/// Failures throw a `TransportException` with the HTTP status and the server's error code: `invalid_credentials` (401,
/// login: unknown email or wrong password, one answer for both), `login_rate_limited` (429), `account_banned` (403),
/// `setup_done` (409), `invalid_password` / `invalid_token` / `invalid_role` / `cannot_operate_self` (400), `forbidden`
/// (403: the role does not allow it), `unauthorized` (401: the access or refresh token is not valid).
///
/// Implementations: [HttpAuthApi] (a real server) and `FakeAuthApi` (`package:collab_client/testing.dart`, in memory).
abstract interface class AuthApi {
  /// `GET /v1/setup`: [SetupStatus.notStarted] or [SetupStatus.finished] (Dify's install page shows while not started).
  Future<String> setupStatus();

  /// `POST /v1/setup`: installs the workspace with this account as its owner (only while no account exists, else
  /// `409 setup_done`). [name]: 1-30 characters; [password]: Dify's rule (8+ characters with a letter and a digit);
  /// [language]: the interface language (Dify's `language`).
  Future<AuthResult> setup({
    required String email,
    required String name,
    required String password,
    String? language,
    String? timezone,
  });

  /// `POST /v1/auth/login`. [inviteToken]: Dify's way in for an invited account that has no password yet (the given
  /// password becomes its password). [rememberMe] is accepted by the server and has no effect.
  Future<AuthResult> login({
    required String email,
    required String password,
    bool rememberMe = false,
    String? inviteToken,
  });

  /// `POST /v1/auth/refresh`: a new pair; [refreshToken] is spent (rotation). `401 unauthorized` if it is not valid.
  Future<AuthTokens> refresh(String refreshToken);

  /// `POST /v1/auth/logout`: revokes every token of the session of [accessToken].
  Future<void> logout(String accessToken);

  /// `GET /v1/account`.
  Future<Account> account(String accessToken);

  /// `PUT /v1/account/name` (3-30 characters).
  Future<Account> updateName(String accessToken, String name);

  /// `PUT /v1/account/password`.
  Future<void> updatePassword(
    String accessToken, {
    required String password,
    required String newPassword,
    required String repeatNewPassword,
  });

  /// `GET /v1/workspace/members`: owner first.
  Future<List<Member>> members(String accessToken);

  /// `POST /v1/workspace/members/invite-email` (owner and admins): one result per email, each successful one with its
  /// activation link ([InvitationResult.url], relative to the web app; there is no mail server).
  Future<List<InvitationResult>> invite(String accessToken, {required List<String> emails, required String role});

  /// `PUT /v1/workspace/members/{id}/update-role` (owner and admins; never the owner, never oneself).
  Future<void> updateRole(String accessToken, String memberId, String role);

  /// `DELETE /v1/workspace/members/{id}` (owner and admins; never the owner, never oneself).
  Future<void> removeMember(String accessToken, String memberId);

  /// `POST /v1/activate/check`: whether an invitation link is still good, and for which email and workspace.
  Future<InvitationCheck> checkInvitation(String token);

  /// `POST /v1/activate`: accepts an invitation (sets the name and password) and signs in.
  Future<AuthResult> activate({
    required String token,
    required String name,
    required String password,
    String? interfaceLanguage,
    String? timezone,
  });
}

/// [AuthApi] against a real server at [baseUrl].
class HttpAuthApi implements AuthApi {
  HttpAuthApi(this.baseUrl, {http.Client? client, this.timeout = const Duration(seconds: 10)})
    : _client = client ?? http.Client(),
      _ownsClient = client == null;

  final Uri baseUrl;
  final Duration timeout;
  final http.Client _client;
  final bool _ownsClient;

  Uri _url(String path) {
    final base = baseUrl.path.endsWith('/') ? baseUrl.path.substring(0, baseUrl.path.length - 1) : baseUrl.path;
    return baseUrl.replace(path: '$base$path');
  }

  @override
  Future<String> setupStatus() async {
    final json = await _send('GET', '/v1/setup', ok: 200) as Map<String, Object?>;
    return json['step'] == SetupStatus.notStarted ? SetupStatus.notStarted : SetupStatus.finished;
  }

  @override
  Future<AuthResult> setup({
    required String email,
    required String name,
    required String password,
    String? language,
    String? timezone,
  }) async => AuthResult.fromJson(
    await _send(
      'POST',
      '/v1/setup',
      ok: 201,
      body: {
        'email': email,
        'name': name,
        'password': password,
        'interface_language': ?language,
        'timezone': ?timezone,
      },
    ),
  );

  @override
  Future<AuthResult> login({
    required String email,
    required String password,
    bool rememberMe = false,
    String? inviteToken,
  }) async => AuthResult.fromJson(
    await _send(
      'POST',
      '/v1/auth/login',
      ok: 200,
      body: {'email': email, 'password': password, 'remember_me': rememberMe, 'invite_token': ?inviteToken},
    ),
  );

  @override
  Future<AuthTokens> refresh(String refreshToken) async =>
      AuthTokens.fromJson(await _send('POST', '/v1/auth/refresh', ok: 200, body: {'refresh_token': refreshToken}));

  @override
  Future<void> logout(String accessToken) => _send('POST', '/v1/auth/logout', ok: 204, token: accessToken);

  @override
  Future<Account> account(String accessToken) async =>
      Account.fromJson(await _send('GET', '/v1/account', ok: 200, token: accessToken));

  @override
  Future<Account> updateName(String accessToken, String name) async =>
      Account.fromJson(await _send('PUT', '/v1/account/name', ok: 200, token: accessToken, body: {'name': name}));

  @override
  Future<void> updatePassword(
    String accessToken, {
    required String password,
    required String newPassword,
    required String repeatNewPassword,
  }) => _send(
    'PUT',
    '/v1/account/password',
    ok: 204,
    token: accessToken,
    body: {'password': password, 'new_password': newPassword, 'repeat_new_password': repeatNewPassword},
  );

  @override
  Future<List<Member>> members(String accessToken) async {
    final json = await _send('GET', '/v1/workspace/members', ok: 200, token: accessToken) as Map<String, Object?>;
    final list = json['accounts'];
    if (list is! List<Object?>) throw const TransportException('malformed member list');
    return [for (final m in list) Member.fromJson(m)];
  }

  @override
  Future<List<InvitationResult>> invite(
    String accessToken, {
    required List<String> emails,
    required String role,
  }) async {
    final json = await _send(
      'POST',
      '/v1/workspace/members/invite-email',
      ok: 201,
      token: accessToken,
      body: {'emails': emails, 'role': role},
    ) as Map<String, Object?>;
    final list = json['invitation_results'];
    if (list is! List<Object?>) throw const TransportException('malformed invitation results');
    return [for (final r in list) InvitationResult.fromJson(r)];
  }

  @override
  Future<void> updateRole(String accessToken, String memberId, String role) => _send(
    'PUT',
    '/v1/workspace/members/${Uri.encodeComponent(memberId)}/update-role',
    ok: 200,
    token: accessToken,
    body: {'role': role},
  );

  @override
  Future<void> removeMember(String accessToken, String memberId) =>
      _send('DELETE', '/v1/workspace/members/${Uri.encodeComponent(memberId)}', ok: 200, token: accessToken);

  @override
  Future<InvitationCheck> checkInvitation(String token) async =>
      InvitationCheck.fromJson(await _send('POST', '/v1/activate/check', ok: 200, body: {'token': token}));

  @override
  Future<AuthResult> activate({
    required String token,
    required String name,
    required String password,
    String? interfaceLanguage,
    String? timezone,
  }) async => AuthResult.fromJson(
    await _send(
      'POST',
      '/v1/activate',
      ok: 200,
      body: {
        'token': token,
        'name': name,
        'password': password,
        'interface_language': ?interfaceLanguage,
        'timezone': ?timezone,
      },
    ),
  );

  Future<Object?> _send(
    String method,
    String path, {
    required int ok,
    Map<String, Object?>? body,
    String? token,
  }) async {
    final req = http.Request(method, _url(path));
    if (token != null) req.headers['Authorization'] = 'Bearer $token';
    if (body != null) {
      req
        ..headers['Content-Type'] = 'application/json'
        ..body = jsonEncode(body);
    }
    final http.Response res;
    try {
      res = await http.Response.fromStream(await _client.send(req).timeout(timeout)).timeout(timeout);
    } on TimeoutException {
      throw TransportException('$method $path timed out', timeout: true);
    } on Object catch (e) {
      throw TransportException('$method $path failed: $e');
    }
    if (res.statusCode != ok) throw transportErrorOf(res.statusCode, utf8.decode(res.bodyBytes, allowMalformed: true));
    if (res.statusCode == 204 || res.bodyBytes.isEmpty) return null;
    try {
      return jsonDecode(utf8.decode(res.bodyBytes));
    } on FormatException catch (e) {
      throw TransportException('malformed answer to $method $path: ${e.message}');
    }
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}

/// The `TransportException` for a non-2xx answer: the server's `{"error":{"code","message"}}` when it sent one.
TransportException transportErrorOf(int status, String body) {
  try {
    final e = (jsonDecode(body) as Map<String, Object?>)['error']! as Map<String, Object?>;
    return TransportException('${e['message']}', statusCode: status, code: e['code'] as String?);
  } on Object {
    return TransportException('HTTP $status', statusCode: status);
  }
}
