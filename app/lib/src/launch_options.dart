import 'settings.dart';

/// Options given on the command line (desktop) or in the URL query (web: `?server=…&doc=…&name=…&demo=1&view=…`).
class LaunchOptions {
  const LaunchOptions({this.server, this.doc, this.name, this.volatile = false, this.demo = false, this.view});

  /// The web build's URL query as options.
  factory LaunchOptions.fromQuery(Map<String, String> q) => LaunchOptions(
    server: q['server'],
    doc: q['doc'],
    name: q['name'],
    volatile: q['volatile'] == '1',
    demo: q['demo'] == '1',
    view: q['view'],
  );

  factory LaunchOptions.parse(List<String> args) {
    String? server;
    String? doc;
    String? name;
    var volatile = false;
    var demo = false;
    String? view;
    for (var i = 0; i < args.length; i++) {
      String? value() => i + 1 < args.length ? args[++i] : null;
      switch (args[i]) {
        case '--server':
          server = value();
        case '--doc':
          doc = value();
        case '--name':
          name = value();
        case '--volatile':
          volatile = true;
        case '--demo':
          demo = true;
        case '--view':
          view = value();
      }
    }
    return LaunchOptions(server: server, doc: doc, name: name, volatile: volatile, demo: demo, view: view);
  }

  final String? server;
  final String? doc;

  /// Display name for this window (protocol 1.3), e.g. to tell several windows apart.
  final String? name;
  final bool volatile;
  final bool demo;

  /// The canvas's first view as a React Flow viewport `x,y,zoom` (screen = canvas * zoom + (x, y)), the way a Dify
  /// workflow file stores it; without it the canvas fits the graph. Visual tests open Dify and us at the same view.
  final String? view;

  bool get autoOpen => demo || doc != null;

  void applyTo(AppSettings s) {
    if (server != null) s.serverUrl = server!;
    if (doc != null) s.lastDoc = doc!;
    if (name != null) s.userName = name!;
    if (volatile) s.journaled = false;
  }
}
