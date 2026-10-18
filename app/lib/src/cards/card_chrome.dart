import 'package:collab_client/collab_client.dart';
import 'package:flutter/material.dart';

import '../i18n/dify_i18n.dart';

import 'package:flutter/scheduler.dart';

import '../canvas/canvas_graph.dart';
import '../canvas/node_card.dart';
import '../design/css_metrics.dart';
import '../design/dify_icon.dart';
import '../design/dify_tokens.g.dart';
import '../design/widgets/tooltip.dart' show DifyTooltip;
import 'card_kit.dart';
import 'card_spinner.dart';
import 'dify_cards.dart';
import 'node_helpers.dart';
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
    // Cards are styled by Dify's tokens alone: nothing inherited from the app's (Material) text theme.
    return DefaultTextStyle(
      style: TextStyle(
        fontFamily: cardFontFamily,
        fontSize: 14,
        height: 20 / 14,
        letterSpacing: 0,
        wordSpacing: 0,
        color: DifyColors.textPrimary,
        leadingDistribution: TextLeadingDistribution.even,
      ),
      child: ListenableBuilder(
        listenable: Listenable.merge([
          node.node,
          node.hovered,
          // The run state shows in live cards; it sizes the retry row (with the selection) in every card.
          if (live || NodeExtras.hasRetry(node.node.value)) node.cardRun,
          if (NodeExtras.hasRetry(node.node.value)) node.selected,
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
      ),
    );
  }

  // `!data._runningStatus && 'hover:shadow-lg'`.
  List<BoxShadow> get _shadow =>
      node.hovered.value && node.cardRun.value.runningStatus == null ? DifyShadows.lg : DifyShadows.xs;

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
      // The 1 px border (transparent or not) takes space in CSS; a DecoratedBox only paints it.
      child: Padding(
        padding: const EdgeInsets.fromLTRB(1, 1, 1, 1 + 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(node: n, run: live ? node.cardRun.value : null),
            body.build(context, ctx),
            NodeExtras.build(n, node.cardRun.value, node.selected.value),
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
    child: Padding(padding: const EdgeInsets.all(1), child: body.build(context, ctx)),
  );

  /// `size-11 rounded-2xl border border-workflow-block-border bg-workflow-block-bg` (+ shadow-xs for iteration).
  Widget _marker(BuildContext context, NodeBody body, BodyContext ctx) => DecoratedBox(
    decoration: BoxDecoration(
      color: DifyColors.workflowBlockBg,
      borderRadius: BorderRadius.circular(DifyRadius.xxl),
      border: Border.all(color: DifyColors.workflowBlockBorder),
      boxShadow: body.chrome == CardChrome.marker ? DifyShadows.xs : null,
    ),
    child: Padding(padding: const EdgeInsets.all(1), child: body.build(context, ctx)),
  );
}

/// The header: `flex items-center rounded-t-2xl px-3 pt-3 pb-2`, block icon, title (`mr-1`), NodeHeaderMeta.
class _Header extends StatelessWidget {
  const _Header({required this.node, this.run});
  final Node node;

  /// The run state, on live cards only.
  final NodeRunView? run;

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
        NodeHeaderMeta(node: node, run: run),
      ],
    ),
  );
}

/// NodeHeaderMeta: the iteration's PARALLEL badge (its tooltip where the card is a widget, not a capture), then on
/// live cards ([run]) the run part ([NodeHeaderRunMeta]).
class NodeHeaderMeta extends StatelessWidget {
  const NodeHeaderMeta({super.key, required this.node, this.run});
  final Node node;
  final NodeRunView? run;

  @override
  Widget build(BuildContext context) {
    final parallel =
        node.type == 'iteration' && node.config['is_parallel'] is VBool && (node.config['is_parallel']! as VBool).value;
    Widget? badge;
    if (parallel) {
      badge = Container(
        margin: const EdgeInsets.only(left: 4),
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
        decoration: BoxDecoration(
          border: Border.all(color: DifyColors.textWarning),
          borderRadius: BorderRadius.circular(DifyRadius.badge),
        ),
        child: DifyText(
          DifyI18n.tr('workflow', 'nodes.iteration.parallelModeUpper'),
          DifyType.system2xsMediumUppercase,
          color: DifyColors.textWarning,
        ),
      );
      if (!CanvasSpinners.drawnByCanvasOf(context)) {
        badge = DifyTooltip(
          content: SizedBox(
            width: 180,
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '${DifyI18n.tr('workflow', 'nodes.iteration.parallelModeEnableTitle')}\n',
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  TextSpan(text: DifyI18n.tr('workflow', 'nodes.iteration.parallelModeEnableDesc')),
                ],
              ),
              style: difyStyle(DifyType.systemXsRegular, DifyColors.textSecondary),
            ),
          ),
          child: badge,
        );
      }
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [?badge, if (run != null) ...NodeHeaderRunMeta.children(node.type, run!)],
    );
  }
}

/// NodeHeaderMeta's run part: the iteration's `index/length` while it runs, the loop's round
/// (`nodes.loop.currentLoopCount` while it runs, `totalLoopCount` after), then the loader (`isLoading`) or the
/// status icon.
abstract final class NodeHeaderRunMeta {
  static List<Widget> children(String type, NodeRunView run) {
    final status = run.runningStatus;
    final iterLength = run.iterationLength ?? 0, iterIndex = run.iterationIndex ?? 0;
    final loopKey = getLoopIndexTextKey(status);
    return [
      if (iterLength != 0 && iterIndex != 0 && status == 'running')
        Padding(
          key: const Key('iteration-progress'),
          padding: const EdgeInsets.only(right: 6),
          child: DifyText(
            '${iterIndex > iterLength ? iterLength : iterIndex}/$iterLength',
            DifyType.systemXsMedium,
            color: DifyColors.textAccent,
          ),
        ),
      if (type == 'loop' && (run.loopIndex ?? 0) != 0 && loopKey != null)
        Padding(
          key: const Key('loop-index'),
          padding: const EdgeInsets.only(right: 8),
          child: DifyText(
            DifyI18n.tr('workflow', loopKey, {'count': run.loopIndex}),
            DifyType.systemXsMedium,
            color: status == 'running' ? DifyColors.textAccent : DifyColors.textTertiary,
          ),
        ),
      _StatusIcon(run: run),
    ];
  }
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
          DifyI18n.tr(
            'workflow',
            type == 'start' || type == 'start-placeholder' ? 'entryNodeStatus.enabled' : 'triggerStatus.enabled',
          ),
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
    child: Align(
      alignment: Alignment.topLeft,
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: SizedBox(
          height: 20,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Center(
              child: DifyText(
                DifyI18n.tr('workflow', 'blocks.datasource'),
                DifyType.system2xsSemiboldUppercase,
                color: DifyColors.textTertiary,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// block-icon.tsx sizes: xs 16 px tile (5 px radius, shadow-xs, 12 px glyph), sm 20 px (6 px, shadow-xs, 14 px),
/// md 24 px (8 px, shadow-md, 16 px).
enum BlockIconSize {
  xs(16, 5, 12),
  sm(20, DifyRadius.md, 14),
  md(24, DifyRadius.lg, 16);

  const BlockIconSize(this.box, this.radius, this.glyph);
  final double box, radius, glyph;
}

/// BlockIcon md (block-icon.tsx): 24 px tile, 8 px radius, shadow-md, the type's colour, a 16 px glyph ([size] picks
/// Dify's smaller ones). The start placeholder is a dashed tile with the glyph at 30 %.
class BlockIcon extends StatelessWidget {
  const BlockIcon({super.key, required this.type, this.size = BlockIconSize.md});
  final String type;
  final BlockIconSize size;

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
        foregroundDecoration: const CssDashedBorder(color: DifyColors.componentsPanelBorder, radius: DifyRadius.lg),
        child: Center(
          child: Opacity(
            opacity: 0.3,
            child: DifyIcon(blockGlyph(type), size: 16, color: DifyColors.textPrimary),
          ),
        ),
      );
    }
    return Container(
      width: size.box,
      height: size.box,
      decoration: BoxDecoration(
        color: blockColor(type),
        borderRadius: BorderRadius.circular(size.radius),
        border: Border.all(color: Colors.white.withValues(alpha: 0.02), width: 0.5),
        boxShadow: size == BlockIconSize.md ? DifyShadows.md : DifyShadows.xs,
      ),
      child: Center(
        child: DifyIcon(blockGlyph(type), size: size.glyph, color: Colors.white),
      ),
    );
  }
}

/// The run status icon at the header's right (NodeHeaderMeta): the spinning loader while the node (or its single
/// run) runs, else the failed / exception / succeeded (also: inspect variables without a running status) / paused
/// icon.
class _StatusIcon extends StatelessWidget {
  const _StatusIcon({required this.run});
  final NodeRunView run;

  @override
  Widget build(BuildContext context) {
    if (run.isLoading) return const CardSpinner(key: Key('status-spinner'));
    final (icon, color) = switch (run.status) {
      'failed' => ('error-warning-fill', DifyColors.textDestructive),
      'exception' => ('alert-fill', DifyColors.textWarningSecondary),
      'succeeded' => ('checkbox-circle-fill', DifyColors.textSuccess),
      'paused' => ('pause-circle-fill', DifyColors.textWarningSecondary),
      _ => (null, null),
    };
    if (icon == null) return const SizedBox.shrink();
    return RemixIcon(icon, size: 14, color: color, key: Key('status-$icon'));
  }
}
