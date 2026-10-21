import 'settings.dart';

/// Options given on the command line (desktop) or in the URL query (web: `?server=…&doc=…&demo=1&view=…`).
class LaunchOptions {
  const LaunchOptions({
    this.server,
    this.doc,
    this.invite,
    this.resetToken,
    this.volatile = false,
    this.demo = false,
    this.view,
    this.lang,
    this.theme,
    this.nodeId,
    this.app,
    this.page,
    this.formToken,
  });

  /// The web build's URL query as options; [path] `/activate` (Dify's invitation link `/activate?token=…`) or `#/activate`
  /// makes `token` the invitation, `/reset-password/set-password` (an admin's reset link) the reset token.
  factory LaunchOptions.fromQuery(Map<String, String> q, {String path = '', String fragment = ''}) => LaunchOptions(
    server: q['server'],
    doc: q['doc'],
    invite: path.endsWith('/activate') || fragment.startsWith('/activate')
        ? (q['token'] ?? Uri.parse(fragment).queryParameters['token'])
        : q['invite'],
    resetToken: path.endsWith('/reset-password/set-password') || fragment.startsWith('/reset-password/set-password')
        ? (q['token'] ?? Uri.parse(fragment).queryParameters['token'])
        : null,
    volatile: q['volatile'] == '1',
    demo: q['demo'] == '1',
    view: q['view'],
    lang: q['lang'],
    theme: q['theme'],
    nodeId: q['node_id'],
    app: q['app'],
    page: q['page'],
    // Dify's mailed link is `/form/{token}` (`(humanInputLayout)/form/[token]`): it opens the form, no account needed.
    formToken: _formTokenOf(path) ?? _formTokenOf(fragment),
  );

  /// The token of Dify's `/form/{token}` page, when the URL is that page.
  static String? _formTokenOf(String path) {
    const prefix = '/form/';
    final i = path.indexOf(prefix);
    if (i < 0) return null;
    final token = path.substring(i + prefix.length).split(RegExp(r'[?#/]')).first;
    return token.isEmpty ? null : token;
  }

  factory LaunchOptions.parse(List<String> args) {
    String? server;
    String? doc;
    String? invite;
    String? resetToken;
    var volatile = false;
    var demo = false;
    String? view;
    String? lang;
    String? theme;
    String? nodeId;
    String? app;
    String? page;
    for (var i = 0; i < args.length; i++) {
      String? value() => i + 1 < args.length ? args[++i] : null;
      switch (args[i]) {
        case '--server':
          server = value();
        case '--doc':
          doc = value();
        case '--invite':
          invite = inviteToken(value());
        case '--reset-link':
          resetToken = inviteToken(value());
        case '--volatile':
          volatile = true;
        case '--demo':
          demo = true;
        case '--view':
          view = value();
        case '--lang':
          lang = value();
        case '--theme':
          theme = value();
        case '--node-id':
          nodeId = value();
        case '--app':
          app = value();
        case '--page':
          page = value();
      }
    }
    return LaunchOptions(
      server: server,
      doc: doc,
      invite: invite,
      resetToken: resetToken,
      volatile: volatile,
      demo: demo,
      view: view,
      lang: lang,
      theme: theme,
      nodeId: nodeId,
      app: app,
      page: page,
    );
  }

  /// The token of an invitation or reset link (`…?email=…&token=…`), or [arg] itself when it is not a link.
  static String? inviteToken(String? arg) {
    if (arg == null) return null;
    final uri = Uri.tryParse(arg);
    return uri?.queryParameters['token'] ?? arg;
  }

  final String? server;
  final String? doc;

  /// An invitation to accept (Dify's `/activate?token=`): `--invite <link or token>` on desktop.
  final String? invite;

  /// An admin's password reset link to open (`/reset-password/set-password?token=`): `--reset-link <link or token>` on
  /// desktop.
  final String? resetToken;
  final bool volatile;
  final bool demo;

  /// The canvas's first view as a React Flow viewport `x,y,zoom` (screen = canvas * zoom + (x, y)), the way a Dify
  /// workflow file stores it; without it the canvas fits the graph. Visual tests open Dify and us at the same view.
  final String? view;

  /// Dify's language code for the UI (`zh-Hans`, `ja-JP`, …); null follows the system locale.
  final String? lang;

  /// The colour theme for this run, `light`, `dark` or `system` (`--theme` / `?theme=`), over the remembered choice
  /// (the visual tests open both apps in the same theme).
  final String? theme;

  /// A node of [doc] to select and bring into view when it opens (Dify's `?node_id=`, use-locate-node.ts).
  final String? nodeId;

  /// An app to open in its detail page (`--app` / `?app=`), at [page]: Dify's last path segment (`workflow`,
  /// `access-point`, `logs`, `annotations`, `overview`); signed in on a server with the apps API.
  final String? app;
  final String? page;

  /// Dify's mailed link (`/form/{token}`): the human input form to show, without an account.
  final String? formToken;

  bool get autoOpen => demo || doc != null;

  void applyTo(AppSettings s) {
    if (server != null) s.serverUrl = server!;
    if (doc != null) s.lastDoc = doc!;
    if (volatile) s.journaled = false;
  }
}
