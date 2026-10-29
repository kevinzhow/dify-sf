import 'package:flutter/widgets.dart';

import '../canvas/agent_progress_view.dart';
import '../design/dify_tokens.g.dart';
import '../design/widgets/widgets.dart';
import '../i18n/dify_i18n.dart';
import '../workflow_editor/run/ui/log_widgets.dart';
import '../workflow_editor/store/workflow_store.dart';
import '../workflow_editor/store/workflow_store_scope.dart';
import 'progress_image.dart';

class AgentCanvasProgress extends StatelessWidget {
  const AgentCanvasProgress({super.key, required this.nodeId, required this.progress});
  final String nodeId;
  final AgentProgressView progress;
  @override
  Widget build(BuildContext context) {
    final image = progress.image;
    final store = context.getInheritedWidgetOfExactType<WorkflowStoreScope>()?.store;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DifyTextLine(
            DifyI18n.tr('agent-v-2', 'inline.progressCalls', {'count': progress.calls, 'max': progress.maximum}),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: difyTextStyle(DifyType.systemXsMedium, DifyColors.textAccent),
          ),
          const SizedBox(height: 4),
          SizedBox(
            height: 36,
            child: DifyTextLine(
              progress.partialReason == 'session_save_failed'
                  ? DifyI18n.tr('agent-v-2', 'inline.sessionSaveFailed')
                  : progress.partialReason != null
                  ? DifyI18n.tr('agent-v-2', 'inline.partialResult')
                  : progress.summary.isEmpty
                  ? DifyI18n.tr('agent-v-2', 'inline.progressStarted')
                  : progress.summary,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textSecondary),
            ),
          ),
          if (image != null) ...[
            const SizedBox(height: 4),
            AgentProgressImage(url: '${image['url']}', caption: '${image['name']}'),
          ],
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: DifyButton(
              size: DifyButtonSize.small,
              disabled: store == null,
              onPressed: store == null
                  ? null
                  : () => showDifyDialog<void>(
                      context,
                      builder: (dialog) =>
                          _AgentProgressLogs(store: store, nodeId: nodeId, onClose: () => Navigator.of(dialog).pop()),
                    ),
              child: DifyTextLine(DifyI18n.tr('agent-v-2', 'inline.progressDetails')),
            ),
          ),
        ],
      ),
    );
  }
}

class _AgentProgressLogs extends StatelessWidget {
  const _AgentProgressLogs({required this.store, required this.nodeId, required this.onClose});
  final WorkflowStore store;
  final String nodeId;
  final VoidCallback onClose;
  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: store.workflowRunningData,
    builder: (context, running, _) {
      final tracing = running?['tracing'] as List? ?? const [];
      final node = tracing.reversed.whereType<Map>().where((n) => n['node_id'] == nodeId).firstOrNull;
      final meta = node?['execution_metadata'];
      final raw = meta is Map ? meta['agent_log'] : null;
      final logs = raw is List ? raw.whereType<Map>().map((e) => e.cast<String, Object?>()).toList() : <DifyJson>[];
      final usage = logs.reversed
          .where((l) => AgentProgressView.map(l['metadata'])['event'] == 'model_call')
          .firstOrNull;
      final hit = AgentProgressView.map(AgentProgressView.map(usage?['data'])['usage'])['prompt_cache_hit_tokens'];
      return DifyDialogSurface(
        label: DifyI18n.tr('agent-v-2', 'inline.progressDetails'),
        width: 720,
        height: MediaQuery.sizeOf(context).height * .8,
        bordered: true,
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: DifyTextLine(
                    DifyI18n.tr('agent-v-2', 'inline.progressDetails'),
                    style: difyTextStyle(DifyType.systemMdSemibold, DifyColors.textPrimary),
                  ),
                ),
                DifyButton(onPressed: onClose, child: DifyTextLine(DifyI18n.tr('common', 'operation.close'))),
              ],
            ),
            const SizedBox(height: 8),
            DifyTextLine(
              DifyI18n.tr('agent-v-2', 'inline.cacheHitTokens', {
                'count': hit is int ? hit : DifyI18n.tr('agent-v-2', 'inline.unknownUsage'),
              }),
              style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textSecondary),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: ListView.builder(
                itemCount: logs.length,
                itemBuilder: (context, i) => Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: AgentLogItem(
                    key: ValueKey(logs[i]['message_id']),
                    item: logs[i],
                    onShowAgentOrToolLog: ([_]) {},
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}
