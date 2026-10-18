import 'package:collab_client/collab_client.dart';
import 'package:flutter/material.dart';

import '../canvas/canvas_controller.dart';
import '../cards/card_kit.dart';
import '../design/dify_tokens.g.dart';
import '../design/widgets/toast.dart';
import '../editor/editor_controller.dart';
import '../editor/undo_manager.dart';
import '../editor/notice_overlay.dart';
import 'context_menu/context_menu.dart';
import 'features/workflow_features.dart';
import 'header/checklist/use_checklist.dart' as checklist;
import 'header/editor_header_binding.dart';
import 'header/features_trigger.dart';
import 'header/titles.dart';
import 'header/workflow_header.dart';
import 'node_panel/node_panel.dart';
import 'note_node/note_node.dart';
import 'operator/operator.dart';
import 'store/app_registers_sync.dart';
import 'store/store.dart';
import 'variable_inspect/inspect_vars.dart';
import 'variable_inspect/panel.dart';
import 'variable_inspect/trigger.dart';
import 'variable_panels/variable_panels.dart';
import 'block_selector/block_selector.dart';
import 'canvas_plus/canvas_plus_buttons.dart';
import 'node_insertion/insert_block.dart';
import 'workflow_editor.dart';

/// The editor as Dify lays it out: the canvas with Dify's header, control bar, operator bar, context menus and
/// shortcuts. dify-sf's own collaboration controls (link state, reconnect, unsaved edits, the host's actions) sit in
/// the header's left slot, where Dify puts its own extra controls.
class DifyWorkflowEditor extends StatefulWidget {
  const DifyWorkflowEditor({
    super.key,
    required this.controller,
    this.serverLabel = '',
    this.actions = const [],
    this.meta = const DocMeta(),
    this.variableInspectServices = VariableInspectServices.none,
  });

  final EditorController controller;
  final String serverLabel;

  /// The document's Dify app metadata: a chatflow (`advanced-chat`) or a workflow, its variables.
  final DocMeta meta;

  /// The host's actions (add node, export, demo), shown behind the session menu.
  final List<Widget> actions;

  /// The variable inspect panel's draft variables (no runs without a runtime: none by default).
  final VariableInspectServices variableInspectServices;

  @override
  State<DifyWorkflowEditor> createState() => _DifyWorkflowEditorState();
}

class _DifyWorkflowEditorState extends State<DifyWorkflowEditor> {
  EditorController get controller => widget.controller;
  DocMeta get meta => widget.meta;
  String get serverLabel => widget.serverLabel;
  List<Widget> get actions => widget.actions;

  /// A context inside the editor's scopes (store, block selector) and its canvas, for popups opened from callbacks.
  BuildContext? _inner;
  CanvasController? _canvas;

  /// The pane menu's Add Node (panel-contextmenu.tsx reuses AddBlock): the block selector at the menu, and the chosen
  /// block becomes the candidate that follows the pointer.
  void _addBlockAt(Offset at) {
    final context = _inner, canvas = _canvas;
    if (context == null || canvas == null) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    final data = BlockSelectorScope.of(context), store = WorkflowStoreScope.of(context);
    final p = BlockSelectorPlacements.paneMenu;
    final screen = box.localToGlobal(canvas.view.toScreen(at));
    BlockSelector(
      placement: p.placement,
      sideOffset: p.sideOffset,
      alignOffset: p.alignOffset,
      popupMinWidth: 256,
      isolateKeyboardEvents: true,
      availableBlocksTypes: useAvailableBlocks(
        'start',
        availableTypes: availableNodeTypes(chatMode: data.chatMode, agentV2: data.agentV2),
      ).next,
      showStartTab: !data.chatMode && data.flow == BlockSelectorFlow.app,
      onSelect: (type, defaults, {toolDefaultValue}) => store.setCandidateNode(
        candidateNodeOf(
          type,
          defaults,
          toolDefaultValue: toolDefaultValue,
          existing: [
            for (final n in data.nodes)
              {
                'id': n.id,
                'data': {'type': n.type},
              },
          ],
        ),
      ),
    ).show(context, anchor: screen & Size.zero);
  }

  /// The node menu's Change Block (change-block.tsx): the block selector at the node, replacing it with the block
  /// picked.
  void _changeBlock(String nodeId, String sourceHandle) {
    final context = _inner, canvas = _canvas;
    final node = canvas?.graph?[nodeId];
    if (context == null || canvas == null || node == null) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    final r = canvas.view.rectToScreen(node.rect);
    WorkflowActions(
      controller: controller,
      canvas: canvas,
      store: WorkflowStoreScope.of(context),
      options: WorkflowMenuOptions(isChatMode: meta.isChatflow),
    ).showChangeBlockSelector(context, nodeId, sourceHandle, anchor: box.localToGlobal(r.topLeft) & r.size);
  }

  /// The control bar's and the pane menu's Add Note (operator/hooks.ts handleAddNote): a note follows the pointer.
  void _addNote() {
    final context = _inner;
    if (context != null) addNoteCandidate(context, controller);
  }

  /// Puts a placed candidate (and an iteration's or loop's start node) into the document as one undo step.
  void _place(CandidatePlacement p) {
    final doc = controller.doc;
    controller.addNodes(
      [
        for (final json in [p.node, ?p.startNode]) nodeFromDify(json, doc, id: json['id']! as String),
      ],
      event: p.historyEvent == 'NoteAdd' ? HistoryEvent.noteAdd : HistoryEvent.nodeAdd,
    );
  }

  @override
  Widget build(BuildContext context) {
    // dify-sf is a collaborative editor: Dify's collaboration chrome (comment mode, online users) is on.
    final options = OperatorOptions(collaborationEnabled: true, onAddNote: _addNote);
    final menuOptions = WorkflowMenuOptions(
      isChatMode: meta.isChatflow,
      onAddBlock: _addBlockAt,
      onAddNote: _addNote,
      onChangeBlock: _changeBlock,
    );
    // Dify's UI is styled by its own tokens: nothing inherited from the app's Material text theme (whose letter
    // spacing would widen every label).
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
      // The block selector reads the app mode and what is on the canvas (singletons, the Start tab's conflicts).
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, child) => BlockSelectorScope(
          data: BlockSelectorData(
            chatMode: meta.isChatflow,
            nodes: [for (final n in controller.doc.nodes.values) (id: n.id, type: n.type)],
          ),
          child: child!,
        ),
        child: OperatorShortcuts(
          history: controller.undo,
          options: options,
          child: Stack(
            fit: StackFit.expand,
            children: [
              WorkflowEditor(
                controller: controller,
                menuOptions: menuOptions,
                header: (context, canvas) => _BoundHeader(
                  controller: controller,
                  canvas: canvas,
                  meta: meta,
                  session: (anchor) => SessionBadge(
                    controller: controller,
                    serverLabel: serverLabel,
                    actions: actions,
                    anchor: anchor,
                    pill: false,
                  ),
                  left: _OfflinePill(controller: controller),
                ),
                // A block picked from Add Node follows the pointer until a click places it (candidate-node.tsx).
                overlay: (context, canvas) {
                  _inner = context;
                  _canvas = canvas;
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      CanvasPlusButtons(controller: controller, canvas: canvas, options: menuOptions),
                      // The selected note, edited in place (drawn by the canvas in the notes' layer).
                      LiveNoteBinding(controller: controller, canvas: canvas, options: menuOptions),
                      CandidateNode(canvas: canvas, onPlace: _place),
                    ],
                  );
                },
                control: workflowControlBuilder(options),
                // The variable inspect trigger and panel share the editor's inspect data; "View log" opens a node's
                // panel on its Last Run tab.
                operator: (context, canvas) => VariableInspectHost(
                  services: widget.variableInspectServices,
                  nodes: () => controller.doc.nodes.values,
                  onViewNode: (nodeId) {
                    WorkflowStoreScope.of(context).setInitShowLastRunTab(true);
                    controller.selectNode(nodeId);
                  },
                  child: workflowOperatorBuilder(
                    controller,
                    options,
                    const VariableInspectTrigger(),
                    const VariableInspectPanel(),
                  )(context, canvas),
                ),
                // Dify's right panels: the selected node's panel (a selected edge has none, as in Dify), then the
                // variable panels.
                panels: (context, canvas) => WorkflowPanels(
                  controller: controller,
                  canvas: canvas,
                  options: menuOptions,
                  others: [
                    VariablePanels(
                      controller: controller,
                      isChatMode: meta.isChatflow,
                      storeSecret: controller.storeSecret,
                    ),
                  ],
                ),
                // The Features drawer (chatflows open it from the header), over everything with its backdrop.
                modal: (context, canvas) => WorkflowFeatures(controller: controller, isChatMode: meta.isChatflow),
              ),
              NoticeOverlay(controller: controller),
            ],
          ),
        ),
      ),
    );
  }
}

/// The header with its data bound to the session ([EditorHeaderBinding] needs the editor's store, found in scope).
class _BoundHeader extends StatefulWidget {
  const _BoundHeader({
    required this.controller,
    required this.canvas,
    required this.meta,
    required this.session,
    this.left,
  });
  final EditorController controller;
  final CanvasController canvas;
  final DocMeta meta;

  /// Dify's auto-saved line, opening dify-sf's session menu.
  final Widget Function(Widget anchor) session;
  final Widget? left;

  @override
  State<_BoundHeader> createState() => _BoundHeaderState();
}

class _BoundHeaderState extends State<_BoundHeader> {
  EditorHeaderBinding? _binding;

  /// The store's environment and conversation variables follow the document (protocol 1.7).
  AppRegistersSync? _variables;

  /// The people on this document; dify-sf has no presence yet, so it is this user.
  final _users = ValueNotifier<List<OnlineUser>>(const []);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_binding == null) _storeVariables();
    _binding ??= EditorHeaderBinding(
      controller: widget.controller,
      store: WorkflowStoreScope.of(context),
      // The app's model catalog is an empty workspace (see ModelCatalog), so LLM nodes need a model configured. The
      // variables are the document's (it is recomputed on every change of the document).
      checklistEnv: () => checklist.ChecklistEnv(
        appMode: widget.meta.appMode,
        environmentVariables: widget.controller.appLists.environmentVariables,
        conversationVariables: widget.controller.appLists.conversationVariables,
        modelProviders: const [],
      ),
    );
    final session = widget.controller.session;
    _users.value = [
      OnlineUser(sid: session.clientId, userId: session.clientId, username: session.displayName ?? ''),
    ];
  }

  @override
  void didUpdateWidget(_BoundHeader old) {
    super.didUpdateWidget(old);
    if (!identical(old.meta, widget.meta)) _storeVariables(refreshChecklist: true);
  }

  /// The app's environment and conversation variables, where Dify's UI reads them: the document's, kept in sync from
  /// then on by [AppRegistersSync] (and the checklist, which depends on the app mode, when the metadata changed).
  /// After the frame: this runs while building, and other widgets listen to the store.
  void _storeVariables({bool refreshChecklist = false}) {
    _variables ??= AppRegistersSync(controller: widget.controller, store: WorkflowStoreScope.of(context));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _variables?.sync();
      if (refreshChecklist) _binding?.refreshChecklist();
    });
  }

  @override
  void dispose() {
    _variables?.dispose();
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
        isChatMode: widget.meta.isChatflow,
        onlineUsers: _users,
        currentUserId: widget.controller.session.clientId,
        handleNodeSelect: b.selectNode,
        handleNodesCancelSelected: b.cancelSelection,
        title: widget.session(const EditingTitle()),
        left: widget.left,
        middle: FeaturesTrigger(
          hooks: WorkflowPublishHooks(
            checkBeforePublish: () => b.checkBeforePublish(difyToast),
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
  const SessionBadge({
    super.key,
    required this.controller,
    this.serverLabel = '',
    this.actions = const [],
    this.anchor,
    this.pill = true,
    this.menu = true,
  });

  final EditorController controller;
  final String serverLabel;
  final List<Widget> actions;

  /// What opens the session menu (Dify's auto-saved line); null: a small cloud icon.
  final Widget? anchor;

  /// Whether the offline pill is part of this widget.
  final bool pill;

  /// Whether the session menu is part of this widget.
  final bool menu;

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
          if (pill && s.link != LinkState.live) ...[
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
          if (menu)
            Flexible(
              child: MenuAnchor(
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
                              s.pending == 0
                                  ? 'All edits saved'
                                  : '${s.pending} unsaved edit${s.pending == 1 ? '' : 's'}',
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
                        // Back to the document list (Dify leaves this to its app sidebar, which the editor does not have).
                        if (ModalRoute.of(context)?.canPop ?? false)
                          TextButton.icon(
                            key: const Key('back-to-documents'),
                            icon: const Icon(Icons.arrow_back, size: 16),
                            label: const Text('Documents', style: TextStyle(fontSize: 12)),
                            onPressed: () => Navigator.of(context).maybePop(),
                          ),
                      ],
                    ),
                  ),
                ],
                builder: (context, menu, _) => anchor != null
                    ? GestureDetector(
                        key: const Key('session-menu'),
                        behavior: HitTestBehavior.opaque,
                        onTap: () => menu.isOpen ? menu.close() : menu.open(),
                        child: MouseRegion(cursor: SystemMouseCursors.click, child: anchor),
                      )
                    : IconButton(
                        key: const Key('session-menu'),
                        tooltip: 'Collaboration session',
                        iconSize: 16,
                        visualDensity: VisualDensity.compact,
                        icon: Icon(
                          Icons.cloud_done_outlined,
                          color: s.link == LinkState.live ? DifyColors.textTertiary : color,
                        ),
                        onPressed: () => menu.isOpen ? menu.close() : menu.open(),
                      ),
              ),
            ),
        ],
      );
    },
  );
}

/// dify-sf's link state while it is not live, with "Reconnect now" (nothing while live, as in Dify).
class _OfflinePill extends StatelessWidget {
  const _OfflinePill({required this.controller});
  final EditorController controller;

  @override
  Widget build(BuildContext context) => SessionBadge(controller: controller, menu: false);
}
