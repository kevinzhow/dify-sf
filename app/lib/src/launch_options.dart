import 'settings.dart';

/// Options given on the command line (desktop) or in the URL query (web: `?server=…&doc=…&demo=1&view=…`).
class LaunchOptions {
  const LaunchOptions({
    this.server,
    this.doc,
    this.invite,
    this.volatile = false,
    this.demo = false,
    this.view,
    this.lang,
  });

  /// The web build's URL query as options; [path] `/activate` (Dify's invitation link `/activate?token=…`) or `#/activate`
  /// makes `token` the invitation.
  factory LaunchOptions.fromQuery(Map<String, String> q, {String path = '', String fragment = ''}) => LaunchOptions(
    server: q['server'],
    doc: q['doc'],
    invite: path.endsWith('/activate') || fragment.startsWith('/activate')
        ? (q['token'] ?? Uri.parse(fragment).queryParameters['token'])
        : q['invite'],
    volatile: q['volatile'] == '1',
    demo: q['demo'] == '1',
    view: q['view'],
    lang: q['lang'],
  );

  factory LaunchOptions.parse(List<String> args) {
    String? server;
    String? doc;
    String? invite;
    var volatile = false;
    var demo = false;
    String? view;
    String? lang;
    for (var i = 0; i < args.length; i++) {
      String? value() => i + 1 < args.length ? args[++i] : null;
      switch (args[i]) {
        case '--server':
          server = value();
        case '--doc':
          doc = value();
        case '--invite':
          invite = inviteToken(value());
        case '--volatile':
          volatile = true;
        case '--demo':
          demo = true;
        case '--view':
          view = value();
        case '--lang':
          lang = value();
      }
    }
    return LaunchOptions(
      server: server,
      doc: doc,
      invite: invite,
      volatile: volatile,
      demo: demo,
      view: view,
      lang: lang,
    );
  }

  /// The token of an invitation link (`…/activate?email=…&token=…`), or [arg] itself when it is not a link.
  static String? inviteToken(String? arg) {
    if (arg == null) return null;
    final uri = Uri.tryParse(arg);
    return uri?.queryParameters['token'] ?? arg;
  }

  final String? server;
  final String? doc;

  /// An invitation to accept (Dify's `/activate?token=`): `--invite <link or token>` on desktop.
  final String? invite;
  final bool volatile;
  final bool demo;

  /// The canvas's first view as a React Flow viewport `x,y,zoom` (screen = canvas * zoom + (x, y)), the way a Dify
  /// workflow file stores it; without it the canvas fits the graph. Visual tests open Dify and us at the same view.
  final String? view;

  /// Dify's language code for the UI (`zh-Hans`, `ja-JP`, …); null follows the system locale.
  final String? lang;

  bool get autoOpen => demo || doc != null;

  void applyTo(AppSettings s) {
    if (server != null) s.serverUrl = server!;
    if (doc != null) s.lastDoc = doc!;
    if (volatile) s.journaled = false;
  }
}
