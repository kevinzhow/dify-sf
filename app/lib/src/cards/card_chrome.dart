import 'package:collab_client/collab_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../canvas/canvas_graph.dart';
import '../canvas/node_card.dart';
import '../design/dify_icon.dart';
import '../design/dify_tokens.g.dart';
import 'card_kit.dart';
import 'dify_cards.dart';
import 'node_body.dart';
import 'node_extras.dart';

/// The card as Dify draws it (nodes/_base/node.tsx): the chrome the body asks for ([CardChrome]), entry nodes inside
/// their START/TRIGGER container, data sources on their tab.
class DifyNodeCard extends StatelessWidget {
  const DifyNodeCard({super.key, required this.node, required this.graph, required this.live, this.onPainted});

  final CanvasNode node;
  final CanvasGraph graph;
  final bool live;
  final VoidCallback? onPainted;

  @override
  Widget build(BuildContext context) {
    final body = DifyCards.bodyOf(node.type);
    return ListenableBuilder(
      listenable: Listenable.merge([
        node.node,
        node.hovered,
        if (live) node.status,
        if (body.chrome == CardChrome.container) graph.restingOrigin,
      ]),
      builder: (context, _) {
        if (onPainted != null) SchedulerBinding.instance.addPostFrameCallback((_) => onPainted!());
        final n = node.node.value;
        final ctx = DifyCards.context(
          n,
          (id) => graph[id]?.node.value,
          graph.startNode,
          viewOrigin: graph.restingOrigin.value,
        );
        final layout = node.layout;
        final card = SizedBox.fromSize(
          size: layout.card.size,
          child: switch (body.chrome) {
            CardChrome.marker || CardChrome.flatMarker => _marker(context, body, ctx),
            CardChrome.bodyOnly => _bodyOnly(context, body, ctx),
            _ => _card(context, n, body, ctx),
          },
        );
        if (layout.visual == layout.card) return card;
        final at = layout.card.topLeft - layout.visual.topLeft;
        return SizedBox.fromSize(
          size: layout.visual.size,
          child: Stack(
            children: [
              Positioned.fill(
                child: DifyCards.isEntry(n.type) ? _EntryContainer(type: n.type) : const _DataSourceTab(),
              ),
              Positioned(left: at.dx, top: at.dy, child: card),
            ],
          ),
        );
      },
    );
  }

  List<BoxShadow> get _shadow => node.hovered.value && node.status.value == 'idle' ? DifyShadows.lg : DifyShadows.xs;

  Widget _card(BuildContext context, Node n, NodeBody body, BodyContext ctx) {
    final container = body.chrome == CardChrome.container;
    final desc = body.chrome == CardChrome.base ? DifyCards.desc(n) : '';
    return DecoratedBox(
      decoration: BoxDecoration(
        color: container ? DifyColors.workflowBlockBgTransparent : DifyColors.workflowBlockBg,
        borderRadius: BorderRadius.circular(DifyRadius.nodeCard),
        border: Border.all(color: container ? DifyColors.workflowBlockBorder : Colors.transparent),
        boxShadow: _shadow,
      ),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(node: n, status: live ? node.status.value : null),
            body.build(context, ctx),
            NodeExtras.build(n),
            if (desc.isNotEmpty && n.type != 'start-placeholder')
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                child: Text(desc, style: difyStyle(DifyType.systemXsRegular, DifyColors.textTertiary)),
              ),
          ],
        ),
      ),
    );
  }

  /// `group relative shadow-xs rounded-[15px] border border-transparent w-60 bg-workflow-block-bg`, no header.
  Widget _bodyOnly(BuildContext context, NodeBody body, BodyContext ctx) => DecoratedBox(
    decoration: BoxDecoration(
      color: DifyColors.workflowBlockBg,
      borderRadius: BorderRadius.circular(DifyRadius.nodeCard),
      border: Border.all(color: Colors.transparent),
      boxShadow: DifyShadows.xs,
    ),
    child: body.build(context, ctx),
  );

  /// `size-11 rounded-2xl border border-workflow-block-border bg-workflow-block-bg` (+ shadow-xs for iteration).
  Widget _marker(BuildContext context, NodeBody body, BodyContext ctx) => DecoratedBox(
    decoration: BoxDecoration(
      color: DifyColors.workflowBlockBg,
      borderRadius: BorderRadius.circular(DifyRadius.xxl),
      border: Border.all(color: DifyColors.workflowBlockBorder),
      boxShadow: body.chrome == CardChrome.marker ? DifyShadows.xs : null,
    ),
    child: body.build(context, ctx),
  );
}

/// The header: `flex items-center rounded-t-2xl px-3 pt-3 pb-2`, block icon, title (`mr-1`), NodeHeaderMeta.
class _Header extends StatelessWidget {
  const _Header({required this.node, this.status});
  final Node node;

  /// The run status, on live cards only.
  final String? status;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
    child: Row(
      children: [
        BlockIcon(type: node.type),
        const SizedBox(width: 8),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(right: 4),
            child: DifyText(
              node.title.isEmpty ? node.type : node.title,
              DifyType.systemSmSemiboldUppercase,
              color: DifyColors.textPrimary,
            ),
          ),
        ),
        // dify-sf: references broken by a delete are shown, never dropped silently.
        if ([for (final v in node.config.values) ...v.brokenRefs].isNotEmpty)
          Tooltip(
            message: 'Broken references',
            child: RemixIcon(
              'link-unlink-m',
              size: 14,
              color: DifyColors.textDestructive,
              key: Key('broken-badge-${node.id}'),
            ),
          ),
        if (node.config['is_parallel'] case VBool(value: true) when node.type == 'iteration')
          Container(
            margin: const EdgeInsets.only(left: 4),
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
            decoration: BoxDecoration(
              border: Border.all(color: DifyColors.textWarning),
              borderRadius: BorderRadius.circular(DifyRadius.badge),
            ),
            child: const DifyText('Parallel Mode', DifyType.system2xsMediumUppercase, color: DifyColors.textWarning),
          ),
        if (status != null) _StatusIcon(status: status!),
      ],
    ),
  );
}

/// EntryNodeContainer: `rounded-2xl bg-workflow-block-wrapper-bg-1`, the START/TRIGGER label above the node.
class _EntryContainer extends StatelessWidget {
  const _EntryContainer({required this.type});
  final String type;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: DifyColors.workflowBlockWrapperBg1,
      borderRadius: BorderRadius.circular(DifyRadius.xxl),
    ),
    child: Align(
      alignment: Alignment.topLeft,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 4, 10, 0),
        child: DifyText(
          type == 'start' || type == 'start-placeholder' ? 'START' : 'TRIGGER',
          DifyType.system2xsSemiboldUppercase,
          color: DifyColors.textTertiary,
        ),
      ),
    ),
  );
}

/// The tab behind data source nodes: `rounded-[18px] bg-node-data-source-bg p-0.5`, a `h-5 px-2.5` label row.
/// (Dify also blurs the canvas behind it, `backdrop-blur-[6px]`; a captured card can't see the canvas.)
class _DataSourceTab extends StatelessWidget {
  const _DataSourceTab();

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      gradient: DifyGradients.nodeDataSourceBg,
      borderRadius: BorderRadius.circular(DifyRadius.dataSourceTab),
    ),
    child: const Align(
      alignment: Alignment.topLeft,
      child: Padding(
        padding: EdgeInsets.all(2),
        child: SizedBox(
          height: 20,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 10),
            child: Center(
              child: DifyText('Data Source', DifyType.system2xsSemiboldUppercase, color: DifyColors.textTertiary),
            ),
          ),
        ),
      ),
    ),
  );
}

/// BlockIcon md (block-icon.tsx): 24 px tile, 8 px radius, shadow-md, the type's colour, a 16 px glyph. The start
/// placeholder is a dashed tile with the glyph at 30 %.
class BlockIcon extends StatelessWidget {
  const BlockIcon({super.key, required this.type});
  final String type;

  @override
  Widget build(BuildContext context) {
    if (type == 'start-placeholder') {
      return Container(
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          color: DifyColors.stateBaseHover,
          borderRadius: BorderRadius.circular(DifyRadius.lg),
        ),
        foregroundDecoration: _DashedBorder(DifyColors.componentsPanelBorder, DifyRadius.lg),
        child: Center(
          child: Opacity(
            opacity: 0.3,
            child: DifyIcon(blockGlyph(type), size: 16, color: DifyColors.textPrimary),
          ),
        ),
      );
    }
    return Container(
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
}

/// A 1 px dashed rounded border (CSS `border border-dashed`: dashes about three times the width, gaps the same).
class _DashedBorder extends Decoration {
  const _DashedBorder(this.color, this.radius);
  final Color color;
  final double radius;

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) => _DashedPainter(this);
}

class _DashedPainter extends BoxPainter {
  _DashedPainter(this.d);
  final _DashedBorder d;

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final rect = (offset & configuration.size!).deflate(0.5);
    final path = Path()..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(d.radius - 0.5)));
    final paint = Paint()
      ..color = d.color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final m in path.computeMetrics()) {
      for (var t = 0.0; t < m.length; t += 6) {
        canvas.drawPath(m.extractPath(t, t + 3), paint);
      }
    }
  }
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
    return RemixIcon(icon, size: 14, color: color);
  }
}
