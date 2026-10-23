import 'package:flutter/widgets.dart';

import 'local_storage.dart';
import 'workflow_store.dart';

/// Dify's WorkflowContext: hands the editor's [WorkflowStore] (and its stored preferences) to the chrome and the
/// panels. The store never changes for a scope, so [of] adds no dependency; widgets listen to the fields they read.
class WorkflowStoreScope extends InheritedWidget {
  const WorkflowStoreScope({super.key, required this.store, this.preferences, required super.child});

  final WorkflowStore store;

  /// Null where nothing is persisted (tests, previews).
  final WorkflowPreferences? preferences;

  /// `useStore` / `useWorkflowStore`: throws when there is no scope above [context].
  static WorkflowStore of(BuildContext context) => _scope(context).store;

  static WorkflowPreferences? preferencesOf(BuildContext context) => _scope(context).preferences;

  static WorkflowStoreScope _scope(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<WorkflowStoreScope>();
    if (scope == null) throw StateError('Missing WorkflowStoreScope in the tree');
    return scope;
  }

  @override
  bool updateShouldNotify(WorkflowStoreScope oldWidget) =>
      store != oldWidget.store || preferences != oldWidget.preferences;
}

/// Dify's WorkflowContextProvider: creates one store for its lifetime (kept across rebuilds) and disposes it.
class WorkflowStoreProvider extends StatefulWidget {
  const WorkflowStoreProvider({super.key, this.create, required this.child});

  /// Makes the store (default: a plain [WorkflowStore]); called once.
  final WorkflowStore Function()? create;
  final Widget child;

  @override
  State<WorkflowStoreProvider> createState() => _WorkflowStoreProviderState();
}

class _WorkflowStoreProviderState extends State<WorkflowStoreProvider> {
  late final store = widget.create?.call() ?? WorkflowStore();

  @override
  void dispose() {
    store.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => WorkflowStoreScope(store: store, child: widget.child);
}
