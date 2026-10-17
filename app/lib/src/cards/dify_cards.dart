import 'package:collab_client/collab_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../canvas/canvas_graph.dart';
import '../canvas/node_card.dart';
import '../design/dify_icon.dart';
import '../design/dify_tokens.g.dart';
import 'bodies/answer_body.dart';
import 'bodies/basic_bodies.dart';
import 'card_kit.dart';
import 'node_body.dart';

/// Dify's node cards: the shared chrome (nodes/_base/node.tsx) around a body per node type.
class DifyCards extends CardSpec {
  const DifyCards();

  static const width = 240.0;
  static const _header = 44.0; // pt-3 + 24 px icon + pb-2
  static const _border = 1.0;
  static const _bottom = 4.0; // pb-1
  static const _entryLabel =
      21.0; // EntryNodeContainer: label row above the node (use-helpline ENTRY_NODE_WRAPPER_OFFSET)

  static const bodies = <String, NodeBody>{
    'start': StartBody(),
    'end': EndBody(),
    'answer': AnswerBody(),
    'if-else': IfElseBody(),
  };

  static NodeBody bodyOf(String type) => bodies[type] ?? const NoBody();

  /// Every icon (asset, colour) cards draw, decoded before the canvas starts (see IconCache).
  static Iterable<(String, Color)> get icons sync* {
    const types = [
      'start',
      'llm',
      'code',
      'end',
      'if-else',
      'http-request',
      'answer',
      'knowledge-retrieval',
      'question-classifier',
      'template-transform',
      'assigner',
      'iteration',
      'loop',
      'loop-end',
      'parameter-extractor',
      'document-extractor',
      'list-operator',
      'agent',
      'knowledge-index',
      'datasource',
      'trigger-schedule',
      'trigger-webhook',
      'human-input',
      'tool',
    ];
    for (final t in types) {
      final glyph = 'assets/dify_icons/${blockGlyph(t)}.svg';
      yield (glyph, Colors.white);
      yield (glyph, DifyColors.textSecondary);
    }
    for (final k in VarKind.values) {
      yield ('assets/dify_icons/${varIcon(k)}.svg', varColor(k));
      yield ('assets/dify_icons/${varIcon(k)}.svg', DifyColors.textWarning);
    }
    for (final name in const [
      'align-left',
      'checkbox-multiple-line',
      'hashtag',
      'checkbox-line',
      'braces-line',
      'file-list-2-line',
      'file-copy-2-line',
      'text-snippet',
    ]) {
      yield ('assets/remix_icons/$name.svg', DifyColors.textTertiary);
    }
    yield ('assets/remix_icons/loader-2-line.svg', DifyColors.textAccent);
    yield ('assets/remix_icons/error-warning-fill.svg', DifyColors.textDestructive);
    yield ('assets/remix_icons/alert-fill.svg', DifyColors.textWarningSecondary);
    yield ('assets/remix_icons/checkbox-circle-fill.svg', DifyColors.textSuccess);
    yield ('assets/remix_icons/pause-circle-fill.svg', DifyColors.textWarningSecondary);
    yield ('assets/remix_icons/link-unlink-m.svg', DifyColors.textDestructive);
  }

  static bool isEntry(String type) => type == 'start' || type == 'start-placeholder' || type.startsWith('trigger-');

  static String _desc(Node n) => n.config['desc'] is VString ? (n.config['desc']! as VString).value : '';

  /// NodeDescription: `px-3 pt-1 pb-2 system-xs-regular`, hidden when empty.
  static double _descHeight(Node n) {
    final d = _desc(n);
    if (d.isEmpty || n.type == 'iteration' || n.type == 'loop') return 0;
    return 4 + textHeight(d, difyStyle(DifyType.systemXsRegular, DifyColors.textTertiary), width - 2 - 24) + 8;
  }

  static BodyContext context(Node n, Node? Function(String) lookup, Node? start) =>
      BodyContext(n, lookup, start: start);

  @override
  CardLayout layoutOf(Node node, Document doc) {
    final ctx = context(node, (id) => doc.nodes[id], doc.nodes.values.where((n) => n.type == 'start').firstOrNull);
    final body = bodyOf(node.type);
    final bodyH = body.height(ctx);
    final h = _border + _header + bodyH + _descHeight(node) + _bottom + _border;
    // React Flow's node element is the selection frame; the card sits 1 px inside it, entry nodes below their label.
    final top = isEntry(node.type) ? _entryLabel + 1 : 1.0;
    final card = Rect.fromLTWH(1, top, width, h);
    final sources = body.sources(ctx);
    return CardLayout(
      card: card,
      visual: isEntry(node.type) ? Rect.fromLTWH(0, 0, width + 2, top + h + 1) : card,
      sources: sources == null
          ? const {'source': CanvasNode.defaultHandleY}
          : {for (final e in sources.entries) e.key: _border + _header + e.value},
      target: body.target,
    );
  }

  @override
  Widget build(
    BuildContext context,
    CanvasNode node,
    CanvasGraph graph, {
    required bool live,
    VoidCallback? onPainted,
  }) => DifyNodeCard(node: node, graph: graph, live: live, onPainted: onPainted);
}

/// The card as Dify draws it: chrome, header, body, description; entry nodes inside their START/TRIGGER container.
class DifyNodeCard extends StatelessWidget {
  const DifyNodeCard({super.key, required this.node, required this.graph, required this.live, this.onPainted});

  final CanvasNode node;
  final CanvasGraph graph;
  final bool live;
  final VoidCallback? onPainted;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([node.node, node.hovered, if (live) node.status]),
    builder: (context, _) {
      if (onPainted != null) SchedulerBinding.instance.addPostFrameCallback((_) => onPainted!());
      final n = node.node.value;
      final ctx = DifyCards.context(n, (id) => graph[id]?.node.value, graph.startNode);
      final card = SizedBox.fromSize(size: node.size, child: _card(context, n, ctx));
      if (!DifyCards.isEntry(n.type)) return card;
      return SizedBox.fromSize(
        size: node.layout.visual.size,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: DifyColors.workflowBlockWrapperBg1,
            borderRadius: BorderRadius.circular(DifyRadius.xxl),
          ),
          child: Stack(
            children: [
              Positioned(
                left: 10,
                top: 4,
                child: DifyText(
                  n.type == 'start' || n.type == 'start-placeholder' ? 'START' : 'TRIGGER',
                  DifyType.system2xsSemiboldUppercase,
                  color: DifyColors.textTertiary,
                ),
              ),
              Positioned(left: 1, top: node.layout.card.top, child: card),
            ],
          ),
        ),
      );
    },
  );

  Widget _card(BuildContext context, Node n, BodyContext ctx) {
    final desc = DifyCards._desc(n);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: DifyColors.workflowBlockBg,
        borderRadius: BorderRadius.circular(DifyRadius.nodeCard),
        border: Border.all(color: Colors.transparent),
        boxShadow: node.hovered.value && node.status.value == 'idle' ? DifyShadows.lg : DifyShadows.xs,
      ),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
              child: Row(
                children: [
                  BlockIcon(type: n.type),
                  const SizedBox(width: 8),
                  Expanded(
                    child: DifyText(
                      n.title.isEmpty ? n.type : n.title,
                      DifyType.systemSmSemiboldUppercase,
                      color: DifyColors.textPrimary,
                    ),
                  ),
                  // dify-sf: references broken by a delete are shown, never dropped silently.
                  if ([for (final v in n.config.values) ...v.brokenRefs].isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: Tooltip(
                        message: 'Broken references',
                        child: RemixIcon(
                          'link-unlink-m',
                          size: 14,
                          color: DifyColors.textDestructive,
                          key: Key('broken-badge-${n.id}'),
                        ),
                      ),
                    ),
                  if (live) _StatusIcon(status: node.status.value),
                ],
              ),
            ),
            DifyCards.bodyOf(n.type).build(context, ctx),
            if (desc.isNotEmpty && n.type != 'iteration' && n.type != 'loop')
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                child: Text(desc, style: difyStyle(DifyType.systemXsRegular, DifyColors.textTertiary)),
              ),
          ],
        ),
      ),
    );
  }
}

/// BlockIcon md (block-icon.tsx): 24 px tile, 8 px radius, shadow-md, the type's colour, a 16 px glyph.
class BlockIcon extends StatelessWidget {
  const BlockIcon({super.key, required this.type});
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
    child: Center(child: DifyIcon(blockGlyph(type), size: 16, color: Colors.white)),
  );
}

/// The run status icon at the header's right (NodeHeaderMeta).
class _StatusIcon extends StatelessWidget {
  const _StatusIcon({required this.status});
  final String status;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (status) {
      'running' => ('loader-2-line', DifyColors.textAccent),
      'failed' => ('error-warning-fill', DifyColors.textDestructive),
      'exception' => ('alert-fill', DifyColors.textWarningSecondary),
      'succeeded' => ('checkbox-circle-fill', DifyColors.textSuccess),
      'paused' => ('pause-circle-fill', DifyColors.textWarningSecondary),
      _ => (null, null),
    };
    if (icon == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: RemixIcon(icon, size: 14, color: color),
    );
  }
}
