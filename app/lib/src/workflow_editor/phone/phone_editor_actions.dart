/// The phone editor's actions (dify-sf): what its toolbar, selection bars, long presses and overflow menu do. Every
/// edit goes through the editor's own operations ([WorkflowActions], `addNodeAt`, the candidate placement, the
/// controller's `connect`), so undo, redo and collaboration see the same changes as on the desktop.
library;

import 'dart:async';

import 'package:collab_client/collab_client.dart';
import 'package:flutter/widgets.dart';

import '../../canvas/canvas_controller.dart';
import '../../canvas/canvas_input.dart' show ControlMode;
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../editor/editor_controller.dart';
import '../../i18n/dify_i18n.dart';
import '../../workflow/dify_json.dart' show difyDataOf;
import '../block_selector/block_selector.dart';
import '../block_selector/selector_widgets.dart' show SelectorBlockIcon, SelectorIconSize;
import '../context_menu/context_menu.dart';
import '../header/checklist/checklist.dart';
import '../header/checklist/checklist_item.dart';
import '../header/header_data.dart';
import '../header/test_run_menu.dart';
import '../header/view_history.dart';
import '../header/workflow_header.dart' show HeaderInNormal;
import '../node_insertion/insert_block.dart';
import '../operator/actions.dart' show ExportImageFormat, OperatorActions, OperatorOptions;
import '../operator/view_workflow_history.dart' show historyEntries, historyEntryText;
import '../store/store.dart';
import 'phone_editor_controller.dart';
import 'steps_view_slot.dart';

String _tw(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('workflow', key, params);

/// dify-sf's own phone editor strings (assets/extension_i18n, namespace `phone-editor`).
String _tp(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('phone-editor', key, params);
String _tc(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('common', key, params);

/// What the phone chrome needs from the editor around it (the editor provides it; tests can build their own).
class PhoneEditorConfig {
  const PhoneEditorConfig({
    required this.controller,
    required this.canvas,
    required this.menuOptions,
    required this.appName,
    required this.body,
    required this.onPlace,
    required this.noteCandidate,
    this.operator = const OperatorOptions(),
    this.onGenerate,
    this.sessionDetails,
    this.publisher,
    this.stepsView,
  });

  final EditorController controller;
  final CanvasController canvas;

  /// What the menus' actions may do (and call back for: run, export, change block).
  final WorkflowMenuOptions menuOptions;
  final String appName;

  /// The canvas, the panels and the modal layers ([PhoneEditorBody]).
  final PhoneEditorBody body;

  /// Puts a placed candidate (a node or a note, with an iteration's or loop's start node) into the document as one
  /// undo step (what the desktop's "follow the pointer" candidate does on its click).
  final void Function(CandidatePlacement placement) onPlace;

  /// A new note as a candidate (its author and author visibility).
  final DifyJson Function() noteCandidate;

  /// Organize, export image, and whether the collaboration items (comments, cursors) exist.
  final OperatorOptions operator;

  /// The AI workflow generator; null: not available.
  final VoidCallback? onGenerate;

  /// The collaboration session's details (link state, unsaved edits, the host's actions) for a sheet; null: none.
  final WidgetBuilder? sessionDetails;

  /// The publisher's panel for a sheet ([close] closes the sheet); null: publishing is not offered.
  final Widget Function(BuildContext context, VoidCallback close)? publisher;

  /// Builds the Steps view; null: [workflowStepsView].
  final StepsViewBuilder? stepsView;
}

/// The phone editor's actions on [context] (inside the editor: its store, header and block selector scopes).
class PhoneEditorActions {
  PhoneEditorActions(this.context, this.config);

  final BuildContext context;
  final PhoneEditorConfig config;

  EditorController get controller => config.controller;
  CanvasController get canvas => config.canvas;
  WorkflowStore get store => WorkflowStoreScope.of(context);
  WorkflowHeaderData get data => WorkflowHeaderScope.of(context);
  PhoneEditorController? get phone => PhoneEditorScope.read(context);

  WorkflowActions get actions =>
      WorkflowActions(controller: controller, canvas: canvas, store: store, options: config.menuOptions);
  OperatorActions get operator => OperatorActions(canvas, store, history: controller.undo, options: config.operator);

  bool get readOnly => actions.nodesReadOnly;
  Document get doc => controller.doc;

  /// A sheet is pushed on the root navigator, outside the editor: it gets the editor's scopes again.
  Widget scoped(Widget child) {
    final p = phone;
    Widget out = WorkflowHeaderScope(
      data: data,
      canvas: canvas,
      child: BlockSelectorScope(data: BlockSelectorScope.of(context), child: child),
    );
    if (p != null) out = PhoneEditorScope(controller: p, child: out);
    return WorkflowStoreScope(store: store, preferences: WorkflowStoreScope.preferencesOf(context), child: out);
  }

  // ----- selection -----

  /// The one selected node (the canvas's, else the document's), or null.
  String? get selectedNodeId {
    final nodes = canvas.selection.nodes;
    if (nodes.length == 1) return canvas.graph?.slots.elementAtOrNull(nodes.single)?.id;
    if (nodes.isEmpty && canvas.selection.edge == null) return controller.selectedNodeId;
    return null;
  }

  /// The selected edge, or null.
  String? get selectedEdgeId {
    final id = canvas.selection.edge ?? controller.selectedEdgeId;
    return id != null && doc.edges.containsKey(id) ? id : null;
  }

  /// The nodes of a box selection (two or more).
  List<Node> get groupSelection => canvas.selection.nodes.length > 1 ? actions.selectedNodes : const [];

  void clearSelection() {
    canvas.selection.selectNodes(const []);
    controller.selectNode(null);
  }

  void selectEdge(String edgeId) {
    canvas.selection.selectEdge(edgeId);
    controller.selectEdge(edgeId);
  }

  // ----- node facts -----

  String titleOf(Node n) => n.title.isNotEmpty ? n.title : _tw('blocks.${n.type}');

  Widget iconOf(Node n, {SelectorIconSize size = SelectorIconSize.md}) =>
      SelectorBlockIcon(type: n.type, size: size, toolIcon: difyDataOf(n)['provider_icon']);

  /// Only workflow blocks have a settings panel (not notes or container starts).
  bool hasSettings(Node n) => reactFlowTypeOf(n) == 'custom';

  bool canRunStep(Node n) =>
      config.menuOptions.canRun && !readOnly && canRunBySingle(n.type, isChildNode: parentIdOf(n) != null);

  /// The node's source handles, in the card's order (none for notes and the like).
  List<String> sourceHandlesOf(Node n) => [...?canvas.graph?[n.id]?.layout.sources.keys];

  bool canAddAfter(Node n) =>
      !readOnly &&
      sourceHandlesOf(n).isNotEmpty &&
      actions.availableBlocksOf(n, BlockSelectorScope.of(context)).next.isNotEmpty;

  bool canDuplicate(Node n) => !readOnly && actions.isNodeCopyable(n);
  bool canDelete(Node n) => !readOnly && !(actions.metaOf(n)?.isUndeletable ?? false);

  /// Whether node [n] has an unconnected input a block may go before.
  bool canAddBefore(Node n) {
    final c = canvas.graph?[n.id];
    if (readOnly || c == null || !c.layout.target) return false;
    if (doc.edges.values.any((e) => e.target == n.id)) return false;
    return actions.availableBlocksOf(n, BlockSelectorScope.of(context)).prev.isNotEmpty;
  }

  /// A source handle's name as the card labels it: IF / ELIF / ELSE, a class's name, the fail branch.
  String handleLabel(Node n, String handle) {
    if (handle == 'fail-branch') return _tw('nodes.common.errorHandle.failBranch.title');
    final data = difyDataOf(n);
    if (n.type == 'if-else') {
      if (handle == 'false') return 'ELSE';
      final cases = (data['cases'] as List?)?.whereType<Map>().toList() ?? const [];
      final i = cases.indexWhere((c) => c['case_id'] == handle);
      return i <= 0 ? 'IF' : 'ELIF ${i + 1}';
    }
    if (n.type == 'question-classifier') {
      final classes = (data['classes'] as List?)?.whereType<Map>().toList() ?? const [];
      final i = classes.indexWhere((c) => '${c['id']}' == handle);
      if (i >= 0) {
        final name = '${classes[i]['name'] ?? ''}';
        return name.isEmpty ? 'CLASS ${i + 1}' : name;
      }
    }
    return handle;
  }

  // ----- settings, run -----

  /// Selects [nodeId] and opens its settings panel.
  void openSettings(String nodeId) {
    if (doc.nodes[nodeId] case final n? when hasSettings(n)) {
      actions.selectNode(nodeId);
      phone?.openSettings(nodeId);
    }
  }

  /// Runs (or stops) the node alone: the panel runs it on its last-run tab, so the panel opens.
  void runStep(String nodeId) {
    actions.runStep(nodeId);
    phone?.openSettings(nodeId);
  }

  /// The app bar's Run: Preview in a chatflow; otherwise the only start option directly, or a sheet of them. An
  /// option whose node has checklist items is refused with Dify's toast.
  Future<void> run() async {
    final d = data;
    if (!d.canRun) return;
    if (d.isChatMode) return d.onRunInChatflow?.call();
    final options = enabledTestRunOptions(testRunOptionsOf(d.facts.nodes));
    void start(TriggerOption o) {
      if (d.facts.checklist.any((n) => n.id == o.nodeId)) {
        d.toast?.call(HeaderToastType.error, _tw('panel.checklistTip'));
        return;
      }
      d.onRun?.call(o);
    }

    if (options.isEmpty) return;
    if (options.length == 1) return start(options.single);
    await showDifyActionSheet(
      context,
      title: _tw('common.chooseStartNodeToRun'),
      actions: [
        for (final o in options)
          DifyActionSheetAction(
            label: o.name,
            icon: o.nodeType == null
                ? const RemixIcon('play-list-2-line', size: 20)
                : SelectorBlockIcon(type: o.nodeType!, size: SelectorIconSize.sm),
            onTap: () => start(o),
          ),
      ],
    );
  }

  void stopRun() => data.onStopRun?.call('${store.workflowRunningData.value?['task_id'] ?? ''}');

  // ----- adding -----

  /// The visible part of the canvas (canvas coordinates).
  Rect get visibleArea {
    final v = canvas.view;
    return Rect.fromPoints(v.toCanvas(Offset.zero), v.toCanvas(v.viewport.bottomRight(Offset.zero)));
  }

  /// A free spot for a new node of [size] in the visible part of the canvas: the first place, scanning rows from the
  /// top left (40 px margins, 40 px steps), where it keeps 24 px clear of every node; else the view's middle.
  Offset freeSpot({Size size = const Size(240, 90)}) {
    final graph = canvas.graph, view = visibleArea;
    final middle = view.center - Offset(size.width / 2, size.height / 2);
    if (graph == null || view.isEmpty || !view.isFinite) return middle;
    const margin = 40.0, step = 40.0, gap = 24.0;
    bool free(Rect r) {
      for (final slot in graph.grid.near(r.inflate(gap))) {
        final n = graph.slots[slot];
        if (n != null && n.parentId == null && n.visual.inflate(gap).overlaps(r)) return false;
      }
      return true;
    }

    for (var y = view.top + margin; y + size.height <= view.bottom - margin; y += step) {
      for (var x = view.left + margin; x + size.width <= view.right - margin; x += step) {
        final r = Offset(x, y) & size;
        if (free(r)) return r.topLeft;
      }
    }
    return middle;
  }

  /// Brings node [id] into view when it is outside it.
  void reveal(String id) {
    final n = canvas.graph?[id];
    if (n == null) return;
    if (!visibleArea.deflate(16).contains(n.rect.center)) canvas.view.center = n.rect.center;
  }

  /// The block picker (a bottom sheet on a phone) inserting at [at]; the new node is selected and shown.
  Future<void> insert(InsertPoint at) async {
    final before = doc.nodes.keys.toSet();
    await actions.showInsertBlockSelector(context, at);
    final id = controller.selectedNodeId;
    if (id != null && !before.contains(id)) reveal(id);
  }

  /// Adds after [nodeId]'s [handle] (its first source handle by default).
  Future<void> addAfter(String nodeId, [String? handle]) async {
    final n = doc.nodes[nodeId];
    if (n == null) return;
    await insert(InsertAfter(nodeId, handle ?? sourceHandlesOf(n).firstOrNull ?? 'source'));
  }

  /// The toolbar's Add: after the selected node, else a block of the picker's at a free spot in view (or at [at]).
  Future<void> add({Offset? at}) async {
    if (readOnly) return;
    final selected = at == null ? selectedNodeId : null;
    if (selected == null ? null : doc.nodes[selected] case final n? when canAddAfter(n)) return addAfter(n.id);
    final data = BlockSelectorScope.of(context);
    await BlockSelector(
      availableBlocksTypes: useAvailableBlocks(
        'start',
        availableTypes: availableNodeTypes(chatMode: data.chatMode, agentV2: data.agentV2),
      ).next,
      showStartTab: !data.chatMode && data.flow == BlockSelectorFlow.app,
      onSelect: (type, defaults, {toolDefaultValue}) =>
          place(candidateNodeOf(type, defaults, toolDefaultValue: toolDefaultValue, existing: _existing(data)), at),
    ).show(context);
  }

  List<DifyJson> _existing(BlockSelectorData data) => [
    for (final n in data.nodes)
      {
        'id': n.id,
        'data': {'type': n.type},
      },
  ];

  /// Puts [candidate] at [at] (canvas coordinates; default: a free spot in view) and selects it: no node follows the
  /// finger.
  void place(DifyJson candidate, [Offset? at]) {
    if (readOnly) return;
    final note = candidate['type'] == 'custom-note';
    final placement = placeCandidate(candidate, at ?? freeSpot(size: note ? const Size(240, 88) : const Size(240, 90)));
    config.onPlace(placement);
    final id = '${placement.node['id']}';
    if (doc.nodes.containsKey(id)) {
      actions.selectNode(id);
      reveal(id);
    }
  }

  /// The toolbar's Note: a note at a free spot in view (or at [at]), selected.
  void addNote({Offset? at}) => place(config.noteCandidate(), at);

  // ----- connecting -----

  /// "Connect…": the source handle (when the node has several), then the node to connect to, from a searchable list
  /// of the nodes a connection may reach; the edge is made as a drag from the handle makes it.
  Future<void> connect(String nodeId) async {
    final n = doc.nodes[nodeId];
    if (n == null || readOnly) return;
    final handles = sourceHandlesOf(n);
    if (handles.isEmpty) return;
    var handle = handles.first;
    if (handles.length > 1) {
      String? picked;
      await showDifyActionSheet(
        context,
        title: _tp('connectFrom', {'name': titleOf(n)}),
        actions: [
          for (final h in handles) DifyActionSheetAction(label: handleLabel(n, h), onTap: () => picked = h),
        ],
      );
      if (picked == null) return;
      handle = picked!;
    }
    final targets = connectTargets(nodeId, handle);
    if (!context.mounted) return;
    final target = await showDifyBottomSheet<String>(
      context,
      (context) => scoped(
        _ConnectSheet(
          title: _tp('connectTitle'),
          subtitle: handles.length > 1 ? '${titleOf(n)} · ${handleLabel(n, handle)}' : titleOf(n),
          targets: [
            for (final t in targets) (id: t.id, title: titleOf(t), type: t.type, icon: iconOf(t)),
          ],
        ),
      ),
      detents: const [DifySheetDetent.half, DifySheetDetent.full],
    );
    if (target != null) connectTo(nodeId, handle, target);
  }

  /// The nodes [handle] of [nodeId] may connect to: siblings in the same container with an input, not yet reached
  /// from that handle, that the editor's connection rules accept.
  List<Node> connectTargets(String nodeId, String handle) {
    final graph = canvas.graph, from = graph?[nodeId];
    if (graph == null || from == null) return const [];
    final reached = {
      for (final e in doc.edges.values)
        if (e.source == nodeId && (e.sourceHandle == handle || (handle == 'source' && e.sourceHandle == 'out')))
          e.target,
    };
    return [
      for (final c in graph.nodes)
        if (c.id != nodeId &&
            c.layout.target &&
            c.parentId == from.parentId &&
            !reached.contains(c.id) &&
            doc.nodes[c.id] != null &&
            canvas.isValidConnection(nodeId, handle, c.id))
          doc.nodes[c.id]!,
    ]..sort((a, b) => titleOf(a).toLowerCase().compareTo(titleOf(b).toLowerCase()));
  }

  /// The edge a drag from [handle] of [source] dropped on [target] makes (with the aggregator's variable popup).
  void connectTo(String source, String handle, String target) {
    if (readOnly || !canvas.isValidConnection(source, handle, target)) return;
    controller.connect(source, target, sourceHandle: handle == 'source' ? null : handle);
    final t = canvas.graph?[target];
    if (t != null) canvas.onConnectDrop?.call(source, handle, target, t.rect.centerLeft);
  }

  // ----- duplicate, delete -----

  /// Duplicates [nodeId] (or the box selection) next to the original, below it, rather than under the last touch.
  Future<void> duplicate([String? nodeId]) async {
    final nodes = nodeId == null ? groupSelection : [?doc.nodes[nodeId]];
    final rects = [for (final n in nodes) ?canvas.graph?[n.id]?.rect];
    if (rects.isNotEmpty) {
      final box = rects.reduce((a, b) => a.expandToInclude(b));
      final p = canvas.view.toScreen(Offset(box.left, box.bottom + 40));
      store.setMousePosition((pageX: p.dx, pageY: p.dy, elementX: p.dx, elementY: p.dy));
    }
    await actions.duplicateNodes(nodeId);
  }

  void delete(String nodeId) {
    if (nodeId == phone?.settingsNodeId) phone?.closeSettings();
    actions.deleteNode(nodeId);
  }

  // ----- sheets -----

  /// A long press on the canvas: the target's action sheet.
  Future<void> longPress(WorkflowContextMenuTarget target, Offset canvasPoint) async {
    switch (target) {
      case NodeContextMenuTarget(:final nodeId) when doc.nodes.containsKey(nodeId):
        actions.selectNode(nodeId);
        await showNodeSheet(nodeId);
      case EdgeContextMenuTarget(:final edgeId) when doc.edges.containsKey(edgeId):
        selectEdge(edgeId);
        await showEdgeSheet(edgeId);
      case SelectionContextMenuTarget():
        await showGroupSheet();
      default:
        await showPaneSheet(canvasPoint);
    }
  }

  /// A node's actions: those of its selection bar, then the menu's others (change, copy, add before).
  Future<void> showNodeSheet(String nodeId) async {
    final n = doc.nodes[nodeId];
    if (n == null) return;
    final running = actions.isSingleRunning(nodeId);
    final meta = actions.metaOf(n);
    final canChange =
        !(meta?.isTypeFixed ?? false) &&
        !(meta?.isUndeletable ?? false) &&
        !readOnly &&
        config.menuOptions.onChangeBlock != null;
    final sourceHandle = doc.edges.values.where((e) => e.target == nodeId).firstOrNull?.sourceHandle ?? 'source';
    await showDifyActionSheet(
      context,
      title: titleOf(n),
      actions: [
        if (hasSettings(n))
          DifyActionSheetAction(
            label: _tc('operation.settings'),
            icon: const RemixIcon('settings-3-line', size: 20),
            onTap: () => openSettings(nodeId),
          ),
        if (canRunStep(n))
          DifyActionSheetAction(
            label: running ? _tw('debug.variableInspect.trigger.stop') : _tw('panel.runThisStep'),
            icon: RemixIcon(running ? 'stop-circle-line' : 'play-large-line', size: 20),
            onTap: () => runStep(nodeId),
          ),
        if (canAddAfter(n))
          DifyActionSheetAction(
            label: _tp('addNext'),
            icon: const RemixIcon('add-circle-line', size: 20),
            onTap: () => unawaited(addAfter(nodeId)),
          ),
        if (canAddBefore(n))
          DifyActionSheetAction(
            label: _tp('addBeforeAction'),
            icon: const RemixIcon('add-circle-line', size: 20),
            onTap: () => unawaited(insert(InsertBefore(nodeId))),
          ),
        if (canAddAfter(n))
          DifyActionSheetAction(
            label: _tp('connect'),
            icon: const RemixIcon('link', size: 20),
            onTap: () => unawaited(connect(nodeId)),
          ),
        if (canChange)
          DifyActionSheetAction(
            label: _tw('panel.changeBlock'),
            icon: const RemixIcon('exchange-2-line', size: 20),
            onTap: () => config.menuOptions.onChangeBlock!(nodeId, sourceHandle),
          ),
        if (canDuplicate(n)) ...[
          DifyActionSheetAction(
            label: _tw('common.copy'),
            icon: const RemixIcon('clipboard-line', size: 20),
            onTap: () => unawaited(actions.copyNodes(nodeId)),
          ),
          DifyActionSheetAction(
            label: _tw('common.duplicate'),
            icon: const RemixIcon('file-copy-2-line', size: 20),
            onTap: () => unawaited(duplicate(nodeId)),
          ),
        ],
        if (canDelete(n))
          DifyActionSheetAction(
            label: _tc('operation.delete'),
            icon: const RemixIcon('delete-bin-line', size: 20),
            destructive: true,
            onTap: () => delete(nodeId),
          ),
      ],
    );
  }

  /// A connection's actions: a step inserted on it, or the connection removed.
  Future<void> showEdgeSheet(String edgeId) async {
    final e = doc.edges[edgeId];
    if (e == null) return;
    await showDifyActionSheet(
      context,
      title: edgeTitle(edgeId),
      actions: [
        DifyActionSheetAction(
          label: _tp('insertStep'),
          icon: const RemixIcon('add-circle-line', size: 20),
          enabled: !readOnly,
          onTap: () => unawaited(insert(InsertOnEdge(edgeId))),
        ),
        DifyActionSheetAction(
          label: _tp('deleteConnection'),
          icon: const RemixIcon('link-unlink', size: 20),
          destructive: true,
          enabled: !readOnly,
          onTap: () => actions.deleteEdge(edgeId),
        ),
      ],
    );
  }

  /// "From → To" for an edge.
  String edgeTitle(String edgeId) {
    final e = doc.edges[edgeId];
    final s = e == null ? null : doc.nodes[e.source], t = e == null ? null : doc.nodes[e.target];
    return s == null || t == null ? _tp('connection') : '${titleOf(s)} → ${titleOf(t)}';
  }

  /// A box selection's actions.
  Future<void> showGroupSheet() async {
    final nodes = groupSelection;
    if (nodes.isEmpty) return;
    await showDifyActionSheet(
      context,
      title: _tp('nodesSelected', {'count': nodes.length}),
      actions: [
        DifyActionSheetAction(
          label: _tw('common.duplicate'),
          icon: const RemixIcon('file-copy-2-line', size: 20),
          enabled: !readOnly,
          onTap: () => unawaited(duplicate()),
        ),
        DifyActionSheetAction(
          label: _tw('common.copy'),
          icon: const RemixIcon('clipboard-line', size: 20),
          enabled: !readOnly,
          onTap: () => unawaited(actions.copyNodes()),
        ),
        DifyActionSheetAction(
          label: _tw('panel.organizeBlocks'),
          icon: const RemixIcon('function-add-line', size: 20),
          enabled: !readOnly,
          onTap: () => unawaited(showAlignSheet()),
        ),
        DifyActionSheetAction(
          label: _tc('operation.delete'),
          icon: const RemixIcon('delete-bin-line', size: 20),
          destructive: true,
          enabled: !readOnly,
          onTap: actions.deleteSelection,
        ),
      ],
    );
  }

  /// The selection menu's alignment, as a sheet.
  Future<void> showAlignSheet() => showDifyActionSheet(
    context,
    title: _tw('panel.organizeBlocks'),
    actions: [
      for (final (type, icon, key) in const [
        (AlignType.left, 'align-left', 'alignLeft'),
        (AlignType.center, 'align-center', 'alignCenter'),
        (AlignType.right, 'align-right', 'alignRight'),
        (AlignType.top, 'align-top', 'alignTop'),
        (AlignType.middle, 'align-center', 'alignMiddle'),
        (AlignType.bottom, 'align-bottom', 'alignBottom'),
        (AlignType.distributeHorizontal, 'align-justify', 'distributeHorizontal'),
        (AlignType.distributeVertical, 'align-justify', 'distributeVertical'),
      ])
        DifyActionSheetAction(
          label: _tw('operator.$key'),
          icon: RemixIcon(icon, size: 20),
          enabled: !readOnly,
          onTap: () => actions.alignNodes(type),
        ),
    ],
  );

  /// The empty canvas's actions at [at]: a node or a note placed there, a comment, paste.
  Future<void> showPaneSheet(Offset at) async {
    final o = config.menuOptions;
    final canEdit = o.canEdit && !actions.workflowOperationReadOnly;
    // handlePaneContextMenu: the system clipboard into the store (Paste is offered once it has nodes).
    final read = await readWorkflowClipboard(o.appDslVersion);
    if (read.nodes.isNotEmpty) {
      store.setClipboardData(nodes: read.nodes, edges: read.edges);
      store.clipboardAgentPackages = read.agentPackages;
    }
    if (!context.mounted) return;
    final p = canvas.view.toScreen(at);
    await showDifyActionSheet(
      context,
      actions: [
        if (canEdit) ...[
          DifyActionSheetAction(
            label: _tw('common.addBlock'),
            icon: const RemixIcon('add-circle-line', size: 20),
            onTap: () => unawaited(add(at: at)),
          ),
          DifyActionSheetAction(
            label: _tw('nodes.note.addNote'),
            icon: const RemixIcon('sticky-note-add-line', size: 20),
            onTap: () => addNote(at: at),
          ),
        ],
        if (canEdit && store.clipboardElements.value.isNotEmpty)
          DifyActionSheetAction(
            label: _tw('common.pasteHere'),
            icon: const RemixIcon('clipboard-line', size: 20),
            onTap: () {
              store.setMousePosition((pageX: p.dx, pageY: p.dy, elementX: p.dx, elementY: p.dy));
              unawaited(actions.pasteNodes());
            },
          ),
        if (!actions.workflowOperationReadOnly && o.commentModeAvailable)
          DifyActionSheetAction(
            label: _tw('comments.actions.addComment'),
            icon: const RemixIcon('chat-3-line', size: 20),
            onTap: () => store
              ..setCommentQuickAdd(true)
              ..setCommentPlacing(true),
          ),
      ],
    );
  }

  /// The checklist in a sheet; an item opens its node's settings.
  Future<void> showChecklist() => showDifyBottomSheet<void>(
    context,
    (sheet) => scoped(_ChecklistSheet(onItem: (item) => _checklistItem(item))),
    detents: const [DifySheetDetent.half, DifySheetDetent.full],
  );

  void _checklistItem(ChecklistItem item) {
    if (!doc.nodes.containsKey(item.id)) return;
    phone?.view = PhoneEditorView.canvas;
    openSettings(item.id);
    reveal(item.id);
    if (item.openInlineAgentPanel) store.setOpenInlineAgentPanelNodeId(item.id);
  }

  /// The version history: browsing versions on the canvas with the list open.
  void versions() {
    if (!data.canReleaseAndVersion) return;
    if (store.isRestoring.value) {
      store.setShowWorkflowVersionHistoryPanel(!store.showWorkflowVersionHistoryPanel.value);
      return;
    }
    phone?.closeSettings();
    HeaderInNormal.startRestoring(store, data, canvas);
  }

  /// Leaves the version browser (the draft comes back).
  void exitVersions() {
    data.handleLoadBackupDraft?.call();
    store
      ..isRestoring.value = false
      ..setShowWorkflowVersionHistoryPanel(false);
  }

  /// Leaves a viewed run (the draft comes back).
  void leaveRunHistory() {
    data.handleLoadBackupDraft?.call();
    store.historyWorkflowData.value = null;
  }

  // ----- the overflow menu -----

  /// The app bar's "…": the header's other actions, the canvas tools the phone has no floating chrome for, and the
  /// host's own (the app's other pages and operations).
  Future<void> showOverflow() async {
    final d = data, o = config.menuOptions;
    final readOnly = nodesReadOnlyOf(store, canEdit: d.canEdit);
    final issues = d.facts.checklist.length;
    final commentMode = store.controlMode.value == ControlMode.comment;
    final host = PhoneEditorHostActions.of(context);
    Widget icon(String name) => RemixIcon(name, size: 20);
    Widget dify(String name) => DifyIcon(name, size: 20);
    await showDifyActionSheet(
      context,
      title: config.appName,
      actions: [
        if (config.publisher != null && d.canReleaseAndVersion)
          DifyActionSheetAction(
            label: _tw('common.publish'),
            icon: icon('upload-cloud-2-line'),
            onTap: () => unawaited(showPublisher()),
          ),
        if (d.canReleaseAndVersion)
          DifyActionSheetAction(label: _tw('common.versionHistory'), icon: icon('history-line'), onTap: versions),
        DifyActionSheetAction(
          label: issues == 0 ? _tw('panel.checklist') : '${_tw('panel.checklist')} ($issues)',
          icon: icon('list-check-3'),
          onTap: () => unawaited(showChecklist()),
        ),
        if (d.fetchRunHistory != null)
          DifyActionSheetAction(
            label: _tw('common.runHistory'),
            icon: icon('time-line'),
            onTap: () => unawaited(showRunHistorySheet(context)),
          ),
        if (d.isChatMode)
          DifyActionSheetAction(
            label: _tw('common.features'),
            icon: icon('apps-2-add-line'),
            enabled: !readOnly || store.isRestoring.value,
            onTap: () => store.setShowFeaturesPanel(true),
          ),
        if (config.onGenerate case final generate?)
          DifyActionSheetAction(label: _tp('generate'), icon: icon('sparkling-line'), onTap: generate),
        if (d.isChatMode)
          DifyActionSheetAction(
            label: _tw('chatVariable.panelTitle'),
            icon: dify('vender/line/others/bubble-x'),
            enabled: !readOnly,
            onTap: () => _openPanel(() => store.setShowChatVariablePanel(true)),
          ),
        if (d.showEnvButton)
          DifyActionSheetAction(
            label: _tw('env.envPanelTitle'),
            icon: dify('vender/line/others/env'),
            enabled: !readOnly,
            onTap: () => _openPanel(() {
              store.setShowEnvPanel(true);
              d.closeAllInputFieldPanels?.call();
            }),
          ),
        if (d.showGlobalVariableButton)
          DifyActionSheetAction(
            label: _tw('globalVar.title'),
            icon: dify('vender/line/others/global-variable'),
            enabled: !readOnly,
            onTap: () => _openPanel(() {
              store.setShowGlobalVariablePanel(true);
              d.closeAllInputFieldPanels?.call();
            }),
          ),
        DifyActionSheetAction(
          label: _tw('debug.variableInspect.title'),
          icon: icon('database-2-line'),
          onTap: () => _openPanel(() => store.setShowVariableInspectPanel(true)),
        ),
        DifyActionSheetAction(
          label: _tw('panel.organizeBlocks'),
          icon: icon('function-add-line'),
          enabled: !this.readOnly,
          onTap: operator.organize,
        ),
        if (config.operator.collaborationEnabled) ...[
          DifyActionSheetAction(
            label: commentMode ? '${_tw('common.commentMode')} ✓' : _tw('common.commentMode'),
            icon: const DifyIcon('public/other/comment', size: 20),
            enabled: commentMode || operator.canUseCommentMode,
            onTap: () {
              if (commentMode) {
                store.setControlMode(ControlMode.pointer);
              } else {
                phone?.view = PhoneEditorView.canvas;
                operator.modeComment();
              }
            },
          ),
          DifyActionSheetAction(
            label: _toggleLabel(_tw('operator.showUserComments'), store.showUserComments.value),
            icon: icon(store.showUserComments.value ? 'eye-line' : 'eye-off-line'),
            onTap: () => store.setShowUserComments(!store.showUserComments.value),
          ),
          DifyActionSheetAction(
            label: _toggleLabel(_tw('operator.showUserCursors'), store.showUserCursors.value),
            icon: icon(store.showUserCursors.value ? 'eye-line' : 'eye-off-line'),
            onTap: () => store.setShowUserCursors(!store.showUserCursors.value),
          ),
        ],
        DifyActionSheetAction(
          label: _tp('zoom'),
          icon: icon('zoom-in-line'),
          onTap: () => unawaited(showZoomSheet()),
        ),
        if (config.operator.onExportImage != null)
          DifyActionSheetAction(
            label: _tw('common.exportImage'),
            icon: icon('image-line'),
            enabled: !this.readOnly,
            onTap: () => unawaited(showExportImageSheet()),
          ),
        DifyActionSheetAction(
          label: _tw('changeHistory.title'),
          icon: icon('list-view'),
          onTap: () => unawaited(showChangeHistorySheet()),
        ),
        if (o.canImportExportDsl && host.isEmpty && o.onExportDsl != null)
          DifyActionSheetAction(
            label: DifyI18n.tr('app', 'export'),
            icon: icon('file-download-line'),
            onTap: o.onExportDsl,
          ),
        ...host,
        if (config.sessionDetails != null)
          DifyActionSheetAction(
            label: _tp('connectionDetails'),
            icon: icon('cloud-line'),
            onTap: () => unawaited(showSessionSheet()),
          ),
      ],
    );
  }

  static String _toggleLabel(String label, bool on) => on ? '$label ✓' : label;

  /// A panel replaces the settings panel and is seen on the canvas page.
  void _openPanel(VoidCallback open) {
    phone?.closeSettings();
    open();
  }

  Future<void> showPublisher() => showDifyBottomSheet<void>(
    context,
    (sheet) => scoped(
      Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DifySheetHeader(title: _tw('common.publish')),
          Flexible(child: config.publisher!(sheet, () => Navigator.of(sheet).maybePop())),
        ],
      ),
    ),
  );

  Future<void> showSessionSheet() => showDifyBottomSheet<void>(
    context,
    (sheet) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DifySheetHeader(title: _tp('connectionDetails')),
        Flexible(child: SingleChildScrollView(child: config.sessionDetails!(sheet))),
      ],
    ),
  );

  Future<void> showZoomSheet() => showDifyActionSheet(
    context,
    title: _tp('zoom'),
    actions: [
      DifyActionSheetAction(label: _tw('operator.zoomIn'), onTap: () => operator.zoomBy(0.1)),
      DifyActionSheetAction(label: _tw('operator.zoomOut'), onTap: () => operator.zoomBy(-0.1)),
      DifyActionSheetAction(label: _tw('operator.zoomTo100'), onTap: () => operator.zoom((c) => c.zoomTo(1))),
      DifyActionSheetAction(label: _tw('operator.zoomTo50'), onTap: () => operator.zoom((c) => c.zoomTo(0.5))),
      DifyActionSheetAction(label: _tw('operator.zoomToFit'), onTap: () => operator.zoom((c) => c.fitView())),
    ],
  );

  Future<void> showExportImageSheet() {
    final export = config.operator.onExportImage!;
    String format(ExportImageFormat f) => _tw(switch (f) {
      ExportImageFormat.png => 'common.exportPNG',
      ExportImageFormat.jpeg => 'common.exportJPEG',
      ExportImageFormat.svg => 'common.exportSVG',
    });
    return showDifyActionSheet(
      context,
      title: _tw('common.exportImage'),
      actions: [
        for (final whole in const [false, true])
          for (final f in ExportImageFormat.values)
            DifyActionSheetAction(
              label: '${_tw(whole ? 'common.currentWorkflow' : 'common.currentView')} · ${format(f)}',
              onTap: () {
                if (!readOnly) export(f, wholeWorkflow: whole);
              },
            ),
      ],
    );
  }

  /// The change history (this session's undo steps): a row undoes or redoes up to it.
  Future<void> showChangeHistorySheet() {
    final history = controller.undo;
    final entries = historyEntries(history);
    return showDifyActionSheet(
      context,
      title: _tw('changeHistory.title'),
      actions: entries.isEmpty
          ? [DifyActionSheetAction(label: _tw('changeHistory.placeholder'), enabled: false)]
          : [
              for (final e in entries)
                DifyActionSheetAction(
                  label: historyEntryText(history, e),
                  enabled: e.index != 0 && !readOnly,
                  onTap: () {
                    for (var i = 0; i < e.index.abs(); i++) {
                      e.index < 0 ? history.undo() : history.redo();
                    }
                  },
                ),
            ],
    );
  }
}

typedef _Target = ({String id, String title, String type, Widget icon});

/// "Connect to…": the nodes a connection may reach, filtered by a search; a row pops its id.
class _ConnectSheet extends StatefulWidget {
  const _ConnectSheet({required this.title, required this.subtitle, required this.targets});
  final String title;
  final String subtitle;
  final List<_Target> targets;

  @override
  State<_ConnectSheet> createState() => _ConnectSheetState();
}

class _ConnectSheetState extends State<_ConnectSheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final shown = [
      for (final t in widget.targets)
        if (q.isEmpty || t.title.toLowerCase().contains(q) || t.type.toLowerCase().contains(q)) t,
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DifySheetHeader(title: widget.title, subtitle: widget.subtitle),
        if (widget.targets.length > 6)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: DifySearchInput(
              key: const ValueKey('phone-connect-search'),
              value: _query,
              height: 40,
              placeholder: _tp('searchSteps'),
              onValueChange: (v) => setState(() => _query = v),
            ),
          ),
        Flexible(
          child: shown.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(24),
                  child: DifyText(
                    _tw(widget.targets.isEmpty ? 'mobile.noTargets' : 'tabs.noResult'),
                    DifyType.systemSmRegular,
                    color: DifyColors.textTertiary,
                    align: TextAlign.center,
                    maxLines: 2,
                  ),
                )
              : ListView(
                  shrinkWrap: true,
                  children: [
                    for (final t in shown)
                      DifyListRow(
                        key: ValueKey('phone-connect-${t.id}'),
                        leading: t.icon,
                        title: t.title,
                        subtitle: _tw('blocks.${t.type}'),
                        onTap: () => Navigator.of(context).pop(t.id),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

/// The checklist's content in a sheet: its description and groups (the popover's), an item calls [onItem].
class _ChecklistSheet extends StatelessWidget {
  const _ChecklistSheet({required this.onItem});
  final ValueChanged<ChecklistItem> onItem;

  @override
  Widget build(BuildContext context) {
    final data = WorkflowHeaderScope.of(context);
    final graph = data.graph;
    Widget body(List<ChecklistItem> items) {
      final plugins = [
        for (final i in items)
          if (i.isPluginMissing) i,
      ];
      final nodes = [
        for (final i in items)
          if (!i.isPluginMissing) i,
      ];
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DifySheetHeader(
            title: items.isEmpty ? _tw('panel.checklist') : '${_tw('panel.checklist')} (${items.length})',
            subtitle: items.isEmpty ? null : _tw('panel.checklistDescription'),
          ),
          Flexible(
            child: items.isEmpty
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      spacing: 8,
                      children: [
                        DifyIcon('vender/line/general/checklist-square', size: 32, color: DifyColors.textQuaternary),
                        DifyText(
                          _tw('panel.checklistResolved'),
                          DifyType.systemXsRegular,
                          color: DifyColors.textTertiary,
                        ),
                      ],
                    ),
                  )
                : SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      spacing: 8,
                      children: [
                        if (plugins.isNotEmpty)
                          ChecklistPluginGroup(
                            items: plugins,
                            dependencies: data.pluginDependencies,
                            onClose: () => Navigator.of(context).maybePop(),
                          ),
                        for (final item in nodes)
                          ChecklistNodeGroup(
                            key: ValueKey(item.id),
                            item: item,
                            showGoTo: true,
                            onItemClick: (i) {
                              Navigator.of(context).pop();
                              onItem(i);
                            },
                          ),
                      ],
                    ),
                  ),
          ),
        ],
      );
    }

    if (graph == null) return body(const []);
    return ValueListenableBuilder(valueListenable: graph, builder: (context, facts, _) => body(facts.checklist));
  }
}
