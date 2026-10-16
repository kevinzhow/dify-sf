import 'settings.dart';

/// Options given on the command line (desktop only; the web build ignores them).
class LaunchOptions {
  const LaunchOptions({this.server, this.doc, this.volatile = false, this.demo = false});

  factory LaunchOptions.parse(List<String> args) {
    String? server;
    String? doc;
    var volatile = false;
    var demo = false;
    for (var i = 0; i < args.length; i++) {
      String? value() => i + 1 < args.length ? args[++i] : null;
      switch (args[i]) {
        case '--server':
          server = value();
        case '--doc':
          doc = value();
        case '--volatile':
          volatile = true;
        case '--demo':
          demo = true;
      }
    }
    return LaunchOptions(server: server, doc: doc, volatile: volatile, demo: demo);
  }

  final String? server;
  final String? doc;
  final bool volatile;
  final bool demo;

  bool get autoOpen => demo || doc != null;

  void applyTo(AppSettings s) {
    if (server != null) s.serverUrl = server!;
    if (doc != null) s.lastDoc = doc!;
    if (volatile) s.journaled = false;
  }
}
