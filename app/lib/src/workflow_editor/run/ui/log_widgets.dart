/// The tracing panel's detail views and the buttons that open them: run/iteration-log, run/loop-log, run/retry-log,
/// run/agent-log and run/special-result-panel.tsx.
library;

import 'package:flutter/widgets.dart';

import '../../../cards/card_chrome.dart' show BlockIcon, BlockIconSize;
import '../../../cards/card_kit.dart';
import '../../../design/css_metrics.dart';
import '../../../design/dify_icon.dart';
import '../../../design/dify_tokens.g.dart';
import '../../../design/widgets/widgets.dart';
import '../../../i18n/dify_i18n.dart';
import '../../code_editor/code_editor.dart';
import '../../header/header_widgets.dart' show Spinning;
import '../../store/workflow_store.dart' show DifyJson;
import 'run_logs.dart';
import 'tracing_node.dart';
import 'tracing_panel.dart';

String _tw(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('workflow', key, params);

DifyJson? _meta(DifyJson n) => n['execution_metadata'] as DifyJson?;
List<NodeTracingList> _details(DifyJson n) => [
  for (final row in (n['details'] as List? ?? const [])) (row as List).cast<DifyJson>(),
];

/// The iteration/loop trigger's face: `flex w-full items-center rounded-lg bg-components-button-tertiary-bg-hover
/// px-3 py-2`, the icon, the `system-sm-medium` label and an arrow, all in the tertiary button's text colour.
class _ContainerLogButton extends StatelessWidget {
  const _ContainerLogButton({required this.icon, required this.label, required this.onPressed});
  final String icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => DifyPressable(
    semanticLabel: label,
    onPressed: onPressed,
    builder: (context, hovered, focused) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: DifyColors.componentsButtonTertiaryBgHover,
        borderRadius: BorderRadius.circular(DifyRadius.lg),
        boxShadow: focused ? const [BoxShadow(spreadRadius: 2, color: DifyColors.stateAccentSolid)] : null,
      ),
      child: Row(
        spacing: 4,
        children: [
          DifyIcon(icon, size: 16, color: DifyColors.componentsButtonTertiaryText),
          Expanded(
            child: DifyText(label, DifyType.systemSmMedium, color: DifyColors.componentsButtonTertiaryText),
          ),
          const RemixIcon('arrow-right-s-line', size: 16, color: DifyColors.componentsButtonTertiaryText),
        ],
      ),
    ),
  );
}

/// IterationLogTrigger: "N Iterations[, M Errors]"; opens the iteration runs, rebuilt from [allExecutions] by the
/// node's `iteration_duration_map` when present (adding failed runs only in `details`).
class IterationLogTrigger extends StatelessWidget {
  const IterationLogTrigger({
    super.key,
    required this.nodeInfo,
    this.allExecutions,
    required this.onShowIterationResultList,
  });

  final DifyJson nodeInfo;
  final NodeTracingList? allExecutions;
  final void Function(List<NodeTracingList> list, DurationMap durationMap) onShowIterationResultList;

  Map? get _durationMap => _meta(nodeInfo)?['iteration_duration_map'] as Map?;

  DurationMap _iterationDurationMap() =>
      ((nodeInfo['iterDurationMap'] as Map?) ?? _durationMap ?? const {}).cast<String, Object?>();

  int _displayCount() {
    final m = _durationMap;
    if (m != null) return m.length;
    final details = _details(nodeInfo);
    if (details.isNotEmpty) return details.length;
    return ((nodeInfo['metadata'] as Map?)?['iterator_length'] as num?)?.toInt() ?? 0;
  }

  Set<int> _failedIterationIndices() {
    final details = _details(nodeInfo);
    if (details.isEmpty) return {};
    final failed = <int>{};
    for (final (index, iteration) in details.indexed) {
      if (!iteration.any((i) => i['status'] == 'failed')) continue;
      failed.add(
        ((iteration.firstOrNull == null ? null : _meta(iteration.first)?['iteration_index']) as num?)?.toInt() ?? index,
      );
    }
    if (_durationMap == null || allExecutions == null) return failed;
    for (final e in allExecutions!) {
      final m = _meta(e);
      if (m?['iteration_id'] == nodeInfo['node_id'] && e['status'] == 'failed' && m?['iteration_index'] is num) {
        failed.add((m!['iteration_index'] as num).toInt());
      }
    }
    return failed;
  }

  NodeTracingList _nodesForInstance(String key) {
    final all = allExecutions;
    if (all == null) return const [];
    final parallel = [
      for (final e in all)
        if (_meta(e)?['parallel_mode_run_id'] == key) e,
    ];
    if (parallel.isNotEmpty) return parallel;
    final serial = int.tryParse(key);
    if (serial != null) {
      final nodes = [
        for (final e in all)
          if (_meta(e)?['iteration_id'] == nodeInfo['node_id'] && _meta(e)?['iteration_index'] == serial) e,
      ];
      if (nodes.isNotEmpty) return nodes;
    }
    return const [];
  }

  List<NodeTracingList> _structuredIterationList() {
    final map = _durationMap;
    final details = _details(nodeInfo);
    if (map == null) return details;
    final structured = [
      for (final key in jsObjectKeys(map))
        if (_nodesForInstance(key) case final nodes when nodes.isNotEmpty) nodes,
    ];
    if (allExecutions == null || details.isEmpty) return structured;
    final existing = <int>{
      for (final iteration in structured)
        for (final node in iteration)
          if (_meta(node)?['iteration_index'] case final num i) i.toInt(),
    };
    for (final (index, iteration) in details.indexed) {
      if (!existing.contains(index) && iteration.any((n) => n['status'] == 'failed')) structured.add(iteration);
    }
    int indexOf(NodeTracingList l) =>
        ((l.firstOrNull == null ? null : _meta(l.first)?['iteration_index']) as num?)?.toInt() ?? 0;
    // Array.prototype.sort is stable.
    final indexed = [for (final (i, l) in structured.indexed) (i, l)]
      ..sort((a, b) {
        final c = indexOf(a.$2).compareTo(indexOf(b.$2));
        return c != 0 ? c : a.$1.compareTo(b.$1);
      });
    return [for (final (_, l) in indexed) l];
  }

  @override
  Widget build(BuildContext context) {
    final count = _displayCount();
    final errors = _failedIterationIndices().length;
    final label =
        _tw('nodes.iteration.iteration', {'count': count}) +
        (errors > 0 ? _tw('nodes.iteration.comma') + _tw('nodes.iteration.error', {'count': errors}) : '');
    return _ContainerLogButton(
      icon: 'vender/workflow/iteration',
      label: label,
      onPressed: () => onShowIterationResultList(_structuredIterationList(), _iterationDurationMap()),
    );
  }
}

/// LoopLogTrigger: "N Loops[, M Errors]"; opens the loop runs (the node's `details`, else rebuilt from
/// [allExecutions] by `loop_duration_map`) with their durations and loop variables.
class LoopLogTrigger extends StatelessWidget {
  const LoopLogTrigger({super.key, required this.nodeInfo, this.allExecutions, required this.onShowLoopResultList});

  final DifyJson nodeInfo;
  final NodeTracingList? allExecutions;
  final void Function(List<NodeTracingList> list, DurationMap durationMap, Map<String, Object?> variableMap)
  onShowLoopResultList;

  NodeTracingList _nodesForInstance(String key) {
    final all = allExecutions;
    if (all == null) return const [];
    final parallel = [
      for (final e in all)
        if (_meta(e)?['parallel_mode_run_id'] == key) e,
    ];
    if (parallel.isNotEmpty) return parallel;
    final serial = int.tryParse(key);
    if (serial != null) {
      final nodes = [
        for (final e in all)
          if (_meta(e)?['loop_id'] == nodeInfo['node_id'] && _meta(e)?['loop_index'] == serial) e,
      ];
      if (nodes.isNotEmpty) return nodes;
    }
    return const [];
  }

  void _show() {
    final meta = _meta(nodeInfo);
    final durations = ((nodeInfo['loopDurationMap'] as Map?) ?? (meta?['loop_duration_map'] as Map?) ?? const {})
        .cast<String, Object?>();
    final variables = ((meta?['loop_variable_map'] as Map?) ?? const {}).cast<String, Object?>();
    var structured = <NodeTracingList>[];
    final details = _details(nodeInfo);
    if (details.isNotEmpty) {
      structured = details;
    } else if (meta?['loop_duration_map'] case final Map map) {
      structured = [
        for (final key in jsObjectKeys(map))
          if (_nodesForInstance(key) case final nodes when nodes.isNotEmpty) nodes,
      ];
    }
    onShowLoopResultList(structured, durations, variables);
  }

  @override
  Widget build(BuildContext context) {
    var count = 0;
    final map = _meta(nodeInfo)?['loop_duration_map'];
    final details = _details(nodeInfo);
    if (map is Map) {
      count = map.length;
    } else if (details.isNotEmpty) {
      count = details.length;
    } else if (((nodeInfo['metadata'] as Map?)?['loop_length'] as num?) case final num n when n != 0) {
      count = n.toInt();
    }
    final errors = details.where((l) => l.any((i) => i['status'] == 'failed')).length;
    final label =
        _tw('nodes.loop.loop', {'count': count}) +
        (errors > 0 ? _tw('nodes.loop.comma') + _tw('nodes.loop.error', {'count': errors}) : '');
    return _ContainerLogButton(icon: 'vender/workflow/loop', label: label, onPressed: _show);
  }
}

/// A tertiary Button the width of its parent (`mb-1 flex w-full items-center justify-between`).
class _TertiaryRowButton extends StatelessWidget {
  const _TertiaryRowButton({required this.label, required this.leading, required this.onPressed});
  final String label;
  final Widget leading;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: DifyPressable(
      semanticLabel: label,
      onPressed: onPressed,
      builder: (context, hovered, focused) => DifyButtonSurface(
        look: difyButtonLook(DifyButtonVariant.tertiary, DifyButtonTone.normal, hovered: hovered, disabled: false),
        radius: DifyButtonSize.medium.radius,
        focused: focused,
        child: SizedBox(
          height: 32,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: DefaultTextStyle.merge(
              style: DifyButtonSize.medium.text,
              maxLines: 1,
              child: Row(
                children: [
                  leading,
                  Expanded(child: Text(label, overflow: TextOverflow.ellipsis)),
                  const RemixIcon('arrow-right-s-line', size: 16, color: DifyColors.componentsButtonTertiaryText),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// RetryLogTrigger: "N Retries"; opens the node's retries.
class RetryLogTrigger extends StatelessWidget {
  const RetryLogTrigger({super.key, required this.nodeInfo, required this.onShowRetryResultList});
  final DifyJson nodeInfo;
  final ValueChanged<NodeTracingList> onShowRetryResultList;

  @override
  Widget build(BuildContext context) {
    final retryDetail = (nodeInfo['retryDetail'] as List?)?.cast<DifyJson>();
    return _TertiaryRowButton(
      label: _tw('nodes.common.retry.retries', {'num': retryDetail?.length}),
      leading: const Padding(
        padding: EdgeInsets.only(right: 2),
        child: RemixIcon('restart-fill', size: 16, color: DifyColors.componentsButtonTertiaryText),
      ),
      onPressed: () => onShowRetryResultList(retryDetail ?? const []),
    );
  }
}

/// AgentLogTrigger: "AGENT STRATEGY", the strategy and "DETAIL →"; opens the node's agent log.
class AgentLogTrigger extends StatelessWidget {
  const AgentLogTrigger({super.key, required this.nodeInfo, required this.onShowAgentOrToolLog});
  final DifyJson nodeInfo;
  final void Function([DifyJson? detail]) onShowAgentOrToolLog;

  @override
  Widget build(BuildContext context) {
    final strategy = (_meta(nodeInfo)?['tool_info'] as Map?)?['agent_strategy'] as String?;
    return DifyPressable(
      semanticLabel: _tw('nodes.agent.strategy.label'),
      onPressed: () =>
          onShowAgentOrToolLog({'message_id': nodeInfo['id'], 'children': nodeInfo['agentLog'] ?? const []}),
      builder: (context, hovered, focused) => Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: DifyColors.componentsButtonTertiaryBg,
          borderRadius: BorderRadius.circular(10),
          boxShadow: focused ? const [BoxShadow(spreadRadius: 2, color: DifyColors.stateAccentSolid)] : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: DifyText(
                _tw('nodes.agent.strategy.label'),
                DifyType.system2xsMediumUppercase,
                color: DifyColors.textTertiary,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 8, 6),
              child: Row(
                children: [
                  Expanded(
                    child: strategy != null
                        ? DifyText(strategy, DifyType.systemXsMedium, color: DifyColors.textSecondary)
                        : const SizedBox.shrink(),
                  ),
                  DifyText(
                    DifyI18n.tr('run-log', 'detail'),
                    DifyType.systemXsRegularUppercase,
                    color: DifyColors.textTertiary,
                  ),
                  const SizedBox(width: 2),
                  const RemixIcon('arrow-right-line', size: 14, color: DifyColors.textTertiary),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The detail views' "← Back" bar: `flex h-8 items-center border-b-[0.5px] border-b-divider-regular px-4
/// text-text-accent-secondary system-sm-medium`.
class _BackBar extends StatelessWidget {
  const _BackBar({required this.onBack, this.border = true});
  final VoidCallback onBack;
  final bool border;

  @override
  Widget build(BuildContext context) => DifyPressable(
    semanticLabel: _tw('singleRun.back'),
    onPressed: onBack,
    builder: (context, hovered, focused) => Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: DifyColors.componentsPanelBg,
        border: border
            ? Border(
                bottom: BorderSide(color: DifyColors.dividerRegular, width: Css.hairline),
              )
            : null,
      ),
      child: Row(
        children: [
          const RemixIcon('arrow-left-line', size: 16, color: DifyColors.textAccentSecondary),
          const SizedBox(width: 4),
          DifyText(_tw('singleRun.back'), DifyType.systemSmMedium, color: DifyColors.textAccentSecondary),
        ],
      ),
    ),
  );
}

String _duration(Object? d) {
  final n = d is num ? d : null;
  return '${n != null && n > 0.01 ? n.toStringAsFixed(2) : 0.01}s';
}

/// IterationResultPanel / LoopResultPanel: Back, then one collapsible card per run ("ITERATION 1" with the cyan icon,
/// its duration or error/spinner and an arrow), showing its tracing (and, in loops, its loop variables) open.
class ContainerResultPanel extends StatefulWidget {
  const ContainerResultPanel({
    super.key,
    required this.list,
    required this.onBack,
    required this.loop,
    this.durationMap,
    this.variableMap,
  });

  final List<NodeTracingList> list;
  final VoidCallback onBack;
  final bool loop;
  final DurationMap? durationMap;
  final Map<String, Object?>? variableMap;

  @override
  State<ContainerResultPanel> createState() => _ContainerResultPanelState();
}

class _ContainerResultPanelState extends State<ContainerResultPanel> {
  final _expanded = <int>{};

  String _runKey(NodeTracingList run, int index) {
    final m = run.firstOrNull == null ? null : _meta(run.first);
    if (widget.loop) {
      if (m?['parallel_mode_run_id'] != null) return '${m!['parallel_mode_run_id']}';
      if (m?['loop_index'] != null) return '${m!['loop_index']}';
      return '$index';
    }
    return '${m?['parallel_mode_run_id'] ?? m?['iteration_index']}';
  }

  Widget _status(int index, NodeTracingList run) {
    if (run.any((i) => i['status'] == 'failed')) {
      return const RemixIcon('error-warning-line', size: 16, color: DifyColors.textDestructive);
    }
    if (run.any((i) => i['status'] == 'running')) {
      return const Spinning(child: RemixIcon('loader-2-line', size: 14, color: Color(0xFF155EEF)));
    }
    final map = widget.durationMap;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (map != null && map.isNotEmpty)
          DifyText(_duration(map[_runKey(run, index)]), DifyType.systemXsRegular, color: DifyColors.textTertiary),
        const SizedBox(width: 8),
        AnimatedRotation(
          turns: _expanded.contains(index) ? 0.25 : 0,
          duration: const Duration(milliseconds: 200),
          child: const RemixIcon('arrow-right-s-line', size: 16, color: DifyColors.textTertiary),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final title = _tw(widget.loop ? 'singleRun.loop' : 'singleRun.iteration');
    return ColoredBox(
      color: DifyColors.componentsPanelBg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _BackBar(onBack: widget.onBack),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (index, run) in widget.list.indexed)
                  Container(
                    margin: const EdgeInsets.only(bottom: 4),
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      color: DifyColors.backgroundSectionBurn,
                      borderRadius: BorderRadius.circular(DifyRadius.xl),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        DifyPressable(
                          semanticLabel: '$title ${index + 1}',
                          onPressed: () => setState(
                            () => _expanded.contains(index) ? _expanded.remove(index) : _expanded.add(index),
                          ),
                          builder: (context, hovered, focused) => Padding(
                            padding: EdgeInsets.fromLTRB(12, 12, 12, _expanded.contains(index) ? 8 : 12),
                            child: Row(
                              spacing: 8,
                              children: [
                                Container(
                                  width: 16,
                                  height: 16,
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    color: DifyColors.utilColorsCyanCyan500,
                                    borderRadius: BorderRadius.circular(5),
                                  ),
                                  child: DifyIcon(
                                    widget.loop ? 'vender/workflow/loop' : 'vender/workflow/iteration',
                                    size: 12,
                                    color: DifyColors.textPrimaryOnSurface,
                                  ),
                                ),
                                Expanded(
                                  child: DifyText(
                                    '$title ${index + 1}',
                                    DifyType.systemSmSemiboldUppercase,
                                    color: DifyColors.textPrimary,
                                  ),
                                ),
                                _status(index, run),
                              ],
                            ),
                          ),
                        ),
                        if (_expanded.contains(index)) ...[
                          Container(height: 1, color: DifyColors.dividerSubtle),
                          if (widget.loop && widget.variableMap?[_runKey(run, index)] != null)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                              child: DifyCodeEditor(
                                readOnly: true,
                                title: _tw('nodes.loop.loopVariables').toUpperCase(),
                                language: CodeLanguage.json,
                                height: 112,
                                value: widget.variableMap![_runKey(run, index)],
                                isJSONStringifyBeauty: true,
                              ),
                            ),
                          TracingPanel(list: run, background: DifyColors.backgroundSectionBurn),
                        ],
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// RetryResultPanel: Back, then each retry as a node row titled "Retry N".
class RetryResultPanel extends StatelessWidget {
  const RetryResultPanel({super.key, required this.list, required this.onBack});
  final NodeTracingList list;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _BackBar(onBack: onBack, border: false),
      Container(
        color: DifyColors.backgroundSectionBurn,
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (index, item) in list.indexed)
              RunNodePanel(
                key: ValueKey('${item['id']}:${item['retry_index'] ?? item['created_at']}'),
                nodeInfo: {...item, 'title': '${_tw('nodes.common.retry.retry')} ${index + 1}'},
              ),
          ],
        ),
      ),
    ],
  );
}

/// NodeStatusIcon (nodes/_base/components/node-status-icon.tsx).
class NodeStatusIcon extends StatelessWidget {
  const NodeStatusIcon({super.key, required this.status});
  final String? status;

  @override
  Widget build(BuildContext context) => switch (status) {
    'succeeded' => const RemixIcon('checkbox-circle-fill', size: 16, color: DifyColors.textSuccess),
    'failed' => const RemixIcon('error-warning-line', size: 16, color: DifyColors.textWarning),
    'stopped' || 'exception' => const RemixIcon('alert-fill', size: 16, color: DifyColors.textWarningSecondary),
    'running' => const Spinning(child: RemixIcon('loader-2-line', size: 16, color: DifyColors.textAccent)),
    _ => const SizedBox.shrink(),
  };
}

/// AgentLogItem: a collapsible card (label, elapsed time, status); open, "N Action Logs" (when it has children) and
/// its data as JSON.
class AgentLogItem extends StatefulWidget {
  const AgentLogItem({super.key, required this.item, required this.onShowAgentOrToolLog});
  final DifyJson item;
  final void Function([DifyJson? detail]) onShowAgentOrToolLog;

  @override
  State<AgentLogItem> createState() => _AgentLogItemState();
}

class _AgentLogItemState extends State<AgentLogItem> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final label = '${item['label'] ?? ''}';
    final status = item['status'] == 'start' ? 'running' : item['status'] as String?;
    final metadata = item['metadata'] as Map?;
    final icon = metadata?['icon'];
    final elapsed = metadata?['elapsed_time'];
    final children = (item['children'] as List?) ?? const [];
    final data = item['data'];
    return Container(
      decoration: BoxDecoration(
        color: DifyColors.backgroundDefault,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: DifyColors.componentsPanelBorder, width: Css.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DifyPressable(
            semanticLabel: label,
            onPressed: () => setState(() => _expanded = !_expanded),
            builder: (context, hovered, focused) => Padding(
              padding: EdgeInsets.fromLTRB(6, 8, 12, _expanded ? 4 : 8),
              child: Row(
                children: [
                  RotatedBox(
                    quarterTurns: _expanded ? 1 : 0,
                    child: const RemixIcon('arrow-right-s-line', size: 16, color: DifyColors.textQuaternary),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: BlockIcon(type: icon is String && icon.isNotEmpty ? 'tool' : 'agent'),
                  ),
                  Expanded(
                    child: DifyText(label, DifyType.systemSmSemiboldUppercase, color: DifyColors.textSecondary),
                  ),
                  if (elapsed is num && elapsed != 0)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: DifyText(
                        '${elapsed.toStringAsFixed(3)}s',
                        DifyType.systemXsRegular,
                        color: DifyColors.textTertiary,
                      ),
                    ),
                  NodeStatusIcon(status: status),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (children.isNotEmpty)
                    _TertiaryRowButton(
                      label: '${children.length} Action Logs',
                      leading: const Padding(
                        padding: EdgeInsets.only(right: 4),
                        child: RemixIcon('list-view', size: 16, color: DifyColors.componentsButtonTertiaryText),
                      ),
                      onPressed: () => widget.onShowAgentOrToolLog(item),
                    ),
                  if (data != null)
                    DifyCodeEditor(
                      readOnly: true,
                      title: 'DATA',
                      language: CodeLanguage.json,
                      value: data,
                      isJSONStringifyBeauty: true,
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// AgentLogNav: "← AGENT / STRATEGY / … / (current)" over the agent log stack.
class AgentLogNav extends StatelessWidget {
  const AgentLogNav({super.key, required this.agentOrToolLogItemStack, required this.onShowAgentOrToolLog});
  final List<DifyJson> agentOrToolLogItemStack;
  final void Function([DifyJson? detail]) onShowAgentOrToolLog;

  @override
  Widget build(BuildContext context) {
    final stack = agentOrToolLogItemStack;
    final first = stack.firstOrNull;
    final mid = stack.length > 2 ? stack.sublist(1, stack.length - 1) : const <DifyJson>[];
    final end = stack.lastOrNull;
    final strategy = _tw('nodes.agent.strategy.label');
    Widget slash() => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: DifyText('/', DifyType.systemXsRegular, color: DifyColors.dividerDeep),
    );
    Widget plain(String text) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 5),
      child: DifyText(text, DifyType.systemXsMediumUppercase, color: DifyColors.textTertiary),
    );
    return Container(
      height: 32,
      color: DifyColors.componentsPanelBg,
      padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
      child: Row(
        children: [
          DifyButton(
            size: DifyButtonSize.small,
            variant: DifyButtonVariant.ghostAccent,
            paddingX: 5,
            onPressed: () => onShowAgentOrToolLog(),
            leading: const RemixIcon('arrow-left-line', size: 14),
            child: const Text('AGENT'),
          ),
          slash(),
          if (stack.length > 1)
            Flexible(
              child: DifyButton(
                size: DifyButtonSize.small,
                variant: DifyButtonVariant.ghostAccent,
                paddingX: 5,
                onPressed: () => onShowAgentOrToolLog(first),
                child: Text(strategy, overflow: TextOverflow.ellipsis),
              ),
            )
          else
            Flexible(child: plain(strategy)),
          if (mid.isNotEmpty) ...[
            slash(),
            AgentLogNavMore(options: mid, onShowAgentOrToolLog: onShowAgentOrToolLog),
          ],
          if (end != null && stack.length > 1) ...[slash(), Flexible(child: plain('${end['label'] ?? ''}'))],
        ],
      ),
    );
  }
}

/// AgentLogNavMore: the "…" menu of the stack's middle entries.
class AgentLogNavMore extends StatelessWidget {
  const AgentLogNavMore({super.key, required this.options, required this.onShowAgentOrToolLog});
  final List<DifyJson> options;
  final void Function([DifyJson? detail]) onShowAgentOrToolLog;

  @override
  Widget build(BuildContext context) => DifyDropdownMenu(
    placement: DifyPlacement.bottomStart,
    sideOffset: 2,
    alignOffset: -54,
    width: 136,
    builder: (context, controller) => DifyIconButton(
      label: DifyI18n.tr('common', 'operation.more'),
      variant: DifyButtonVariant.ghostAccent,
      icon: const RemixIcon('more-line', size: 16),
      onPressed: controller.toggle,
    ),
    children: [
      for (final option in options)
        DifyMenuItem(onSelect: () => onShowAgentOrToolLog(option), child: Text('${option['label'] ?? ''}')),
    ],
  );
}

/// AgentResultPanel: the nav, the top entry's children as [AgentLogItem]s, and the circular invocation warning.
class AgentResultPanel extends StatelessWidget {
  const AgentResultPanel({
    super.key,
    required this.agentOrToolLogItemStack,
    required this.agentOrToolLogListMap,
    required this.onShowAgentOrToolLog,
  });

  final List<DifyJson> agentOrToolLogItemStack;
  final Map<String, List<DifyJson>> agentOrToolLogListMap;
  final void Function([DifyJson? detail]) onShowAgentOrToolLog;

  @override
  Widget build(BuildContext context) {
    final top = agentOrToolLogItemStack.last;
    final list = agentOrToolLogListMap['${top['message_id']}'] ?? const <DifyJson>[];
    return ColoredBox(
      color: DifyColors.backgroundSection,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AgentLogNav(agentOrToolLogItemStack: agentOrToolLogItemStack, onShowAgentOrToolLog: onShowAgentOrToolLog),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 4,
              children: [
                for (final item in list)
                  AgentLogItem(
                    key: ValueKey(item['message_id']),
                    item: item,
                    onShowAgentOrToolLog: onShowAgentOrToolLog,
                  ),
              ],
            ),
          ),
          if (top['hasCircle'] == true)
            Container(
              margin: const EdgeInsets.only(top: 4),
              padding: const EdgeInsets.fromLTRB(12, 0, 8, 0),
              decoration: BoxDecoration(
                color: DifyColors.componentsPanelBgBlur,
                borderRadius: BorderRadius.circular(DifyRadius.xl),
                border: Border.all(color: DifyColors.componentsPanelBorder),
                boxShadow: DifyShadows.md,
              ),
              foregroundDecoration: BoxDecoration(
                borderRadius: BorderRadius.circular(DifyRadius.xl),
                gradient: const LinearGradient(
                  colors: [Color(0x1AF79009), Color(0x00FFFFFF)],
                ),
              ),
              child: Row(
                children: [
                  const Padding(
                    padding: EdgeInsets.only(right: 6),
                    child: RemixIcon('alert-fill', size: 16, color: DifyColors.textWarningSecondary),
                  ),
                  Expanded(
                    child: DifyText(
                      DifyI18n.tr('run-log', 'circularInvocationTip'),
                      DifyType.systemXsMedium,
                      color: DifyColors.textPrimary,
                      maxLines: null,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// SpecialResultPanel: whichever detail view [logs] asks for (retries, iterations, loops, the agent log stack).
class SpecialResultPanel extends StatelessWidget {
  const SpecialResultPanel({super.key, required this.logs});
  final RunLogs logs;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (logs.showRetryDetail && logs.retryResultList.isNotEmpty)
        RetryResultPanel(list: logs.retryResultList, onBack: logs.setShowRetryDetailFalse),
      if (logs.showIteratingDetail && logs.iterationResultList.isNotEmpty)
        ContainerResultPanel(
          loop: false,
          list: logs.iterationResultList,
          onBack: logs.setShowIteratingDetailFalse,
          durationMap: logs.iterationResultDurationMap,
        ),
      if (logs.showLoopingDetail && logs.loopResultList.isNotEmpty)
        ContainerResultPanel(
          loop: true,
          list: logs.loopResultList,
          onBack: logs.setShowLoopingDetailFalse,
          durationMap: logs.loopResultDurationMap,
          variableMap: logs.loopResultVariableMap,
        ),
      if (logs.agentOrToolLogItemStack.isNotEmpty)
        AgentResultPanel(
          agentOrToolLogItemStack: logs.agentOrToolLogItemStack,
          agentOrToolLogListMap: logs.agentOrToolLogListMap,
          onShowAgentOrToolLog: logs.handleShowAgentOrToolLog,
        ),
    ],
  );
}

/// BlockIcon in the tracing rows (`size="sm"`, `xs` in chat messages).
Widget tracingBlockIcon(String type, {bool inMessage = false}) =>
    BlockIcon(type: type, size: inMessage ? BlockIconSize.xs : BlockIconSize.sm);
