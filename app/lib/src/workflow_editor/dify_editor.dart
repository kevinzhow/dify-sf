import 'dart:async';

import 'package:collab_client/collab_client.dart';
import 'package:flutter/material.dart';

import '../canvas/canvas_controller.dart';
import '../canvas/workflow_canvas.dart' show CanvasDefaults;
import '../cards/card_kit.dart';
import '../cards/provider_icon_image.dart';
import '../design/dify_tokens.g.dart';
import '../design/widgets/toast.dart';
import '../editor/editor_controller.dart';
import '../editor/undo_manager.dart';
import '../editor/notice_overlay.dart';
import '../workflow/workspace_models.dart';
import 'context_menu/context_menu.dart';
import 'features/features_services.dart' show FeaturesServices;
import 'features/workflow_features.dart';
import 'header/checklist/use_checklist.dart' as checklist;
import 'header/editor_header_binding.dart';
import 'header/features_trigger.dart';
import 'header/publisher/app_publisher.dart' show PublisherAppInfo;
import 'header/titles.dart';
import 'header/workflow_header.dart';
import 'dsl/dsl_export_confirm_modal.dart';
import 'dsl/update_dsl_modal.dart';
import 'operator/image_export.dart';
import 'hooks/use_locate_node.dart';
import 'hooks/use_tool_icon.dart';
import 'node_panel/bodies/llm/group_host.dart';
import 'node_panel/node_panel.dart';
import 'note_node/note_node.dart';
import 'operator/operator.dart';
import 'organize/workflow_organize.dart';
import 'run/mock_run_service.dart';
import 'run/run_graph.dart';
import 'run/run_scope.dart';
import 'run/run_service.dart';
import 'run/ui/run_panels.dart';
import 'store/app_registers_sync.dart';
import 'store/store.dart';
import 'variable_inspect/inspect_vars.dart';
import 'variable_inspect/panel.dart';
import 'variable_inspect/trigger.dart';
import 'variable_panels/variable_panels.dart';
import 'block_selector/block_selector.dart';
import 'comments/comment_layer.dart';
import 'comments/comments_panel.dart';
import 'comments/comments_store.dart';
import 'canvas_plus/canvas_plus_buttons.dart';
import 'node_insertion/insert_block.dart';
import 'canvas_plus/container_child_size.dart';
import 'canvas_plus/node_resizers.dart';
import 'version_history/version_history_panel.dart';
import 'workflow_editor.dart';

/// hooks-store `WorkflowAccessControl`: what the user may do in the editor (Dify derives it from the app's permission
/// keys; dify-sf from the account's role).
class WorkflowAccessControl {
  const WorkflowAccessControl({
    this.canEdit = true,
    this.canRun = true,
    this.canImportExportDsl = true,
    this.canReleaseAndVersion = true,
  });

  /// `fullWorkflowAccessControl`.
  static const full = WorkflowAccessControl();

  /// A member who may only look (Dify's normal members and dataset operators): `nodesReadOnly`, no run, no DSL import
  /// or export, no publishing or version history.
  static const viewOnly = WorkflowAccessControl(
    canEdit: false,
    canRun: false,
    canImportExportDsl: false,
    canReleaseAndVersion: false,
  );

  final bool canEdit, canRun, canImportExportDsl, canReleaseAndVersion;
}

/// The signed-in user as the editor shows them (online users, comment authorship): the account (protocol 1.8).
class EditorUser {
  const EditorUser({required this.id, required this.name, this.avatarUrl});
  final String id;
  final String name;
  final String? avatarUrl;
}

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
    this.runService,
    this.commentsStore,
    this.access = WorkflowAccessControl.full,
    this.user,
    this.locateNodeId,
    this.onExportDsl,
    this.onImportDsl,
    this.pickDslFile,
    this.saveImage,
    this.models,
    this.openModelProviderSettings,
  });

  /// The workspace's model providers and models (the model selector, parameter rules, default models, the checklist's
  /// "Configure a model", OpenAI moderation); null: an empty workspace (no server).
  final WorkspaceModels? models;

  /// Opens the model provider settings (Dify's settings destination `provider`); refetching the models afterwards is
  /// the caller's. Null: the selector has no "Model Provider Settings" footer.
  final VoidCallback? openModelProviderSettings;

  /// What the signed-in user may do (read-only for members without the edit role).
  final WorkflowAccessControl access;

  /// The signed-in account; null (the demo, tests): the session's client id and display name stand in.
  final EditorUser? user;

  /// A node to select and bring into view once it is in the document (use-locate-node.ts, the URL's `node_id`).
  final String? locateNodeId;

  /// Exports the document as a Dify workflow file (`include` secret values or not); null: no export. The pane
  /// menu's Export asks about secrets first (use-DSL.ts exportCheck).
  final Future<void> Function(bool includeSecret)? onExportDsl;
  final WorkflowImport? onImportDsl;
  final PickDslFile? pickDslFile;
  final SaveCanvasImage? saveImage;

  final EditorController controller;
  final String serverLabel;

  /// The document's Dify app metadata: a chatflow (`advanced-chat`) or a workflow, its variables.
  final DocMeta meta;

  /// The host's actions (add node, export, demo), shown behind the session menu.
  final List<Widget> actions;

  /// The variable inspect panel's draft variables (no runs without a runtime: none by default).
  final VariableInspectServices variableInspectServices;

  /// The run/debug backend; null: the mock runtime over the document (dify-sf has no runtime yet).
  final WorkflowRunService? runService;

  /// The document's canvas comments. Null: the editor keeps its own for the controller's session (created with it,
  /// disposed with it). Either way the comments UI finds it with [CommentsScope.of].
  final CommentsStore? commentsStore;

  @override
  State<DifyWorkflowEditor> createState() => _DifyWorkflowEditorState();
}

class _DifyWorkflowEditorState extends State<DifyWorkflowEditor> {
  EditorController get controller => widget.controller;
  DocMeta get meta => widget.meta;
  String get serverLabel => widget.serverLabel;
  List<Widget> get actions => widget.actions;

  final _runHost = GlobalKey<WorkflowRunHostState>();

  /// The mock runtime when no run service was given (one per editor): it also serves the variable inspect panel the
  /// values of its runs, unless inspect services were given.
  MockWorkflowRunService? _mockRuns;

  WorkflowRunService _runService(BuildContext context, CanvasController canvas) {
    if (widget.runService case final s?) return s;
    final store = WorkflowStoreScope.of(context);
    final user = widget.user;
    return _mockRuns ??= MockWorkflowRunService(
      graph: () => EditorRunGraph(controller, canvas),
      conversationVariables: () => store.conversationVariables.value,
      // Visual tests compare a run with a real Dify run of the same workflow (about a second): at that pace.
      scenario: CanvasDefaults.reportRect
          ? const MockRunScenario(stepDelay: Duration(milliseconds: 50))
          : const MockRunScenario(),
      // Runs are the signed-in account's (Dify's created_by_account; the run panel's Executor).
      user: user == null ? MockWorkflowRunService.defaultUser : {'id': user.id, 'name': user.name, 'email': ''},
    );
  }

  VariableInspectServices _inspectServices(BuildContext context, CanvasController canvas) {
    final given = widget.variableInspectServices;
    if (!identical(given, VariableInspectServices.none) || widget.runService != null) return given;
    return (_runService(context, canvas) as MockWorkflowRunService).inspectServices;
  }

  /// The comments store this editor created (when none was passed in), tied to the controller's session.
  CommentsStore? _ownComments;
  CommentsStore get _comments =>
      widget.commentsStore ??
      (_ownComments ??= CommentsStore.forSession(controller.session, accountId: widget.user?.id));

  @override
  void initState() {
    super.initState();
    // Dialog routes opened from the editor are outside its icon scope.
    if (widget.models case final models?) ProviderIconScope.fallback = models.icons;
  }

  @override
  void didUpdateWidget(DifyWorkflowEditor old) {
    super.didUpdateWidget(old);
    if (widget.models case final models? when old.models != models) ProviderIconScope.fallback = models.icons;
    if (old.controller.session != controller.session || widget.commentsStore != null) {
      _ownComments?.dispose();
      _ownComments = null;
    }
  }

  @override
  void dispose() {
    _ownComments?.dispose();
    super.dispose();
  }

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
      options: _menuOptions(),
    ).showChangeBlockSelector(context, nodeId, sourceHandle, anchor: box.localToGlobal(r.topLeft) & r.size);
  }

  /// The control bar's and the pane menu's Add Note (operator/hooks.ts handleAddNote): a note follows the pointer.
  void _addNote() {
    final context = _inner;
    if (context != null) addNoteCandidate(context, controller);
  }

  /// The control bar's Organize and Mod+O (useWorkflowOrganize handleLayout).
  void _organize() {
    final context = _inner, canvas = _canvas;
    if (context == null || canvas == null) return;
    WorkflowOrganize(controller: controller, canvas: canvas, store: WorkflowStoreScope.of(context)).handleLayout();
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

  WorkflowMenuOptions _menuOptions({
    void Function(Offset at)? onAddBlock,
    VoidCallback? onAddNote,
    void Function(String nodeId, String sourceHandle)? onChangeBlock,
  }) => WorkflowMenuOptions(
    isChatMode: meta.isChatflow,
    canEdit: widget.access.canEdit,
    canRun: widget.access.canRun,
    canImportExportDsl: widget.access.canImportExportDsl,
    onAddBlock: onAddBlock,
    onAddNote: onAddNote,
    onChangeBlock: onChangeBlock,
    onExportDsl: widget.onExportDsl == null ? null : _exportDsl,
    // Run this step / Stop: the node's single run (local run state in the store).
    isSingleRunning: (nodeId) {
      final context = _inner;
      if (context == null || !context.mounted) return false;
      final status = WorkflowStoreScope.of(context).nodeRunDataOf(nodeId)['_singleRunningStatus'];
      return status == 'running' || status == 'listening';
    },
  );

  /// The pane menu's Export: use-DSL.ts exportCheck over the document's environment variables.
  void _exportDsl() {
    final context = _inner, export = widget.onExportDsl;
    if (context == null || !context.mounted || export == null) return;
    unawaited(
      exportDslWithCheck(context, environmentVariables: controller.appLists.environmentVariables, export: export),
    );
  }

  bool _exportingImage = false;
  Future<void> _exportImage(ExportImageFormat format, {required bool wholeWorkflow}) async {
    final context = _inner, canvas = _canvas;
    if (_exportingImage || context == null || !context.mounted || canvas == null) return;
    _exportingImage = true;
    try {
      await performCanvasImageExport(
        appName: meta.appName,
        readOnly: WorkflowStoreScope.of(context).nodesReadOnly,
        wholeWorkflow: wholeWorkflow,
        capture: () =>
            captureCanvasImage(context, controller.doc, canvas, meta.appName, format, wholeWorkflow: wholeWorkflow),
        save: widget.saveImage ?? saveCanvasImage,
        preview: (image) async {
          if (context.mounted) await showCanvasImagePreview(context, image);
        },
        onError: (error) => toast.error('Export image failed: $error'),
      );
    } finally {
      _exportingImage = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    // dify-sf is a collaborative editor: Dify's collaboration chrome (comment mode, online users) is on.
    final options = OperatorOptions(
      collaborationEnabled: true,
      onAddNote: _addNote,
      onOrganize: _organize,
      onExportImage: (format, {required wholeWorkflow}) => _exportImage(format, wholeWorkflow: wholeWorkflow),
    );
    final menuOptions = _menuOptions(
      onAddBlock: _addBlockAt,
      onAddNote: _addNote,
      onChangeBlock: _changeBlock,
    );
    // Dify's UI is styled by its own tokens: nothing inherited from the app's Material text theme (whose letter
    // spacing would widen every label).
    return _withModels(
      CommentsScope(
        store: _comments,
        child: DefaultTextStyle(
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
                    canEdit: widget.access.canEdit,
                    header: (context, canvas) => _BoundHeader(
                      controller: controller,
                      models: widget.models,
                      canvas: canvas,
                      meta: meta,
                      access: widget.access,
                      user: widget.user,
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
                          // Iteration, loop and note resize controls (node-resizer.tsx).
                          NodeResizers(controller: controller, canvas: canvas, options: menuOptions),
                          // Selected container children grow their container (useNodeResizeObserver).
                          ContainerChildSizeObserver(controller: controller, canvas: canvas, options: menuOptions),
                          // The selected note, edited in place (drawn by the canvas in the notes' layer).
                          LiveNoteBinding(controller: controller, canvas: canvas, options: menuOptions),
                          // Canvas comments: the pins, comment mode's clicks, the new comment's box and the thread.
                          CommentLayer(canvas: canvas),
                          CandidateNode(canvas: canvas, onPlace: _place),
                          if (widget.locateNodeId != null)
                            LocateNodeOnOpen(controller: controller, canvas: canvas, nodeId: widget.locateNodeId),
                        ],
                      );
                    },
                    control: workflowControlBuilder(options),
                    // Editor-wide: the variable inspect data (its trigger and panel; "View log" opens a node's panel on
                    // its Last Run tab; Stop is EVENT_WORKFLOW_STOP) and the run host (runs, single runs, the chatflow
                    // preview; run state is local view state).
                    scope: (context, canvas, child) => VariableInspectHost(
                      services: _inspectServices(context, canvas),
                      nodes: () => controller.doc.nodes.values,
                      onViewNode: (nodeId) {
                        WorkflowStoreScope.of(context).setInitShowLastRunTab(true);
                        controller.selectNode(nodeId);
                      },
                      onStop: () => _runHost.currentState?.emitWorkflowStop(),
                      child: Builder(
                        builder: (context) => WorkflowRunHost(
                          key: _runHost,
                          controller: controller,
                          canvas: canvas,
                          service: _runService(context, canvas),
                          isChatMode: () => widget.meta.isChatflow,
                          fetchInspectVars: VariableInspectScope.of(context).crud.fetchInspectVars,
                          child: child,
                        ),
                      ),
                    ),
                    operator: workflowOperatorBuilder(
                      controller,
                      options,
                      const VariableInspectTrigger(),
                      const VariableInspectPanel(),
                    ),
                    // Dify's right panels: the selected node's panel (a selected edge has none, as in Dify), then the
                    // variable panels.
                    panels: (context, canvas) => WorkflowPanels(
                      controller: controller,
                      canvas: canvas,
                      options: menuOptions,
                      others: [
                        // The viewed history run and the Test Run / Debug & Preview panel (workflow-panel.tsx).
                        RunPanels(controller: controller, isChatMode: meta.isChatflow, canRun: widget.access.canRun),
                        VariablePanels(
                          controller: controller,
                          isChatMode: meta.isChatflow,
                          storeSecret: controller.storeSecret,
                        ),
                        // The comment list, in comment mode.
                        CommentsPanel(canvas: canvas),
                        // While browsing versions (no version service yet: the current draft alone).
                        VersionHistoryPanelHost(
                          data: VersionHistoryPanelData(
                            currentUserId: widget.user?.id ?? controller.session.clientId,
                            canImportExportDsl: widget.access.canImportExportDsl,
                          ),
                        ),
                      ],
                    ),
                    // The Features drawer (chatflows open it from the header), over everything with its backdrop.
                    modal: (context, canvas) => Stack(
                      children: [
                        if (widget.models case final models?)
                          ListenableBuilder(
                            listenable: models,
                            builder: (context, _) => WorkflowFeatures(
                              controller: controller,
                              isChatMode: meta.isChatflow,
                              services: _featuresServices(),
                            ),
                          )
                        else
                          WorkflowFeatures(controller: controller, isChatMode: meta.isChatflow),
                        ImportDslHost(
                          appMode: meta.appMode,
                          onImport: widget.onImportDsl,
                          pickFile: widget.pickDslFile,
                          onBackup: widget.onExportDsl == null ? null : _exportDsl,
                        ),
                      ],
                    ),
                  ),
                  NoticeOverlay(controller: controller),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The model-node panels' services from the workspace's models (rebuilt when they change).
  Widget _withModels(Widget child) {
    final models = widget.models;
    if (models == null) return child;
    return ListenableBuilder(
      listenable: models,
      builder: (context, child) => LlmGroupScope(
        services: LlmGroupServices(
          models: models.catalog,
          defaultModels: models.defaultModelsMap,
          parameterRules: models.parameterRules,
          openModelProviderSettings: widget.openModelProviderSettings,
          refreshModels: () => unawaited(models.refreshModelLists()),
        ),
        child: ProviderIconScope(source: models.icons, child: child!),
      ),
      child: child,
    );
  }

  /// The features panel's services: the model providers (OpenAI moderation) and the settings destination.
  FeaturesServices _featuresServices() {
    final models = widget.models;
    if (models == null) return FeaturesServices.empty;
    final open = widget.openModelProviderSettings;
    return FeaturesServices(
      modelProviders: models.providerDetails ?? const [],
      modelProvidersLoading: models.providerDetails == null,
      openAccountSettings: open == null ? null : (destination) => destination == 'provider' ? open() : null,
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
    this.access = WorkflowAccessControl.full,
    this.user,
    this.models,
  });
  final EditorController controller;
  final CanvasController canvas;
  final WorkspaceModels? models;
  final DocMeta meta;
  final WorkflowAccessControl access;
  final EditorUser? user;

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

  /// The people on this document: this user (by account, like Dify's online users; several windows of one account are
  /// one user). dify-sf has no presence of others yet.
  final _users = ValueNotifier<List<OnlineUser>>(const []);

  /// The providers the checklist last saw: it is recomputed when they change.
  List<Json>? _providers;

  @override
  void initState() {
    super.initState();
    widget.models?.addListener(_modelsChanged);
  }

  void _modelsChanged() {
    final providers = widget.models?.summary;
    if (identical(providers, _providers)) return;
    _providers = providers;
    _binding?.refreshChecklist();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_binding == null) _storeVariables();
    final store = WorkflowStoreScope.of(context);
    _binding ??= EditorHeaderBinding(
      controller: widget.controller,
      store: store,
      // The workspace's providers (empty while loading or without a server, as Dify's query default), so LLM nodes
      // of other providers need a model configured. The variables are the document's (it is recomputed on every change
      // of the document).
      checklistEnv: () => checklist.ChecklistEnv(
        appMode: widget.meta.appMode,
        language: widget.models?.language ?? 'en_US',
        environmentVariables: widget.controller.appLists.environmentVariables,
        conversationVariables: widget.controller.appLists.conversationVariables,
        modelProviders: [for (final p in widget.models?.summary ?? const <Json>[]) '${p['provider']}'],
        // useGetToolIcon: the store's tool collections, else the icon the node was created with.
        toolIcon: (n) => getToolIcon(store)(n.data),
      ),
    );
    final session = widget.controller.session, user = widget.user;
    _users.value = [
      OnlineUser(
        sid: session.clientId,
        userId: user?.id ?? session.clientId,
        username: user?.name ?? session.displayName ?? '',
        avatar: user?.avatarUrl,
      ),
    ];
  }

  @override
  void didUpdateWidget(_BoundHeader old) {
    super.didUpdateWidget(old);
    if (old.models != widget.models) {
      old.models?.removeListener(_modelsChanged);
      widget.models?.addListener(_modelsChanged);
    }
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
    widget.models?.removeListener(_modelsChanged);
    _variables?.dispose();
    _binding?.dispose();
    _users.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final b = _binding!;
    final run = WorkflowRunScope.maybeOf(context)?.run;
    return WorkflowHeader(
      canvas: widget.canvas,
      data: WorkflowHeaderData(
        graph: b.graph,
        onRun: run?.handleStartRunFromOption,
        onRunInChatflow: run?.handleWorkflowStartRunInChatflow,
        onStopRun: run?.handleStopRun,
        fetchRunHistory: run?.fetchRunHistory,
        invalidAllLastRun: run?.invalidAllLastRun,
        isChatMode: widget.meta.isChatflow,
        onlineUsers: _users,
        currentUserId: widget.user?.id ?? widget.controller.session.clientId,
        canEdit: widget.access.canEdit,
        canRun: widget.access.canRun,
        canReleaseAndVersion: widget.access.canReleaseAndVersion,
        handleNodeSelect: (id, {cancelSelection = false}) =>
            cancelSelection ? cancelNodesSelectedOn(widget.canvas, widget.controller) : b.selectNode(id),
        handleNodesCancelSelected: () => cancelNodesSelectedOn(widget.canvas, widget.controller),
        title: widget.session(const EditingTitle()),
        left: widget.left,
        middle: FeaturesTrigger(
          // The document as the publisher's app (its mode: a workflow or a chatflow, both Dify's workflow apps).
          app: PublisherAppInfo(id: widget.controller.docId, name: widget.meta.appName, mode: widget.meta.appMode),
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
