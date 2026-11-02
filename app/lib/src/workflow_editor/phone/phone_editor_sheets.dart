/// The phone editor's sheets (dify-sf, compact windows; mockup 7-run): the run as a persistent sheet over the editor
/// (at its peek: the run's state, time and Stop; dragged up: Input | Result | Detail | Tracing), the run's and a single
/// step's input forms as modal sheets, and the editor's other panels (the variable panels, variable inspect, the
/// comment list, the version list) as bottom sheets instead of the area under the app bar.
///
/// No sheet is a route: a route on the root navigator would not see the editor's scopes (the store, the run host, the
/// header's data, variable inspect, comments), which their content needs. The non-modal sheets (the run, the version
/// list, the comment list) are [DifyPersistentSheet]s between the view switch and the bottom bar, so the Steps view or
/// the canvas above them and the toolbar or selection bar below them stay usable. The modal ones (the input forms, the
/// chat, variable inspect, the variable panels) are [DifySheetPortal]s, as the node's settings are: shown over the whole
/// window from the editor's tree, with a scrim. The store's panel flags say which sheet shows, exactly as they say
/// which desktop panel shows, and closing a sheet clears its flag the way the desktop panel's close button does. Back
/// closes a modal sheet first (its own back step), then the docked ones ([PhoneEditorSheets.backStep]).
library;

import 'dart:async';

import 'package:collab_client/collab_client.dart' show Node;
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/rendering.dart';
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
    _phone = phone..canvasCover = () => dockedHeight;
    if (store == _store) return;
    _store?.pendingSingleRun.removeListener(_pendingSingleRun);
    _store?.nodeRunData.removeListener(_nodeRunChanged);
    _store?.workflowRunningData.removeListener(_liveChanged);
    _store?.historyWorkflowData.removeListener(_sourceChanged);
    _store?.isRestoring.removeListener(_sourceChanged);
    _store?.showDebugAndPreviewPanel.removeListener(_sourceChanged);
    _store = store
      ..pendingSingleRun.addListener(_pendingSingleRun)
      ..nodeRunData.addListener(_nodeRunChanged)
      ..workflowRunningData.addListener(_liveChanged)
      ..historyWorkflowData.addListener(_sourceChanged)
      ..isRestoring.addListener(_sourceChanged)
      ..showDebugAndPreviewPanel.addListener(_sourceChanged);
    _liveStatus = _liveRunId = null;
    _liveChanged();
    _source = _sourceOf(store);
    _singleStatus
      ..clear()
      ..addAll({for (final e in store.nodeRunData.value.entries) e.key: e.value['_singleRunningStatus'] as String?});
  }

  void dispose() {
    _store?.pendingSingleRun.removeListener(_pendingSingleRun);
    _store?.nodeRunData.removeListener(_nodeRunChanged);
    _store?.workflowRunningData.removeListener(_liveChanged);
    _store?.historyWorkflowData.removeListener(_sourceChanged);
    _store?.isRestoring.removeListener(_sourceChanged);
    _store?.showDebugAndPreviewPanel.removeListener(_sourceChanged);
    liveTime.dispose();
    stepTime.dispose();
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

  // ----- the test run's time -----

  /// The wall clock the run times count on (a run's start is taken the moment it starts, not from the last frame,
  /// which is stale while the page sat idle). Tests point it at the test binding's clock.
  @visibleForTesting
  static DateTime Function() now = DateTime.now;

  /// The test run's time ([_RunClock]): the run sheet's header and the view row's chip both show it (whichever
  /// shows), so they agree and change together. Each run that starts is a new run with its own start, also when it
  /// follows a run that had not been closed.
  final liveTime = _RunClock();

  /// The shown step run's time (the run sheet's header): each start of a step, also of the same step again, is a new
  /// run with its own start.
  final stepTime = _RunClock();
  String? _liveStatus, _liveRunId, _stepClockNode;

  void _liveChanged() {
    final data = _store?.workflowRunningData.value;
    final status = runningStatusOf(data);
    final running = status == WorkflowRunningStatus.running;
    final id = data?['task_id'] ?? resultOf(data)['workflow_run_id'];
    final runId = id == null ? null : '$id';
    // Another run (its id changed from one it already had) is a new run, as a start is.
    final another = running && runId != null && _liveRunId != null && runId != _liveRunId;
    if (running && (_liveStatus != WorkflowRunningStatus.running || another)) {
      liveTime.start();
      _liveRunId = runId;
      // The newest choice shows: the run sheet shows the test run that starts, not a step's run.
      _phone?.singleRunNodeId = null;
    } else {
      if (!running && _liveStatus == WorkflowRunningStatus.running) liveTime.end();
      if (runId != null) _liveRunId = runId;
    }
    _liveStatus = status;
  }

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

  /// What the run sheet can show besides a step's run, as last seen: a viewed past run, the version browser, the test
  /// run's panel.
  ({Object? history, bool restoring, bool panel}) _source = (history: null, restoring: false, panel: false);

  static ({Object? history, bool restoring, bool panel}) _sourceOf(WorkflowStore store) => (
    history: store.historyWorkflowData.value,
    restoring: store.isRestoring.value,
    panel: store.showDebugAndPreviewPanel.value,
  );

  /// The newest choice shows in the run sheet: a past run picked from the run history, the version browser entered, or
  /// the test run's panel opened (Run's form, the chip) replaces a step's run there; the step's run does not come back
  /// when they close (Dify's run history and version browser also close the run panel).
  void _sourceChanged() {
    final store = _store;
    if (store == null) return;
    final was = _source, now = _sourceOf(store);
    _source = now;
    final picked = now.history != null && !identical(now.history, was.history);
    if (picked || (now.restoring && !was.restoring) || (now.panel && !was.panel)) _phone?.singleRunNodeId = null;
  }

  static bool _going(String? status) => status == NodeRunningStatus.running || status == NodeRunningStatus.listening;

  /// A step that starts running (from here, the step's form, or its settings) is the run sheet's: a new run of that
  /// step, with its own time ([stepTime]), also when the same step runs again.
  void _nodeRunChanged() {
    final store = _store, phone = _phone;
    if (store == null || phone == null) return;
    String? started;
    var ended = false;
    for (final MapEntry(key: id, value: data) in store.nodeRunData.value.entries) {
      final s = data['_singleRunningStatus'] as String?;
      final was = _singleStatus[id];
      if (was == s) continue;
      _singleStatus[id] = s;
      if (_going(s) && !_going(was)) started = id;
      if (!_going(s) && _going(was) && id == _stepClockNode) ended = true;
    }
    if (started != null) {
      _stepClockNode = started;
      stepTime.start();
    } else if (ended) {
      stepTime.end();
    }
    if (started == null) return;
    final id = started;
    void show() {
      // The newest choice shows: the test run's sheet gives way to the step's run (hidden, not closed: the view row's
      // chip brings it back), so closing the step's run does not bring the older run back by itself.
      if (store.showDebugAndPreviewPanel.value && !_panels.isChatMode) store.setShowDebugAndPreviewPanel(false);
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
      run: history
          ? _RunKind.history
          : step != null && controller.doc.nodes.containsKey(step)
          ? _RunKind.step
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

  /// What Back does to the newest open docked sheet, or null when none is open: the comment list, the version list
  /// and the run sheet drop to their peek and then close. The modal sheets ([DifySheetPortal]) hold their own back
  /// steps, which are newer: they close first, and they are not handled here.
  VoidCallback? backStep() {
    final s = _shown();
    final store = _store;
    if (store == null) return null;
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

  /// The view row's chips: [issues] (the checklist's chip; `compact` asks for its short form), with the test run's
  /// chip before it while the run sheet is hidden and the run is going, or has ended and was not closed ("Running ·
  /// 12 s", "Succeeded", "Failed"...); a tap reopens the run sheet at its peek. In a short row the issues chip, then the
  /// run chip, take their short forms.
  Widget viewRowChips({required Widget Function(bool compact) issues}) => _RunChipRow(sheets: this, issues: issues);

  /// Shows the hidden test run's sheet again (at its peek).
  void reopenRun() => _store?.setShowDebugAndPreviewPanel(true);

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
        // Comment mode is for the canvas: the list starts at its peek.
        initialDetent: _listPeek,
        slideIn: true,
        onDismiss: sheets._exitCommentMode,
        child: PanelSheetScope(
          onClose: () => unawaited(sheets.comments.dismiss()),
          child: sheets._panels.comments!,
        ),
      ),
  ];

  /// The step whose form the step sheet showed last (it keeps showing it while it slides away).
  String? _stepInput;

  List<Widget> _modal(BuildContext context, _Shown s, WorkflowStore store) {
    // Each modal sheet is a DifySheetPortal, mounted all along and open while the store says so: it slides in and out,
    // keeps the editor's scopes, holds its own back step, and closes through [onDismiss] (the panel's own close).
    Widget portal({
      required String key,
      required bool open,
      required DifySheetController controller,
      required VoidCallback onDismiss,
      required WidgetBuilder builder,
      List<DifySheetDetent> detents = const [DifySheetDetent.half, DifySheetDetent.full],
    }) => DifySheetPortal(
      key: ValueKey('$key-portal'),
      open: open,
      controller: controller,
      detents: detents,
      onDismiss: onDismiss,
      barrierLabel: DifyI18n.tr('common', 'operation.close'),
      builder: (context) => KeyedSubtree(
        key: ValueKey(key),
        child: PanelSheetScope(
          onClose: onDismiss,
          child: Builder(builder: builder),
        ),
      ),
    );
    final panel = RunPanelContext(
      startVariables: startVariablesOf(sheets.controller.doc),
      hasSelectedNode: sheets.controller.selectedNode != null,
      canRun: sheets._panels.canRun,
    );
    if (s.stepInput case final id?) _stepInput = id;
    final step = _stepInput;
    return [
      portal(
        key: 'phone-variables-sheet',
        open: s.variables,
        controller: sheets.variables,
        onDismiss: sheets._closeVariables,
        builder: (context) => sheets._panels.variables ?? const SizedBox.shrink(),
      ),
      portal(
        key: 'phone-inspect-sheet',
        open: s.inspect,
        controller: sheets.inspect,
        detents: const [DifySheetDetent.full],
        onDismiss: () => store.setShowVariableInspectPanel(false),
        // The panel's phone layout: the list, a variable's value as a page (its header is the sheet's).
        builder: (context) => const InspectPanel(),
      ),
      portal(
        key: 'phone-chat-sheet',
        open: s.chat,
        controller: sheets.chat,
        detents: const [DifySheetDetent.full],
        onDismiss: sheets._cancelRunPanel,
        builder: (context) => DebugAndPreview(panel: panel),
      ),
      portal(
        key: 'phone-run-input-sheet',
        open: s.runInput,
        controller: sheets.runInput,
        onDismiss: sheets._cancelRunPanel,
        builder: (context) => _RunInputSheet(panel: panel, sheets: sheets),
      ),
      portal(
        key: 'phone-step-input-sheet',
        open: s.stepInput != null,
        controller: sheets.stepInput,
        onDismiss: () {
          if (step != null) sheets._hideStepInput(step);
        },
        // The node's single-run form (what covers its panel on the desktop), as tall as its fields: Start Run runs
        // it, its result goes to the run sheet.
        builder: (context) => switch (step == null ? null : sheets.controller.doc.nodes[step]) {
          final node? => NodeSingleRunOverlay(node: node, doc: sheets.controller.doc, fill: false),
          _ => const SizedBox.shrink(),
        },
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
                    live: sheets.liveTime,
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
          time: sheets.stepTime,
          onClose: close,
          stop: sheets.stopRun,
        );
    }
  }
}

/// A step's run in the run sheet: the step's icon and title, the run's state and time, Stop while it runs, and the
/// node panel's Last Run view (its result) below.
class _StepRun extends StatelessWidget {
  const _StepRun({super.key, required this.node, required this.time, required this.onClose, required this.stop});
  final Node node;
  final ValueListenable<double> time;
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
              live: time,
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

/// A `WorkflowRunningStatus` / `NodeRunningStatus` that is still going.
bool _isRunning(String status) =>
    status == NodeRunningStatus.running || status == NodeRunningStatus.listening || status == NodeRunningStatus.waiting;

/// The run's state in words (the run sheet's header, the view row's run chip).
String _stateLabel(String status) => switch (status) {
  NodeRunningStatus.running || NodeRunningStatus.waiting => _tw('common.running'),
  NodeRunningStatus.listening => _tw('common.listening'),
  NodeRunningStatus.succeeded || 'partial-succeeded' => _tp('runSucceeded'),
  NodeRunningStatus.failed || NodeRunningStatus.exception => _tp('runFailed'),
  NodeRunningStatus.stopped => _tp('runStopped'),
  NodeRunningStatus.paused => _tp('runPaused'),
  _ => status,
};

/// The run's state as an icon: a spinner while it goes, then a check, an error, stop or pause.
Widget _stateIcon(String status, double size) {
  if (_isRunning(status)) {
    return DifySpinner(key: const ValueKey('phone-run-state-running'), size: size, color: DifyColors.textAccent);
  }
  final (icon, color) = switch (status) {
    NodeRunningStatus.succeeded || 'partial-succeeded' => ('checkbox-circle-fill', DifyColors.textSuccess),
    NodeRunningStatus.failed || NodeRunningStatus.exception => ('error-warning-fill', DifyColors.textDestructive),
    NodeRunningStatus.stopped => ('stop-circle-fill', DifyColors.textWarningSecondary),
    NodeRunningStatus.paused => ('pause-circle-fill', DifyColors.textWarningSecondary),
    _ => ('checkbox-circle-line', DifyColors.textTertiary),
  };
  return RemixIcon(icon, key: ValueKey('phone-run-state-$status'), size: size, color: color);
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
    this.live,
  });

  /// The run's time while it goes, when it is kept elsewhere (the test run's, [PhoneEditorSheets.liveTime]); null:
  /// counted from when this header first showed it running.
  final ValueListenable<double>? live;

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

  bool get _running => _isRunning(status);
  String get _state => _stateLabel(status);
  Widget _icon() => _stateIcon(status, 20);

  @override
  Widget build(BuildContext context) {
    final running = _running;
    final stop = onStop;
    return _RunTime(
      run: run,
      running: running,
      seconds: seconds,
      live: live,
      builder: (context, time) => DifySheetHeader(
        key: const ValueKey('phone-run-sheet-header'),
        leading: Row(mainAxisSize: MainAxisSize.min, spacing: 8, children: [_icon(), ?leading]),
        title: title,
        subtitle: time == null ? _state : '$_state · $time',
        showClose: !running,
        onClose: onClose,
        actions: [
          // A button in a phone sheet is 44 px (the design's touch height there).
          if (running && stop != null)
            DifyButton(
              key: const ValueKey('phone-run-sheet-stop'),
              leading: const RemixIcon('stop-circle-line', size: 16),
              onPressed: stop,
              child: DifyTextLine(_tp('stop')),
            ),
        ],
        tabs: tabs,
      ),
    );
  }
}

/// A run's time for the run sheet's header and the view row's chip, from [start] (the moment the run starts,
/// [PhoneEditorSheets.now]) to [end]: whole seconds while the run goes, moved by one tick a second from its start; the
/// run's time to the tenth once it ended ([_formatRunTime]). A new [start] is a new run: its time starts at 0.
class _RunClock extends ChangeNotifier implements ValueListenable<double> {
  DateTime? _start, _end;
  Timer? _tick;
  double _value = 0;

  @override
  double get value => _value;

  void start() {
    _start = PhoneEditorSheets.now();
    _end = null;
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => _update());
    _update(always: true);
  }

  void end() {
    if (_start == null || _end != null) return;
    _end = PhoneEditorSheets.now();
    _tick?.cancel();
    _tick = null;
    _update();
  }

  double get _seconds {
    final start = _start;
    if (start == null) return 0;
    final d = (_end ?? PhoneEditorSheets.now()).difference(start);
    return d.isNegative ? 0 : d.inMilliseconds / 1000;
  }

  void _update({bool always = false}) {
    // The ticks fall on the whole seconds since the start, give or take the timer's lateness.
    final next = _end == null ? (_seconds + 0.05).floorToDouble() : (_seconds * 10).round() / 10;
    if (next == _value && !always) return;
    _value = next;
    notifyListeners();
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }
}

/// A test run's time as the run sheet's header and the view row's chip show it: whole seconds while it [running]
/// ("12 s", the chip stays short), the run's time to the tenth once it ended ("3.1 s").
String _formatRunTime(num seconds, {required bool running}) {
  if (!running) return formatStepSeconds(seconds);
  final whole = seconds.floor();
  return whole < 60 ? '$whole s' : formatStepSeconds(whole);
}

/// The run's time: [live] while it runs (from its start, ticking with the view row's chip), else counted from when
/// this run was first shown running (tenths of a second, only while it runs); then the run's own time once it has one.
class _RunTime extends StatefulWidget {
  const _RunTime({
    required this.run,
    required this.running,
    required this.seconds,
    required this.builder,
    this.live,
  });
  final Object? run;
  final bool running;
  final num? seconds;
  final ValueListenable<double>? live;
  final Widget Function(BuildContext context, String? time) builder;

  @override
  State<_RunTime> createState() => _RunTimeState();
}

class _RunTimeState extends State<_RunTime> {
  /// When this run was first shown running, and when it stopped ([PhoneEditorSheets.now]).
  DateTime? _start, _end;
  Timer? _tick;

  static DateTime get _now => PhoneEditorSheets.now();

  @override
  void initState() {
    super.initState();
    widget.live?.addListener(_changed);
    _sync();
  }

  @override
  void didUpdateWidget(_RunTime old) {
    super.didUpdateWidget(old);
    if (old.live != widget.live) {
      old.live?.removeListener(_changed);
      widget.live?.addListener(_changed);
    }
    if (old.run != widget.run) _start = _end = null;
    _sync();
  }

  void _changed() {
    if (!mounted) return;
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => _changed());
      return;
    }
    setState(() {});
  }

  void _sync() {
    // A live time ticks by itself.
    if (widget.running && widget.live == null) {
      _start ??= _now;
      _end = null;
      _tick ??= Timer.periodic(const Duration(milliseconds: 100), (_) {
        if (mounted) setState(() {});
      });
    } else {
      if (_start != null) _end ??= _now;
      _tick?.cancel();
      _tick = null;
    }
  }

  @override
  void dispose() {
    widget.live?.removeListener(_changed);
    _tick?.cancel();
    super.dispose();
  }

  double get _counted {
    final start = _start;
    if (start == null) return 0;
    final d = (_end ?? _now).difference(start);
    return d.isNegative ? 0 : d.inMilliseconds / 1000;
  }

  @override
  Widget build(BuildContext context) {
    final own = widget.seconds, live = widget.live;
    final String? time;
    if (!widget.running && own != null) {
      time = formatStepSeconds(own);
    } else if (live != null) {
      time = widget.running
          ? _formatRunTime(live.value, running: true)
          : live.value > 0
          ? formatStepSeconds(live.value)
          : null;
    } else {
      time = _counted > 0 ? formatStepSeconds(_counted) : null;
    }
    return widget.builder(context, time);
  }
}

/// The view row's run chip before the issues chip ([PhoneEditorSheets.viewRowChips]).
class _RunChipRow extends StatefulWidget {
  const _RunChipRow({required this.sheets, required this.issues});
  final PhoneEditorSheets sheets;
  final Widget Function(bool compact) issues;

  @override
  State<_RunChipRow> createState() => _RunChipRowState();
}

class _RunChipRowState extends State<_RunChipRow> {
  WorkflowStore? _store;
  Listenable? _watched;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final store = WorkflowStoreScope.of(context);
    if (store == _store) return;
    _watched?.removeListener(_changed);
    _store = store;
    _watched = Listenable.merge([
      store.workflowRunningData,
      store.showDebugAndPreviewPanel,
      store.historyWorkflowData,
      store.isListening,
      store.isRestoring,
      // The run's time: the same value and tick as the run sheet's header.
      widget.sheets.liveTime,
    ])..addListener(_changed);
  }

  @override
  void dispose() {
    _watched?.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => _changed());
      return;
    }
    setState(() {});
  }

  /// The hidden test run's state, or null when there is no chip to show.
  String? get _status {
    final store = _store!;
    final data = store.workflowRunningData.value;
    if (widget.sheets._panels.isChatMode ||
        data == null ||
        store.showDebugAndPreviewPanel.value ||
        store.historyWorkflowData.value != null ||
        store.isRestoring.value) {
      return null;
    }
    return store.isListening.value
        ? NodeRunningStatus.listening
        : runningStatusOf(data) ?? WorkflowRunningStatus.running;
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    if (status == null) return widget.issues(false);
    final running = status == WorkflowRunningStatus.running;
    // The run sheet's header shows the same time ([PhoneEditorSheets.liveTime] while it runs, the run's own after).
    final elapsed = resultOf(_store!.workflowRunningData.value)['elapsed_time'];
    final time = _formatRunTime(!running && elapsed is num ? elapsed : widget.sheets.liveTime.value, running: running);
    final full = running ? '${_stateLabel(status)} · $time' : _stateLabel(status);
    // Ended: the short form is its time beside the outcome's icon ("✓ 3.1 s"), never a bare icon like the issues chip's.
    Widget chip({required bool compact}) => DifyFilterChip(
      label: compact ? time : full,
      semanticLabel: full,
      leading: SizedBox.square(dimension: 16, child: Center(child: _stateIcon(status, 16))),
      onPressed: widget.sheets.reopenRun,
    );
    Widget row(Widget run, bool compactIssues) =>
        Row(mainAxisSize: MainAxisSize.min, spacing: 8, children: [run, widget.issues(compactIssues)]);
    return _FirstThatFits(
      key: const ValueKey('phone-run-chip'),
      children: [
        row(chip(compact: false), false),
        row(chip(compact: false), true),
        row(chip(compact: true), true),
      ],
    );
  }
}

/// Lays out its [children] (the same content, longest form first) and shows the first that fits the width it is
/// given, else the last; only that one paints, takes pointers and is read out.
class _FirstThatFits extends MultiChildRenderObjectWidget {
  const _FirstThatFits({super.key, required super.children});

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderFirstThatFits();
}

class _FitParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderFirstThatFits extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _FitParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _FitParentData> {
  RenderBox? _shown;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _FitParentData) child.parentData = _FitParentData();
  }

  @override
  void performLayout() {
    final loose = BoxConstraints(maxHeight: constraints.maxHeight);
    final was = _shown;
    _shown = null;
    var child = firstChild;
    while (child != null) {
      child.layout(loose, parentUsesSize: true);
      if (_shown == null && (child.size.width <= constraints.maxWidth || childAfter(child) == null)) _shown = child;
      child = childAfter(child);
    }
    size = constraints.constrain(_shown?.size ?? Size.zero);
    // Another form shows (the run's time grew, it ended): it is the one read out, the one before leaves the tree.
    if (_shown != was) markNeedsSemanticsUpdate();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (_shown case final child?) context.paintChild(child, offset);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      _shown?.hitTest(result, position: position) ?? false;

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    if (_shown case final child?) visitor(child);
  }

  @override
  double computeMinIntrinsicWidth(double height) => lastChild?.getMinIntrinsicWidth(height) ?? 0;

  @override
  double computeMaxIntrinsicWidth(double height) => firstChild?.getMaxIntrinsicWidth(height) ?? 0;

  @override
  double computeMinIntrinsicHeight(double width) => firstChild?.getMinIntrinsicHeight(width) ?? 0;

  @override
  double computeMaxIntrinsicHeight(double width) => firstChild?.getMaxIntrinsicHeight(width) ?? 0;
}
