import 'package:flutter/widgets.dart';

import 'server_address.dart';

/// The app-level connection action, also available to pages pushed above the home page. AppRoot owns the actual
/// session replacement; keeping it above the navigator lets account menus use the same action everywhere.
class ServerConnectionController extends ChangeNotifier {
  ServerConnectionController({required String server, this.enabled = true})
    : _server = server; // ignore: prefer_initializing_formals -- The public input stays named server.

  final bool enabled;
  String _server;
  String get server => _server;
  int get generation => _generation;
  int _generation = 0;
  bool get busy => _busy;
  bool _busy = false;
  bool _disposed = false;
  Future<void> Function(String)? _connect;
  bool get canChange => enabled && _connect != null;

  void bind(Future<void> Function(String) connect) => _connect = connect;

  Future<void> select(String address) async {
    final server = normalizeServerAddress(address);
    if (!canChange) throw StateError('Server switching is unavailable');
    if (_busy) throw StateError('A connection change is already in progress');
    if (server == _server) return;
    _busy = true;
    _generation++;
    notifyListeners();
    try {
      await _connect!(server);
      _server = server;
    } on Object {
      _generation--;
      rethrow;
    } finally {
      _busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _connect = null;
    super.dispose();
  }
}

class ServerConnectionScope extends InheritedNotifier<ServerConnectionController> {
  const ServerConnectionScope({super.key, required ServerConnectionController controller, required super.child})
    : super(notifier: controller);

  static ServerConnectionController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ServerConnectionScope>()?.notifier;
}
