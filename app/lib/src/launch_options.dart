import 'settings.dart';

/// Options given on the command line (desktop only; the web build ignores them).
class LaunchOptions {
  const LaunchOptions({this.server, this.doc, this.name, this.volatile = false, this.demo = false});

  factory LaunchOptions.parse(List<String> args) {
    String? server;
    String? doc;
    String? name;
    var volatile = false;
    var demo = false;
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
      }
    }
    return LaunchOptions(server: server, doc: doc, name: name, volatile: volatile, demo: demo);
  }

  final String? server;
  final String? doc;

  /// Display name for this window (protocol 1.3), e.g. to tell several windows apart.
  final String? name;
  final bool volatile;
  final bool demo;

  bool get autoOpen => demo || doc != null;

  void applyTo(AppSettings s) {
    if (server != null) s.serverUrl = server!;
    if (doc != null) s.lastDoc = doc!;
    if (name != null) s.userName = name!;
    if (volatile) s.journaled = false;
  }
}
