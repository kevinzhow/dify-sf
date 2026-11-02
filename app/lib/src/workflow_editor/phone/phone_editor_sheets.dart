/// The phone editor's sheets (dify-sf, compact windows; mockup 7-run): the run as a persistent sheet over the editor
/// (at its peek: the run's state, time and Stop; dragged up: Input | Result | Detail | Tracing), the run's and a single
/// step's input forms as modal sheets, and the editor's other panels (the variable panels, variable inspect, the
/// comment list, the version list) as bottom sheets instead of the area under the app bar.
///
/// Every sheet is a [DifyPersistentSheet] in the editor's page, not a route: its content keeps the editor's scopes
/// (the store, the run host, the header's data, variable inspect, comments), which a route on the root navigator would
/// not see. The store's panel flags say which sheet shows, exactly as they say which desktop panel shows, and closing a
/// sheet clears its flag the way the desktop panel's close button does. The non-modal sheets (the run, the version
/// list, the comment list) sit between the view switch and the bottom bar, so the Steps view or the canvas above them
/// and the toolbar or selection bar below them stay usable; the modal ones cover the page with a scrim, as a sheet
/// route does. Back closes the newest first ([PhoneEditorSheets.backStep]).
library;

import 'dart:async';

import 'package:collab_client/collab_client.dart' show Node;
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../../canvas/canvas_input.dart' show ControlMode;
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../editor/editor_controller.dart';
import '../../i18n/dify_i18n.dart';
import '../block_selector/selector_widgets.dart' show SelectorBlockIcon, SelectorIconSize;
import '../comments/comments_store.dart' show CommentsScope;
import '../context_menu/context_menu.dart' show canRunBySingle, parentIdOf;
import '../header/format.dart' as fmt;
import '../header/header_data.dart';
import '../header/titles.dart' show workflowVersionDraft;
import '../run/run_scope.dart';
import '../run/run_types.dart' show NodeRunningStatus, resultOf;
import '../run/ui/debug_and_preview.dart';
import '../run/ui/node_run_ui.dart';
import '../run/ui/run_panel.dart';
import '../run/ui/run_panels.dart' show ChatRecord, startVariablesOf;
import '../run/ui/workflow_preview.dart';
import '../steps/step_labels.dart' show formatStepSeconds;
import '../store/store.dart';
import '../variable_inspect/panel.dart' show InspectPanel;
import 'panel_sheet_scope.dart';
import 'phone_editor_controller.dart';

String _tw(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('workflow', key, params);

/// dify-sf's own phone editor strings (assets/extension_i18n, namespace `phone-editor`).
String _tp(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('phone-editor', key, params);

/// The editor's panels the phone shows in sheets, built by the editor (they need its objects). Each shows itself
/// while the store says so (as in the desktop's panel row); the sheets decide from the same flags whether to show.
@immutable
class PhoneEditorPanels {
  const PhoneEditorPanels({required this.isChatMode, this.canRun = true, this.variables, this.comments, this.versions});

  /// A chatflow: Run is the Debug & Preview chat, and a viewed run is its conversation.
  final bool isChatMode;

  /// `accessControl.canRun` (the run panels' Start Run).
  final bool canRun;

  /// The environment / conversation / system variable panels (`VariablePanels`).
  final Widget? variables;

  /// The comment list of comment mode (`CommentsPanel`).
  final Widget? comments;

  /// The version list of the version browser (`VersionHistoryPanelHost`).
  final Widget? versions;
}

/// The run sheet's peek: the grab handle (20) and the header row (48 + 4): the run's state, its time and Stop.
const _runPeek = DifySheetDetent.peek(72);

/// The version and comment lists' peek: the handle and the header row.
const _listPeek = DifySheetDetent.peek(72);

/// What the run sheet shows: a step run alone, a viewed past run, or the editor's test run.
enum _RunKind { step, history, live }

/// Which of the phone's sheets show, from the store and the phone editor's state.
typedef _Shown = ({
  _RunKind? run,
  bool runInput,
  bool chat,
  String? stepInput,
  bool inspect,
  bool variables,
  bool comments,
  bool versions,
});

/// The phone editor's sheets: their controllers, the single-step runs they start, and Back. Made and disposed by the
/// phone editor's frame, which places [dockedLayer] and [modalLayer] in its page and asks [backStep] on Back.
class PhoneEditorSheets {
  PhoneEditorSheets(this.controller);

  /// The document (the Start node's variables, the nodes a step run shows).
  EditorController controller;

  /// The sheets' controllers (Back collapses and dismisses through them; tests read where they rest).
  final run = DifySheetController(),
      runInput = DifySheetController(),
      chat = DifySheetController(),
      stepInput = DifySheetController(),
      inspect = DifySheetController(),
      variables = DifySheetController(),
      comments = DifySheetController(),
      versions = DifySheetController();

  BuildContext? _context;
  WorkflowStore? _store;
  PhoneEditorController? _phone;
  PhoneEditorPanels _panels = const PhoneEditorPanels(isChatMode: false);

  /// Each node's last seen `_singleRunningStatus` (a step run that starts shows in the run sheet).
  final _singleStatus = <String, String?>{};

  /// Binds to the editor's [store] and phone state; [context] is the frame's (inside the run host). Call it from the
  /// frame's `didChangeDependencies` and `didUpdateWidget`.
  void bind(
    BuildContext context,
    EditorController controller,
    WorkflowStore store,
    PhoneEditorController phone,
    PhoneEditorPanels? panels,
  ) {
    _context = context;
    this.controller = controller;
    _panels = panels ?? const PhoneEditorPanels(isChatMode: false);
    _phone = phone;
    if (store == _store) return;
    _store?.pendingSingleRun.removeListener(_pendingSingleRun);
    _store?.nodeRunData.removeListener(_nodeRunChanged);
    _store = store
      ..pendingSingleRun.addListener(_pendingSingleRun)
      ..nodeRunData.addListener(_nodeRunChanged);
    _singleStatus
      ..clear()
      ..addAll({for (final e in store.nodeRunData.value.entries) e.key: e.value['_singleRunningStatus'] as String?});
  }

  void dispose() {
    _store?.pendingSingleRun.removeListener(_pendingSingleRun);
    _store?.nodeRunData.removeListener(_nodeRunChanged);
    for (final c in [run, runInput, chat, stepInput, inspect, variables, comments, versions]) {
      c.dispose();
    }
  }

  /// Everything that decides which sheets show (the layers rebuild when it changes).
  static List<Listenable> watched(WorkflowStore store) => [
    store.showDebugAndPreviewPanel,
    store.showInputsPanel,
    store.workflowRunningData,
    store.historyWorkflowData,
    store.showVariableInspectPanel,
    store.showEnvPanel,
    store.showChatVariablePanel,
    store.showGlobalVariablePanel,
    store.showWorkflowVersionHistoryPanel,
    store.controlMode,
    store.nodeRunData,
  ];

  // ----- single-step runs -----

  /// "Run step" from the selection bar, a long press or the Steps view leaves a request for the node's panel; on a
  /// phone the panel is not open, so the sheets run it: the node's input form as a sheet when it needs values, its
  /// result in the run sheet. A node whose settings are open runs in its panel, as on the desktop.
  void _pendingSingleRun() {
    final store = _store, phone = _phone, context = _context;
    final p = store?.pendingSingleRun.value;
    if (store == null || phone == null || context == null || p == null || !context.mounted) return;
    if (phone.settingsNodeId == p.nodeId) return;
    store.setPendingSingleRun();
    final node = controller.doc.nodes[p.nodeId];
    if (node == null) return;
    if (p.action == SingleRunAction.stop) {
      WorkflowRunScope.maybeOf(context)?.singleRunOf(p.nodeId).handleStop();
      return;
    }
    handleNodeSingleRun(context, node, controller.doc);
    // The request's "open on Last Run" is for a panel; none opens here.
    store.setInitShowLastRunTab(false);
  }

  /// A step that starts running (from here, the step's form, or its settings) is the run sheet's.
  void _nodeRunChanged() {
    final store = _store, phone = _phone;
    if (store == null || phone == null) return;
    String? started;
    for (final MapEntry(key: id, value: data) in store.nodeRunData.value.entries) {
      final s = data['_singleRunningStatus'] as String?;
      if (_singleStatus[id] == s) continue;
      _singleStatus[id] = s;
      if (s == NodeRunningStatus.running || s == NodeRunningStatus.listening) started = id;
    }
    if (started == null) return;
    final id = started;
    void show() {
      phone.singleRunNodeId = id;
      if (phone.settingsNodeId != id) store.setInitShowLastRunTab(false);
      unawaited(run.animateTo(_runPeek));
    }

    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => show());
    } else {
      show();
    }
  }

  // ----- what shows -----

  /// The node whose single-run form is open (`_isSingleRun`) without its settings showing it.
  String? _stepInputNode(WorkflowStore store, PhoneEditorController phone) {
    for (final MapEntry(key: id, value: data) in store.nodeRunData.value.entries) {
      if (data['_isSingleRun'] == true && phone.settingsNodeId != id && controller.doc.nodes.containsKey(id)) {
        return id;
      }
    }
    return null;
  }

  _Shown _shown() {
    final store = _store, phone = _phone, context = _context;
    if (store == null || phone == null || context == null) {
      return (
        run: null,
        runInput: false,
        chat: false,
        stepInput: null,
        inspect: false,
        variables: false,
        comments: false,
        versions: false,
      );
    }
    final chat = _panels.isChatMode;
    final debug = store.showDebugAndPreviewPanel.value;
    final inputStage = debug && !chat && store.showInputsPanel.value && store.workflowRunningData.value == null;
    final step = phone.singleRunNodeId;
    final history = store.historyWorkflowData.value != null;
    return (
      run: step != null && controller.doc.nodes.containsKey(step)
          ? _RunKind.step
          : history
          ? _RunKind.history
          : debug && !chat && !inputStage
          ? _RunKind.live
          : null,
      runInput: inputStage,
      chat: debug && chat,
      stepInput: _stepInputNode(store, phone),
      inspect: store.showVariableInspectPanel.value,
      variables:
          _panels.variables != null &&
          (store.showEnvPanel.value ||
              (store.showChatVariablePanel.value && chat) ||
              store.showGlobalVariablePanel.value),
      comments:
          _panels.comments != null &&
          store.controlMode.value == ControlMode.comment &&
          CommentsScope.read(context) != null,
      versions: _panels.versions != null && store.showWorkflowVersionHistoryPanel.value,
    );
  }

  /// How much of the view the non-modal sheets cover at least (their peek), so the Steps view can scroll its last
  /// step above them; 0 while none shows.
  double get dockedHeight {
    final s = _shown();
    if (s.run != null) return _runPeek.height!;
    if (s.versions || s.comments) return _listPeek.height!;
    return 0;
  }

  // ----- closing -----

  void _cancelRunPanel() {
    final store = _store!, context = _context;
    final cancel = context == null ? null : WorkflowRunScope.maybeOf(context)?.run.handleCancelDebugAndPreviewPanel;
    if (cancel != null) return cancel();
    store
      ..setShowDebugAndPreviewPanel(false)
      ..workflowRunningData.value = null;
  }

  void _leaveRunHistory() {
    final context = _context;
    if (context != null && context.mounted) WorkflowHeaderScope.of(context).handleLoadBackupDraft?.call();
    _store!.historyWorkflowData.value = null;
  }

  void _closeVariables() {
    _store!
      ..setShowEnvPanel(false)
      ..setShowChatVariablePanel(false)
      ..setShowGlobalVariablePanel(false);
  }

  void _exitCommentMode() {
    _store!
      ..setControlMode(ControlMode.pointer)
      ..setActiveCommentId(null);
  }

  /// Stops a run with [stop]. Dify opens variable inspect when a run stops (the desktop's bottom panel, beside the
  /// canvas); on a phone that would be a full sheet over the stopped run, so it stays as it was.
  void stopRun(VoidCallback stop) {
    final store = _store;
    final inspecting = store?.showVariableInspectPanel.value ?? true;
    stop();
    if (!inspecting) store?.setShowVariableInspectPanel(false);
  }

  bool get _running {
    final store = _store!;
    return runningStatusOf(store.workflowRunningData.value) == WorkflowRunningStatus.running || store.isListening.value;
  }

  /// Closes the run sheet: a step run's sheet goes (the run itself goes on); a viewed run is left; the test run's
  /// panel closes (still running: it only hides, as the desktop panel's Back does; finished: its statuses go too).
  void _closeRun(_RunKind kind) {
    switch (kind) {
      case _RunKind.step:
        _phone!.singleRunNodeId = null;
      case _RunKind.history:
        _leaveRunHistory();
      case _RunKind.live:
        if (_running) {
          _store!.setShowDebugAndPreviewPanel(false);
        } else {
          _cancelRunPanel();
        }
    }
  }

  /// A non-modal sheet above its lowest detent collapses to it first; there it closes.
  VoidCallback _collapseOr(DifySheetController c, DifySheetDetent lowest, VoidCallback close) {
    final at = c.detent;
    if (c.isAttached && at != null && at != lowest) return () => unawaited(c.animateTo(lowest));
    return close;
  }

  /// A modal sheet slides away, then its `onDismiss` clears its state.
  VoidCallback _dismiss(DifySheetController c, VoidCallback close) =>
      c.isAttached ? () => unawaited(c.dismiss()) : close;

  /// What Back does to the newest open sheet, or null when none is open: the modal sheets close first (a single
  /// step's form, the run's form, the chat, variable inspect, the variable panels), then the lists and the run sheet
  /// collapse to their peek and then close.
  VoidCallback? backStep() {
    final s = _shown();
    final store = _store;
    if (store == null) return null;
    if (s.stepInput case final id?) {
      return _dismiss(stepInput, () => _hideStepInput(id));
    }
    if (s.runInput) return _dismiss(runInput, _cancelRunPanel);
    if (s.chat) return _dismiss(chat, _cancelRunPanel);
    if (s.inspect) return _dismiss(inspect, () => store.setShowVariableInspectPanel(false));
    if (s.variables) return _dismiss(variables, _closeVariables);
    if (s.comments) return _collapseOr(comments, _listPeek, _exitCommentMode);
    if (s.versions) return _collapseOr(versions, _listPeek, () => store.setShowWorkflowVersionHistoryPanel(false));
    if (s.run case final kind?) return _collapseOr(run, _runPeek, () => _closeRun(kind));
    return null;
  }

  void _hideStepInput(String nodeId) {
    final context = _context;
    if (context == null) return;
    WorkflowRunScope.maybeOf(context)?.singleRunOf(nodeId).hideSingleRun();
  }

  /// The non-modal sheets (the run, the version list, the comment list): put it last in the Stack between the view
  /// switch and the bottom bar.
  Widget dockedLayer() => _SheetLayer(sheets: this, modal: false);

  /// The modal sheets (the input forms, the chat, variable inspect, the variable panels): put it over the whole page.
  Widget modalLayer() => _SheetLayer(sheets: this, modal: true);
}

class _SheetLayer extends StatefulWidget {
  const _SheetLayer({required this.sheets, required this.modal});
  final PhoneEditorSheets sheets;
  final bool modal;

  @override
  State<_SheetLayer> createState() => _SheetLayerState();
}

/// Rebuilds only when which sheets show changes (a run's events change the store many times a second; the sheets'
/// content listens for what it shows itself).
class _SheetLayerState extends State<_SheetLayer> {
  Listenable? _watched;
  _Shown? _last;

  PhoneEditorSheets get sheets => widget.sheets;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final store = WorkflowStoreScope.of(context);
    final phone = PhoneEditorScope.maybeOf(context);
    _watched?.removeListener(_changed);
    // The document too: the sheets' content shows the Start node's variables and the step being run.
    _watched = Listenable.merge([...PhoneEditorSheets.watched(store), ?phone])..addListener(_changed);
    _document?.removeListener(_documentChanged);
    _document = sheets.controller..addListener(_documentChanged);
  }

  EditorController? _document;

  @override
  void dispose() {
    _watched?.removeListener(_changed);
    _document?.removeListener(_documentChanged);
    super.dispose();
  }

  void _documentChanged() => _changed(always: true);

  void _changed({bool always = false}) {
    if (!mounted || (!always && sheets._shown() == _last)) return;
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => _changed(always: always));
      return;
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final store = WorkflowStoreScope.of(context);
    final s = _last = sheets._shown();
    final children = widget.modal ? _modal(context, s, store) : _docked(context, s, store);
    if (children.isEmpty) return const SizedBox.shrink();
    return Stack(fit: StackFit.expand, children: children);
  }

  List<Widget> _docked(BuildContext context, _Shown s, WorkflowStore store) => [
    if (s.run case final kind?)
      DifyPersistentSheet(
        key: const ValueKey('phone-run-sheet'),
        controller: sheets.run,
        detents: const [_runPeek, DifySheetDetent.half, DifySheetDetent.full],
        slideIn: true,
        child: PanelSheetScope(
          onClose: () => sheets._closeRun(kind),
          child: _RunSheet(sheets: sheets, kind: kind),
        ),
      ),
    if (s.versions)
      DifyPersistentSheet(
        key: const ValueKey('phone-versions-sheet'),
        controller: sheets.versions,
        detents: const [_listPeek, DifySheetDetent.half, DifySheetDetent.full],
        initialDetent: DifySheetDetent.half,
        slideIn: true,
        onDismiss: () => store.setShowWorkflowVersionHistoryPanel(false),
        child: PanelSheetScope(
          onClose: () => unawaited(sheets.versions.dismiss()),
          child: _CollapseOnVersion(sheets: sheets, child: sheets._panels.versions!),
        ),
      ),
    if (s.comments)
      DifyPersistentSheet(
        key: const ValueKey('phone-comments-sheet'),
        controller: sheets.comments,
        detents: const [_listPeek, DifySheetDetent.half, DifySheetDetent.full],
        initialDetent: DifySheetDetent.half,
        slideIn: true,
        onDismiss: sheets._exitCommentMode,
        child: PanelSheetScope(
          onClose: () => unawaited(sheets.comments.dismiss()),
          child: sheets._panels.comments!,
        ),
      ),
  ];

  List<Widget> _modal(BuildContext context, _Shown s, WorkflowStore store) {
    Widget modalSheet({
      required String key,
      required DifySheetController controller,
      required VoidCallback onDismiss,
      required Widget child,
      List<DifySheetDetent> detents = const [DifySheetDetent.half, DifySheetDetent.full],
    }) => DifyPersistentSheet(
      key: ValueKey(key),
      controller: controller,
      modal: true,
      slideIn: true,
      detents: detents,
      onDismiss: onDismiss,
      child: PanelSheetScope(onClose: () => unawaited(controller.dismiss()), child: child),
    );
    final panel = RunPanelContext(
      startVariables: startVariablesOf(sheets.controller.doc),
      hasSelectedNode: sheets.controller.selectedNode != null,
      canRun: sheets._panels.canRun,
    );
    return [
      if (s.variables)
        modalSheet(
          key: 'phone-variables-sheet',
          controller: sheets.variables,
          onDismiss: sheets._closeVariables,
          child: sheets._panels.variables!,
        ),
      if (s.inspect)
        modalSheet(
          key: 'phone-inspect-sheet',
          controller: sheets.inspect,
          detents: const [DifySheetDetent.full],
          onDismiss: () => store.setShowVariableInspectPanel(false),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DifySheetHeader(
                title: _tw('debug.variableInspect.title'),
                onClose: () => unawaited(sheets.inspect.dismiss()),
              ),
              // Its two panes are laid out by the width the editor's bottom panel reports; on a phone that is the
              // window's, as in the full-area page this replaces.
              const Expanded(child: InspectPanel()),
            ],
          ),
        ),
      if (s.chat)
        modalSheet(
          key: 'phone-chat-sheet',
          controller: sheets.chat,
          detents: const [DifySheetDetent.full],
          onDismiss: sheets._cancelRunPanel,
          child: DebugAndPreview(panel: panel),
        ),
      if (s.runInput)
        modalSheet(
          key: 'phone-run-input-sheet',
          controller: sheets.runInput,
          onDismiss: sheets._cancelRunPanel,
          child: _RunInputSheet(panel: panel, sheets: sheets),
        ),
      if (s.stepInput case final id?)
        modalSheet(
          key: 'phone-step-input-sheet',
          controller: sheets.stepInput,
          detents: const [DifySheetDetent.full],
          onDismiss: () => sheets._hideStepInput(id),
          // The node's single-run form (what covers its panel on the desktop): Start Run runs it, its result goes to
          // the run sheet.
          child: Stack(
            fit: StackFit.expand,
            children: [NodeSingleRunOverlay(node: sheets.controller.doc.nodes[id]!, doc: sheets.controller.doc)],
          ),
        ),
    ];
  }
}

/// The run's input form (Start's variables) as a sheet: Start Run starts the run, and the run sheet takes over.
class _RunInputSheet extends StatelessWidget {
  const _RunInputSheet({required this.panel, required this.sheets});
  final RunPanelContext panel;
  final PhoneEditorSheets sheets;

  @override
  Widget build(BuildContext context) {
    final start = sheets.controller.doc.nodes.values.where((n) => n.type == 'start').firstOrNull;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DifySheetHeader(
          title: _tw('common.run'),
          subtitle: start == null ? null : (start.title.isEmpty ? _tw('blocks.start') : start.title),
          onClose: () => unawaited(sheets.runInput.dismiss()),
        ),
        Flexible(
          child: SingleChildScrollView(
            key: const ValueKey('phone-run-input'),
            child: InputsPanel(panel: panel, onRun: () {}),
          ),
        ),
      ],
    );
  }
}

/// Picking a version in the list shows its graph: the list collapses to its peek so the graph is in view.
class _CollapseOnVersion extends StatefulWidget {
  const _CollapseOnVersion({required this.sheets, required this.child});
  final PhoneEditorSheets sheets;
  final Widget child;

  @override
  State<_CollapseOnVersion> createState() => _CollapseOnVersionState();
}

class _CollapseOnVersionState extends State<_CollapseOnVersion> {
  WorkflowStore? _store;
  Object? _version;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final store = WorkflowStoreScope.of(context);
    if (store == _store) return;
    _store?.currentVersion.removeListener(_changed);
    _store = store..currentVersion.addListener(_changed);
    _version = store.currentVersion.value?['id'];
  }

  @override
  void dispose() {
    _store?.currentVersion.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    final current = _store?.currentVersion.value;
    final id = current?['id'];
    if (id == _version) return;
    _version = id;
    // The list selects the draft by itself when it shows (Dify's draft item does); the draft is the editor's own
    // graph, nothing to uncover.
    if (id != null && current?['version'] != workflowVersionDraft) {
      unawaited(widget.sheets.versions.animateTo(_listPeek));
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// The run sheet's content for [kind]: the header (the run's state, time, Stop or close) over the tabs and their
/// content (the desktop run panels' own widgets).
class _RunSheet extends StatelessWidget {
  const _RunSheet({required this.sheets, required this.kind});
  final PhoneEditorSheets sheets;
  final _RunKind kind;

  @override
  Widget build(BuildContext context) {
    final store = WorkflowStoreScope.of(context);
    void close() => sheets._closeRun(kind);
    switch (kind) {
      case _RunKind.live:
        return WorkflowPreview(
          key: const ValueKey('phone-run-live'),
          openOnResult: true,
          panel: RunPanelContext(
            startVariables: startVariablesOf(sheets.controller.doc),
            hasSelectedNode: sheets.controller.selectedNode != null,
            canRun: sheets._panels.canRun,
          ),
          layout: (context, tabs, content) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ListenableBuilder(
                listenable: Listenable.merge([store.workflowRunningData, store.isListening]),
                builder: (context, _) {
                  final data = store.workflowRunningData.value;
                  final status = store.isListening.value
                      ? NodeRunningStatus.listening
                      : runningStatusOf(data) ?? WorkflowRunningStatus.running;
                  final elapsed = resultOf(data)['elapsed_time'];
                  return _RunHeader(
                    status: status,
                    title: _tw('common.run'),
                    run: data?['task_id'] ?? resultOf(data)['workflow_run_id'],
                    seconds: elapsed is num ? elapsed : null,
                    onStop: () => sheets.stopRun(
                      () => WorkflowHeaderScope.of(
                        context,
                      ).onStopRun?.call('${store.workflowRunningData.value?['task_id'] ?? ''}'),
                    ),
                    onClose: close,
                    tabs: tabs,
                  );
                },
              ),
              Expanded(child: content),
            ],
          ),
        );
      case _RunKind.history:
        final history = store.historyWorkflowData.value!;
        final elapsed = history['elapsed_time'];
        final header = _RunHeader(
          status: '${history['status'] ?? WorkflowRunningStatus.succeeded}',
          title: '${_tw('common.run')}${fmt.formatWorkflowRunIdentifier((history['finished_at'] as num?)?.toInt())}',
          run: history['id'],
          seconds: elapsed is num ? elapsed : null,
          onClose: close,
        );
        if (sheets._panels.isChatMode) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              header,
              Expanded(
                child: PanelSheetScope(
                  onClose: close,
                  child: ChatRecord(
                    key: ValueKey(history['id']),
                    startVariables: startVariablesOf(sheets.controller.doc),
                  ),
                ),
              ),
            ],
          );
        }
        return RunPanel(
          key: ValueKey(history['id']),
          runId: '${history['id'] ?? ''}',
          layout: (context, tabs, content) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _RunHeader(
                status: header.status,
                title: header.title,
                run: header.run,
                seconds: header.seconds,
                onClose: close,
                tabs: tabs,
              ),
              Expanded(child: content),
            ],
          ),
        );
      case _RunKind.step:
        final id = sheets._phone!.singleRunNodeId!;
        return _StepRun(
          key: ValueKey('phone-step-run-$id'),
          node: sheets.controller.doc.nodes[id]!,
          onClose: close,
          stop: sheets.stopRun,
        );
    }
  }
}

/// A step's run in the run sheet: the step's icon and title, the run's state and time, Stop while it runs, and the
/// node panel's Last Run view (its result) below.
class _StepRun extends StatelessWidget {
  const _StepRun({super.key, required this.node, required this.onClose, required this.stop});
  final Node node;
  final VoidCallback onClose;
  final void Function(VoidCallback stop) stop;

  @override
  Widget build(BuildContext context) {
    final store = WorkflowStoreScope.of(context);
    final scope = WorkflowRunScope.maybeOf(context);
    final c = scope?.singleRunOf(node.id);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListenableBuilder(
          listenable: Listenable.merge([store.nodeRunData, ?c]),
          builder: (context, _) {
            final status = c?.runningStatus ?? NodeRunningStatus.notStart;
            final result = c?.runResult ?? c?.lastRun;
            final elapsed = result?['elapsed_time'];
            return _RunHeader(
              status: status == NodeRunningStatus.notStart ? NodeRunningStatus.running : status,
              title: node.title.isEmpty ? _tw('blocks.${node.type}') : node.title,
              leading: SelectorBlockIcon(type: node.type, size: SelectorIconSize.md),
              run: node.id,
              seconds: elapsed is num ? elapsed : null,
              onStop: c == null ? null : () => stop(c.handleStop),
              onClose: onClose,
            );
          },
        ),
        Expanded(
          child: ColoredBox(
            color: DifyColors.componentsPanelBg,
            child: NodeLastRun(
              nodeId: node.id,
              canSingleRun: canRunBySingle(node.type, isChildNode: parentIdOf(node) != null),
              onSingleRun: () => store.setPendingSingleRun((nodeId: node.id, action: SingleRunAction.run)),
            ),
          ),
        ),
      ],
    );
  }
}

/// The run sheet's header (mockup 7): the run's state as an icon and in words with its time (counting while it
/// runs), Stop while it runs, close once it is over, and the tabs under it.
class _RunHeader extends StatelessWidget {
  const _RunHeader({
    required this.status,
    required this.title,
    required this.run,
    required this.onClose,
    this.seconds,
    this.onStop,
    this.leading,
    this.tabs,
  });

  /// A `WorkflowRunningStatus` / `NodeRunningStatus`.
  final String status;
  final String title;

  /// Which run this is (its time counts from when it was first shown running).
  final Object? run;

  /// The run's own time, once it has one.
  final num? seconds;
  final VoidCallback? onStop;
  final VoidCallback onClose;
  final Widget? leading, tabs;

  bool get _running =>
      status == NodeRunningStatus.running ||
      status == NodeRunningStatus.listening ||
      status == NodeRunningStatus.waiting;

  String get _state => switch (status) {
    NodeRunningStatus.running || NodeRunningStatus.waiting => _tw('common.running'),
    NodeRunningStatus.listening => _tw('common.listening'),
    NodeRunningStatus.succeeded || 'partial-succeeded' => _tp('runSucceeded'),
    NodeRunningStatus.failed || NodeRunningStatus.exception => _tp('runFailed'),
    NodeRunningStatus.stopped => _tp('runStopped'),
    NodeRunningStatus.paused => _tp('runPaused'),
    _ => status,
  };

  Widget _icon() {
    if (_running) {
      return DifySpinner(key: const ValueKey('phone-run-state-running'), size: 20, color: DifyColors.textAccent);
    }
    final (icon, color) = switch (status) {
      NodeRunningStatus.succeeded || 'partial-succeeded' => ('checkbox-circle-fill', DifyColors.textSuccess),
      NodeRunningStatus.failed || NodeRunningStatus.exception => ('error-warning-fill', DifyColors.textDestructive),
      NodeRunningStatus.stopped => ('stop-circle-fill', DifyColors.textWarningSecondary),
      NodeRunningStatus.paused => ('pause-circle-fill', DifyColors.textWarningSecondary),
      _ => ('checkbox-circle-line', DifyColors.textTertiary),
    };
    return RemixIcon(icon, key: ValueKey('phone-run-state-$status'), size: 20, color: color);
  }

  @override
  Widget build(BuildContext context) {
    final running = _running;
    final stop = onStop;
    return _RunTime(
      run: run,
      running: running,
      seconds: seconds,
      builder: (context, time) => DifySheetHeader(
        key: const ValueKey('phone-run-sheet-header'),
        leading: Row(mainAxisSize: MainAxisSize.min, spacing: 8, children: [_icon(), ?leading]),
        title: title,
        subtitle: time == null ? _state : '$_state · $time',
        showClose: !running,
        onClose: onClose,
        actions: [
          if (running && stop != null)
            DifyTouchTarget(
              child: DifyButton(
                key: const ValueKey('phone-run-sheet-stop'),
                size: DifyButtonSize.medium,
                leading: const RemixIcon('stop-circle-line', size: 16),
                onPressed: stop,
                child: DifyTextLine(_tp('stop')),
              ),
            ),
        ],
        tabs: tabs,
      ),
    );
  }
}

/// The run's time: counted from when this run was first shown running (tenths of a second, only while it runs),
/// then the run's own time once it has one.
class _RunTime extends StatefulWidget {
  const _RunTime({required this.run, required this.running, required this.seconds, required this.builder});
  final Object? run;
  final bool running;
  final num? seconds;
  final Widget Function(BuildContext context, String? time) builder;

  @override
  State<_RunTime> createState() => _RunTimeState();
}

class _RunTimeState extends State<_RunTime> {
  final _watch = Stopwatch();
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(_RunTime old) {
    super.didUpdateWidget(old);
    if (old.run != widget.run) _watch.reset();
    _sync();
  }

  void _sync() {
    if (widget.running) {
      _watch.start();
      _tick ??= Timer.periodic(const Duration(milliseconds: 100), (_) {
        if (mounted) setState(() {});
      });
    } else {
      _watch.stop();
      _tick?.cancel();
      _tick = null;
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final own = widget.seconds;
    final counted = _watch.elapsedMilliseconds / 1000;
    final time = !widget.running && own != null
        ? formatStepSeconds(own)
        : _watch.elapsedMilliseconds > 0
        ? formatStepSeconds(counted)
        : null;
    return widget.builder(context, time);
  }
}
