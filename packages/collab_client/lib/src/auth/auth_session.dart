import 'dart:async';

import 'package:http/http.dart' as http;

import '../client/transport.dart';
import 'account.dart';
import 'auth_api.dart';
import 'token_store.dart';

/// What the transports need from a sign-in (protocol 1.8): the current access token, and a way to get a new one after a
/// `401`. [AuthSession] implements it; an app with its own session object can implement these two members instead.
abstract interface class TokenProvider {
  /// The access token to send as `Authorization: Bearer`; null = signed out (requests go without a token).
  String? get accessToken;

  /// A request was answered `401` with [failedToken]: get a new access token (once for all callers that hold the same
  /// stale token). True = [accessToken] is new, repeat the request; false = signed out or the server is unreachable.
  Future<bool> refresh({String? failedToken});
}

/// The signed-in user of one server (protocol 1.8): keeps the tokens (in a [TokenStore], under [server]), refreshes them,
/// and hands them to every request.
///
/// ```dart
/// final auth = AuthSession(api: HttpAuthApi(baseUrl), store: TokenStore.platform(directory: dir), server: '$baseUrl');
/// if (!await auth.restore()) {                                  // no saved sign-in (or it expired)
///   if (await auth.api.setupStatus() == SetupStatus.notStarted) {
///     await auth.setup(email: e, name: n, password: p);         // Dify's install: the first account is the owner
///   } else {
///     await auth.login(email: e, password: p);
///   }
/// }
/// auth.signedOut.listen((_) => showSignIn());
/// final transport = HttpTransport(baseUrl: baseUrl, docId: id, auth: auth);   // Bearer on every request
/// final docs = DocsApi(baseUrl, auth: auth);
/// final canEdit = auth.currentAccount?.canEdit ?? false;       // false: the editor is read-only (Dify's nodesReadOnly)
/// ```
///
/// Rules: every request carries `Authorization: Bearer <access token>`. On a `401` the request is repeated once after a
/// refresh (one refresh at a time, however many requests failed together); if the server refuses the refresh, the
/// session signs out: the tokens are forgotten and [signedOut] fires. A refresh that fails because the server is
/// unreachable keeps the tokens (the user stays signed in; the request fails like any network error).
class AuthSession implements TokenProvider {
  AuthSession({required this.api, TokenStore? store, this.server = 'default'}) : store = store ?? MemoryTokenStore();

  /// The account endpoints (public calls go straight through it; [refresh] uses it too).
  final AuthApi api;
  final TokenStore store;

  /// The key of this server's tokens in [store] (its base URL, when the app knows several servers).
  final String server;

  AuthTokens? _tokens;
  Account? _account;
  Future<bool>? _refreshing;
  final _signedOut = StreamController<void>.broadcast();
  final _accountChanges = StreamController<Account?>.broadcast();

  @override
  String? get accessToken => _tokens?.accessToken;

  /// The current tokens; null when signed out.
  AuthTokens? get tokens => _tokens;

  bool get isSignedIn => _tokens != null;

  /// The signed-in account as last seen (sign-in answer or [account]); null when signed out or not fetched yet.
  Account? get currentAccount => _account;

  /// Fires when the session ends without [logout]: the server refused to refresh (expired, revoked, removed member).
  Stream<void> get signedOut => _signedOut.stream;

  /// The account after every sign-in, refetch, rename, and null at sign-out.
  Stream<Account?> get accountChanges => _accountChanges.stream;

  /// Loads the saved tokens and checks them (`GET /v1/account`, refreshing if needed). True = signed in. When the server
  /// is unreachable the saved tokens are kept and this answers true with [currentAccount] still null.
  Future<bool> restore() async {
    _tokens = await store.read(server);
    if (_tokens == null) return false;
    try {
      await account();
      return true;
    } on TransportException catch (e) {
      if (e.statusCode == 401) return false; // signed out by the refused refresh
      if (e.statusCode == null || e.statusCode! >= 500) return true; // offline: keep the session
      await _clear();
      return false;
    }
  }

  // ---- signing in --------------------------------------------------------------------------------

  /// Dify's install: creates the workspace with this account as the owner and signs in.
  Future<Account> setup({
    required String email,
    required String name,
    required String password,
    String? language,
    String? timezone,
  }) async =>
      adopt(await api.setup(email: email, name: name, password: password, language: language, timezone: timezone));

  /// Email + password sign-in (`401 invalid_credentials`, `429 login_rate_limited`, ... as `TransportException`).
  Future<Account> login({
    required String email,
    required String password,
    bool rememberMe = false,
    String? inviteToken,
  }) async =>
      adopt(await api.login(email: email, password: password, rememberMe: rememberMe, inviteToken: inviteToken));

  /// Accepts an invitation and signs in as the invited account.
  Future<Account> activate({
    required String token,
    required String name,
    required String password,
    String? interfaceLanguage,
    String? timezone,
  }) async => adopt(
    await api.activate(
      token: token,
      name: name,
      password: password,
      interfaceLanguage: interfaceLanguage,
      timezone: timezone,
    ),
  );

  /// Takes over a sign-in answer (saves the tokens).
  Future<Account> adopt(AuthResult result) async {
    _tokens = result.tokens;
    await store.write(server, result.tokens);
    _setAccount(result.account);
    return result.account;
  }

  /// Signs out: forgets the tokens, then revokes them on the server (best-effort; offline is fine).
  Future<void> logout() async {
    final token = accessToken;
    await _clear();
    if (token != null) {
      try {
        await api.logout(token);
      } on Object {
        // the tokens are gone here; the server's copies expire on their own
      }
    }
  }

  // ---- tokens --------------------------------------------------------------------------------------

  @override
  Future<bool> refresh({String? failedToken}) {
    if (failedToken != null && _tokens != null && _tokens!.accessToken != failedToken) return Future.value(true);
    return _refreshing ??= _refresh().whenComplete(() => _refreshing = null);
  }

  Future<bool> _refresh() async {
    final current = _tokens;
    if (current == null) return false;
    try {
      final next = await api.refresh(current.refreshToken);
      if (!identical(_tokens, current)) return _tokens != null; // signed out or in again meanwhile
      _tokens = next;
      await store.write(server, next);
      return true;
    } on TransportException catch (e) {
      final status = e.statusCode;
      if (status != null && status < 500 && identical(_tokens, current)) {
        await _clear();
        if (!_signedOut.isClosed) _signedOut.add(null);
      }
      return false;
    }
  }

  /// Runs [call] with the access token; after a `401` it refreshes once and repeats it. Throws a `401`
  /// `TransportException` when signed out.
  Future<T> authorized<T>(Future<T> Function(String accessToken) call) async {
    final token = accessToken;
    if (token == null) throw const TransportException('not signed in', statusCode: 401, code: 'unauthorized');
    try {
      return await call(token);
    } on TransportException catch (e) {
      if (e.statusCode != 401 || !await refresh(failedToken: token)) rethrow;
      final again = accessToken;
      if (again == null) rethrow;
      return call(again);
    }
  }

  /// An HTTP client that adds the bearer token to every request and repeats a request once after a refresh when it was
  /// answered `401`. Closing it closes [inner] (a fresh `http.Client` when omitted).
  http.Client httpClient([http.Client? inner]) => AuthenticatedClient(inner ?? http.Client(), this);

  // ---- account and members (the AuthApi calls, with the session's token) -----------------------

  /// `GET /v1/account`; updates [currentAccount].
  Future<Account> account() async {
    final a = await authorized(api.account);
    _setAccount(a);
    return a;
  }

  /// `PUT /v1/account/name`.
  Future<Account> updateName(String name) async {
    final a = await authorized((t) => api.updateName(t, name));
    _setAccount(a);
    return a;
  }

  /// `PUT /v1/account/password`.
  Future<void> updatePassword({
    required String password,
    required String newPassword,
    required String repeatNewPassword,
  }) => authorized(
    (t) => api.updatePassword(t, password: password, newPassword: newPassword, repeatNewPassword: repeatNewPassword),
  );

  /// `PATCH /v1/account/profile` (1.12): name, interface language, time zone; updates [currentAccount].
  Future<Account> updateProfile({String? name, String? interfaceLanguage, String? timezone, String? avatar}) async {
    final a = await authorized(
      (t) => api.updateProfile(t, name: name, interfaceLanguage: interfaceLanguage, timezone: timezone, avatar: avatar),
    );
    _setAccount(a);
    return a;
  }

  /// `POST /v1/account/change-email` (1.12): the token for [checkChangeEmailCode].
  Future<String> sendChangeEmailCode({required String email, String? language, String? phase, String? token}) =>
      authorized((t) => api.sendChangeEmailCode(t, email: email, language: language, phase: phase, token: token));

  /// `POST /v1/account/change-email/validity` (1.12).
  Future<ResetCodeCheck> checkChangeEmailCode({required String email, required String code, required String token}) =>
      authorized((t) => api.checkChangeEmailCode(t, email: email, code: code, token: token));

  /// `POST /v1/account/change-email/reset` (1.12); updates [currentAccount].
  Future<Account> changeEmail({required String newEmail, required String token}) async {
    final a = await authorized((t) => api.changeEmail(t, newEmail: newEmail, token: token));
    _setAccount(a);
    return a;
  }

  /// `POST /v1/account/change-email/check-email-unique` (1.12).
  Future<void> checkEmailUnique(String email) => authorized((t) => api.checkEmailUnique(t, email));

  /// `GET /v1/workspace/members`.
  Future<List<Member>> members() => authorized(api.members);

  /// `POST /v1/workspace/members/invite-email` (owner and admins).
  Future<List<InvitationResult>> invite({required List<String> emails, required String role}) =>
      authorized((t) => api.invite(t, emails: emails, role: role));

  /// `PUT /v1/workspace/members/{id}/update-role` (owner and admins).
  Future<void> updateRole(String memberId, String role) => authorized((t) => api.updateRole(t, memberId, role));

  /// `DELETE /v1/workspace/members/{id}` (owner and admins).
  Future<void> removeMember(String memberId) => authorized((t) => api.removeMember(t, memberId));

  /// `POST /v1/workspace/members/{id}/reset-password-link` (owner and admins; dify-sf only).
  Future<PasswordResetLink> resetPasswordLink(String memberId) => authorized((t) => api.resetPasswordLink(t, memberId));

  // ---- internals -------------------------------------------------------------------------------

  void _setAccount(Account? a) {
    if (a == _account && a != null) return;
    _account = a;
    if (!_accountChanges.isClosed) _accountChanges.add(a);
  }

  Future<void> _clear() async {
    _tokens = null;
    _setAccount(null);
    await store.clear(server);
  }

  /// Closes the streams (the tokens stay in the store).
  Future<void> dispose() async {
    await _signedOut.close();
    await _accountChanges.close();
  }
}

/// Adds `Authorization: Bearer <access token>` of [auth] to every request; a `401` answer to a request whose body can be
/// sent again (`http.Request`, `http.AbortableRequest`) is repeated once after [TokenProvider.refresh]. Other `401`s,
/// and the `401` after a refused refresh, are handed back unchanged.
class AuthenticatedClient extends http.BaseClient {
  /// [closeInner]: whether [close] closes [_inner] (false when the caller owns it).
  AuthenticatedClient(this._inner, this.auth, {this.closeInner = true});

  final http.Client _inner;
  final TokenProvider auth;
  final bool closeInner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final token = auth.accessToken;
    if (token != null) request.headers['Authorization'] = 'Bearer $token';
    final replay = request is http.Request ? request.bodyBytes : null;
    final res = await _inner.send(request);
    if (res.statusCode != 401 || token == null || replay == null) return res;
    final body = await res.stream.toBytes();
    final original = http.StreamedResponse(
      Stream.value(body),
      res.statusCode,
      contentLength: body.length,
      request: res.request,
      headers: res.headers,
      reasonPhrase: res.reasonPhrase,
    );
    if (!await auth.refresh(failedToken: token)) return original;
    final fresh = auth.accessToken;
    if (fresh == null) return original;
    final r = request as http.Request;
    final again = r is http.AbortableRequest
        ? http.AbortableRequest(r.method, r.url, abortTrigger: r.abortTrigger)
        : http.Request(r.method, r.url);
    again
      ..headers.addAll(r.headers)
      ..headers['Authorization'] = 'Bearer $fresh'
      ..followRedirects = r.followRedirects
      ..maxRedirects = r.maxRedirects
      ..persistentConnection = r.persistentConnection
      ..bodyBytes = replay;
    return _inner.send(again);
  }

  @override
  void close() {
    if (closeInner) _inner.close();
  }
}
