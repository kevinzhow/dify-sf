import 'dart:async';

import 'package:dify_sf_app/src/auth/auth_api.dart';
import 'package:dify_sf_app/src/auth/auth_controller.dart';

/// An in-memory accounts server for the pages' widget tests (collab_client's RecordingAuthApi drives the editors' fakes;
/// this one records every call, for the ported Dify specs' payload checks): setup, login (same answer for an unknown email and a wrong
/// password), refresh rotation, logout, invitations. Every call is recorded in [calls]; [hold] makes the next calls of
/// a kind wait until the completer completes.
class RecordingAuthApi implements AuthApi {
  RecordingAuthApi({this.setupDone = true});

  bool setupDone;
  final accounts = <String, ({Account account, String? password})>{};
  final invitations = <String, ({String email, String role})>{};
  final sessions = <String, String>{}; // access token -> account id
  final refreshTokens = <String, String>{}; // refresh token -> account id
  final calls = <(String, Map<String, Object?>)>[];
  final hold = <String, Completer<void>>{};
  var _n = 0;

  /// Answers to invitation checks that replace the computed one (e.g. an active account's invitation).
  final checkAnswers = <String, InvitationCheck>{};

  /// The workspace's name in invitation checks.
  String workspaceName = 'Acme';

  /// Forgot password: whether the server sends mail, the token a sent code answers, the right code and the token it
  /// answers, and errors to throw instead (by call name: `sendResetCode`, `checkResetCode`, `resetPassword`,
  /// `resetPasswordLink`).
  bool emailSetup = false;
  String resetToken = 'reset-token';
  String resetCode = '123456';
  String verifiedToken = 'verified-token';
  final failures = <String, TransportException>{};

  Account addAccount({
    required String email,
    String name = 'User',
    String password = 'Password123',
    String role = AccountRole.owner,
    String? id,
  }) {
    final a = Account(id: id ?? 'acc-${++_n}', email: email, name: name, role: role);
    accounts[email.toLowerCase()] = (account: a, password: password);
    setupDone = true;
    return a;
  }

  String addInvitation(String email, {String role = AccountRole.normal}) {
    final token = 'inv-${++_n}';
    invitations[token] = (email: email, role: role);
    return token;
  }

  Future<void> _call(String name, [Map<String, Object?> args = const {}]) async {
    calls.add((name, args));
    final h = hold[name];
    if (h != null) await h.future;
  }

  AuthResult _session(Account a) {
    final access = 'at-${++_n}', refresh = 'rt-$_n';
    sessions[access] = a.id;
    refreshTokens[refresh] = a.id;
    return AuthResult(
      tokens: AuthTokens(accessToken: access, refreshToken: refresh),
      account: a,
    );
  }

  static const _unauthorized = TransportException('unauthorized', statusCode: 401, code: 'unauthorized');

  @override
  Future<String> setupStatus() async {
    await _call('setupStatus');
    return setupDone ? 'finished' : 'not_started';
  }

  @override
  Future<AuthResult> setup({
    required String email,
    required String name,
    required String password,
    String? language,
    String? timezone,
  }) async {
    await _call('setup', {'email': email, 'name': name, 'password': password, 'language': language});
    if (setupDone) throw const TransportException('setup is done', statusCode: 409, code: 'setup_done');
    return _session(addAccount(email: email, name: name, password: password));
  }

  @override
  Future<AuthResult> login({
    required String email,
    required String password,
    bool rememberMe = false,
    String? inviteToken,
  }) async {
    await _call('login', {'email': email, 'password': password, 'invite_token': inviteToken});
    final e = accounts[email.toLowerCase()];
    if (e == null || e.password != password) {
      throw const TransportException('Invalid email or password.', statusCode: 401, code: 'invalid_credentials');
    }
    return _session(e.account);
  }

  @override
  Future<AuthTokens> refresh(String refreshToken) async {
    await _call('refresh', {'refresh_token': refreshToken});
    final id = refreshTokens.remove(refreshToken);
    if (id == null) throw _unauthorized;
    final a = accounts.values.firstWhere((e) => e.account.id == id).account;
    return _session(a).tokens;
  }

  @override
  Future<void> logout(String accessToken) async {
    await _call('logout', {'token': accessToken});
    sessions.remove(accessToken);
  }

  @override
  Future<Account> account(String accessToken) async {
    await _call('account', {'token': accessToken});
    final id = sessions[accessToken];
    if (id == null) throw _unauthorized;
    return accounts.values.firstWhere((e) => e.account.id == id).account;
  }

  @override
  Future<InvitationCheck> checkInvitation(String token) async {
    await _call('checkInvitation', {'token': token});
    final answer = checkAnswers[token];
    if (answer != null) return answer;
    final i = invitations[token];
    return i == null
        ? const InvitationCheck(isValid: false)
        : InvitationCheck(isValid: true, email: i.email, workspaceName: workspaceName);
  }

  @override
  Future<AuthResult> activate({
    required String token,
    required String name,
    required String password,
    String? interfaceLanguage,
    String? timezone,
  }) async {
    await _call('activate', {
      'token': token,
      'name': name,
      'password': password,
      'interface_language': ?interfaceLanguage,
      'timezone': ?timezone,
    });
    final i = invitations.remove(token);
    if (i == null) {
      throw const TransportException('The token is invalid or has expired.', statusCode: 400, code: 'invalid_token');
    }
    return _session(addAccount(email: i.email, name: name, password: password, role: i.role));
  }

  @override
  Future<Account> updateName(String accessToken, String name) => throw UnimplementedError();

  @override
  Future<void> updatePassword(
    String accessToken, {
    required String password,
    required String newPassword,
    required String repeatNewPassword,
  }) => throw UnimplementedError();

  @override
  Future<List<Member>> members(String accessToken) => throw UnimplementedError();

  @override
  Future<List<InvitationResult>> invite(String accessToken, {required List<String> emails, required String role}) =>
      throw UnimplementedError();

  @override
  Future<void> updateRole(String accessToken, String memberId, String role) => throw UnimplementedError();

  @override
  Future<void> removeMember(String accessToken, String memberId) => throw UnimplementedError();

  Future<void> _maybeFail(String name) async {
    final e = failures[name];
    if (e != null) throw e;
  }

  @override
  Future<SystemFeatures> systemFeatures() async {
    await _call('systemFeatures');
    return SystemFeatures(isEmailSetup: emailSetup);
  }

  @override
  Future<String> sendResetCode({required String email, String? language}) async {
    await _call('sendResetCode', {'email': email, 'language': language});
    await _maybeFail('sendResetCode');
    return resetToken;
  }

  @override
  Future<ResetCodeCheck> checkResetCode({required String email, required String code, required String token}) async {
    await _call('checkResetCode', {'email': email, 'code': code, 'token': token});
    await _maybeFail('checkResetCode');
    if (code != resetCode) {
      throw const TransportException('Email code is invalid or expired.', statusCode: 400, code: 'email_code_error');
    }
    return ResetCodeCheck(isValid: true, email: email.toLowerCase(), token: verifiedToken);
  }

  @override
  Future<void> resetPassword({
    required String token,
    required String newPassword,
    required String passwordConfirm,
  }) async {
    await _call('resetPassword', {'token': token, 'new_password': newPassword, 'password_confirm': passwordConfirm});
    await _maybeFail('resetPassword');
  }

  @override
  Future<PasswordResetLink> resetPasswordLink(String accessToken, String memberId) async {
    await _call('resetPasswordLink', {'member': memberId});
    if (sessions[accessToken] == null) throw _unauthorized;
    await _maybeFail('resetPasswordLink');
    return PasswordResetLink(url: '/reset-password/set-password?token=link-$memberId');
  }

  /// The names of the calls made, in order.
  List<String> get callNames => [for (final c in calls) c.$1];
}

/// A controller signed in as [role] on [api] (a fresh [RecordingAuthApi] by default).
Future<AuthController> signedInAuth({
  String role = AccountRole.owner,
  String name = 'Kim',
  String email = 'kim@example.com',
  RecordingAuthApi? api,
}) async {
  final fake = api ?? RecordingAuthApi();
  fake.addAccount(email: email, name: name, role: role);
  final auth = AuthController.on(server: 'http://test', api: fake, store: MemoryTokenStore());
  await auth.signIn(email: email, password: 'Password123');
  return auth;
}
