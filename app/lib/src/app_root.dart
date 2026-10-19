import 'dart:async';

import 'package:flutter/material.dart';

import 'auth/activate_page.dart';
import 'auth/auth_api.dart';
import 'auth/auth_controller.dart';
import 'auth/install_page.dart';
import 'auth/invite_settings_page.dart';
import 'auth/reset_password_page.dart';
import 'auth/signin_page.dart';
import 'auth/unreachable_page.dart';
import 'auth/widgets/auth_widgets.dart';
import 'launch_options.dart';
import 'settings.dart';

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

  @override
  State<AppRoot> createState() => _AppRootState();
}

class _AppRootState extends State<AppRoot> {
  AuthController? _own;
  AuthController get _auth => widget.auth ?? _own!;
  AuthRoute? _shown;

  @override
  void initState() {
    super.initState();
    if (widget.auth == null) {
      _connect(widget.settings.serverUrl, activate: widget.launch?.invite, reset: widget.launch?.resetToken);
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
    _own?.removeListener(_routeChanged);
    _own?.dispose();
    final api = (widget.authApiFor ?? defaultAuthApiFor)(Uri.parse(server));
    _own = AuthController.on(server: server, api: api, store: widget.tokenStore ?? TokenStore.platform())
      ..addListener(_routeChanged);
    unawaited(_own!.start(activateToken: activate, resetToken: reset));
    if (mounted) _publish();
  }

  Future<void> _changeServer(String server) async {
    widget.settings.serverUrl = server;
    await widget.settings.save();
    if (!mounted) return;
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
    _own?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final route = _auth.route;
    final Widget page = switch (route) {
      StartingRoute() => const AuthPageFrame(child: Center(child: DifyAreaLoading())),
      UnreachableRoute(:final error) => UnreachablePage(
        server: _auth.server,
        error: error,
        onRetry: (server) => server == _auth.server ? unawaited(_auth.start()) : unawaited(_changeServer(server)),
      ),
      InstallRoute() => const InstallPage(),
      SignInRoute() => SignInPage(key: ValueKey(route), route: route),
      ActivateRoute(:final token) => ActivatePage(key: ValueKey(token), token: token),
      InviteSettingsRoute(:final inviteToken) => InviteSettingsPage(inviteToken: inviteToken),
      ResetPasswordRoute() => ResetPasswordPage(route: route),
      ResetPasswordCheckCodeRoute(:final token) => ResetPasswordCheckCodePage(key: ValueKey(token), route: route),
      ResetPasswordSetRoute(:final token) => ResetPasswordSetPage(key: ValueKey(token), route: route),
      HomeRoute() => Builder(builder: widget.home),
    };
    return AuthScope(controller: _auth, child: page);
  }
}

/// The accounts API of [server]: the HTTP one.
AuthApi Function(Uri server) defaultAuthApiFor = HttpAuthApi.new;
