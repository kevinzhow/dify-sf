/// run/tracing-panel.tsx: a run's node executions as formatted by format-log — node cards, parallel groups (a
/// collapsible "PARALLEL-1" header over a branch line, highlighted while hovered) with branch labels — or, while one
/// is open, a detail view (retries, iterations, loops, agent log).
library;

import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../../../cards/card_kit.dart';
import '../../../design/dify_icon.dart';
import '../../../design/dify_tokens.g.dart';
import '../../../design/widgets/widgets.dart';
import '../../store/workflow_store.dart' show DifyJson;
import 'format_log.dart';
import 'log_widgets.dart';
import 'run_logs.dart';
import 'run_widgets.dart' show ExpandedSemantics;
import 'tracing_node.dart';

class TracingPanel extends StatefulWidget {
  const TracingPanel({
    super.key,
    required this.list,
    this.background,
    this.hideNodeInfo = false,
    this.hideNodeProcessDetail = false,
    this.scrollable = false,
    this.formatNodeList,
    this.logs,
    this.onOpenUrl,
  });

  final NodeTracingList list;
  final Color? background;
  final bool hideNodeInfo;
  final bool hideNodeProcessDetail;

  /// Lays the rows out lazily in its own scroll view (the run panels' Tracing tab); otherwise a column for a parent
  /// scroll view.
  final bool scrollable;

  /// format-log's `formatToTracingNodeList` (tests replace it as Dify's tests mock the module).
  final List<DifyJson> Function(NodeTracingList list)? formatNodeList;

  /// The detail view state (`useLogs`); the panel keeps its own by default.
  final RunLogs? logs;
  final ValueChanged<String>? onOpenUrl;

  @override
  State<TracingPanel> createState() => _TracingPanelState();
}

class _TracingPanelState extends State<TracingPanel> {
  RunLogs? _ownLogs;
  RunLogs get _logs => widget.logs ?? (_ownLogs ??= RunLogs());
  final _collapsed = <String>{};

  /// The parallel groups under the pointer, outermost first: the hovered one is the innermost (Dify resolves the
  /// group a pointer leaves into with `closest('[data-parallel-id]')`).
  final _hoverStack = <String>[];

  /// Formatted when the list is given (Dify formats on every render; the panel's own state changes need no format).
  late List<DifyJson> _treeNodes = _format();

  List<DifyJson> _format() => (widget.formatNodeList ?? formatToTracingNodeList)(widget.list);

  @override
  void didUpdateWidget(TracingPanel old) {
    super.didUpdateWidget(old);
    _treeNodes = _format();
  }

  @override
  void dispose() {
    _ownLogs?.dispose();
    super.dispose();
  }

  String? get _hovered => _hoverStack.lastOrNull;

  Widget _renderNode(DifyJson node) {
    final id = '${node['id']}';
    final detail = node['parallelDetail'] as Map?;
    if (detail?['isParallelStartNode'] == true) {
      final collapsed = _collapsed.contains(id);
      final hovered = _hovered == id;
      final title = '${detail!['parallelTitle'] ?? ''}';
      final children = [for (final c in (detail['children'] as List? ?? const [])) c as DifyJson];
      return MouseRegion(
        key: ValueKey('parallel-$id'),
        onEnter: (_) => setState(() => _hoverStack.add(id)),
        onExit: (_) => setState(() => _hoverStack.remove(id)),
        child: Padding(
          padding: const EdgeInsets.only(left: 16, bottom: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    ExpandedSemantics(
                      expanded: !collapsed,
                      child: DifyPressable(
                        semanticLabel: title,
                        onPressed: () => setState(() => collapsed ? _collapsed.remove(id) : _collapsed.add(id)),
                        builder: (context, h, focused) => Container(
                          margin: const EdgeInsets.only(right: 8),
                          decoration: hovered
                              ? BoxDecoration(
                                  color: DifyColors.componentsButtonPrimaryBg,
                                  borderRadius: BorderRadius.circular(DifyRadius.sm),
                                  border: Border.all(color: DifyColors.componentsButtonPrimaryBorder),
                                )
                              : null,
                          child: hovered
                              ? RemixIcon('arrow-down-s-line', size: 12, color: DifyColors.textPrimaryOnSurface)
                              : RemixIcon('menu-4-line', size: 12, color: DifyColors.textTertiary),
                        ),
                      ),
                    ),
                    DifyText(title, DifyType.systemXsSemiboldUppercase, color: DifyColors.textSecondary),
                    Expanded(
                      child: Container(
                        height: 1,
                        margin: const EdgeInsets.symmetric(horizontal: 8),
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(colors: [Color(0x14101828), Color(0x00FFFFFF)]),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Offstage(
                offstage: collapsed,
                child: Stack(
                  children: [
                    Positioned(
                      top: 0,
                      bottom: 0,
                      left: 5,
                      width: 2,
                      child: ColoredBox(color: hovered ? DifyColors.textAccentSecondary : DifyColors.dividerSubtle),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [for (final c in children) _renderNode(c)],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }
    final hovered = _hovered == id;
    final branchTitle = detail?['branchTitle'] as String?;
    return Column(
      key: ValueKey('node-$id'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (branchTitle != null && branchTitle.isNotEmpty)
          Transform.translate(
            offset: const Offset(0, 0),
            child: Padding(
              padding: const EdgeInsets.only(left: 16),
              child: SizedBox(
                // `-mb-1.5`: the label overlaps the card's top padding.
                height: 18 - 6,
                child: OverflowBox(
                  alignment: Alignment.topLeft,
                  maxHeight: 18,
                  child: DifyText(
                    branchTitle,
                    DifyType.system2xsMediumUppercase,
                    color: hovered ? DifyColors.textTertiary : DifyColors.textQuaternary,
                  ),
                ),
              ),
            ),
          ),
        // An empty branch title (`-mb-1.5`) still pulls the card up into the gap above it.
        _PullUp(
          by: branchTitle == null || branchTitle.isEmpty ? 6 : 0,
          child: RunNodePanel(
            nodeInfo: node,
            allExecutions: widget.list,
            onShowIterationDetail: _logs.handleShowIterationResultList,
            onShowLoopDetail: _logs.handleShowLoopResultList,
            onShowRetryDetail: _logs.handleShowRetryResultList,
            onShowAgentOrToolLog: _logs.handleShowAgentOrToolLog,
            hideInfo: widget.hideNodeInfo,
            hideProcessDetail: widget.hideNodeProcessDetail,
            onOpenUrl: widget.onOpenUrl,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _logs,
    builder: (context, _) {
      if (_logs.showSpecialResultPanel) {
        final panel = SpecialResultPanel(logs: _logs);
        return widget.scrollable ? SingleChildScrollView(child: panel) : panel;
      }
      final nodes = _treeNodes;
      // `onClick={e => e.stopPropagation()}`: taps inside never reach what is behind the panel.
      Widget content;
      if (widget.scrollable) {
        content = ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: nodes.length,
          itemBuilder: (context, i) => _renderNode(nodes[i]),
        );
      } else {
        content = Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [for (final n in nodes) _renderNode(n)],
          ),
        );
      }
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {},
        child: widget.background == null ? content : ColoredBox(color: widget.background!, child: content),
      );
    },
  );
}

/// A negative top margin of [by]: the child is drawn [by] higher and takes that much less height.
class _PullUp extends SingleChildRenderObjectWidget {
  const _PullUp({required this.by, required super.child});
  final double by;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderPullUp(by);

  @override
  void updateRenderObject(BuildContext context, _RenderPullUp renderObject) => renderObject.by = by;
}

class _RenderPullUp extends RenderProxyBox {
  _RenderPullUp(this._by);
  double _by;
  set by(double v) {
    if (v == _by) return;
    _by = v;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    child!.layout(constraints.loosen().copyWith(minWidth: constraints.minWidth), parentUsesSize: true);
    size = constraints.constrain(Size(child!.size.width, math.max(0, child!.size.height - _by)));
  }

  @override
  void paint(PaintingContext context, Offset offset) => context.paintChild(child!, offset - Offset(0, _by));

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) => result.addWithPaintOffset(
    offset: Offset(0, -_by),
    position: position,
    hitTest: (result, transformed) => child!.hitTest(result, position: transformed),
  );

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) => transform.translateByDouble(0, -_by, 0, 1);
}
