/// The app-level variables the variable panels edit (Dify's environment and conversation variables) as the
/// collaborative document keeps them (protocol 1.7): keyed lists under the reserved node `$app`, item id = the
/// variable's id, item value = Dify's variable object. Writes are plain item ops; Dify keeps these edits out of the
/// workflow history, and so do they (item ops and event-less config writes are not recorded for undo).
///
/// Renaming or deleting a variable rewrites the nodes that use it (Dify's `updateAffectedNodes` /
/// `removeUsedVarInNodes`: `findUsedVarNodes` + `updateNodeVars` over all nodes).
library;

import 'package:collab_client/collab_client.dart';
import 'package:flutter/widgets.dart';

import '../../editor/editor_controller.dart';
import '../../workflow/node_used_vars.dart';
import '../node_panel/bodies/llm/group_host.dart';
import '../node_panel/panel_edit.dart' show writeNodeConfig;
import '../store/store.dart';

/// Dify's variable object (`{id, name, value, value_type, description}`; secrets add `secret_ref`).
typedef DifyVariable = Map<String, Object?>;

/// Stores a secret's plaintext server-side: its reference and Dify's mask of it (`EditorController.storeSecret`).
typedef StoreSecret = Future<({String ref, String masked})> Function(String plaintext);

/// One of the two variable lists of the document: [path] under [Document.appNode].
class AppVariableList {
  const AppVariableList(this.controller, this.path);
  final EditorController controller;
  final List<String> path;

  static const environment = [AppRegisters.environmentVariables];
  static const conversation = [AppRegisters.conversationVariables];

  /// Adds [v] at the front (Dify prepends new variables).
  void add(DifyVariable v) => controller.insertItem(Document.appNode, path, Value.of(v), id: v['id']! as String);

  /// Replaces the variable [v] (by its id); [base] is the version the edit began on, so a variable someone else
  /// changed meanwhile turns this into a conflict instead of being overwritten.
  void update(DifyVariable v, {required int base}) =>
      controller.updateItem(Document.appNode, path, v['id']! as String, Value.of(v), base: base);

  void remove(String id) => controller.removeItem(Document.appNode, path, id);
}

/// `findUsedVarNodes`: the nodes among [nodes] that use [selector] (a node Dify's code cannot read is skipped).
List<Node> findUsedVarNodes(List<String> selector, Iterable<Node> nodes) {
  final key = selector.join('.');
  return [
    for (final n in nodes)
      if (_usedVars(n).any((v) => v.join('.') == key)) n,
  ];
}

List<List<String>> _usedVars(Node n) {
  try {
    return getNodeUsedVars(n);
  } on StateError {
    return const [];
  }
}

/// `updateAffectedNodes` / `removeUsedVarInNodes`: every node using [selector] now uses [next] (`[]`: the uses are
/// cleared), and prompt editors re-render (`setControlPromptEditorRerenderKey`). False when no node used it.
bool updateAffectedNodes(EditorController c, WorkflowStore store, List<String> selector, List<String> next) {
  final affected = findUsedVarNodes(selector, c.doc.nodes.values);
  if (affected.isEmpty) return false;
  for (final n in affected) {
    try {
      writeNodeConfig(c, n, updateNodeVars(n, selector, next));
    } on StateError {
      // Dify's code would throw on this node's data; leave it.
    }
  }
  store.setControlPromptEditorRerenderKey(DateTime.now().millisecondsSinceEpoch);
  return true;
}

/// Dify's `toast.error(message)` through the host's toast (none without one).
void toastError(BuildContext context, String message) =>
    LlmGroupScope.of(context).toast?.call(LlmToastType.error, message);

/// The variable [id] in [list], or null.
DifyVariable? variableById(List<DifyVariable> list, Object? id) => list.where((v) => v['id'] == id).firstOrNull;
