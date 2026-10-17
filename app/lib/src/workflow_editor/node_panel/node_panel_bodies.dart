/// The per-node-type bodies of the node panel (nodes/components.ts PanelComponentMap): what the Settings tab shows
/// above the shared sections, and the shared output-variables section bodies put at their end.
library;

import 'package:collab_client/collab_client.dart';

import 'bodies/core/core_bodies.dart';
import 'bodies/data/data_bodies.dart';
import 'bodies/entry/entry_bodies.dart';

import 'package:flutter/widgets.dart';

import '../../editor/config_editor.dart';
import '../../editor/editor_controller.dart';
import '../../workflow/dify_json.dart';
import '../../workflow/output_vars.dart';
import '../context_menu/workflow_actions.dart';
import '../panel_fields/panel_fields.dart';

/// What a node's body gets: the node as it is now, the collaboration-aware edit API and the canvas actions.
@immutable
class NodePanelProps {
  const NodePanelProps({required this.node, required this.controller, required this.actions});

  final Node node;

  /// Edits go through here, one small op per change (`setConfig`, `insertItem` / `updateItem` / `removeItem`); typed
  /// text passes the version its draft began on as `base` (see [DescriptionInput]).
  final EditorController controller;
  final WorkflowActions actions;

  String get id => node.id;
  bool get readOnly => actions.nodesReadOnly;
  bool get chatMode => actions.chatMode;

  /// Dify's node `data` (config as plain JSON, `type`, `title`); built on each call.
  Map<String, Object?> get data => difyDataOf(node);

  /// Sets the top-level `data.<key>` to [value] (plain JSON or a [Value]; null clears it).
  void setData(String key, Object? value, {int? base}) =>
      controller.setConfig(node.id, [key], value is Value ? value : Value.of(value), base: base);
}

/// Builds a node type's body.
typedef NodePanelBodyBuilder = Widget Function(BuildContext context, NodePanelProps props);

/// The bodies by node type, and the [fallback] for types without one. A node type's panel plugs in by adding its
/// builder: `NodePanelBodies({'llm': llmPanelBody, ...})`; the shell rebuilds it whenever the node changes.
class NodePanelBodies {
  const NodePanelBodies([this.bodies = const {}, this.fallback = genericNodePanelBody]);

  final Map<String, NodePanelBodyBuilder> bodies;
  final NodePanelBodyBuilder fallback;

  /// The bodies ported so far; other types use [genericNodePanelBody].
  static const defaults = NodePanelBodies({...corePanelBodies, ...dataPanelBodies, ...entryPanelBodies});

  NodePanelBodyBuilder of(String type) => bodies[type] ?? fallback;
}

/// Config keys the shell edits itself (description, retry, error handling) or that are not settings (React Flow's
/// node fields).
const _shellKeys = {'desc', 'retry_config', 'error_strategy', 'default_value', 'selected', 'type', 'title'};

/// The body of node types not ported yet: dify-sf's generic config editor over the node's settings (every config
/// field, keyed lists by item, references through the variable picker), then the output variables.
Widget genericNodePanelBody(BuildContext context, NodePanelProps props) {
  final n = props.node;
  final settings = Node(
    id: n.id,
    type: n.type,
    title: n.title,
    x: n.x,
    y: n.y,
    config: {
      for (final e in n.config.entries)
        if (!_shellKeys.contains(e.key) && !e.key.startsWith('_')) e.key: e.value,
    },
  );
  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: ConfigEditor(controller: props.controller, node: settings),
      ),
      NodeOutputVars(node: n, chatMode: props.chatMode),
    ],
  );
}

/// The variables [node] offers downstream, by name and type: its keyed `outputs` list when it has one (dify-sf's
/// declared outputs), else what Dify's `formatItem` gives for its data. Empty when the data is not what Dify expects.
List<({String name, String type})> nodeOutputVars(Node node, {bool chatMode = false}) {
  if (node.config['outputs'] case VItems(:final items)) {
    return [
      for (final i in items)
        if (i.value case VMap(:final entries))
          (name: jsStr(plainOf(entries['name'])) ?? i.id, type: jsStr(plainOf(entries['type'])) ?? ''),
    ];
  }
  try {
    return [
      for (final v in formatItem(node.id, difyDataOf(node), chatMode: chatMode)) (name: v.variable, type: v.type ?? ''),
    ];
  } on JsTypeError {
    return const [];
  }
}

/// The "Output Variables" section (output-vars.tsx with a VarItem per variable) after a [PanelSplit]; nothing when
/// the node has no outputs.
class NodeOutputVars extends StatelessWidget {
  const NodeOutputVars({super.key, required this.node, this.chatMode = false});
  final Node node;
  final bool chatMode;

  @override
  Widget build(BuildContext context) {
    final vars = nodeOutputVars(node, chatMode: chatMode);
    if (vars.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PanelSplit(),
        OutputVars(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [for (final v in vars) VarItem(name: v.name, type: v.type)],
          ),
        ),
      ],
    );
  }
}
