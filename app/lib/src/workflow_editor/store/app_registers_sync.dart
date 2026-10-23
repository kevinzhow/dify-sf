import 'package:collab_client/collab_client.dart';

import '../../editor/editor_controller.dart';
import 'workflow_store.dart';

/// Keeps [WorkflowStore.environmentVariables], [WorkflowStore.conversationVariables] and [WorkflowStore.features]
/// equal to the document's (protocol 1.7: they live in the collaborative document under `$app`, not in the app
/// metadata): after every applied commit and every local optimistic edit, the store holds what this client's view
/// shows. The store is written only when a value actually changed.
class AppRegistersSync {
  AppRegistersSync({required this.controller, required this.store}) {
    controller.addListener(sync);
  }

  final EditorController controller;
  final WorkflowStore store;
  Value? _env;
  Value? _conv;
  Value? _features;
  bool _synced = false;

  /// Copies the variables into the store if they changed since the last call (the first call always writes).
  void sync() {
    final doc = controller.doc;
    final env = doc.app[AppRegisters.environmentVariables];
    final conv = doc.app[AppRegisters.conversationVariables];
    final features = doc.app[AppRegisters.features];
    if (!_synced || env != _env) {
      store.setEnvironmentVariables(AppRegisters.variables(doc, AppRegisters.environmentVariables));
    }
    if (!_synced || conv != _conv) {
      store.setConversationVariables(AppRegisters.variables(doc, AppRegisters.conversationVariables));
    }
    if (!_synced || features != _features) store.setFeatures(AppRegisters.featuresOf(doc));
    _env = env;
    _conv = conv;
    _features = features;
    _synced = true;
  }

  void dispose() => controller.removeListener(sync);
}
