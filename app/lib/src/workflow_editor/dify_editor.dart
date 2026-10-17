import 'package:collab_client/collab_client.dart';
import 'package:flutter/material.dart';

import '../canvas/canvas_controller.dart';
import '../design/dify_tokens.g.dart';
import '../editor/editor_controller.dart';
import '../editor/node_panel.dart';
import '../editor/notice_overlay.dart';
import 'header/checklist/use_checklist.dart' as checklist;
import 'header/editor_header_binding.dart';
import 'header/features_trigger.dart';
import 'header/workflow_header.dart';
import 'operator/operator.dart';
import 'store/store.dart';
import 'variable_inspect/trigger.dart';
import 'workflow_editor.dart';

/// The editor as Dify lays it out: the canvas with Dify's header, control bar, operator bar, context menus and
/// shortcuts. dify-sf's own collaboration controls (link state, reconnect, unsaved edits, the host's actions) sit in
/// the header's left slot, where Dify puts its own extra controls.
class DifyWorkflowEditor extends StatelessWidget {
  const DifyWorkflowEditor({super.key, required this.controller, this.serverLabel = '', this.actions = const []});

  final EditorController controller;
  final String serverLabel;

  /// The host's actions (add node, export, demo), shown behind the session menu.
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    // dify-sf is a collaborative editor: Dify's collaboration chrome (comment mode, online users) is on.
    const options = OperatorOptions(collaborationEnabled: true);
    return OperatorShortcuts(
      history: controller.undo,
      options: options,
      child: Stack(
        fit: StackFit.expand,
        children: [
          WorkflowEditor(
            controller: controller,
            header: (context, canvas) => _BoundHeader(
              controller: controller,
              canvas: canvas,
              left: SessionBadge(controller: controller, serverLabel: serverLabel, actions: actions),
            ),
            control: workflowControlBuilder(options),
            operator: workflowOperatorBuilder(controller, options, const VariableInspectTrigger()),
            panels: (context, canvas) => ListenableBuilder(
              listenable: controller,
              // The node panel shows while a node or an edge is selected (Dify's NodePanel / edge details).
              builder: (context, _) => controller.selectedNode == null && controller.selectedEdgeId == null
                  ? const SizedBox.shrink()
                  : NodePanel(controller: controller),
            ),
          ),
          NoticeOverlay(controller: controller),
        ],
      ),
    );
  }
}

/// The header with its data bound to the session ([EditorHeaderBinding] needs the editor's store, found in scope).
class _BoundHeader extends StatefulWidget {
  const _BoundHeader({required this.controller, required this.canvas, this.left});
  final EditorController controller;
  final CanvasController canvas;
  final Widget? left;

  @override
  State<_BoundHeader> createState() => _BoundHeaderState();
}

class _BoundHeaderState extends State<_BoundHeader> {
  EditorHeaderBinding? _binding;

  /// The people on this document; dify-sf has no presence yet, so it is this user.
  final _users = ValueNotifier<List<OnlineUser>>(const []);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _binding ??= EditorHeaderBinding(
      controller: widget.controller,
      store: WorkflowStoreScope.of(context),
      // The app's model catalog is an empty workspace (see ModelCatalog), so LLM nodes need a model configured.
      checklistEnv: () => checklist.ChecklistEnv(modelProviders: const []),
    );
    final session = widget.controller.session;
    _users.value = [
      OnlineUser(sid: session.clientId, userId: session.clientId, username: session.displayName ?? ''),
    ];
  }

  @override
  void dispose() {
    _binding?.dispose();
    _users.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final b = _binding!;
    return WorkflowHeader(
      canvas: widget.canvas,
      data: WorkflowHeaderData(
        graph: b.graph,
        onlineUsers: _users,
        currentUserId: widget.controller.session.clientId,
        handleNodeSelect: b.selectNode,
        handleNodesCancelSelected: b.cancelSelection,
        left: widget.left,
        middle: FeaturesTrigger(
          hooks: WorkflowPublishHooks(
            checkBeforePublish: () => b.checkBeforePublish(null),
            syncWorkflowDraft: b.syncWorkflowDraft,
          ),
        ),
      ),
    );
  }
}

/// dify-sf's session in Dify's header: a pill only while the link is not live (with "Reconnect now"), and a menu with
/// the link state, unsaved edits, the last seq, this client's identity and the host's actions. Saving progress itself
/// is Dify's own "Auto-Saved … / Syncing" line.
class SessionBadge extends StatelessWidget {
  const SessionBadge({super.key, required this.controller, this.serverLabel = '', this.actions = const []});

  final EditorController controller;
  final String serverLabel;
  final List<Widget> actions;

  static const _small = TextStyle(fontSize: 12, height: 16 / 12, color: DifyColors.textTertiary);

  (Color, String) _link(SessionStatus s) => switch (s.link) {
    LinkState.live => (DifyColors.textSuccess, 'Live'),
    LinkState.connecting => (DifyColors.textWarning, 'Connecting…'),
    LinkState.reconnecting => (DifyColors.textWarning, 'Reconnecting…'),
    LinkState.offline => (DifyColors.textDestructive, 'Offline'),
  };

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final s = controller.status;
      final (color, label) = _link(s);
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Back to the document list (Dify leaves this to its app sidebar, which the editor does not include).
          if (ModalRoute.of(context)?.canPop ?? false) const BackButton(),
          if (s.link != LinkState.live) ...[
            Icon(Icons.circle, size: 8, color: color),
            const SizedBox(width: 4),
            Text(label, style: _small),
            TextButton(
              key: const Key('reconnect-now'),
              style: TextButton.styleFrom(minimumSize: const Size(0, 24), padding: const EdgeInsets.all(4)),
              onPressed: controller.reconnectNow,
              child: const Text('Reconnect now', style: TextStyle(fontSize: 12)),
            ),
          ],
          MenuAnchor(
            menuChildren: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.circle, size: 8, color: color, key: const Key('link-dot')),
                        const SizedBox(width: 6),
                        Text(label, key: const Key('link-state'), style: _small),
                        const SizedBox(width: 12),
                        Text(
                          s.pending == 0 ? 'All edits saved' : '${s.pending} unsaved edit${s.pending == 1 ? '' : 's'}',
                          key: const Key('pending-count'),
                          style: s.pending == 0 ? _small : _small.copyWith(color: DifyColors.textWarning),
                        ),
                        const SizedBox(width: 12),
                        Text('seq ${s.lastSeq}', key: const Key('last-seq'), style: _small),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${controller.journaled ? 'journaled' : 'volatile'} · ${controller.session.clientId} · '
                      '${controller.docId} · $serverLabel',
                      style: _small,
                    ),
                    if (s.lastError != null)
                      Text(s.lastError!, style: _small.copyWith(color: DifyColors.textDestructive)),
                    if (actions.isNotEmpty) Row(mainAxisSize: MainAxisSize.min, children: actions),
                  ],
                ),
              ),
            ],
            builder: (context, menu, _) => IconButton(
              key: const Key('session-menu'),
              tooltip: 'Collaboration session',
              iconSize: 16,
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.cloud_done_outlined, color: s.link == LinkState.live ? DifyColors.textTertiary : color),
              onPressed: () => menu.isOpen ? menu.close() : menu.open(),
            ),
          ),
        ],
      );
    },
  );
}
