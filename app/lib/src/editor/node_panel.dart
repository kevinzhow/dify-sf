import 'package:collab_client/collab_client.dart';
import 'package:flutter/material.dart';

import 'config_editor.dart';
import 'editor_controller.dart';
import 'graph_info.dart';
import 'synced_text_field.dart';

/// The right-hand panel: the selected node's title and config, or the selected connection.
class NodePanel extends StatelessWidget {
  const NodePanel({super.key, required this.controller});

  final EditorController controller;

  @override
  Widget build(BuildContext context) {
    final node = controller.selectedNode;
    final edge = controller.selectedEdgeId == null ? null : controller.doc.edges[controller.selectedEdgeId!];
    Widget body;
    if (node != null) {
      body = _NodeDetails(key: ValueKey('panel-${node.id}'), controller: controller, node: node);
    } else if (edge != null) {
      body = _EdgeDetails(controller: controller, edge: edge);
    } else {
      body = const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Select a node to edit its title, configuration and outputs.\n\n'
            'Drag from a node\'s right handle to another node to connect them.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.black54),
          ),
        ),
      );
    }
    return Container(
      width: 360,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(left: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: body,
    );
  }
}

class _EdgeDetails extends StatelessWidget {
  const _EdgeDetails({required this.controller, required this.edge});
  final EditorController controller;
  final Edge edge;

  @override
  Widget build(BuildContext context) {
    return ListView(padding: const EdgeInsets.all(16), children: [
      Text('Connection', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 8),
      Text('${controller.titleOf(edge.source)}  →  ${controller.titleOf(edge.target)}'),
      const SizedBox(height: 16),
      OutlinedButton.icon(
        key: const Key('delete-edge'),
        icon: const Icon(Icons.link_off),
        label: const Text('Delete connection'),
        onPressed: () => controller.deleteEdge(edge.id),
      ),
    ]);
  }
}

class _NodeDetails extends StatelessWidget {
  const _NodeDetails({super.key, required this.controller, required this.node});
  final EditorController controller;
  final Node node;

  @override
  Widget build(BuildContext context) {
    final broken = _brokenIn(node);
    return ListView(padding: const EdgeInsets.all(16), children: [
      Row(children: [
        Chip(label: Text(node.type), visualDensity: VisualDensity.compact),
        const SizedBox(width: 8),
        Expanded(
          child: Text(node.id, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: Colors.black45)),
        ),
        IconButton(
          key: const Key('delete-node'),
          tooltip: 'Delete node',
          icon: const Icon(Icons.delete_outline),
          onPressed: () => _confirmDelete(context),
        ),
      ]),
      const SizedBox(height: 8),
      SyncedTextField(
        key: ValueKey('title-${node.id}'),
        value: node.title,
        label: 'Title',
        currentVersion: () => controller.seenVersion,
        onCommit: (text, base) => controller.setTitle(node.id, text, base: base),
      ),
      if (broken.isNotEmpty) ...[
        const SizedBox(height: 12),
        _BrokenSummary(controller: controller, broken: broken),
      ],
      const SizedBox(height: 16),
      Text('Configuration', style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 8),
      ConfigEditor(controller: controller, node: node),
    ]);
  }

  static List<OutputRef> _brokenIn(Node n) => [for (final v in n.config.values) ...v.brokenRefs];

  Future<void> _confirmDelete(BuildContext context) async {
    final refs = controller.referencesTo(node.id);
    final title = controller.titleOf(node.id);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const Key('delete-dialog'),
        title: Text('Delete $title?'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(refs.isEmpty
              ? 'Its connections will be removed.'
              : 'Its connections will be removed, and ${refs.length} reference${refs.length == 1 ? '' : 's'} to it '
                  'will be marked as broken:'),
          const SizedBox(height: 8),
          for (final r in refs)
            Text('• ${controller.titleOf(r.node)} › ${fieldLabel(r.field)}  (${r.ref.node}.${r.ref.output})',
                style: const TextStyle(fontSize: 13)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            key: const Key('confirm-delete'),
            style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok ?? false) controller.deleteNode(node.id);
  }
}

class _BrokenSummary extends StatelessWidget {
  const _BrokenSummary({required this.controller, required this.broken});
  final EditorController controller;
  final List<OutputRef> broken;

  @override
  Widget build(BuildContext context) {
    final red = Theme.of(context).colorScheme.error;
    return Container(
      key: const Key('broken-summary'),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: red.withValues(alpha: 0.08),
        border: Border.all(color: red.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.link_off, color: red, size: 18),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '${broken.length} broken reference${broken.length == 1 ? '' : 's'}: the node'
            '${broken.map((r) => r.node).toSet().length == 1 ? '' : 's'} they pointed to '
            '${broken.map((r) => r.node).toSet().length == 1 ? 'was' : 'were'} deleted. Pick new variables below.',
            style: TextStyle(color: red, fontSize: 13),
          ),
        ),
      ]),
    );
  }
}
