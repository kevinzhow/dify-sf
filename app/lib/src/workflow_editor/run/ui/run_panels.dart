/// workflow-app/components/workflow-panel.tsx's run panels in the right panel row: the viewed history run (Record in
/// workflows, ChatRecord in chatflows) and the Test Run / Debug & Preview panel while it is open.
library;

import 'package:collab_client/collab_client.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' show Colors;

import '../../../design/dify_icon.dart';
import '../../../design/dify_tokens.g.dart';
import '../../../design/widgets/widgets.dart';
import '../../../i18n/dify_i18n.dart';
import '../../../editor/editor_controller.dart';
import '../../../workflow/dify_json.dart' show difyDataOf;
import '../../header/format.dart' as fmt;
import '../../store/workflow_store.dart';
import '../../store/workflow_store_scope.dart';
import '../debug_chat.dart' show getThreadMessages;
import '../run_scope.dart';
import 'chat.dart';
import 'debug_and_preview.dart';
import 'run_panel.dart';
import 'run_widgets.dart' show getProcessedFilesFromResponse;
import 'workflow_preview.dart';

/// The Start node's `variables` in [doc].
List<DifyJson> startVariablesOf(Document doc) {
  final start = doc.nodes.values.where((n) => n.type == 'start').firstOrNull;
  if (start == null) return const [];
  return [
    for (final v in (difyDataOf(start)['variables'] as List? ?? const []))
      if (v is Map) v.cast<String, Object?>(),
  ];
}

class RunPanels extends StatelessWidget {
  const RunPanels({
    super.key,
    required this.controller,
    required this.isChatMode,
    this.canRun = true,
    this.onBackToEdit,
  });

  final EditorController controller;
  final bool isChatMode;
  final bool canRun;

  /// ChatRecord's close: useWorkflowRun's handleLoadBackupDraft before leaving the history view.
  final VoidCallback? onBackToEdit;

  @override
  Widget build(BuildContext context) {
    final store = WorkflowStoreScope.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([store.historyWorkflowData, store.showDebugAndPreviewPanel]),
      builder: (context, _) {
        final history = store.historyWorkflowData.value;
        final debug = store.showDebugAndPreviewPanel.value;
        if (history == null && !debug) return const SizedBox.shrink();
        return ListenableBuilder(
          listenable: controller,
          builder: (context, _) {
            final panel = RunPanelContext(
              startVariables: startVariablesOf(controller.doc),
              hasSelectedNode: controller.selectedNode != null,
              canRun: canRun,
            );
            return Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (history != null && !isChatMode) const RunRecord(),
                if (history != null && isChatMode)
                  ChatRecord(key: ValueKey(history['id']), startVariables: panel.startVariables, onClose: onBackToEdit),
                if (debug && isChatMode) DebugAndPreview(panel: panel),
                if (debug && !isChatMode) WorkflowPreview(panel: panel),
              ],
            );
          },
        );
      },
    );
  }
}

/// chat-record's getFormattedChatList: the conversation's messages as question / answer chat items.
List<DifyJson> getFormattedChatList(List<DifyJson> messages) {
  final res = <DifyJson>[];
  List<DifyJson> files(DifyJson m, String belongsTo) => getProcessedFilesFromResponse([
    for (final f in (m['message_files'] as List? ?? const []))
      if (f is Map && f['belongs_to'] == belongsTo) {...f.cast<String, Object?>(), 'related_id': f['id']},
  ]);
  for (final m in messages) {
    res
      ..add({
        'id': 'question-${m['id']}',
        'content': m['query'],
        'isAnswer': false,
        'message_files': files(m, 'user'),
        'parentMessageId': (m['parent_message_id'] as String?)?.isNotEmpty == true ? m['parent_message_id'] : null,
      })
      ..add({
        'id': m['id'],
        'content': m['answer'],
        'feedback': m['feedback'],
        'isAnswer': true,
        'citation': (m['metadata'] as Map?)?['retriever_resources'],
        'reasoningContent': (m['metadata'] as Map?)?['reasoning'],
        'reasoningFinished': true,
        'message_files': files(m, 'assistant'),
        'workflow_run_id': m['workflow_run_id'],
        'parentMessageId': 'question-${m['id']}',
      });
  }
  return res;
}

/// base/chat/utils.ts buildChatItemTree (no legacy `UUID_NIL` threads in dify-sf): question/answer pairs under their
/// parent answers, sibling indexes per parent.
List<DifyJson> buildChatItemTree(List<DifyJson> all) {
  final map = <String, DifyJson>{};
  final roots = <DifyJson>[];
  final childrenCount = <String, int>{};
  final ids = {for (final m in all) m['id']};
  final pending = <String, List<DifyJson>>{};
  void appendPending(String parentId) {
    final children = pending.remove(parentId);
    if (children != null) (map[parentId]!['children']! as List).addAll(children);
  }

  for (var i = 0; i + 1 < all.length; i += 2) {
    final question = all[i], answer = all[i + 1];
    final parentId = '${question['parentMessageId'] ?? ''}';
    childrenCount[parentId] = (childrenCount[parentId] ?? 0) + 1;
    final q = <String, Object?>{...question, 'children': <DifyJson>[]};
    map['${question['id']}'] = q;
    childrenCount['${question['id']}'] = 1;
    final a = <String, Object?>{...answer, 'children': <DifyJson>[], 'siblingIndex': childrenCount[parentId]! - 1};
    map['${answer['id']}'] = a;
    (q['children']! as List).add(a);
    appendPending('${question['id']}');
    appendPending('${answer['id']}');
    if (parentId.isEmpty || !ids.contains(parentId)) {
      roots.add(q);
    } else if (map[parentId] == null) {
      pending.putIfAbsent(parentId, () => []).add(q);
    } else {
      (map[parentId]!['children']! as List).add(q);
    }
  }
  return roots;
}

/// ChatRecord: the viewed chatflow run's conversation ("TEST CHAT (time)", close) read-only, with the user inputs.
class ChatRecord extends StatefulWidget {
  const ChatRecord({super.key, this.startVariables = const [], this.onClose, this.fetchChatMessages});
  final List<DifyJson> startVariables;
  final VoidCallback? onClose;
  final Future<List<DifyJson>> Function(String conversationId)? fetchChatMessages;

  @override
  State<ChatRecord> createState() => _ChatRecordState();
}

class _ChatRecordState extends State<ChatRecord> {
  bool _fetched = false;
  List<DifyJson> _tree = const [];
  List<DifyJson> _thread = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _fetch());
  }

  Future<void> _fetch() async {
    final store = WorkflowStoreScope.of(context);
    final id = store.historyWorkflowData.value?['conversation_id'] as String?;
    final fetch = widget.fetchChatMessages ?? WorkflowRunScope.maybeOf(context)?.service.fetchChatMessages;
    if (id == null || fetch == null) {
      setState(() => _fetched = true);
      return;
    }
    try {
      final items = getFormattedChatList(await fetch(id));
      final tree = buildChatItemTree(items);
      if (mounted) {
        setState(() {
          _tree = tree;
          _thread = getThreadMessages(tree, items.lastOrNull?['id'] as String?);
        });
      }
    } catch (_) {
      // Dify ignores a failed fetch.
    } finally {
      if (mounted) setState(() => _fetched = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = WorkflowStoreScope.of(context);
    final history = store.historyWorkflowData.value;
    return Container(
      width: DifyAdaptive.panelWidth(context, 420),
      decoration: BoxDecoration(
        gradient: DifyGradients.chatbotBg,
        borderRadius: const BorderRadius.horizontal(left: Radius.circular(DifyRadius.xxl)),
        border: Border.all(color: DifyColors.componentsPanelBorder),
        boxShadow: DifyShadows.xl,
      ),
      clipBehavior: Clip.antiAlias,
      child: !_fetched
          ? const RunLoading(color: Colors.transparent)
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'TEST CHAT${fmt.formatWorkflowRunIdentifier((history?['finished_at'] as num?)?.toInt())}',
                          style: difyTextStyle(DifyType.systemMdSemibold, DifyColors.textPrimary),
                        ),
                      ),
                      DifyPressable(
                        semanticLabel: 'close',
                        onPressed: () {
                          widget.onClose?.call();
                          store.historyWorkflowData.value = null;
                        },
                        builder: (context, h, f) => SizedBox(
                          width: 24,
                          height: 24,
                          child: Center(child: RemixIcon('close-line', size: 16, color: DifyColors.textTertiary)),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: DebugChat(
                    chatList: _thread,
                    noChatInput: true,
                    switchSibling: (id) => setState(() => _thread = getThreadMessages(_tree, id)),
                    // chat-record renders its UserInput without variables: nothing shows.
                    chatNode: const ChatRecordUserInput(),
                  ),
                ),
              ],
            ),
    );
  }
}

/// chat-record/user-input.tsx: a collapsible "USER INPUT FIELD" card with a row per variable (ChatRecord passes none, so
/// it renders nothing there).
class ChatRecordUserInput extends StatefulWidget {
  const ChatRecordUserInput({super.key, this.variables = const [], this.initialExpanded = true});
  final List<DifyJson> variables;
  final bool initialExpanded;

  @override
  State<ChatRecordUserInput> createState() => _ChatRecordUserInputState();
}

class _ChatRecordUserInputState extends State<ChatRecordUserInput> {
  late bool _expanded = widget.initialExpanded;

  @override
  Widget build(BuildContext context) {
    if (widget.variables.isEmpty) return const SizedBox.shrink();
    return Container(
      decoration: BoxDecoration(
        color: _expanded ? DifyTailwind.white : DifyColors.componentsPanelOnPanelItemBg,
        borderRadius: BorderRadius.circular(DifyRadius.xl),
        border: Border.all(color: _expanded ? Colors.transparent : DifyColors.componentsPanelBorderSubtle),
        boxShadow: _expanded ? DifyShadows.xs : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GestureDetector(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 16, 8, 0),
              child: Row(
                children: [
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: RotatedBox(
                      quarterTurns: _expanded ? 0 : 3,
                      child: RemixIcon(
                        'arrow-down-s-line',
                        size: 12,
                        color: _expanded ? DifyColors.textTertiary : DifyColors.textAccent,
                      ),
                    ),
                  ),
                  Text(
                    DifyI18n.tr('workflow', 'panel.userInputField').toUpperCase(),
                    style: difyTextStyle(
                      DifyTw.text13Semibold,
                      _expanded ? DifyColors.textSecondary : DifyColors.textAccentSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
            child: _expanded
                ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Column(
                      children: [
                        for (final (i, v) in widget.variables.indexed)
                          SizedBox(
                            key: ValueKey('record-input-${v['variable']}'),
                            height: i == widget.variables.length - 1 ? 0 : 8,
                          ),
                      ],
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}
