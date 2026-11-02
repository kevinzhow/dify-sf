import 'web/startup_ready.dart';

import 'dart:async';

import 'package:collab_client/collab_client.dart' show WorkflowRunApi;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import 'public_app/public_app_page.dart';
import 'auth/activate_page.dart';
import 'auth/auth_api.dart';
import 'auth/auth_controller.dart';
import 'auth/install_page.dart';
import 'auth/invite_settings_page.dart';
import 'auth/reset_password_page.dart';
import 'human_input/human_input_form_page.dart';
import 'auth/signin_page.dart';
import 'auth/unreachable_page.dart';
import 'auth/widgets/auth_widgets.dart';
import 'auth/server_address_form.dart';
import 'server_connection.dart';
import 'server_address.dart';
import 'launch_options.dart';
import 'settings.dart';
import 'design/widgets/widgets.dart';

/// The app's pages by the signed-in state (Dify's routing around the console): the install page until the server
/// has an owner, the sign-in, activation, invitation and password reset pages while signed out, and [home] (with the
/// editors it opens) while signed in. Signing out, or a session the server no longer accepts, closes every page above the
/// home page and shows the sign-in page.
class AppRoot extends StatefulWidget {
  const AppRoot({
    super.key,
    required this.settings,
    required this.home,
    required this.navigatorKey,
    this.launch,
    this.auth,
    this.authApiFor,
    this.tokenStore,
    this.authRelay,
    this.humanInputApiFor,
    this.connection,
  });

  final AppSettings settings;
  final LaunchOptions? launch;

  /// The signed-in home page.
  final WidgetBuilder home;

  /// The app's navigator (editors are pushed on it; they go when the session ends).
  final GlobalKey<NavigatorState> navigatorKey;

  /// A ready controller (tests); null creates one for the settings' server and starts it.
  final AuthController? auth;

  /// The accounts API of a server (the HTTP one by default).
  final AuthApi Function(Uri server)? authApiFor;
  final TokenStore? tokenStore;

  /// Where the current controller is published for the [AuthScope] above the navigator (buildApp's), so that pages
  /// pushed over the home page (the Account page, app detail pages, dialogs) see the session too.
  final ValueNotifier<AuthController?>? authRelay;

  /// The API a mailed form link reads and submits with (tests pass one; the page builds an unauthenticated one).
  final WorkflowRunApi Function(Uri server)? humanInputApiFor;
  final ServerConnectionController? connection;

  @override
  State<AppRoot> createState() => _AppRootState();
}

class _AppRootState extends State<AppRoot> {
  AuthController? _own;
  AuthController get _auth => widget.auth ?? _own!;
  AuthRoute? _shown;
  bool _needsAddress = false;
  late final _connection =
      widget.connection ??
      ServerConnectionController(
        server: widget.settings.serverUrl,
        enabled: widget.auth == null,
      );

  @override
  void initState() {
    super.initState();
    _connection.bind(_changeServer);
    if (widget.auth == null) {
      _connect(
        widget.settings.serverUrl,
        activate: widget.launch?.invite,
        reset: widget.launch?.resetToken,
      );
    }
    _shown = _auth.route;
    widget.auth?.addListener(_routeChanged);
    _publish();
  }

  /// Hands the controller to [AppRoot.authRelay] after this frame (its listeners build above this widget).
  void _publish() {
    final relay = widget.authRelay;
    if (relay == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) relay.value = _auth;
    });
  }

  /// A controller for [server] (a new one when the server changes), started.
  void _connect(String server, {String? activate, String? reset}) {
    _releaseConnection();
    final uri = Uri.tryParse(server);
    _needsAddress = server.isEmpty || uri == null;
    if (!kIsWeb) {
      try {
        normalizeServerAddress(server);
      } on ServerAddressException {
        _needsAddress = true;
      }
    }
    final api = _needsAddress ? const OfflineAuthApi() : (widget.authApiFor ?? defaultAuthApiFor)(uri!);
    _own = AuthController.on(
      server: server,
      api: api,
      store: widget.tokenStore ?? TokenStore.platform(),
    )..addListener(_routeChanged);
    if (!_needsAddress) unawaited(_own!.start(activateToken: activate, resetToken: reset));
    if (mounted) _publish();
  }

  void _releaseConnection() {
    final previous = _own;
    if (previous == null) return;
    previous.removeListener(_routeChanged);
    previous.dispose();
    unawaited(previous.session.dispose());
    // Default HTTP APIs belong to this connection. Injected APIs retain their caller's lifetime.
    if (widget.authApiFor == null) {
      final api = previous.api;
      if (api is HttpAuthApi) api.close();
    }
    _own = null;
  }

  Future<void> _changeServer(String server) async {
    final previousServer = widget.settings.serverUrl, previousDoc = widget.settings.lastDoc;
    widget.settings.serverUrl = server;
    // A document id and a launch link belong to the old server. The old write-ahead journal and per-server tokens
    // remain in their own stores, but none of that server's screens or cached models is reused on the new one.
    widget.settings.lastDoc = '';
    try {
      await widget.settings.save();
    } on Object {
      widget.settings.serverUrl = previousServer;
      widget.settings.lastDoc = previousDoc;
      rethrow;
    }
    if (!mounted) return;
    widget.navigatorKey.currentState?.popUntil((r) => r.isFirst);
    setState(() => _connect(server));
  }

  void _routeChanged() {
    final route = _auth.route;
    if (_shown is HomeRoute && route is! HomeRoute) {
      // The session is over: the editors and dialogs opened from the home page go with it.
      widget.navigatorKey.currentState?.popUntil((r) => r.isFirst);
    }
    _shown = route;
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _auth.removeListener(_routeChanged);
    _releaseConnection();
    _connection.dispose();
    super.dispose();
  }

  /// The app shows its pages edge to edge ([DifyApplication.edgeToEdge] in [buildApp]); a page that does not pad
  /// itself for the system bars sits in the safe area as before. The home pads itself ([HomePage]: a [DifyPage]), and
  /// so do the auth pages on a phone (their frames go full bleed there).
  @override
  Widget build(BuildContext context) {
    final phone = DifyWindowClass.of(context) == DifyWindowClass.compact;
    if (_needsAddress) {
      markStartupReadyAfterFrame();
      final page = ServerAddressPage(connection: _connection);
      return ServerConnectionScope(
        controller: _connection,
        child: phone ? page : SafeArea(child: page),
      );
    }
    final launch = _connection.generation == 0 ? widget.launch : null;
    // Dify's mailed link (`/form/{token}`) is a page of its own, outside the account: a recipient has none.
    if (launch?.formToken case final token?) {
      return SafeArea(
        child: HumanInputFormPage(
          token: token,
          server: Uri.parse(_auth.server),
          apiFor: widget.humanInputApiFor,
        ),
      );
    }
    if (launch?.publicAppCode case final code?) {
      return SafeArea(
        child: PublicAppPage(code: code, server: Uri.parse(_auth.server), parameters: launch!.publicParameters),
      );
    }
    final route = _auth.route;
    Widget page = switch (route) {
      StartingRoute() => const AuthPageFrame(
        child: Center(child: DifyLoading()),
      ),
      UnreachableRoute(:final error) => UnreachablePage(
        server: _auth.server,
        error: error,
        onRetry: (server) => server == _auth.server ? _auth.start() : _connection.select(server),
      ),
      InstallRoute() => const InstallPage(),
      SignInRoute() => SignInPage(key: ValueKey(route), route: route),
      ActivateRoute(:final token) => ActivatePage(
        key: ValueKey(token),
        token: token,
      ),
      InviteSettingsRoute(:final inviteToken) => InviteSettingsPage(
        inviteToken: inviteToken,
      ),
      ResetPasswordRoute() => ResetPasswordPage(route: route),
      ResetPasswordCheckCodeRoute(:final token) => ResetPasswordCheckCodePage(
        key: ValueKey(token),
        route: route,
      ),
      ResetPasswordSetRoute(:final token) => ResetPasswordSetPage(
        key: ValueKey(token),
        route: route,
      ),
      HomeRoute() => Builder(builder: widget.home),
    };
    // A server change recreates the home subtree as well as the auth controller, so model/member/app caches cannot
    // survive a change to another server, even when it signs in with an identically named account.
    page = KeyedSubtree(key: ValueKey(_auth.server), child: page);
    if (!kIsWeb && route is! HomeRoute && _connection.canChange) {
      // The native app's server button: on a phone a row of the page under its header (it used to overlap the
      // page's top), on wider windows a bar above the page as before.
      page = phone
          ? AuthServerSlot(
              indicator: NativeServerButton(connection: _connection),
              child: page,
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
                    child: NativeServerButton(connection: _connection),
                  ),
                ),
                Expanded(child: page),
              ],
            );
    }
    if (route is! HomeRoute && !phone) page = SafeArea(child: page);
    if (route is! StartingRoute) markStartupReadyAfterFrame();
    return ServerConnectionScope(
      controller: _connection,
      child: AuthScope(controller: _auth, child: page),
    );
  }
}

/// The accounts API of [server]: the HTTP one.
AuthApi Function(Uri server) defaultAuthApiFor = HttpAuthApi.new;
