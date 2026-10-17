import 'package:collab_client/collab_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'canvas_graph.dart';

/// How cards look and how big they are. The Dify-faithful cards per node type replace [NodeCard] later; the canvas
/// only needs a size per node and a widget.
class CardSpec {
  const CardSpec();

  Size sizeOf(Node node) => const Size(220, 78);

  /// The card for [node]. [live] cards show run status in their content (captures for zoomed-out views leave it
  /// out: the canvas draws status itself). [onPainted] is called after a frame in which the card repainted.
  Widget build(BuildContext context, CanvasNode node, {required bool live, VoidCallback? onPainted}) =>
      NodeCard(node: node, live: live, onPainted: onPainted);
}

Color typeColor(String type) => switch (type) {
  'start' => Colors.green.shade600,
  'llm' => Colors.indigo.shade500,
  'code' => Colors.orange.shade700,
  'answer' => Colors.teal.shade600,
  _ => Colors.blueGrey,
};

class NodeCard extends StatelessWidget {
  const NodeCard({super.key, required this.node, required this.live, this.onPainted});

  final CanvasNode node;
  final bool live;
  final VoidCallback? onPainted;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: Listenable.merge([node.node, if (live) node.status]),
      builder: (context, _) {
        if (onPainted != null) SchedulerBinding.instance.addPostFrameCallback((_) => onPainted!());
        final n = node.node.value;
        final accent = typeColor(n.type);
        final broken = [for (final v in n.config.values) ...v.brokenRefs].length;
        final status = node.status.value;
        return SizedBox.fromSize(
          size: node.size,
          child: Material(
            color: scheme.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: BorderSide(color: scheme.outlineVariant),
            ),
            clipBehavior: Clip.antiAlias,
            child: Row(
              children: [
                Container(width: 6, color: accent),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          n.title.isEmpty ? '(untitled)' : n.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Text(
                              live && status != 'idle' ? '${n.type} · $status' : n.type,
                              style: TextStyle(color: accent, fontSize: 12, fontWeight: FontWeight.w500),
                            ),
                            if (broken > 0) ...[
                              const SizedBox(width: 8),
                              Icon(Icons.link_off, size: 14, color: scheme.error, key: Key('broken-badge-${n.id}')),
                              const SizedBox(width: 2),
                              Text('$broken broken', style: TextStyle(color: scheme.error, fontSize: 12)),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
