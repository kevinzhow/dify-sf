import 'package:collab_client/collab_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../design/dify_tokens.g.dart';
import 'canvas_graph.dart';

/// How cards look and how big they are. Per-type bodies (phase 3 of the replica) plug in here; the canvas only needs
/// a size per node and a widget.
class CardSpec {
  const CardSpec();

  /// Dify's NODE_WIDTH; the height of the header-only card (12 top + 24 icon + 8 bottom + 4 card bottom padding,
  /// plus the 1 px border on both sides).
  static const width = 240.0;
  static const headerOnlyHeight = 50.0;

  Size sizeOf(Node node) => const Size(width, headerOnlyHeight);

  /// The card for [node]. [live] cards show run status in their content (captures for zoomed-out views leave it
  /// out: the canvas draws status itself). [onPainted] is called after a frame in which the card repainted.
  Widget build(BuildContext context, CanvasNode node, {required bool live, VoidCallback? onPainted}) =>
      NodeCard(node: node, live: live, onPainted: onPainted);
}

/// BlockIcon background by node type (block-icon.tsx).
Color blockColor(String type) => switch (type) {
  'start' || 'start-placeholder' => const Color(0xFF085AFC),
  'llm' || 'agent' || 'agent-v2' => const Color(0xFF6172F3),
  'code' ||
  'template-transform' ||
  'variable-assigner' ||
  'variable-aggregator' ||
  'tool' ||
  'assigner' ||
  'parameter-extractor' ||
  'trigger-webhook' ||
  'trigger-plugin' => const Color(0xFF2E90FA),
  'end' || 'answer' || 'loop-end' || 'knowledge-base' => const Color(0xFFF79009),
  'if-else' || 'iteration' || 'loop' || 'list-operator' || 'human-input' => const Color(0xFF06AED4),
  'http-request' || 'trigger-schedule' => const Color(0xFF875BF7),
  'knowledge-retrieval' || 'question-classifier' || 'document-extractor' => const Color(0xFF17B26A),
  'datasource' || 'data-source' => const Color(0xFF828DAD),
  _ => const Color(0xFF828DAD),
};

/// The node card's chrome (nodes/_base/node.tsx): 240 px wide, a 1 px transparent border (the canvas draws the run
/// status border behind it), radius 15, workflow-block-bg, shadow-xs (shadow-lg on hover), and the header: a 24 px
/// block icon and the title in system-sm-semibold uppercase.
class NodeCard extends StatelessWidget {
  const NodeCard({super.key, required this.node, required this.live, this.onPainted});

  final CanvasNode node;
  final bool live;
  final VoidCallback? onPainted;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([node.node, node.hovered, if (live) node.status]),
      builder: (context, _) {
        if (onPainted != null) SchedulerBinding.instance.addPostFrameCallback((_) => onPainted!());
        final n = node.node.value;
        final broken = [for (final v in n.config.values) ...v.brokenRefs].length;
        final title = DifyType.systemSmSemiboldUppercase;
        return SizedBox.fromSize(
          size: node.size,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: DifyColors.workflowBlockBg,
              borderRadius: BorderRadius.circular(DifyRadius.nodeCard),
              border: Border.all(color: Colors.transparent),
              boxShadow: node.hovered.value && node.status.value == 'idle' ? DifyShadows.lg : DifyShadows.xs,
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _BlockIcon(type: n.type),
                  const SizedBox(width: 8),
                  Expanded(
                    child: SizedBox(
                      height: 24,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          (n.title.isEmpty ? n.type : n.title).toUpperCase(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: title.style.copyWith(color: DifyColors.textPrimary),
                        ),
                      ),
                    ),
                  ),
                  if (broken > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 5),
                      child: Icon(
                        Icons.link_off,
                        size: 14,
                        color: DifyColors.textDestructive,
                        key: Key('broken-badge-${n.id}'),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _BlockIcon extends StatelessWidget {
  const _BlockIcon({required this.type});
  final String type;

  @override
  Widget build(BuildContext context) => Container(
    width: 24,
    height: 24,
    decoration: BoxDecoration(
      color: blockColor(type),
      borderRadius: BorderRadius.circular(DifyRadius.lg),
      border: Border.all(color: Colors.white.withValues(alpha: 0.02), width: 0.5),
      boxShadow: DifyShadows.md,
    ),
    // Dify's per-type glyphs come with the node cards (replica phase 3).
    child: Center(
      child: Text(
        type.isEmpty ? '?' : type[0].toUpperCase(),
        style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600, height: 1),
      ),
    ),
  );
}
