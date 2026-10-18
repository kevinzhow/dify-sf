/// run/result-panel.tsx: a run's (or a node's) detail — the status box, the log buttons of a container, retried,
/// agent or tool node, INPUT / PROCESS DATA / OUTPUT as read-only JSON, and the metadata.
library;

import 'package:flutter/widgets.dart';

import '../../../design/dify_tokens.g.dart';
import '../../../i18n/dify_i18n.dart';
import '../../code_editor/code_editor.dart';
import '../../node_panel/workflow_node_panel.dart' show hasRetryNode;
import '../../panel_fields/node_config.dart' show ErrorHandleTip, ErrorHandleType;
import '../../store/workflow_store.dart' show DifyJson;
import '../../variable_inspect/value_content.dart' show LargeDataAlert;
import 'log_widgets.dart';
import 'run_logs.dart';
import 'status.dart';

String _tw(String key) => DifyI18n.tr('workflow', key);

class ResultPanel extends StatelessWidget {
  const ResultPanel({
    super.key,
    this.nodeInfo,
    this.inputs,
    this.inputsTruncated = false,
    this.processData,
    this.processDataTruncated = false,
    this.outputs,
    this.outputsTruncated = false,
    this.outputsFullContent,
    required this.status,
    this.error,
    this.elapsedTime,
    this.totalTokens,
    this.createdAt,
    this.createdBy,
    this.steps,
    this.showSteps = true,
    this.exceptionCounts,
    this.executionMetadata,
    this.isListening = false,
    this.workflowRunId,
    this.onOpenTracingTab,
    this.handleShowIterationResultList,
    this.handleShowLoopResultList,
    this.onShowRetryDetail,
    this.handleShowAgentOrToolLog,
    this.fetchPausedDetails,
    this.formatTime,
  });

  /// Builds the panel from a run detail or node execution's JSON (Dify's field names), with [overrides] on top.
  factory ResultPanel.fromJson(
    DifyJson json, {
    Key? key,
    String? status,
    bool showSteps = true,
    String? createdBy,
    bool isListening = false,
    DifyJson? nodeInfo,
    VoidCallback? onOpenTracingTab,
    void Function(List<NodeTracingList>, DurationMap)? handleShowIterationResultList,
    void Function(List<NodeTracingList>, DurationMap, Map<String, Object?>)? handleShowLoopResultList,
    ValueChanged<NodeTracingList>? onShowRetryDetail,
    void Function([DifyJson?])? handleShowAgentOrToolLog,
    PausedDetailsFetcher? fetchPausedDetails,
  }) => ResultPanel(
    key: key,
    nodeInfo: nodeInfo,
    inputs: json['inputs'],
    inputsTruncated: json['inputs_truncated'] == true,
    processData: json['process_data'],
    processDataTruncated: json['process_data_truncated'] == true,
    outputs: json['outputs'],
    outputsTruncated: json['outputs_truncated'] == true,
    outputsFullContent: json['outputs_full_content'] as Map?,
    status: status ?? '${json['status'] ?? ''}',
    error: json['error'] as String?,
    elapsedTime: json['elapsed_time'] as num?,
    totalTokens: json['total_tokens'] as num?,
    createdAt: (json['created_at'] as num?)?.toInt(),
    createdBy: createdBy,
    steps: (json['total_steps'] as num?)?.toInt(),
    showSteps: showSteps,
    exceptionCounts: (json['exceptions_count'] as num?)?.toInt(),
    executionMetadata: json['execution_metadata'] as Map?,
    isListening: isListening,
    workflowRunId: json['id'] as String?,
    onOpenTracingTab: onOpenTracingTab,
    handleShowIterationResultList: handleShowIterationResultList,
    handleShowLoopResultList: handleShowLoopResultList,
    onShowRetryDetail: onShowRetryDetail,
    handleShowAgentOrToolLog: handleShowAgentOrToolLog,
    fetchPausedDetails: fetchPausedDetails,
  );

  final DifyJson? nodeInfo;
  final Object? inputs;
  final bool inputsTruncated;
  final Object? processData;
  final bool processDataTruncated;
  final Object? outputs;
  final bool outputsTruncated;
  final Map? outputsFullContent;
  final String status;
  final String? error;
  final num? elapsedTime;
  final num? totalTokens;
  final int? createdAt;
  final String? createdBy;
  final int? steps;
  final bool showSteps;
  final int? exceptionCounts;
  final Map? executionMetadata;
  final bool isListening;
  final String? workflowRunId;
  final VoidCallback? onOpenTracingTab;
  final void Function(List<NodeTracingList>, DurationMap)? handleShowIterationResultList;
  final void Function(List<NodeTracingList>, DurationMap, Map<String, Object?>)? handleShowLoopResultList;
  final ValueChanged<NodeTracingList>? onShowRetryDetail;
  final void Function([DifyJson?])? handleShowAgentOrToolLog;
  final PausedDetailsFetcher? fetchPausedDetails;
  final String Function(int seconds, String format)? formatTime;

  Widget _largeDataAlert({String? downloadUrl}) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
    child: SizedBox(height: 28, child: LargeDataAlert(textHasNoExport: true, downloadUrl: downloadUrl)),
  );

  @override
  Widget build(BuildContext context) {
    final n = nodeInfo;
    final type = n?['node_type'];
    final hasDetails = (n?['details'] as List?)?.isNotEmpty ?? false;
    final isIteration = type == 'iteration' && hasDetails;
    final isLoop = type == 'loop' && hasDetails;
    final isRetry = hasRetryNode(type as String?) && ((n?['retryDetail'] as List?)?.isNotEmpty ?? false);
    final hasAgentLog = (n?['agentLog'] as List?)?.isNotEmpty ?? false;
    final isAgentOrTool = (type == 'agent' || type == 'tool') && hasAgentLog;
    final strategy = ErrorHandleType.of(executionMetadata?['error_strategy']);
    return Container(
      color: DifyColors.componentsPanelBg,
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: StatusPanel(
              status: status,
              time: elapsedTime,
              tokens: totalTokens,
              error: error,
              exceptionCounts: exceptionCounts,
              isListening: isListening,
              workflowRunId: workflowRunId,
              onOpenTracingTab: onOpenTracingTab,
              fetchPausedDetails: fetchPausedDetails,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (isIteration && handleShowIterationResultList != null)
                  IterationLogTrigger(nodeInfo: n!, onShowIterationResultList: handleShowIterationResultList!),
                if (isLoop && handleShowLoopResultList != null)
                  LoopLogTrigger(nodeInfo: n!, onShowLoopResultList: handleShowLoopResultList!),
                if (isRetry && onShowRetryDetail != null)
                  RetryLogTrigger(nodeInfo: n!, onShowRetryResultList: onShowRetryDetail!),
                if (isAgentOrTool && handleShowAgentOrToolLog != null)
                  AgentLogTrigger(nodeInfo: n!, onShowAgentOrToolLog: handleShowAgentOrToolLog!),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 8,
              children: [
                DifyCodeEditor(
                  readOnly: true,
                  title: _tw('common.input').toUpperCase(),
                  language: CodeLanguage.json,
                  value: inputs,
                  isJSONStringifyBeauty: true,
                  footer: inputsTruncated ? _largeDataAlert() : null,
                ),
                if (processData != null && processData != '')
                  DifyCodeEditor(
                    readOnly: true,
                    title: _tw('common.processData').toUpperCase(),
                    language: CodeLanguage.json,
                    value: processData,
                    isJSONStringifyBeauty: true,
                    footer: processDataTruncated ? _largeDataAlert() : null,
                  ),
                if ((outputs != null && outputs != '') || status == 'running')
                  DifyCodeEditor(
                    readOnly: true,
                    title: _tw('common.output').toUpperCase(),
                    language: CodeLanguage.json,
                    value: outputs,
                    isJSONStringifyBeauty: true,
                    tip: strategy == null ? null : ErrorHandleTip(type: strategy),
                    footer: outputsTruncated
                        ? _largeDataAlert(downloadUrl: outputsFullContent?['download_url'] as String?)
                        : null,
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            // `divider-subtle h-[0.5px]`: no background utility in Dify, so the line is not drawn.
            child: const SizedBox(height: 0.5),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: RunMetaData(
              status: status,
              executor: createdBy,
              startTime: createdAt,
              time: elapsedTime,
              tokens: totalTokens,
              steps: steps,
              showSteps: showSteps,
              formatTime: formatTime,
            ),
          ),
        ],
      ),
    );
  }
}
