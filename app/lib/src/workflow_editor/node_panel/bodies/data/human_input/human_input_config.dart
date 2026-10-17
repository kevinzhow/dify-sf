/// hooks/use-config.ts and hooks/use-form-content.ts: the Human Input panel's edits of its node, as small document
/// ops (Dify's `setInputs`), with the edge moves of renamed actions and the downstream renames of renamed inputs.
library;

import 'package:collab_client/collab_client.dart';

import '../../../../../workflow/dify_json.dart';
import '../../../../../workflow/node_used_vars.dart';
import '../../../node_panel_bodies.dart';
import '../data_common.dart';
import 'human_input_model.dart';

/// `handleOutVarRenameChange`: every other node's use of [oldSelector] now names [newSelector].
void renameVarInOtherNodes(NodePanelProps props, List<String> oldSelector, List<String> newSelector) {
  final c = props.controller;
  final key = oldSelector.join('.');
  for (final n in c.doc.nodes.values.toList()) {
    if (n.id == props.id) continue;
    try {
      if (!getNodeUsedVars(n).any((s) => s.join('.') == key)) continue;
      final next = updateNodeVars(n, oldSelector, newSelector);
      for (final MapEntry(:key, :value) in next.config.entries) {
        if (n.config[key] != value) c.setConfig(n.id, [key], value);
      }
    } on StateError {
      // Dify's code would throw on this node's data; leave it.
    }
  }
}

/// `handleEdgeSourceHandleChange`: the edges leaving the node from handle [from] now leave from [to].
void moveSourceHandle(NodePanelProps props, String from, String to) {
  final c = props.controller;
  final edges = <Edge>[
    for (final e in c.doc.edges.values)
      if (e.source == props.id && e.sourceHandle == from) e,
  ];
  for (final e in edges) {
    c.deleteEdge(e.id);
    c.connect(props.id, e.target, sourceHandle: to);
  }
}

/// `useConfig(id, data)` over [props].
class HumanInputConfig {
  const HumanInputConfig(this.props);
  final NodePanelProps props;

  Map<String, Object?> get inputs => props.data;
  bool get readOnly => props.readOnly;

  List<Map<String, Object?>> get userActions => [
    for (final a in jsList(inputs['user_actions']))
      if (a is Map<String, Object?>) a,
  ];

  void deliveryMethodChange(List<Map<String, Object?>> methods) => patchInputs(props, {'delivery_methods': methods});

  void userActionAdd(Map<String, Object?> action) => patchInputs(props, {
    'user_actions': [...userActions, action],
  });

  /// The action at [index] replaced; a new ID moves its edges to the new handle.
  void userActionChange(int index, Map<String, Object?> action, {int? base}) {
    final actions = userActions;
    if (index < 0 || index >= actions.length) return;
    final old = actions[index];
    patchInputs(props, {
      'user_actions': [for (final (i, a) in actions.indexed) i == index ? action : a],
    }, base: base);
    if (old['id'] != action['id']) moveSourceHandle(props, '${old['id']}', '${action['id']}');
  }

  /// The action [id] removed with its branch's edges.
  void userActionDelete(String id) {
    patchInputs(props, {
      'user_actions': [
        for (final a in userActions)
          if (a['id'] != id) a,
      ],
    });
    props.actions.deleteBranch(props.id, id);
  }

  void timeoutChange(num timeout, String unit) => patchInputs(props, {'timeout': timeout, 'timeout_unit': unit});

  // ---- use-form-content ----

  void formContentChange(String value, {int? base}) => patchInputs(props, {'form_content': value}, base: base);

  void formInputsChange(List<Object?> formInputs) => patchInputs(props, {'inputs': formInputs});

  /// A new input and the content with its token, as one edit.
  void formInputInsert(Map<String, Object?> payload, String content) => patchInputs(props, {
    'form_content': content,
    'inputs': [...jsList(inputs['inputs']), payload],
  });

  /// `handleFormInputItemRename`: refused when the name is another input's; downstream uses follow the new name.
  bool formInputRename(Map<String, Object?> payload, String oldName) {
    final next = renameFormInput(inputs, payload, oldName);
    if (next == null) return false;
    setInputs(props, next);
    final newName = inputNameOf(payload);
    if (oldName != newName) renameVarInOtherNodes(props, [props.id, oldName], [props.id, newName]);
    return true;
  }

  void formInputRemove(String name) => setInputs(props, removeFormInput(inputs, name));
}
