import 'package:collab_client/collab_client.dart';

import '../../editor/editor_controller.dart';
import 'workflow_store.dart';

/// Keeps [WorkflowStore.environmentVariables] and [WorkflowStore.conversationVariables] equal to the document's
/// variables (protocol 1.7: they live in the collaborative document under `$app`, not in the app metadata): after
/// every applied commit and every local optimistic edit, the store holds what this client's view shows. The store is
/// written only when a list actually changed.
class AppRegistersSync {
  AppRegistersSync({required this.controller, required this.store}) {
    controller.addListener(sync);
  }

  final EditorController controller;
  final WorkflowStore store;
  Value? _env;
  Value? _conv;
  bool _synced = false;

  /// Copies the variables into the store if they changed since the last call (the first call always writes).
  void sync() {
    final doc = controller.doc;
    final env = doc.app[AppRegisters.environmentVariables];
    final conv = doc.app[AppRegisters.conversationVariables];
    if (!_synced || env != _env) {
      store.setEnvironmentVariables(AppRegisters.variables(doc, AppRegisters.environmentVariables));
    }
    if (!_synced || conv != _conv) {
      store.setConversationVariables(AppRegisters.variables(doc, AppRegisters.conversationVariables));
    }
    _env = env;
    _conv = conv;
    _synced = true;
  }

  void dispose() => controller.removeListener(sync);
}
