import 'dart:async';

import 'package:flutter/widgets.dart';

import 'auth_api.dart';

/// The pages before the editor, as Dify routes them (web/app/install, signin, activate, signin/invite-settings,
/// reset-password) and the home page behind them.
sealed class AuthRoute {
  const AuthRoute();
}

/// Waiting for `GET /v1/setup` and the stored session.
final class StartingRoute extends AuthRoute {
  const StartingRoute();
}

/// The server could not be reached (dify-sf: Dify's web app is served by its own server and has no such state).
final class UnreachableRoute extends AuthRoute {
  const UnreachableRoute(this.error);
  final Object error;
}

/// `/install`: the first owner.
final class InstallRoute extends AuthRoute {
  const InstallRoute();
}

/// `/signin`, or `/signin?invite_token=&email=` for an invitation.
final class SignInRoute extends AuthRoute {
  const SignInRoute({this.inviteToken, this.email});
  final String? inviteToken;
  final String? email;

  bool get isInvite => inviteToken != null && inviteToken!.isNotEmpty && inviteToken != 'null';
}

/// `/activate?token=`: checks an invitation link, then goes on to the invitation's sign-in.
final class ActivateRoute extends AuthRoute {
  const ActivateRoute(this.token);
  final String token;
}

/// `/signin/invite-settings?invite_token=`: the invited account's name, language and time zone.
final class InviteSettingsRoute extends AuthRoute {
  const InviteSettingsRoute(this.inviteToken);
  final String inviteToken;
}

/// `/reset-password`: the email the code goes to (Dify's reset-password/page.tsx). [inviteToken]: the invitation sign-in
/// the user came from (Dify keeps the sign-in page's query through the flow), where the success page leads back.
final class ResetPasswordRoute extends AuthRoute {
  const ResetPasswordRoute({this.inviteToken});
  final String? inviteToken;
}

/// `/reset-password/check-code?email=&token=`: the code from the mail.
final class ResetPasswordCheckCodeRoute extends AuthRoute {
  const ResetPasswordCheckCodeRoute({required this.email, required this.token, this.inviteToken});
  final String email;
  final String token;
  final String? inviteToken;
}

/// `/reset-password/set-password?token=`: the new password, with the token of a right code or of an admin's reset link.
final class ResetPasswordSetRoute extends AuthRoute {
  const ResetPasswordSetRoute({required this.token, this.inviteToken});
  final String token;
  final String? inviteToken;
}

/// Signed in: the home page (and the editors opened from it).
final class HomeRoute extends AuthRoute {
  const HomeRoute();
}

/// The pages' view of the signed-in session of one server: collab_client's [AuthSession] (tokens in a [TokenStore],
/// Bearer on every request, one refresh after a 401, [AuthSession.signedOut] when the server refuses it) plus the page
/// to show. A session that ends brings the sign-in page back (Dify's 401 handling in service/base.ts).
class AuthController extends ChangeNotifier {
  AuthController({required this.session}) {
    _signedOut = session.signedOut.listen((_) => unawaited(_end()));
    _accountChanges = session.accountChanges.listen((a) {
      if (a != null && a != _account) {
        _account = a;
        notifyListeners();
      }
    });
  }

  /// A session on [api] keeping its tokens in [store] under [server].
  factory AuthController.on({required String server, required AuthApi api, required TokenStore store}) =>
      AuthController(
        session: AuthSession(api: api, store: store, server: server),
      );

  /// The tokens and the requests' authentication; transports and DocsApi take it as their `auth`.
  final AuthSession session;

  /// The server's base URL (the token store's key).
  String get server => session.server;
  AuthApi get api => session.api;

  late final StreamSubscription<void> _signedOut;
  late final StreamSubscription<Account?> _accountChanges;
  AuthRoute _route = const StartingRoute();
  Account? _account;
  bool _disposed = false;
  SystemFeatures _features = SystemFeatures.none;

  /// Dify's `leftTime` in local storage: the resend countdown the check-code page starts from (milliseconds), set when
  /// a code was sent.
  int? countdownLeftMs;

  /// The password typed on an invitation's sign-in page, sent with the activation (protocol 1.8 activates with the
  /// new account's name and password at once; Dify asks for them on two pages).
  String? _invitePassword;

  AuthRoute get route => _route;
  Account? get account => _account;
  AuthTokens? get tokens => session.tokens;
  bool get signedIn => _account != null && session.isSignedIn;

  /// Dify's `canEdit` (owner, admin, editor); normal members and dataset operators see the editor read-only.
  bool get canEdit => _account?.canEdit ?? false;

  bool get hasInvitePassword => _invitePassword != null;

  /// The server's system features (`GET /v1/system-features`), read by [start].
  SystemFeatures get systemFeatures => _features;

  /// Dify's `systemFeatures.is_email_setup`: "Forgot your password?" works.
  bool get isEmailSetup => _features.isEmailSetup;

  void go(AuthRoute route) {
    if (_disposed) return;
    _route = route;
    notifyListeners();
  }

  /// Where to begin: the install page until the server has an owner, an invitation link when the app was opened with
  /// one ([activateToken]), the new password page for a reset link ([resetToken]), the home page for a stored session
  /// that still works, else the sign-in page.
  Future<void> start({String? activateToken, String? resetToken}) async {
    go(const StartingRoute());
    final String step;
    try {
      step = await api.setupStatus();
    } on Object catch (e) {
      go(UnreachableRoute(e));
      return;
    }
    if (step != SetupStatus.finished) return go(const InstallRoute());
    try {
      _features = await api.systemFeatures();
    } on Object {
      _features = SystemFeatures.none;
    }
    if (activateToken != null && activateToken.isNotEmpty) return go(ActivateRoute(activateToken));
    if (resetToken != null && resetToken.isNotEmpty) return go(ResetPasswordSetRoute(token: resetToken));
    final bool restored;
    try {
      restored = await session.restore();
    } on Object catch (e) {
      go(UnreachableRoute(e));
      return;
    }
    final a = session.currentAccount;
    if (restored && a != null) {
      _account = a;
      return go(const HomeRoute());
    }
    // Restored but not checked: the server stopped answering in between.
    if (restored) return go(const UnreachableRoute(TransportException('the server did not answer')));
    go(const SignInRoute());
  }

  /// `GET /v1/setup`.
  Future<String> setupStatus() => api.setupStatus();

  /// Creates the first owner and signs in.
  Future<void> install({
    required String email,
    required String name,
    required String password,
    String? language,
  }) async => _signedIn(await session.setup(email: email, name: name, password: password, language: language));

  /// Dify signs in with `remember_me: true`.
  Future<void> signIn({required String email, required String password}) async =>
      _signedIn(await session.login(email: email, password: password, rememberMe: true));

  /// An invitation's sign-in: keeps the password for the activation and moves on to the account settings.
  void continueInvite({required String inviteToken, required String password}) {
    _invitePassword = password;
    go(InviteSettingsRoute(inviteToken));
  }

  Future<InvitationCheck> checkInvitation(String token) => api.checkInvitation(token);

  /// Accepts the invitation: the new account's [name] and the password from the sign-in step; signs in.
  Future<void> activate({
    required String token,
    required String name,
    String? interfaceLanguage,
    String? timezone,
  }) async {
    final password = _invitePassword;
    if (password == null) throw StateError('no password for the invitation');
    final a = await session.activate(
      token: token,
      name: name,
      password: password,
      interfaceLanguage: interfaceLanguage,
      timezone: timezone,
    );
    _invitePassword = null;
    await _signedIn(a);
  }

  /// `POST /v1/forgot-password`: mails a code; the token for [checkResetCode].
  Future<String> sendResetCode(String email, {String? language}) => api.sendResetCode(email: email, language: language);

  /// `POST /v1/forgot-password/validity`.
  Future<ResetCodeCheck> checkResetCode({required String email, required String code, required String token}) =>
      api.checkResetCode(email: email, code: code, token: token);

  /// `POST /v1/forgot-password/resets`.
  Future<void> resetPassword({required String token, required String newPassword, required String passwordConfirm}) =>
      api.resetPassword(token: token, newPassword: newPassword, passwordConfirm: passwordConfirm);

  Future<void> _signedIn(Account a) async {
    _account = a;
    go(const HomeRoute());
  }

  /// Dify's logout: the server forgets the session, the tokens are dropped, the sign-in page comes back.
  Future<void> signOut() async {
    await session.logout();
    await _end();
  }

  /// The server no longer accepts the session (401 after a refresh): back to the sign-in page.
  Future<void> sessionExpired() async {
    if (session.isSignedIn) await session.logout();
    await _end();
  }

  Future<void> _end() async {
    _account = null;
    _invitePassword = null;
    go(const SignInRoute());
  }

  /// Runs [call] with the access token, refreshing once after a 401 ([AuthSession.authorized]); a refused refresh
  /// signs out.
  Future<T> authorized<T>(Future<T> Function(String accessToken) call) => session.authorized(call);

  /// Signs in without a server (the in-memory demo): [account] with dummy tokens.
  void useLocalAccount(Account account) {
    _account = account;
    unawaited(
      session.adopt(
        AuthResult(
          tokens: const AuthTokens(accessToken: 'local', refreshToken: 'local'),
          account: account,
        ),
      ),
    );
    go(const HomeRoute());
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_signedOut.cancel());
    unawaited(_accountChanges.cancel());
    super.dispose();
  }
}

/// Provides the [AuthController] to the pages (rebuilding dependents when it changes).
class AuthScope extends InheritedNotifier<AuthController> {
  const AuthScope({super.key, required AuthController controller, required super.child}) : super(notifier: controller);

  static AuthController of(BuildContext context) => maybeOf(context)!;

  static AuthController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AuthScope>()?.notifier;

  /// Without subscribing (for callbacks).
  static AuthController? read(BuildContext context) => context.getInheritedWidgetOfExactType<AuthScope>()?.notifier;
}
