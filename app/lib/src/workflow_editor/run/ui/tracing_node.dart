/// run/node.tsx: one node execution in the tracing list — a card with the node's icon, title, tokens and time and its
/// status, opening to its log buttons (iterations, loops, retries, agent log), its stop/error notice and its input,
/// process data and output as read-only JSON.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import '../../../design/dify_icon.dart';
import '../../../design/dify_tokens.g.dart';
import '../../../design/widgets/widgets.dart';
import '../../../i18n/dify_i18n.dart';
import '../../code_editor/code_editor.dart';
import '../../node_panel/workflow_node_panel.dart' show hasRetryNode;
import '../../panel_fields/node_config.dart' show ErrorHandleTip, ErrorHandleType;
import '../../store/workflow_store.dart' show DifyJson;
import '../../variable_inspect/value_content.dart' show LargeDataAlert;
import 'log_widgets.dart';
import 'run_logs.dart';
import 'status.dart';

String _tw(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('workflow', key, params);

/// node.tsx getTime: "120.000 ms", "1.250 s", "2 m 5.000 s".
String formatNodeTime(num time) {
  if (time < 1) return '${(time * 1000).toStringAsFixed(3)} ms';
  if (time > 60) return '${time ~/ 60} m ${(time % 60).toStringAsFixed(3)} s';
  return '${time.toStringAsFixed(3)} s';
}

/// node.tsx getTokenCount: 999, "1.5K", "2.25M" (`parseFloat(x.toFixed(3))`).
String formatTokenCount(num tokens) {
  String trim(num v) {
    final s = v.toStringAsFixed(3);
    return s.contains('.') ? s.replaceFirst(RegExp(r'\.?0+$'), '') : s;
  }

  if (tokens < 1000) return '$tokens';
  if (tokens < 1000000) return '${trim(tokens / 1000)}K';
  return '${trim(tokens / 1000000)}M';
}

/// Dify's NodePanel in the tracing list. Collapsed unless the execution is marked `expand`.
class RunNodePanel extends StatefulWidget {
  const RunNodePanel({
    super.key,
    required this.nodeInfo,
    this.allExecutions,
    this.inMessage = false,
    this.hideInfo = false,
    this.hideProcessDetail = false,
    this.onShowIterationDetail,
    this.onShowLoopDetail,
    this.onShowRetryDetail,
    this.onShowAgentOrToolLog,
    this.notShowIterationNav = false,
    this.notShowLoopNav = false,
    this.onOpenUrl,
  });

  final DifyJson nodeInfo;
  final NodeTracingList? allExecutions;
  final bool inMessage;
  final bool hideInfo;
  final bool hideProcessDetail;
  final void Function(List<NodeTracingList> list, DurationMap durationMap)? onShowIterationDetail;
  final void Function(List<NodeTracingList> list, DurationMap durationMap, Map<String, Object?> variableMap)?
  onShowLoopDetail;
  final ValueChanged<NodeTracingList>? onShowRetryDetail;
  final void Function([DifyJson? detail])? onShowAgentOrToolLog;
  final bool notShowIterationNav;
  final bool notShowLoopNav;
  final ValueChanged<String>? onOpenUrl;

  @override
  State<RunNodePanel> createState() => _RunNodePanelState();
}

class _RunNodePanelState extends State<RunNodePanel> {
  late bool _collapsed = widget.hideProcessDetail ? true : widget.nodeInfo['expand'] != true;
  bool _hovered = false;

  @override
  void didUpdateWidget(RunNodePanel old) {
    super.didUpdateWidget(old);
    if (old.nodeInfo['expand'] != widget.nodeInfo['expand']) _setCollapsed(widget.nodeInfo['expand'] != true);
  }

  void _setCollapsed(bool v) {
    if (widget.hideProcessDetail) return;
    setState(() => _collapsed = v);
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.nodeInfo;
    final type = '${n['node_type'] ?? ''}';
    final status = n['status'] as String?;
    final meta = n['execution_metadata'] as Map?;
    final details = (n['details'] as List?) ?? const [];
    final isIteration = type == 'iteration' && details.isNotEmpty;
    final isLoop = type == 'loop' && details.isNotEmpty;
    final isRetry = hasRetryNode(type) && ((n['retryDetail'] as List?)?.isNotEmpty ?? false);
    final hasAgentLog = (n['agentLog'] as List?)?.isNotEmpty ?? false;
    final isAgentOrTool = (type == 'agent' || type == 'tool') && hasAgentLog;
    final hideInfo = widget.hideInfo;
    final tokens = (meta?['total_tokens'] as num?) ?? 0;
    final elapsed = (n['elapsed_time'] as num?) ?? 0;
    final inputsTitle = (type == 'loop' ? _tw('nodes.loop.initialLoopVariables') : _tw('common.input')).toUpperCase();
    final outputTitle = (type == 'loop' ? _tw('nodes.loop.finalLoopVariables') : _tw('common.output')).toUpperCase();
    final title = '${n['title'] ?? ''}';
    final header = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _setCollapsed(!_collapsed),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            hideInfo ? 8 : 4,
            hideInfo ? 8 : 6,
            12,
            !_collapsed ? (hideInfo ? 4 : 6) : (hideInfo ? 8 : 6),
          ),
          child: Row(
            children: [
              if (!widget.hideProcessDetail)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: AnimatedRotation(
                    turns: _collapsed ? 0 : 0.25,
                    duration: const Duration(milliseconds: 150),
                    child: RemixIcon(
                      'arrow-right-s-line',
                      size: 16,
                      color: _hovered ? DifyColors.textTertiary : DifyColors.textQuaternary,
                    ),
                  ),
                ),
              Padding(
                padding: EdgeInsets.only(right: widget.inMessage ? 4 : 8),
                child: tracingBlockIcon(type, inMessage: widget.inMessage),
              ),
              Expanded(
                child: DifyTooltip(
                  content: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 320), child: DifyTextLine(title)),
                  child: hideInfo
                      ? DifyTextLine(
                          title.toUpperCase(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: difyStyle(
                            DifyType.systemXsSemiboldUppercase,
                            DifyColors.textSecondary,
                          ).copyWith(fontSize: 12, height: 16 / 12),
                        )
                      : DifyText(title, DifyType.systemXsSemiboldUppercase, color: DifyColors.textSecondary),
                ),
              ),
              if (status != 'running' && status != 'paused' && !hideInfo)
                DifyText(
                  '${tokens != 0 ? '${formatTokenCount(tokens)} tokens · ' : ''}${formatNodeTime(elapsed)}',
                  DifyType.systemXsRegular,
                  color: DifyColors.textTertiary,
                ),
              ...switch (status) {
                'succeeded' => [
                  SizedBox(width: 8),
                  RemixIcon('checkbox-circle-fill', size: 14, color: DifyColors.textSuccess),
                ],
                'failed' => [
                  SizedBox(width: 8),
                  RemixIcon('error-warning-fill', size: 14, color: DifyColors.textDestructive),
                ],
                'stopped' || 'exception' => [
                  const SizedBox(width: 8),
                  RemixIcon('alert-fill', size: widget.inMessage ? 14 : 16, color: DifyColors.textWarningSecondary),
                ],
                'paused' => [
                  const SizedBox(width: 8),
                  RemixIcon(
                    'pause-circle-fill',
                    size: widget.inMessage ? 14 : 16,
                    color: DifyColors.textWarningSecondary,
                  ),
                ],
                'running' => [
                  const SizedBox(width: 8),
                  DifyTextLine(
                    'Running',
                    style: difyStyle(
                      DifyType.systemXsRegular,
                      DifyColors.textAccent,
                    ).copyWith(fontSize: 12, fontWeight: FontWeight.w400),
                  ),
                  const SizedBox(width: 8),
                  DifySpinner(size: 14, color: DifyColors.textAccent),
                ],
                _ => const <Widget>[],
              },
            ],
          ),
        ),
      ),
    );
    final error = '${n['error'] ?? ''}';
    final strategy = ErrorHandleType.of(meta?['error_strategy']);
    final body = Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (isIteration && !widget.notShowIterationNav && widget.onShowIterationDetail != null)
            IterationLogTrigger(
              nodeInfo: n,
              allExecutions: widget.allExecutions,
              onShowIterationResultList: widget.onShowIterationDetail!,
            ),
          if (isLoop && !widget.notShowLoopNav && widget.onShowLoopDetail != null)
            LoopLogTrigger(
              nodeInfo: n,
              allExecutions: widget.allExecutions,
              onShowLoopResultList: widget.onShowLoopDetail!,
            ),
          if (isRetry && widget.onShowRetryDetail != null)
            RetryLogTrigger(nodeInfo: n, onShowRetryResultList: widget.onShowRetryDetail!),
          if (isAgentOrTool && widget.onShowAgentOrToolLog != null)
            AgentLogTrigger(nodeInfo: n, onShowAgentOrToolLog: widget.onShowAgentOrToolLog!),
          Padding(
            padding: hideInfo ? const EdgeInsets.fromLTRB(8, 2, 8, 6) : const EdgeInsets.only(bottom: 4),
            child: switch (status) {
              'stopped' => StatusContainer(
                status: 'stopped',
                child: DifyTextLine(
                  _tw('tracing.stopBy', {'user': (n['created_by'] as Map?)?['name'] ?? 'N/A'}),
                ),
              ),
              'exception' => StatusContainer(
                status: 'stopped',
                child: DifyTextLine.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: error),
                      TextSpan(
                        text: _tw('common.learnMore'),
                        style: TextStyle(color: DifyColors.textAccent),
                        recognizer: widget.onOpenUrl == null
                            ? null
                            : (TapGestureRecognizer()
                                ..onTap = () => widget.onOpenUrl!('https://docs.dify.ai/use-dify/debug/error-type')),
                      ),
                    ],
                  ),
                ),
              ),
              'failed' || 'retry' => StatusContainer(status: 'failed', child: DifyTextLine(error)),
              'paused' => StatusContainer(
                status: 'paused',
                child: DifyText(
                  _tw('nodes.humanInput.log.reasonContent'),
                  DifyType.systemXsRegular,
                  color: DifyColors.textWarning,
                  maxLines: null,
                ),
              ),
              _ => const SizedBox.shrink(),
            },
          ),
          if (meta?['agent_partial'] is Map)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: StatusContainer(
                status: 'paused',
                child: DifyTextLine(DifyI18n.tr('agent-v-2', 'inline.partialResult'), maxLines: null),
              ),
            ),
          if (n['inputs'] != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: DifyCodeEditor(
                readOnly: true,
                title: inputsTitle,
                language: CodeLanguage.json,
                value: n['inputs'],
                isJSONStringifyBeauty: true,
                footer: n['inputs_truncated'] == true ? _largeDataAlert() : null,
              ),
            ),
          if (n['process_data'] != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: DifyCodeEditor(
                readOnly: true,
                title: _tw('common.processData').toUpperCase(),
                language: CodeLanguage.json,
                value: n['process_data'],
                isJSONStringifyBeauty: true,
              ),
            ),
          if (n['outputs'] != null)
            DifyCodeEditor(
              readOnly: true,
              title: outputTitle,
              language: CodeLanguage.json,
              value: n['outputs'],
              isJSONStringifyBeauty: true,
              tip: strategy == null ? null : ErrorHandleTip(type: strategy),
              footer: n['outputs_truncated'] == true
                  ? _largeDataAlert(downloadUrl: (n['outputs_full_content'] as Map?)?['download_url'] as String?)
                  : null,
            ),
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          decoration: BoxDecoration(
            color: DifyColors.backgroundDefault,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: DifyColors.componentsPanelBorder),
            boxShadow: _hovered ? DifyShadows.md : DifyShadows.xs,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [header, if (!_collapsed && !widget.hideProcessDetail) body],
          ),
        ),
      ),
    );
  }

  /// LargeDataAlert `textHasNoExport className="mx-1 mt-2 mb-1 h-7"`.
  Widget _largeDataAlert({String? downloadUrl}) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
    child: SizedBox(height: 28, child: LargeDataAlert(textHasNoExport: true, downloadUrl: downloadUrl)),
  );
}
