import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';

import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';
import '../store/workflow_store_scope.dart';
import 'header_data.dart';
import 'publisher/utils.dart';

String _tr(String key) => DifyI18n.tr('workflow', key);

/// `WorkflowVersion.Draft`.
const workflowVersionDraft = 'draft';

/// header/editing-title.tsx: "Auto-Saved 14:03:12 · Published 2 hours ago" (or "· Unpublished"), and "· Syncing
/// data, just a few seconds." while the draft syncs. A status line named "Workflow save status".
class EditingTitle extends StatelessWidget {
  const EditingTitle({super.key});

  @override
  Widget build(BuildContext context) {
    final store = WorkflowStoreScope.of(context);
    final f = WorkflowHeaderScope.of(context).formatters;
    const dot = Padding(
      padding: EdgeInsets.symmetric(horizontal: 4),
      child: ExcludeSemantics(child: Text('·')),
    );
    return Semantics(
      role: SemanticsRole.status,
      label: _tr('common.workflowSaveStatus'),
      container: true,
      explicitChildNodes: true,
      child: ListenableBuilder(
        listenable: Listenable.merge([store.draftUpdatedAt, store.publishedAt, store.isSyncingWorkflowDraft]),
        builder: (context, _) {
          final draftUpdatedAt = store.draftUpdatedAt.value, publishedAt = store.publishedAt.value;
          return DefaultTextStyle.merge(
            style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textTertiary),
            maxLines: 1,
            softWrap: false,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 300, minHeight: 18, maxHeight: 18),
              // Clipped, not wrapped, when the header is too narrow (the browser would let it overflow).
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                physics: const NeverScrollableScrollPhysics(),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (draftUpdatedAt != 0) ...[
                      Text(_tr('common.autoSaved')),
                      const SizedBox(width: 4),
                      Text(f.formatTime(draftUpdatedAt ~/ 1000, 'HH:mm:ss')),
                    ],
                    dot,
                    if (publishedAt != 0) ...[
                      Text(_tr('common.published')),
                      const SizedBox(width: 4),
                      Text(f.formatTimeFromNow(publishedAt)),
                    ] else
                      Text(_tr('common.unpublished')),
                    if (store.isSyncingWorkflowDraft.value) ...[dot, Text(_tr('common.syncingData'))],
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// The "View Only" badge.
class _ViewOnlyBadge extends StatelessWidget {
  const _ViewOnlyBadge({required this.border, required this.background, required this.style});
  final Color border;
  final Color background;
  final TextStyle style;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
    decoration: BoxDecoration(
      color: background,
      border: Border.all(color: border),
      borderRadius: BorderRadius.circular(DifyRadius.badge),
    ),
    child: Text(_tr('common.viewOnly').toUpperCase(), style: style),
  );
}

/// header/running-title.tsx: "Test Run (02:30:25 PM) · VIEW ONLY" while a past run is shown.
class RunningTitle extends StatelessWidget {
  const RunningTitle({super.key});

  @override
  Widget build(BuildContext context) {
    final store = WorkflowStoreScope.of(context);
    final data = WorkflowHeaderScope.of(context);
    final gray500 = DifyColors.gray500; // text-gray-500
    return ValueListenableBuilder(
      valueListenable: store.historyWorkflowData,
      builder: (context, history, _) {
        final finishedAt = (history?['finished_at'] as num?)?.toInt();
        final id = data.formatters.formatWorkflowRunIdentifier(finishedAt);
        return SizedBox(
          height: 18,
          child: DefaultTextStyle.merge(
            style: difyTextStyle(DifyType.systemXsRegular, gray500), // text-xs
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                DifyIcon('vender/line/time/clock-play', size: 12, color: gray500),
                const SizedBox(width: 4),
                Text(data.isChatMode ? 'Test Chat$id' : 'Test Run$id'),
                const Padding(padding: EdgeInsets.symmetric(horizontal: 4), child: Text('·')),
                const SizedBox(width: 4),
                // `h-4.5 rounded-[5px] border border-indigo-300 bg-white/48 px-1 text-2xs font-semibold text-indigo-600`
                _ViewOnlyBadge(
                  border: DifyColors.indigo300,
                  background: DifyTailwind.white.withValues(alpha: 0.48),
                  style: difyTextStyle(DifyTw.text2xsSemiboldLeading14, DifyColors.indigo600),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// header/restoring-title.tsx: the version's name with "VIEW ONLY", and "Published · 3 hours ago 09:30:00 · Alice".
class RestoringTitle extends StatelessWidget {
  const RestoringTitle({super.key});

  @override
  Widget build(BuildContext context) {
    final store = WorkflowStoreScope.of(context);
    final f = WorkflowHeaderScope.of(context).formatters;
    return ValueListenableBuilder(
      valueListenable: store.currentVersion,
      builder: (context, v, _) {
        final isDraft = v?['version'] == workflowVersionDraft;
        final name = isDraft
            ? _tr('versionHistory.currentDraft')
            : getWorkflowVersionName(
                markedName: v?['marked_name'] as String?,
                versionNumber: (v?['version_number'] as num?)?.toInt(),
                defaultName: _tr('versionHistory.defaultName'),
              );
        int secs(String k) => (v?[k] as num?)?.toInt() ?? 0;
        final creator = (v?['created_by'] as Map?)?['name'] ?? '';
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 2,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 4,
              children: [
                Text(name, style: difyTextStyle(DifyType.systemSmSemibold, DifyColors.textPrimary)),
                _ViewOnlyBadge(
                  border: DifyColors.textAccentSecondary,
                  background: DifyColors.componentsBadgeBgDimm,
                  style: difyTextStyle(DifyType.system2xsMediumUppercase, DifyColors.textAccentSecondary),
                ),
              ],
            ),
            SizedBox(
              height: 16,
              child: DefaultTextStyle.merge(
                style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textTertiary),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  spacing: 4,
                  children: [
                    if (v != null) ...[
                      Text(_tr(isDraft ? 'common.unpublished' : 'common.published')),
                      const Text('·'),
                      Text(
                        '${f.formatTimeFromNow(secs(isDraft ? 'updated_at' : 'created_at') * 1000)} '
                        '${f.formatTime(secs('created_at'), 'HH:mm:ss')}',
                      ),
                      const Text('·'),
                      Text('$creator'),
                    ],
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
