import 'dart:math';

import 'package:clock/clock.dart';

import '../auth/account.dart';
import '../auth/auth_api.dart';
import '../client/transport.dart';
import 'fake_transport.dart';

/// A refusal of the in-memory accounts server, with the HTTP status and error code the real server would answer.
final class FakeAuthError implements Exception {
  const FakeAuthError(this.status, this.code, this.message);
  final int status;
  final String code;
  final String message;

  TransportException toTransport() => TransportException(message, statusCode: status, code: code);

  @override
  String toString() => 'FakeAuthError($status $code: $message)';
}

/// One account of a [FakeAccounts] workspace.
class FakeAccount {
  FakeAccount({
    required this.id,
    required this.email,
    required this.name,
    this.password,
    this.status = 'active',
    this.role,
    this.avatarUrl,
    this.interfaceLanguage,
    this.timezone,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? clock.now().toUtc();

  final String id;
  final String email;
  String name;

  /// Kept in plain text: this is a test double.
  String? password;
  String status;

  /// null = not a member (removed).
  String? role;
  String? avatarUrl;
  String? interfaceLanguage;
  String? timezone;
  final DateTime createdAt;
  DateTime? lastLoginAt;

  bool get canEdit => AccountRole.canEdit(role);

  Account toAccount() => Account(
    id: id,
    email: email,
    name: name,
    avatarUrl: avatarUrl,
    role: role ?? AccountRole.normal,
    interfaceLanguage: interfaceLanguage,
    timezone: timezone,
    createdAt: createdAt,
  );
}

class _Token {
  _Token(this.account, this.session, this.expires);
  final String account;
  final String session;
  final DateTime expires;
}

/// A mail the fake server "sent" (forgot password): the code, or null for the "no account" notice.
class FakeMail {
  const FakeMail({required this.to, required this.code, required this.language});
  final String to;
  final String? code;
  final String language;
}

class _Reset {
  _Reset(this.account, this.email, this.code, this.phase, this.expires);
  final String? account;
  final String email;
  final String? code;

  /// `verify`, `reset` or `link`.
  final String phase;
  final DateTime expires;
}

class _Invitation {
  _Invitation(this.account, this.email, this.expires);
  final String account;
  final String email;
  final DateTime expires;
  bool used = false;
}

/// The accounts of one in-memory server (protocol 1.8, docs/protocol.md "Accounts") with the reference server's rules:
/// setup once (the first account is the owner), email + password sign-in with one answer for unknown emails and wrong
/// passwords, Dify's login rate limit (more than [maxLoginFailures] failures lock the email), opaque tokens with refresh
/// rotation and per-session logout, roles, invitations with activation links, owner protection, and the
/// password and name rules.
///
/// Give it to a `FakeServer` / `HttpFakeServer` (`accounts:`) and every request needs a token; talk to it through
/// [FakeAuthApi] (or HTTP). Test helpers: [addMember] (an activated account), [signIn] (tokens without a password),
/// [expireAccessTokens] (to exercise refreshes).
///
/// Forgot password (docs/protocol.md "Password reset"): with [emailSetup] the codes "sent" are in [sentMails]; the send
/// interval, code expiry and wrong-code lockout are the server's (the per-IP mail limit is not modelled). Admins' reset
/// links work with or without mail.
class FakeAccounts {
  FakeAccounts({
    this.accessTtl = const Duration(minutes: 60),
    this.refreshTtl = const Duration(days: 30),
    this.maxLoginFailures = 5,
    this.lockout = const Duration(hours: 24),
    this.emailSetup = false,
    this.resetTokenTtl = const Duration(minutes: 5),
    this.resetSendInterval = const Duration(seconds: 60),
    this.maxResetCodeFailures = 5,
    this.resetLockout = const Duration(hours: 24),
    this.resetLinkTtl = const Duration(hours: 24),
    Random? random,
  }) : _random = random ?? Random(11);

  final Duration accessTtl;
  final Duration refreshTtl;
  final int maxLoginFailures;
  final Duration lockout;
  final Random _random;

  /// The server sends mail (`is_email_setup`).
  bool emailSetup;
  final Duration resetTokenTtl;
  final Duration resetSendInterval;
  final int maxResetCodeFailures;
  final Duration resetLockout;
  final Duration resetLinkTtl;

  /// Every forgot-password mail, in order.
  final List<FakeMail> sentMails = [];
  final Map<String, _Reset> _resets = {};
  final Map<String, DateTime> _lastResetMail = {};
  final Map<String, ({int count, DateTime until})> _codeFailures = {};

  final Map<String, FakeAccount> byId = {};
  final Map<String, _Token> _access = {};
  final Map<String, _Token> _refresh = {};
  final Map<String, _Invitation> _invitations = {};
  final Map<String, ({int count, DateTime until})> _failures = {};
  int _n = 0;

  /// Requests that reached this server (for assertions about refreshes).
  int requests = 0;
  int refreshes = 0;

  bool get isSetUp => byId.isNotEmpty;

  FakeAccount? byEmail(String email) {
    final key = email.trim().toLowerCase();
    for (final a in byId.values) {
      if (a.email.toLowerCase() == key) return a;
    }
    return null;
  }

  FakeAccount? get owner {
    for (final a in byId.values) {
      if (a.role == AccountRole.owner) return a;
    }
    return null;
  }

  String get workspaceName => owner == null ? 'Workspace' : "${owner!.name}'s Workspace";

  // ---- test helpers ------------------------------------------------------------------------------

  /// An activated member (the first one added is the owner unless [role] says otherwise).
  FakeAccount addMember({required String email, String? name, String password = 'password-1', String? role}) {
    final a = FakeAccount(
      id: _newId(),
      email: email,
      name: name ?? email.split('@').first,
      password: password,
      role: role ?? (owner == null ? AccountRole.owner : AccountRole.editor),
    );
    byId[a.id] = a;
    return a;
  }

  /// Tokens for [email] as if it had signed in (no password check).
  AuthResult signIn(String email) {
    final a = byEmail(email) ?? (throw ArgumentError('no account $email'));
    return _session(a);
  }

  /// Every access token expires now (refresh tokens stay valid): the next request is answered 401 and refreshes.
  void expireAccessTokens() {
    for (final k in _access.keys.toList()) {
      final t = _access[k]!;
      _access[k] = _Token(t.account, t.session, clock.now().subtract(const Duration(seconds: 1)));
    }
  }

  /// Every token of every session is revoked (the next refresh fails: everybody is signed out).
  void revokeAll() {
    _access.clear();
    _refresh.clear();
  }

  // ---- authentication ----------------------------------------------------------------------------

  /// The member behind [accessToken] (`401 unauthorized` otherwise), checked for [edit] / [privileged] (`403 forbidden`).
  FakeAccount principal(String? accessToken, {bool edit = false, bool privileged = false}) {
    final t = accessToken == null ? null : _access[accessToken];
    final a = t == null ? null : byId[t.account];
    if (t == null || a == null || !t.expires.isAfter(clock.now()) || a.role == null || a.status != 'active') {
      throw const FakeAuthError(401, 'unauthorized', 'invalid or expired access token');
    }
    if (edit && !a.canEdit) throw FakeAuthError(403, 'forbidden', 'the ${a.role} role cannot edit');
    if (privileged && !AccountRole.isPrivileged(a.role)) {
      throw const FakeAuthError(403, 'forbidden', 'only the workspace owner or an admin may do this');
    }
    return a;
  }

  String _sessionOf(String accessToken) => _access[accessToken]?.session ?? '';

  // ---- the endpoints (wire JSON, as the server answers) -----------------------------------------

  String setupStatus() => isSetUp ? SetupStatus.finished : SetupStatus.notStarted;

  Map<String, Object?> setup({Object? email, Object? name, Object? password, Object? language, Object? timezone}) {
    final e = _email(email), n = _name(name), p = _password(password);
    if (isSetUp) throw const FakeAuthError(409, 'setup_done', 'the workspace is already set up');
    final a = FakeAccount(
      id: _newId(),
      email: e,
      name: n,
      password: p,
      role: AccountRole.owner,
      interfaceLanguage: language as String?,
      timezone: timezone as String?,
    )..lastLoginAt = clock.now().toUtc();
    byId[a.id] = a;
    return _signedIn(a);
  }

  Map<String, Object?> login({Object? email, Object? password, Object? inviteToken}) {
    const invalid = FakeAuthError(401, 'invalid_credentials', 'Invalid email or password.');
    if (email is! String || password is! String || email.trim().isEmpty || password.isEmpty) throw invalid;
    final key = email.trim().toLowerCase();
    final f = _failures[key];
    if (f != null && f.until.isAfter(clock.now()) && f.count > maxLoginFailures) {
      throw const FakeAuthError(
        429,
        'login_rate_limited',
        'Too many incorrect password attempts. Please try again later.',
      );
    }
    Never fail() {
      final now = clock.now();
      final prev = _failures[key];
      final count = prev != null && prev.until.isAfter(now) ? prev.count : 0;
      _failures[key] = (count: count + 1, until: now.add(lockout));
      throw invalid;
    }

    final a = byEmail(key);
    if (a == null) fail();
    if (a.password == null) {
      final inv = inviteToken is String ? _invitations[inviteToken] : null;
      if (inv == null ||
          inv.used ||
          inv.account != a.id ||
          !inv.expires.isAfter(clock.now()) ||
          !_validPassword(password)) {
        fail();
      }
      inv.used = true;
      a
        ..password = password
        ..status = 'active';
    } else if (a.password != password) {
      fail();
    }
    if (a.status == 'banned') throw const FakeAuthError(403, 'account_banned', 'Account is banned.');
    if (a.role == null) throw const FakeAuthError(403, 'forbidden', 'this account is not a member of the workspace');
    _failures.remove(key);
    a.lastLoginAt = clock.now().toUtc();
    return _signedIn(a);
  }

  Map<String, Object?> refresh(Object? refreshToken) {
    refreshes++;
    final t = refreshToken is String ? _refresh.remove(refreshToken) : null;
    final a = t == null ? null : byId[t.account];
    if (t == null || a == null || !t.expires.isAfter(clock.now()) || a.role == null || a.status != 'active') {
      throw const FakeAuthError(401, 'unauthorized', 'invalid or expired refresh token');
    }
    final pair = _pair(a.id, t.session);
    return pair.toJson();
  }

  void logout(String? accessToken) {
    principal(accessToken);
    final session = _sessionOf(accessToken!);
    _access.removeWhere((_, t) => t.session == session);
    _refresh.removeWhere((_, t) => t.session == session);
  }

  Map<String, Object?> account(String? accessToken) => principal(accessToken).toAccount().toJson();

  Map<String, Object?> updateName(String? accessToken, Object? name) {
    final a = principal(accessToken);
    a.name = _name(name, min: 3);
    return a.toAccount().toJson();
  }

  void updatePassword(String? accessToken, {Object? password, Object? newPassword, Object? repeatNewPassword}) {
    final a = principal(accessToken);
    if (newPassword != repeatNewPassword) {
      throw const FakeAuthError(400, 'invalid_password', 'the new passwords do not match');
    }
    if (a.password != null && password != a.password) {
      throw const FakeAuthError(400, 'invalid_password', 'the current password is incorrect');
    }
    a.password = _password(newPassword);
  }

  List<Map<String, Object?>> members(String? accessToken) {
    principal(accessToken);
    return [for (final a in _members) _memberJson(a)];
  }

  List<Map<String, Object?>> invite(String? accessToken, {Object? emails, Object? role}) {
    final inviter = principal(accessToken, privileged: true);
    if (role is! String || !AccountRole.assignable.contains(role)) {
      throw const FakeAuthError(400, 'invalid_role', 'invalid role');
    }
    if (emails is! List<Object?> || emails.isEmpty || emails.length > 100) {
      throw const FakeAuthError(400, 'bad_request', 'emails must list 1-100 addresses');
    }
    final out = <Map<String, Object?>>[];
    final seen = <String>{};
    for (final raw in emails) {
      final e = raw is String ? raw.trim() : '';
      if (!_validEmail(e)) {
        out.add({'email': '$raw', 'status': 'failed', 'message': 'invalid email address'});
        continue;
      }
      if (!seen.add(e.toLowerCase())) continue;
      var a = byEmail(e);
      if (a != null && a.role != null) {
        out.add({'email': e, 'status': 'already_member', 'message': 'Account already in workspace.'});
        continue;
      }
      a ??= FakeAccount(id: _newId(), email: e, name: e.split('@').first, status: 'pending');
      a.role = role;
      byId[a.id] = a;
      final token = _newToken();
      _invitations[token] = _Invitation(a.id, e, clock.now().add(const Duration(hours: 72)));
      out.add({'email': e, 'status': 'success', 'url': '/activate?email=${Uri.encodeQueryComponent(e)}&token=$token'});
    }
    inviter.lastLoginAt ??= clock.now().toUtc();
    return out;
  }

  void updateRole(String? accessToken, String memberId, Object? role) {
    final me = principal(accessToken, privileged: true);
    if (role is! String || !AccountRole.assignable.contains(role)) {
      throw const FakeAuthError(400, 'invalid_role', 'invalid role');
    }
    if (memberId == me.id) throw const FakeAuthError(400, 'cannot_operate_self', 'Cannot operate self.');
    final a = byId[memberId];
    if (a == null || a.role == null) throw const FakeAuthError(404, 'not_found', 'unknown member');
    if (a.role == AccountRole.owner) throw const FakeAuthError(403, 'forbidden', "the owner's role cannot be changed");
    a.role = role;
  }

  void removeMember(String? accessToken, String memberId) {
    final me = principal(accessToken, privileged: true);
    if (memberId == me.id) throw const FakeAuthError(400, 'cannot_operate_self', 'Cannot operate self.');
    final a = byId[memberId];
    if (a == null || a.role == null) throw const FakeAuthError(404, 'not_found', 'unknown member');
    if (a.role == AccountRole.owner) throw const FakeAuthError(403, 'forbidden', 'the owner cannot be removed');
    a.role = null;
    _access.removeWhere((_, t) => t.account == a.id);
    _refresh.removeWhere((_, t) => t.account == a.id);
    _invitations.removeWhere((_, i) => i.account == a.id);
    if (a.status == 'pending' && a.password == null) byId.remove(a.id);
  }

  Map<String, Object?> checkInvitation(Object? token) {
    final inv = token is String ? _invitations[token] : null;
    final a = inv == null ? null : byId[inv.account];
    if (inv == null ||
        a == null ||
        inv.used ||
        !inv.expires.isAfter(clock.now()) ||
        a.role == null ||
        a.password != null) {
      return {'is_valid': false};
    }
    return {
      'is_valid': true,
      'data': {
        'email': inv.email,
        'workspace_name': workspaceName,
        'account_status': 'pending',
        'requires_setup': true,
      },
    };
  }

  Map<String, Object?> activate({
    Object? token,
    Object? name,
    Object? password,
    Object? interfaceLanguage,
    Object? timezone,
  }) {
    final n = _name(name), p = _password(password);
    const invalid = FakeAuthError(400, 'invalid_token', 'The token is invalid or has expired.');
    final inv = token is String ? _invitations[token] : null;
    final a = inv == null ? null : byId[inv.account];
    if (inv == null ||
        a == null ||
        inv.used ||
        !inv.expires.isAfter(clock.now()) ||
        a.role == null ||
        a.password != null) {
      throw invalid;
    }
    inv.used = true;
    a
      ..name = n
      ..password = p
      ..status = 'active'
      ..interfaceLanguage = interfaceLanguage as String? ?? a.interfaceLanguage
      ..timezone = timezone as String? ?? a.timezone
      ..lastLoginAt = clock.now().toUtc();
    return _signedIn(a);
  }

  // ---- forgot password and reset links -----------------------------------------------------------

  Map<String, Object?> systemFeatures() => {
    'enable_email_code_login': false,
    'enable_email_password_login': true,
    'is_allow_register': false,
    'is_email_setup': emailSetup,
  };

  Map<String, Object?> sendResetCode({Object? email, Object? language}) {
    final e = _email(email);
    final lang = language == 'zh-Hans' ? 'zh-Hans' : 'en-US';
    if (!emailSetup) {
      throw const FakeAuthError(
        400,
        'mail_not_configured',
        'Mail is not configured on this server: ask the workspace owner or an admin for a reset link.',
      );
    }
    final a = byEmail(e);
    final destination = a?.email ?? e.toLowerCase();
    final key = destination.toLowerCase(), now = clock.now();
    final last = _lastResetMail[key];
    if (last != null && now.isBefore(last.add(resetSendInterval))) {
      final minutes = (resetSendInterval.inSeconds + 59) ~/ 60;
      throw FakeAuthError(
        429,
        'password_reset_rate_limit_exceeded',
        'Too many password reset emails have been sent. Please try again in ${minutes < 1 ? 1 : minutes} minutes.',
      );
    }
    final code = List.generate(6, (_) => _random.nextInt(10)).join(), token = _newToken();
    _resets.removeWhere((_, r) => r.email.toLowerCase() == key && r.phase != 'link');
    _resets[token] = _Reset(a?.id, destination, code, 'verify', now.add(resetTokenTtl));
    sentMails.add(FakeMail(to: destination, code: a == null ? null : code, language: lang));
    _lastResetMail[key] = now;
    return {'result': 'success', 'data': token};
  }

  Map<String, Object?> checkResetCode({Object? email, Object? code, Object? token}) {
    final key = _email(email).toLowerCase(), now = clock.now();
    if (token is! String || token.isEmpty) throw const FakeAuthError(400, 'bad_request', 'token is required');
    final f = _codeFailures[key];
    if (f != null && f.until.isAfter(now) && f.count > maxResetCodeFailures) {
      throw const FakeAuthError(
        429,
        'email_password_reset_limit',
        'Too many failed password reset attempts. Please try again in 24 hours.',
      );
    }
    final r = _resets[token];
    if (r == null || r.phase != 'verify' || !r.expires.isAfter(now)) {
      throw const FakeAuthError(400, 'invalid_token', 'The token is invalid or has expired.');
    }
    if (r.email.toLowerCase() != key) {
      throw const FakeAuthError(400, 'invalid_email', 'The email address is not valid.');
    }
    if (code != r.code) {
      final count = f != null && f.until.isAfter(now) ? f.count : 0;
      _codeFailures[key] = (count: count + 1, until: now.add(resetLockout));
      throw const FakeAuthError(400, 'email_code_error', 'Email code is invalid or expired.');
    }
    _resets.remove(token);
    final next = _newToken();
    _resets[next] = _Reset(r.account, r.email, null, 'reset', now.add(resetTokenTtl));
    _codeFailures.remove(key);
    return {'is_valid': true, 'email': key, 'token': next};
  }

  Map<String, Object?> resetPassword({Object? token, Object? newPassword, Object? passwordConfirm}) {
    if (token is! String || token.isEmpty) throw const FakeAuthError(400, 'bad_request', 'token is required');
    final p = _password(newPassword);
    _password(passwordConfirm);
    if (p != passwordConfirm) throw const FakeAuthError(400, 'password_mismatch', 'The passwords do not match.');
    final r = _resets.remove(token);
    if (r == null || r.phase == 'verify' || !r.expires.isAfter(clock.now())) {
      throw const FakeAuthError(400, 'invalid_token', 'The token is invalid or has expired.');
    }
    final a = r.account != null ? byId[r.account] : byEmail(r.email);
    if (a == null || a.email.toLowerCase() != r.email.toLowerCase()) {
      throw const FakeAuthError(400, 'account_not_found', 'Account not found.');
    }
    a.password = p;
    if (a.status == 'pending') a.status = 'active';
    _access.removeWhere((_, t) => t.account == a.id);
    _refresh.removeWhere((_, t) => t.account == a.id);
    _resets.removeWhere((_, x) => x.account == a.id);
    return {'result': 'success'};
  }

  Map<String, Object?> resetPasswordLink(String? accessToken, String memberId) {
    final me = principal(accessToken, privileged: true);
    final a = byId[memberId];
    if (a == null || a.role == null) throw const FakeAuthError(404, 'not_found', 'unknown member');
    if (a.role == AccountRole.owner && a.id != me.id) {
      throw const FakeAuthError(403, 'forbidden', "only the owner may reset the owner's password");
    }
    final token = _newToken(), expires = clock.now().add(resetLinkTtl);
    _resets.removeWhere((_, r) => r.account == a.id && r.phase == 'link');
    _resets[token] = _Reset(a.id, a.email, null, 'link', expires);
    return {
      'url': '/reset-password/set-password?email=${Uri.encodeQueryComponent(a.email)}&token=$token',
      'expires_at': expires.toUtc().toIso8601String(),
    };
  }

  /// `GET /comments/mention-users`.
  List<Map<String, Object?>> mentionUsers(String? accessToken) {
    principal(accessToken);
    return [
      for (final a in _members)
        {'id': a.id, 'name': a.name, 'email': a.email, 'avatar_url': ?a.avatarUrl, 'role': a.role},
    ];
  }

  // ---- internals ---------------------------------------------------------------------------------

  Iterable<FakeAccount> get _members {
    final list = byId.values.where((a) => a.role != null).toList()
      ..sort((x, y) {
        if ((x.role == AccountRole.owner) != (y.role == AccountRole.owner)) return x.role == AccountRole.owner ? -1 : 1;
        return x.createdAt.compareTo(y.createdAt);
      });
    return list;
  }

  Map<String, Object?> _memberJson(FakeAccount a) => {
    'id': a.id,
    'name': a.name,
    'email': a.email,
    'avatar_url': ?a.avatarUrl,
    'role': a.role,
    'status': a.status,
    'last_login_at': ?a.lastLoginAt?.toIso8601String(),
    'created_at': a.createdAt.toIso8601String(),
  };

  Map<String, Object?> _signedIn(FakeAccount a) {
    final r = _session(a);
    return {...r.tokens.toJson(), 'account': r.account.toJson()};
  }

  AuthResult _session(FakeAccount a) => AuthResult(tokens: _pair(a.id, 'session-${++_n}'), account: a.toAccount());

  AuthTokens _pair(String account, String session) {
    final now = clock.now();
    final access = _newToken(), refresh = _newToken();
    _access[access] = _Token(account, session, now.add(accessTtl));
    _refresh[refresh] = _Token(account, session, now.add(refreshTtl));
    return AuthTokens(accessToken: access, refreshToken: refresh);
  }

  String _newId() {
    final hex = List.generate(32, (_) => _random.nextInt(16).toRadixString(16)).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-4${hex.substring(13, 16)}-a${hex.substring(17, 20)}-${hex.substring(20)}';
  }

  String _newToken() {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
    return List.generate(43, (_) => chars[_random.nextInt(chars.length)]).join();
  }

  static bool _validEmail(String e) {
    final parts = e.split('@');
    return e.length <= 254 &&
        parts.length == 2 &&
        parts[0].isNotEmpty &&
        parts[1].contains('.') &&
        !parts[1].startsWith('.') &&
        !parts[1].endsWith('.') &&
        !e.contains(RegExp(r'\s'));
  }

  static String _email(Object? raw) {
    final e = raw is String ? raw.trim() : '';
    if (!_validEmail(e)) throw const FakeAuthError(400, 'bad_request', 'invalid email address');
    return e;
  }

  static String _name(Object? raw, {int min = 1}) {
    final n = raw is String ? raw.trim() : '';
    if (n.runes.length < min || n.runes.length > 30) {
      throw FakeAuthError(400, 'bad_request', 'name must be $min-30 characters');
    }
    return n;
  }

  /// Dify's rule `^(?=.*[a-zA-Z])(?=.*\d).{8,}$`.
  static bool _validPassword(String p) => RegExp(r'^(?=.*[a-zA-Z])(?=.*\d).{8,}$', unicode: true).hasMatch(p);

  static String _password(Object? raw) {
    if (raw is! String || !_validPassword(raw)) {
      throw const FakeAuthError(
        400,
        'invalid_password',
        'Password must contain letters and numbers, and the length must be at least 8 characters.',
      );
    }
    return raw;
  }
}

/// [AuthApi] on in-memory [FakeAccounts], through the reachability of a [FakeNetwork] (refused or partitioned: the call
/// fails like a connect error). Answers go through the same JSON as the real server's.
class FakeAuthApi implements AuthApi {
  FakeAuthApi(this.accounts, {FakeNetwork? network}) : network = network ?? FakeNetwork();

  final FakeAccounts accounts;
  final FakeNetwork network;

  Future<T> _call<T>(T Function(FakeAccounts a) f) async {
    await Future<void>.microtask(() {}); // asynchronous like a request (no timer: widget tests stay clean)
    if (network.refused || network.partitioned) throw const TransportException('connection refused');
    accounts.requests++;
    try {
      return f(accounts);
    } on FakeAuthError catch (e) {
      throw e.toTransport();
    }
  }

  @override
  Future<String> setupStatus() => _call((a) => a.setupStatus());

  @override
  Future<AuthResult> setup({
    required String email,
    required String name,
    required String password,
    String? language,
    String? timezone,
  }) => _call(
    (a) => AuthResult.fromJson(
      a.setup(email: email, name: name, password: password, language: language, timezone: timezone),
    ),
  );

  @override
  Future<AuthResult> login({
    required String email,
    required String password,
    bool rememberMe = false,
    String? inviteToken,
  }) => _call((a) => AuthResult.fromJson(a.login(email: email, password: password, inviteToken: inviteToken)));

  @override
  Future<AuthTokens> refresh(String refreshToken) => _call((a) => AuthTokens.fromJson(a.refresh(refreshToken)));

  @override
  Future<void> logout(String accessToken) => _call((a) => a.logout(accessToken));

  @override
  Future<Account> account(String accessToken) => _call((a) => Account.fromJson(a.account(accessToken)));

  @override
  Future<Account> updateName(String accessToken, String name) =>
      _call((a) => Account.fromJson(a.updateName(accessToken, name)));

  @override
  Future<void> updatePassword(
    String accessToken, {
    required String password,
    required String newPassword,
    required String repeatNewPassword,
  }) => _call(
    (a) => a.updatePassword(
      accessToken,
      password: password,
      newPassword: newPassword,
      repeatNewPassword: repeatNewPassword,
    ),
  );

  @override
  Future<List<Member>> members(String accessToken) =>
      _call((a) => [for (final m in a.members(accessToken)) Member.fromJson(m)]);

  @override
  Future<List<InvitationResult>> invite(String accessToken, {required List<String> emails, required String role}) =>
      _call((a) => [for (final r in a.invite(accessToken, emails: emails, role: role)) InvitationResult.fromJson(r)]);

  @override
  Future<void> updateRole(String accessToken, String memberId, String role) =>
      _call((a) => a.updateRole(accessToken, memberId, role));

  @override
  Future<void> removeMember(String accessToken, String memberId) => _call((a) => a.removeMember(accessToken, memberId));

  @override
  Future<InvitationCheck> checkInvitation(String token) =>
      _call((a) => InvitationCheck.fromJson(a.checkInvitation(token)));

  @override
  Future<AuthResult> activate({
    required String token,
    required String name,
    required String password,
    String? interfaceLanguage,
    String? timezone,
  }) => _call(
    (a) => AuthResult.fromJson(
      a.activate(
        token: token,
        name: name,
        password: password,
        interfaceLanguage: interfaceLanguage,
        timezone: timezone,
      ),
    ),
  );

  @override
  Future<SystemFeatures> systemFeatures() => _call((a) => SystemFeatures.fromJson(a.systemFeatures()));

  @override
  Future<String> sendResetCode({required String email, String? language}) =>
      _call((a) => a.sendResetCode(email: email, language: language)['data']! as String);

  @override
  Future<ResetCodeCheck> checkResetCode({required String email, required String code, required String token}) =>
      _call((a) => ResetCodeCheck.fromJson(a.checkResetCode(email: email, code: code, token: token)));

  @override
  Future<void> resetPassword({required String token, required String newPassword, required String passwordConfirm}) =>
      _call((a) => a.resetPassword(token: token, newPassword: newPassword, passwordConfirm: passwordConfirm));

  @override
  Future<PasswordResetLink> resetPasswordLink(String accessToken, String memberId) =>
      _call((a) => PasswordResetLink.fromJson(a.resetPasswordLink(accessToken, memberId)));
}
