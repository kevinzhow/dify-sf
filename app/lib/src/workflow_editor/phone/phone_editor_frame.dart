/// The workflow editor's phone layout (dify-sf, compact windows; mockups 2-steps and 3-canvas): a one-line app bar
/// (back, the app's name with its save state and collaborators, Run, "…"), the Steps | Canvas switch with the
/// checklist's issues, the view, and a bottom bar (the toolbar, or what is selected on the canvas). The canvas has no
/// floating desktop chrome: two small buttons (pan / select mode, fit to screen); everything else is in the bars and
/// the "…" sheet. The node's settings take the whole area under the app bar; the run and the other panels are sheets
/// ([PhoneEditorSheets]). Android back closes the newest layer first.
library;

import 'dart:async';

import 'package:collab_client/collab_client.dart' show LinkState, Node;
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../../canvas/canvas_controller.dart';
import '../../canvas/canvas_input.dart' show ControlMode;
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../editor/editor_controller.dart';
import '../../i18n/dify_i18n.dart';
import '../header/header_data.dart';
import '../header/view_history.dart' show showRunHistorySheet;
import '../header/workflow_header.dart' show HeaderInRestoring;
import '../node_insertion/insert_block.dart' show InsertOnEdge;
import '../operator/actions.dart' show OperatorReadOnly;
import '../store/store.dart';
import 'phone_editor_actions.dart';
import 'phone_editor_controller.dart';
import 'phone_editor_sheets.dart';
import 'steps_view_slot.dart';

export 'phone_editor_actions.dart' show PhoneEditorActions, PhoneEditorConfig;

String _tw(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('workflow', key, params);

/// dify-sf's own phone editor strings (assets/extension_i18n, namespace `phone-editor`).
String _tp(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('phone-editor', key, params);
String _tc(String key) => DifyI18n.tr('common', key);

/// The phone layout of the editor. Build it inside the editor's scopes (the store, the header's data, the block
/// selector, [PhoneEditorScope]) with [config].
class PhoneEditorFrame extends StatefulWidget {
  const PhoneEditorFrame({super.key, required this.config});

  final PhoneEditorConfig config;

  @override
  State<PhoneEditorFrame> createState() => _PhoneEditorFrameState();
}

class _PhoneEditorFrameState extends State<PhoneEditorFrame> {
  PhoneEditorController? _phone;
  WorkflowStore? _store;

  /// The run, its input forms and the other panels as sheets.
  late final _sheets = PhoneEditorSheets(widget.config.controller);

  EditorController get _controller => widget.config.controller;
  CanvasController get _canvas => widget.config.canvas;
  PhoneEditorActions get _actions => PhoneEditorActions(context, widget.config);

  @override
  void initState() {
    super.initState();
    _controller.addListener(_documentChanged);
    _canvas.onHandleTap = _handleTap;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _store = WorkflowStoreScope.of(context);
    final phone = PhoneEditorScope.maybeOf(context);
    if (phone == _phone) return _bindSheets();
    _phone?.removeListener(_phoneChanged);
    if (_phone?.onCanvasLongPress == _longPress) _phone?.onCanvasLongPress = null;
    _phone = phone
      ?..addListener(_phoneChanged)
      ..onCanvasLongPress = _longPress;
    _phoneChanged();
    _bindSheets();
  }

  void _bindSheets() {
    if (_phone case final phone?) _sheets.bind(context, _controller, _store!, phone, widget.config.panels);
  }

  @override
  void didUpdateWidget(PhoneEditorFrame old) {
    super.didUpdateWidget(old);
    _bindSheets();
    if (old.config.controller != _controller) {
      old.config.controller.removeListener(_documentChanged);
      _controller.addListener(_documentChanged);
    }
    if (old.config.canvas != _canvas) {
      if (old.config.canvas.onHandleTap == _handleTap) old.config.canvas.onHandleTap = null;
      _canvas.onHandleTap = _handleTap;
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_documentChanged);
    if (_canvas.onHandleTap == _handleTap) _canvas.onHandleTap = null;
    _canvas.touchSelect.value = false;
    _phone?.removeListener(_phoneChanged);
    if (_phone?.onCanvasLongPress == _longPress) _phone?.onCanvasLongPress = null;
    _sheets.dispose();
    super.dispose();
  }

  /// Select mode draws boxes with one finger, on the canvas page only (in pointer mode, which box selection needs).
  void _phoneChanged() {
    final phone = _phone;
    if (phone == null) return;
    final select = phone.selectMode && phone.view == PhoneEditorView.canvas;
    _canvas.touchSelect.value = select;
    final store = _store;
    if (select && store != null && store.controlMode.value == ControlMode.hand) {
      store.setControlMode(ControlMode.pointer);
    }
  }

  /// The settings panel belongs to the selected node: it closes when the selection moves on (or the panel's own
  /// close button clears it).
  void _documentChanged() {
    final phone = _phone, open = phone?.settingsNodeId;
    if (phone == null || open == null || _controller.selectedNodeId == open) return;
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted && _controller.selectedNodeId != phone.settingsNodeId) phone.closeSettings();
      });
    } else {
      phone.closeSettings();
    }
  }

  void _handleTap(String nodeId, String handle) {
    if (mounted) unawaited(_actions.addAfter(nodeId, handle));
  }

  void _longPress(WorkflowContextMenuTarget target, Offset canvasPoint) {
    if (mounted) unawaited(_actions.longPress(target, canvasPoint));
  }

  /// The newest open layer's closing, in the order back unwinds them; null when none is open.
  VoidCallback? _topLayer(PhoneEditorActions a) {
    final store = a.store, phone = _phone;
    if (phone == null) return null;
    if (phone.settingsNodeId != null) return phone.closeSettings;
    // The sheets: the modal ones, then the lists and the run sheet (collapsed to their peek first).
    if (_sheets.backStep() case final step?) return step;
    final panels = <ValueNotifier<bool>, VoidCallback>{
      store.showDebugAndPreviewPanel: () => store.setShowDebugAndPreviewPanel(false),
      store.showEnvPanel: () => store.setShowEnvPanel(false),
      store.showChatVariablePanel: () => store.setShowChatVariablePanel(false),
      store.showGlobalVariablePanel: () => store.setShowGlobalVariablePanel(false),
      store.showCommentsPanel: () => store.setShowCommentsPanel(false),
      store.showFeaturesPanel: () => store.setShowFeaturesPanel(false),
      store.showWorkflowVersionHistoryPanel: () => store.setShowWorkflowVersionHistoryPanel(false),
    };
    for (final MapEntry(key: open, value: close) in panels.entries) {
      if (open.value) return close;
    }
    if (store.historyWorkflowData.value != null) return a.leaveRunHistory;
    if (store.isRestoring.value) return a.exitVersions;
    if (store.controlMode.value == ControlMode.comment) return () => store.setControlMode(ControlMode.pointer);
    if (_canvas.selection.nodes.isNotEmpty || a.selectedEdgeId != null || _controller.selectedNodeId != null) {
      return a.clearSelection;
    }
    if (phone.selectMode) return () => phone.selectMode = false;
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final store = WorkflowStoreScope.of(context);
    final phone = PhoneEditorScope.maybeOf(context)!;
    final config = widget.config;
    final layers = Listenable.merge([
      _controller,
      _controller.undo,
      _canvas.selection,
      phone,
      store.showEnvPanel,
      store.showChatVariablePanel,
      store.showGlobalVariablePanel,
      store.showDebugAndPreviewPanel,
      store.showCommentsPanel,
      store.showWorkflowVersionHistoryPanel,
      store.showVariableInspectPanel,
      store.showFeaturesPanel,
      store.historyWorkflowData,
      store.isRestoring,
      store.controlMode,
      store.nodeRunData,
      store.readOnlyChanges,
    ]);
    return ListenableBuilder(
      listenable: layers,
      builder: (context, _) {
        final a = _actions;
        final close = _topLayer(a);
        return DifyBackDismiss(
          enabled: close != null,
          onDismiss: () {
            _topLayer(_actions)?.call();
            // A layer that only collapses (a sheet back to its peek) changes nothing this frame listens to: rebuild so
            // the next layer's back step is held again.
            if (mounted) setState(() {});
          },
          child: ColoredBox(
            color: DifyColors.backgroundBody,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _PhoneTopBar(config: config, actions: a),
                    Expanded(
                      child: MediaQuery.removePadding(
                        context: context,
                        removeTop: true,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _ViewRow(actions: a, sheets: _sheets),
                                Expanded(
                                  child: MediaQuery.removePadding(
                                    context: context,
                                    removeTop: true,
                                    removeBottom: true,
                                    child: _body(context, a, phone),
                                  ),
                                ),
                                _bottomBar(a, phone),
                              ],
                            ),
                            // The node's settings (the other panels are sheets).
                            if (phone.settingsNodeId != null) ?config.body.panels,
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                _sheets.modalLayer(),
                ?config.body.modal,
                config.body.confirm,
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _body(BuildContext context, PhoneEditorActions a, PhoneEditorController phone) {
    final steps = phone.view == PhoneEditorView.steps;
    final config = widget.config;
    return Stack(
      fit: StackFit.expand,
      children: [
        Offstage(
          offstage: steps,
          child: TickerMode(enabled: !steps, child: config.body.canvas),
        ),
        if (!steps)
          Positioned(
            top: 12,
            right: 12 + MediaQuery.paddingOf(context).right,
            child: _CanvasButtons(actions: a, phone: phone),
          ),
        if (steps)
          Positioned.fill(
            // The run sheet (or a list) rests over the view's end: the last step scrolls above it.
            child: Builder(
              builder: (context) {
                final media = MediaQuery.of(context);
                return MediaQuery(
                  data: media.copyWith(
                    padding: media.padding.copyWith(bottom: media.padding.bottom + _sheets.dockedHeight),
                  ),
                  child: (config.stepsView ?? workflowStepsView)(
                    context,
                    StepsViewHost(
                      controller: _controller,
                      canvas: _canvas,
                      actions: () => _actions.actions,
                      openSettings: (id) => _actions.openSettings(id),
                      insert: (at) => _actions.insert(at),
                      showNodeActions: (id) => unawaited(_actions.showNodeSheet(id)),
                      registerAddAtEnd: (fn) => phone.stepsAddAtEnd = fn,
                    ),
                  ),
                );
              },
            ),
          ),
        // The run sheet and the version and comment lists, over the view and above the bottom bar.
        _sheets.dockedLayer(),
      ],
    );
  }

  Widget _bottomBar(PhoneEditorActions a, PhoneEditorController phone) {
    final store = a.store;
    if (store.isRestoring.value) {
      return DifyBottomToolbar(
        key: const ValueKey('phone-restoring-bar'),
        actions: [
          DifyToolbarAction(
            icon: const RemixIcon('history-line', size: 22),
            label: _tp('versions'),
            onTap: a.versions,
          ),
          DifyToolbarAction(
            icon: const RemixIcon('close-circle-line', size: 22),
            label: _tw('common.exitVersions'),
            onTap: a.exitVersions,
          ),
        ],
      );
    }
    if (store.historyWorkflowData.value != null) {
      return DifyBottomToolbar(
        key: const ValueKey('phone-history-bar'),
        actions: [
          DifyToolbarAction(
            icon: const RemixIcon('time-line', size: 22),
            label: _tw('common.runHistory'),
            onTap: () => unawaited(showRunHistorySheet(context)),
          ),
          DifyToolbarAction(
            icon: const RemixIcon('arrow-go-back-line', size: 22),
            label: _tw('common.goBackToEdit'),
            onTap: a.leaveRunHistory,
          ),
        ],
      );
    }
    if (phone.view == PhoneEditorView.canvas) {
      final group = a.groupSelection;
      if (group.isNotEmpty) return _groupBar(a, group);
      if (a.selectedEdgeId case final edge?) return _edgeBar(a, edge);
      if (a.selectedNodeId case final id? when a.doc.nodes[id] != null) return _nodeBar(a, a.doc.nodes[id]!);
    }
    return _toolbar(a);
  }

  Widget _toolbar(PhoneEditorActions a) {
    final store = a.store, undo = _controller.undo;
    final editable = !a.readOnly;
    final undoable = !(store.nodesReadOnly || store.workflowReadOnly);
    return DifyBottomToolbar(
      key: const ValueKey('phone-toolbar'),
      actions: [
        DifyToolbarAction(
          icon: const RemixIcon('arrow-go-back-line', size: 22),
          label: _tw('common.undo'),
          enabled: undoable && undo.canUndo,
          onTap: a.operator.historyBack,
        ),
        DifyToolbarAction(
          icon: const RemixIcon('arrow-go-forward-fill', size: 22),
          label: _tw('common.redo'),
          enabled: undoable && undo.canRedo,
          onTap: a.operator.historyForward,
        ),
        DifyToolbarAction(
          icon: const RemixIcon('sticky-note-add-line', size: 22),
          label: _tp('note'),
          enabled: editable,
          onTap: () => a.addNote(),
        ),
        DifyToolbarAction(
          icon: const RemixIcon('history-line', size: 22),
          label: _tp('versions'),
          enabled: a.data.canReleaseAndVersion,
          onTap: a.versions,
        ),
      ],
      center: DifyFab(
        key: const ValueKey('phone-add'),
        icon: const RemixIcon('add-line', size: 28),
        label: _tw('common.addBlock'),
        disabled: !editable,
        onPressed: () => unawaited(a.add()),
      ),
    );
  }

  Widget _nodeBar(PhoneEditorActions a, Node n) {
    final running = a.actions.isSingleRunning(n.id);
    return DifySelectionBar(
      key: const ValueKey('phone-node-bar'),
      leading: a.iconOf(n),
      title: a.titleOf(n),
      subtitle: _tp('selected'),
      onClose: a.clearSelection,
      actions: [
        DifyToolbarAction(
          key: const ValueKey('phone-node-settings'),
          icon: const RemixIcon('settings-3-line', size: 22),
          label: _tc('operation.settings'),
          enabled: a.hasSettings(n),
          onTap: () => a.openSettings(n.id),
        ),
        DifyToolbarAction(
          key: const ValueKey('phone-node-run'),
          icon: RemixIcon(running ? 'stop-circle-line' : 'play-large-line', size: 22),
          label: _tp(running ? 'stop' : 'runStep'),
          enabled: a.canRunStep(n),
          onTap: () => a.runStep(n.id),
        ),
        DifyToolbarAction(
          key: const ValueKey('phone-node-add-next'),
          icon: const RemixIcon('add-circle-line', size: 22),
          label: _tp('addNext'),
          enabled: a.canAddAfter(n),
          onTap: () => unawaited(a.addAfter(n.id)),
        ),
        DifyToolbarAction(
          key: const ValueKey('phone-node-connect'),
          icon: const RemixIcon('link', size: 22),
          label: _tp('connect'),
          enabled: a.canAddAfter(n),
          onTap: () => unawaited(a.connect(n.id)),
        ),
        DifyToolbarAction(
          key: const ValueKey('phone-node-duplicate'),
          icon: const RemixIcon('file-copy-2-line', size: 22),
          label: _tw('common.duplicate'),
          enabled: a.canDuplicate(n),
          onTap: () => unawaited(a.duplicate(n.id)),
        ),
        DifyToolbarAction(
          key: const ValueKey('phone-node-delete'),
          icon: const RemixIcon('delete-bin-line', size: 22),
          label: _tc('operation.delete'),
          destructive: true,
          enabled: a.canDelete(n),
          onTap: () => a.delete(n.id),
        ),
      ],
    );
  }

  Widget _edgeBar(PhoneEditorActions a, String edgeId) => DifySelectionBar(
    key: const ValueKey('phone-edge-bar'),
    leading: RemixIcon('git-commit-line', size: 22, color: DifyColors.textTertiary),
    title: a.edgeTitle(edgeId),
    onClose: a.clearSelection,
    actions: [
      DifyToolbarAction(
        key: const ValueKey('phone-edge-insert'),
        icon: const RemixIcon('add-circle-line', size: 22),
        label: _tp('insertStep'),
        enabled: !a.readOnly,
        onTap: () => unawaited(a.insert(InsertOnEdge(edgeId))),
      ),
      DifyToolbarAction(
        key: const ValueKey('phone-edge-delete'),
        icon: const RemixIcon('link-unlink', size: 22),
        label: _tp('deleteConnection'),
        destructive: true,
        enabled: !a.readOnly,
        onTap: () => a.actions.deleteEdge(edgeId),
      ),
    ],
  );

  Widget _groupBar(PhoneEditorActions a, List<Node> group) => DifySelectionBar(
    key: const ValueKey('phone-group-bar'),
    leading: RemixIcon('checkbox-multiple-line', size: 22, color: DifyColors.textTertiary),
    title: _tp('nodesSelected', {'count': group.length}),
    onClose: a.clearSelection,
    actions: [
      DifyToolbarAction(
        key: const ValueKey('phone-group-duplicate'),
        icon: const RemixIcon('file-copy-2-line', size: 22),
        label: _tw('common.duplicate'),
        enabled: !a.readOnly,
        onTap: () => unawaited(a.duplicate()),
      ),
      DifyToolbarAction(
        key: const ValueKey('phone-group-organize'),
        icon: const RemixIcon('function-add-line', size: 22),
        label: _tp('organize'),
        enabled: !a.readOnly,
        onTap: () => unawaited(a.showAlignSheet()),
      ),
      DifyToolbarAction(
        key: const ValueKey('phone-group-delete'),
        icon: const RemixIcon('delete-bin-line', size: 22),
        label: _tc('operation.delete'),
        destructive: true,
        enabled: !a.readOnly,
        onTap: a.actions.deleteSelection,
      ),
    ],
  );
}

/// The app bar: back (the newest layer, then the page), the app's name over its save state and collaborators, the
/// mode's main action (Run or Stop, Restore while browsing versions) and "…".
class _PhoneTopBar extends StatelessWidget {
  const _PhoneTopBar({required this.config, required this.actions});

  final PhoneEditorConfig config;
  final PhoneEditorActions actions;

  static String _link(LinkState s) => switch (s) {
    LinkState.live => 'Live',
    LinkState.connecting => 'Connecting…',
    LinkState.reconnecting => 'Reconnecting…',
    LinkState.offline => 'Offline',
  };

  String? _subtitle(WorkflowHeaderData data, WorkflowStore store) {
    if (store.isRestoring.value) return _tw('common.versionHistory');
    if (store.historyWorkflowData.value case final history?) {
      final id = data.formatters.formatWorkflowRunIdentifier((history['finished_at'] as num?)?.toInt());
      return data.isChatMode ? 'Test Chat$id' : 'Test Run$id';
    }
    final parts = <String>[];
    final link = config.controller.status.link;
    final draft = store.draftUpdatedAt.value;
    if (link != LinkState.live) {
      parts.add(_link(link));
    } else if (store.isSyncingWorkflowDraft.value) {
      parts.add(_tw('common.syncingData'));
    } else if (draft != 0) {
      parts.add('${_tw('common.autoSaved')} ${data.formatters.formatTime(draft ~/ 1000, 'HH:mm')}');
    }
    final others = <String>{
      for (final u in data.onlineUsers?.value ?? const <OnlineUser>[])
        if (u.userId != data.currentUserId && u.username.isNotEmpty) u.username,
    }.toList();
    if (others.isNotEmpty) {
      final names = others.length > 2 ? '${others.take(2).join(', ')} +${others.length - 2}' : others.join(', ');
      parts.add(_tp('editingWith', {'names': names}));
    }
    return parts.isEmpty ? null : parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final data = WorkflowHeaderScope.of(context);
    final store = actions.store;
    return ListenableBuilder(
      listenable: Listenable.merge([
        store.draftUpdatedAt,
        store.isSyncingWorkflowDraft,
        store.workflowRunningData,
        store.isListening,
        store.currentVersion,
        ?data.onlineUsers,
        ?data.graph,
      ]),
      builder: (context, _) => DifyTopAppBar(
        key: const ValueKey('phone-editor-app-bar'),
        title: config.appName,
        subtitle: _subtitle(data, store),
        backgroundColor: DifyColors.backgroundBody,
        actions: [
          ?_mainAction(data, store),
          DifyTouchIconButton(
            key: const ValueKey('phone-editor-more'),
            label: _tc('operation.more'),
            icon: const RemixIcon('more-fill', size: 22),
            onPressed: () => unawaited(actions.showOverflow()),
          ),
        ],
      ),
    );
  }

  Widget? _mainAction(WorkflowHeaderData data, WorkflowStore store) {
    if (store.historyWorkflowData.value != null) return null;
    if (store.isRestoring.value) {
      return DifyTouchTarget(
        child: DifyButton(
          key: const ValueKey('phone-restore'),
          variant: DifyButtonVariant.primary,
          size: DifyButtonSize.large,
          disabled: !HeaderInRestoring.canRestore(store.currentVersion.value, data),
          onPressed: () => unawaited(HeaderInRestoring.restore(store, data)),
          child: DifyTextLine(_tw('common.restore')),
        ),
      );
    }
    final running =
        runningStatusOf(store.workflowRunningData.value) == WorkflowRunningStatus.running || store.isListening.value;
    if (running && data.canRun) {
      return DifyTouchTarget(
        child: DifyButton(
          key: const ValueKey('phone-stop'),
          size: DifyButtonSize.large,
          leading: const RemixIcon('stop-circle-line', size: 16),
          onPressed: actions.stopRun,
          child: DifyTextLine(_tp('stop')),
        ),
      );
    }
    return DifyTouchTarget(
      child: DifyButton(
        key: const ValueKey('phone-run'),
        variant: DifyButtonVariant.primary,
        size: DifyButtonSize.large,
        disabled: !data.canRun,
        leading: const RemixIcon('play-large-fill', size: 16),
        onPressed: () => unawaited(actions.run()),
        child: DifyTextLine(data.isChatMode ? _tw('common.debugAndPreview') : _tp('run')),
      ),
    );
  }
}

/// The Steps | Canvas switch and the checklist's issues (after a hidden run's chip, [PhoneEditorSheets.viewRowChips]).
class _ViewRow extends StatelessWidget {
  const _ViewRow({required this.actions, required this.sheets});
  final PhoneEditorActions actions;
  final PhoneEditorSheets sheets;

  @override
  Widget build(BuildContext context) {
    final phone = actions.phone!;
    final graph = WorkflowHeaderScope.of(context).graph;
    final insets = MediaQuery.paddingOf(context);
    String label(int count) => count == 0
        ? _tp('noIssues')
        : count == 1
        ? _tp('issue')
        : _tp('issues', {'count': count});
    // compact (beside a run's chip in a short row): the icon and the count.
    Widget issues(int count, bool compact) => DifyFilterChip(
      key: ValueKey(compact ? 'phone-issues-compact' : 'phone-issues'),
      label: compact ? (count == 0 ? '' : '$count') : label(count),
      semanticLabel: compact ? label(count) : null,
      leading: count == 0
          ? RemixIcon('checkbox-circle-line', size: 16, color: DifyColors.textSuccess)
          : RemixIcon('error-warning-fill', size: 16, color: DifyColors.textWarning),
      onPressed: () => unawaited(actions.showChecklist()),
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(16 + insets.left, 0, 16 + insets.right, 4),
      child: Row(
        children: [
          DifySegmentedControl<PhoneEditorView>(
            key: const ValueKey('phone-view-switch'),
            size: DifySegmentedControlSize.touch,
            semanticLabel: _tp('view'),
            value: phone.view,
            onChanged: (v) => phone.view = v,
            segments: [
              (
                value: PhoneEditorView.steps,
                label: _tp('steps'),
                child: DifySegmentLabel(icon: const RemixIcon('list-unordered', size: 16), text: _tp('steps')),
              ),
              (
                value: PhoneEditorView.canvas,
                label: _tp('canvas'),
                child: DifySegmentLabel(icon: const RemixIcon('flow-chart', size: 16), text: _tp('canvas')),
              ),
            ],
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child: sheets.viewRowChips(
                issues: (compact) => graph == null
                    ? issues(0, compact)
                    : ValueListenableBuilder(
                        valueListenable: graph,
                        builder: (context, facts, _) => issues(facts.checklist.length, compact),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The canvas's two floating buttons: pan / select mode and fit to screen.
class _CanvasButtons extends StatelessWidget {
  const _CanvasButtons({required this.actions, required this.phone});
  final PhoneEditorActions actions;
  final PhoneEditorController phone;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    spacing: 12,
    children: [
      DifyFloatingIconButton(
        key: const ValueKey('phone-canvas-mode'),
        label: _tp('selectMode'),
        selected: phone.selectMode,
        icon: RemixIcon(phone.selectMode ? 'cursor-line' : 'hand', size: 22),
        onPressed: () => phone.selectMode = !phone.selectMode,
      ),
      DifyFloatingIconButton(
        key: const ValueKey('phone-canvas-fit'),
        label: _tw('operator.zoomToFit'),
        icon: const RemixIcon('focus-2-line', size: 22),
        onPressed: () => actions.operator.zoom((c) => c.fitView()),
      ),
    ],
  );
}
