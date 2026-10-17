import 'dart:async';

import 'package:collab_client/collab_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../../canvas/canvas_controller.dart';
import '../../canvas/canvas_graph.dart';
import '../../editor/editor_controller.dart';
import '../../editor/undo_manager.dart';
import '../../i18n/dify_i18n.dart';
import '../../ids.dart';
import '../store/workflow_store.dart';
import 'clipboard.dart';
import 'node_meta.dart';

/// What the app gives the canvas menus; Dify gets these from its hooks store (access control, configs), system
/// features and the hooks of features not ported yet. Absent callbacks hide the items that need them.
class WorkflowMenuOptions {
  const WorkflowMenuOptions({
    this.canEdit = true,
    this.canRun = true,
    this.canImportExportDsl = true,
    this.isChatMode = false,
    this.isSnippetCanvas = false,
    this.commentModeAvailable = false,
    this.canCreateSnippet = false,
    this.appDslVersion = '',
    this.docsProduct = 'self-host',
    this.onAddBlock,
    this.onAddNote,
    this.onRun,
    this.onExportDsl,
    this.onChangeBlock,
    this.onCreateSnippet,
    this.openUrl,
    this.isSingleRunning,
    this.workflowAppHref,
    this.pluginInstallLocked,
  });

  /// accessControl.canEdit / canRun / canImportExportDSL.
  final bool canEdit;
  final bool canRun;
  final bool canImportExportDsl;

  /// useIsChatMode (a chatflow).
  final bool isChatMode;

  /// A snippet canvas (no "Import App").
  final bool isSnippetCanvas;

  /// useWorkflowMoveMode isCommentModeAvailable (collaboration on).
  final bool commentModeAvailable;

  /// The workspace may create snippets (`snippets.create_and_modify`).
  final bool canCreateSnippet;

  /// The server's `app_dsl_version`, stamped on clipboard contents.
  final String appDslVersion;

  /// The docs product for "View Docs": `self-host`, or `cloud` on Dify Cloud.
  final String docsProduct;

  /// "Add Node" on the pane: the block selector, placing at [at] (canvas coordinates).
  final void Function(Offset at)? onAddBlock;

  /// operator/hooks.ts handleAddNote.
  final VoidCallback? onAddNote;

  /// useWorkflowStartRun: handleStartWorkflowRun, or handleWorkflowStartRunInChatflow in a chatflow.
  final VoidCallback? onRun;

  /// useDSL exportCheck.
  final VoidCallback? onExportDsl;

  /// "Change Node": the block selector replacing [nodeId], connected from [sourceHandle].
  final void Function(String nodeId, String sourceHandle)? onChangeBlock;

  /// "Create Snippet" from the selected nodes.
  final void Function(List<String> nodeIds)? onCreateSnippet;

  /// Opens a link (View Docs, Open Workflow) in a browser.
  final void Function(String url)? openUrl;

  /// Whether a node is being single-run (Dify's `data._singleRunningStatus === running`).
  final bool Function(String nodeId)? isSingleRunning;

  /// The app a workflow-tool node runs (`/app/<id>/workflow`), from the workspace's workflow tools.
  final String? Function(Node node)? workflowAppHref;

  /// Whether a node waits for its plugin to be installed (node-control hides on hover).
  final bool Function(Node node)? pluginInstallLocked;
}

/// selection-contextmenu.tsx AlignType.
enum AlignType { left, center, right, top, middle, bottom, distributeHorizontal, distributeVertical }

/// A node as alignment sees it: its position (relative to its container, as React Flow's) and its React Flow size
/// (null until measured).
typedef AlignNode = ({String id, Offset position, Size? size});

typedef AlignBounds = ({double minX, double maxX, double minY, double maxY});

/// getAlignBounds: the box around the measured nodes; null with fewer than two.
AlignBounds? alignBounds(List<AlignNode> nodes) {
  final valid = [
    for (final n in nodes)
      if (n.size != null && !n.size!.isEmpty) n,
  ];
  if (valid.length <= 1) return null;
  var b = (minX: double.infinity, maxX: -double.infinity, minY: double.infinity, maxY: -double.infinity);
  for (final n in valid) {
    b = (
      minX: b.minX < n.position.dx ? b.minX : n.position.dx,
      maxX: b.maxX > n.position.dx + n.size!.width ? b.maxX : n.position.dx + n.size!.width,
      minY: b.minY < n.position.dy ? b.minY : n.position.dy,
      maxY: b.maxY > n.position.dy + n.size!.height ? b.maxY : n.position.dy + n.size!.height,
    );
  }
  return b;
}

/// alignNodePosition for each measured node: the new positions.
Map<String, Offset> alignPositions(List<AlignNode> nodes, AlignType type, AlignBounds b) => {
  for (final n in nodes)
    if (n.size != null && !n.size!.isEmpty)
      n.id: switch (type) {
        AlignType.left => Offset(b.minX, n.position.dy),
        AlignType.center => Offset(b.minX + (b.maxX - b.minX) / 2 - n.size!.width / 2, n.position.dy),
        AlignType.right => Offset(b.maxX - n.size!.width, n.position.dy),
        AlignType.top => Offset(n.position.dx, b.minY),
        AlignType.middle => Offset(n.position.dx, b.minY + (b.maxY - b.minY) / 2 - n.size!.height / 2),
        AlignType.bottom => Offset(n.position.dx, (b.maxY - n.size!.height).roundToDouble()),
        _ => n.position,
      },
};

/// distributeNodes: the first and last nodes along the axis stay, the others get equal gaps; null with fewer than
/// three nodes or no room.
Map<String, Offset>? distributePositions(List<AlignNode> nodes, AlignType type) {
  final horizontal = type == AlignType.distributeHorizontal;
  double pos(AlignNode n) => horizontal ? n.position.dx : n.position.dy;
  double len(AlignNode n) => horizontal ? (n.size?.width ?? 0) : (n.size?.height ?? 0);
  final sorted = [...nodes]..sort((a, b) => pos(a).compareTo(pos(b)));
  if (sorted.length < 3) return null;
  final total = pos(sorted.last) + len(sorted.last) - pos(sorted.first);
  final fixed = sorted.fold(0.0, (s, n) => s + len(n));
  final spacing = (total - fixed) / (sorted.length - 1);
  if (spacing <= 0) return null;
  var at = pos(sorted.first) + len(sorted.first);
  final out = <String, Offset>{};
  for (final n in sorted.sublist(1, sorted.length - 1)) {
    final next = at + spacing;
    out[n.id] = horizontal ? Offset(next, n.position.dy) : Offset(n.position.dx, next);
    at = next + len(n);
  }
  return out;
}

/// utils/node.ts genNewNodeTitleFromOld: `X` → `X (1)`, `X (1)` → `X (2)`.
String genNewNodeTitleFromOld(String old) {
  final m = RegExp(r'^(.+?)\s*\((\d+)\)\s*$').firstMatch(old);
  return m == null ? '$old (1)' : '${m[1]} (${int.parse(m[2]!) + 1})';
}

/// The container a node is in (Dify's `parentId`).
String? parentIdOf(Node n) => CanvasGraph.parentOf(n);

/// Nodes the menus never offer (handleNodeContextMenu stops on them): notes, iteration and loop starts.
bool hasNoNodeMenu(Node n) => isNoteNode(n) || n.type == 'iteration-start' || n.type == 'loop-start';

/// React Flow's nested z-index (constants.ts NESTED_ELEMENT_Z_INDEX).
const _nestedZ = 1001;

/// The actions behind the canvas menus, the node control and the shortcuts: Dify's useNodesInteractions,
/// useEdgesInteractions, usePanelInteractions, useSelectionInteractions and the node actions menu model, as edits
/// through [controller] (one undo step per action) and state in [store]. Selection is the canvas's: several
/// selected nodes are Dify's box-selected ("bundled") nodes, one is its selected node.
class WorkflowActions {
  WorkflowActions({
    required this.controller,
    required this.canvas,
    required this.store,
    this.options = const WorkflowMenuOptions(),
  });

  final EditorController controller;
  final CanvasController canvas;
  final WorkflowStore store;
  final WorkflowMenuOptions options;

  Document get doc => controller.doc;
  bool get chatMode => options.isChatMode;
  NodeMeta? metaOf(Node n) => nodeMetaOf(n.type, chatMode: chatMode);

  // ----- read-only states (use-workflow.ts) -----

  /// A run is going (or paused), a past version is shown or being restored.
  bool get workflowOperationReadOnly {
    final status = switch (store.workflowRunningData.value?['result']) {
      final Map<String, Object?> r => r['status'],
      _ => null,
    };
    return status == 'running' ||
        status == 'paused' ||
        store.historyWorkflowData.value != null ||
        store.isRestoring.value;
  }

  /// useNodesReadOnly.
  bool get nodesReadOnly => store.canvasReadOnly.value || !options.canEdit || workflowOperationReadOnly;

  /// The store fields the read-only states depend on.
  Listenable get readOnlyChanges =>
      Listenable.merge([store.canvasReadOnly, store.workflowRunningData, store.historyWorkflowData, store.isRestoring]);

  // ----- selection -----

  /// The selected nodes, in selection order.
  List<Node> get selectedNodes => [
    for (final s in canvas.selection.nodes)
      if (canvas.graph?.slots.elementAtOrNull(s)?.id case final id? when doc.nodes[id] != null) doc.nodes[id]!,
  ];

  bool _isBundled(String id) {
    final slot = canvas.graph?[id]?.slot;
    return canvas.selection.nodes.length > 1 && slot != null && canvas.selection.nodes.contains(slot);
  }

  /// handleNodeSelect.
  void selectNode(String id) {
    final slot = canvas.graph?[id]?.slot;
    if (slot != null) canvas.selection.selectNodes([slot]);
    controller.selectNode(id);
  }

  /// React Flow's size of a node (its card and frame), or null when unknown.
  Size? sizeOf(Node n) {
    final c = canvas.graph?[n.id];
    if (c != null) return c.layout.visual.isEmpty ? null : Size(c.layout.visual.width + 2, c.layout.visual.height + 2);
    double? num(Value? v) => switch (v) {
      VInt(:final value) => value.toDouble(),
      VDouble(:final value) => value,
      _ => null,
    };
    final extra = n.config['_dify_node'];
    if (extra is! VMap) return null;
    final w = num(extra.entries['width']), h = num(extra.entries['height']);
    return w == null || h == null ? null : Size(w, h);
  }

  // ----- edits -----

  void _submit(Op op) {
    controller.undo.record(op);
    controller.session.edit(op);
  }

  /// Runs [edit] as one undo step.
  void _step(HistoryEvent event, String? nodeId, void Function() edit) {
    controller.undo.begin(event, nodeId: nodeId);
    try {
      edit();
    } finally {
      controller.undo.end();
    }
  }

  // ----- context menu targets -----

  /// usePanelInteractions handlePaneContextMenu: the pane menu, with the system clipboard synced into the store
  /// first (Paste Here is disabled while the clipboard is empty).
  void handlePaneContextMenu() {
    unawaited(
      readWorkflowClipboard(options.appDslVersion).then((r) {
        if (r.nodes.isNotEmpty) store.setClipboardData(nodes: r.nodes, edges: r.edges);
      }),
    );
    store.setContextMenuTarget(WorkflowContextMenuTarget.panel);
  }

  void handlePaneContextmenuCancel() => store.setContextMenuTarget(null);

  /// handleNodeContextMenu: the node menu (selecting the node); false for nodes without one.
  bool handleNodeContextMenu(String nodeId) {
    final n = doc.nodes[nodeId];
    if (n == null || hasNoNodeMenu(n)) return false;
    store.setContextMenuTarget(NodeContextMenuTarget(nodeId));
    selectNode(nodeId);
    return true;
  }

  /// handleEdgeContextMenu: selects the edge alone and targets it; false while read-only.
  bool handleEdgeContextMenu(String edgeId) {
    if (nodesReadOnly) return false;
    canvas.selection.selectEdge(edgeId);
    controller.selectEdge(edgeId);
    store.setContextMenuTarget(EdgeContextMenuTarget(edgeId));
    return true;
  }

  /// handleSelectionContextMenu: only on the selection's box.
  bool handleSelectionContextMenu({required bool onSelectionRect}) {
    if (!onSelectionRect) return false;
    store.setContextMenuTarget(WorkflowContextMenuTarget.selection);
    return true;
  }

  // ----- single run -----

  bool isSingleRunning(String nodeId) => options.isSingleRunning?.call(nodeId) ?? false;

  /// "Run this step" / "Stop run": asks the panel to run or stop the node, on its last-run tab.
  void runStep(String nodeId) {
    store
      ..setInitShowLastRunTab(true)
      ..setPendingSingleRun((
        nodeId: nodeId,
        action: isSingleRunning(nodeId) ? SingleRunAction.stop : SingleRunAction.run,
      ));
    selectNode(nodeId);
  }

  // ----- copy, paste, duplicate -----

  /// isNodeCopyable: never starts, loop ends, knowledge bases, empty data sources, container starts or singletons.
  bool isNodeCopyable(Node n) {
    if (n.type == 'iteration-start' || n.type == 'loop-start') return false;
    if (const {'start', 'loop-end', 'knowledge-index', 'datasource-empty'}.contains(n.type)) return false;
    if (isNoteNode(n)) return true;
    final meta = metaOf(n);
    return meta != null && !meta.isSingleton;
  }

  /// handleNodesCopy: [nodeId], else the box-selected nodes (not those inside containers), else the selected node;
  /// containers bring their children, and the edges between copied nodes come along.
  void copyNodes([String? nodeId]) {
    if (nodesReadOnly) return;
    var toCopy = <Node>[];
    if (nodeId != null) {
      final n = doc.nodes[nodeId];
      if (n != null && isNodeCopyable(n)) toCopy = [n];
    } else {
      final selected = selectedNodes;
      if (selected.length > 1) {
        toCopy = [
          for (final n in selected)
            if (isNodeCopyable(n) && (isNoteNode(n) || parentIdOf(n) == null)) n,
        ];
      }
      if (toCopy.isEmpty && selected.length == 1 && isNodeCopyable(selected.single)) toCopy = selected;
    }
    if (toCopy.isEmpty) return;
    final copied = {for (final n in toCopy) n.id: n};
    final queue = [
      for (final n in toCopy)
        if (n.type == 'iteration' || n.type == 'loop') n.id,
    ];
    while (queue.isNotEmpty) {
      final parent = queue.removeAt(0);
      for (final n in doc.nodes.values) {
        if (parentIdOf(n) != parent || copied.containsKey(n.id)) continue;
        copied[n.id] = n;
        if (n.type == 'iteration' || n.type == 'loop') queue.add(n.id);
      }
    }
    final data = (
      nodes: [for (final n in copied.values) difyNodeOf(n)],
      edges: [
        for (final e in doc.edges.values)
          if (copied.containsKey(e.source) && copied.containsKey(e.target)) difyEdgeOf(e, doc),
      ],
    );
    store.setClipboardData(nodes: data.nodes, edges: data.edges);
    unawaited(writeWorkflowClipboard(data, options.appDslVersion).catchError((Object _) {}));
  }

  /// Where pasted nodes go: the pointer's last position on the canvas.
  Offset get pastePosition {
    final m = store.mousePosition.value;
    return canvas.view.toCanvas(Offset(m.elementX, m.elementY));
  }

  /// handleNodesPaste: the system clipboard (else the store's) is pasted with its top-left at the pointer, with new
  /// ids, titles made unique, containers with a new start node and their children, and the edges between pasted
  /// nodes; into the selected iteration or loop when one is selected and is not itself being pasted.
  Future<void> pasteNodes() async {
    if (nodesReadOnly) return;
    final read = await readWorkflowClipboard(options.appDslVersion);
    final fromSystem = read.nodes.isNotEmpty;
    if (fromSystem) store.setClipboardData(nodes: read.nodes, edges: read.edges);
    final elements = (fromSystem ? read.nodes : store.clipboardElements.value).where(isClipboardNodeStructurallyValid);
    final clipEdges = (fromSystem ? read.edges : store.clipboardEdges.value).where(isClipboardEdgeStructurallyValid);

    String typeOf(DifyJson n) => ((n['data'] as Map)['type'] as String?) ?? '';
    bool known(DifyJson n) => n['type'] == 'custom-note' || nodeMetaOf(typeOf(n), chatMode: chatMode) != null;
    bool isStart(DifyJson n) => n['type'] == 'custom-iteration-start' || n['type'] == 'custom-loop-start';
    String? parentOf(DifyJson n) => n['parentId'] as String?;
    Offset positionOf(DifyJson n) =>
        Offset(((n['position'] as Map)['x'] as num).toDouble(), ((n['position'] as Map)['y'] as num).toDouble());

    final compatible = elements.where(known).toList();
    if (compatible.isEmpty) return;
    final ids = {for (final n in compatible) n['id']};
    final roots = [
      for (final n in compatible)
        if (parentOf(n) == null || !ids.contains(parentOf(n))) n,
    ];
    final reference = roots.isNotEmpty ? roots : compatible;
    var topLeft = const Offset(double.infinity, double.infinity);
    for (final n in reference) {
      final p = positionOf(n);
      topLeft = Offset(p.dx < topLeft.dx ? p.dx : topLeft.dx, p.dy < topLeft.dy ? p.dy : topLeft.dy);
    }
    final offset = pastePosition - topLeft;
    final titles = {for (final n in doc.nodes.values) n.title};
    String uniqueTitle(String t) {
      while (titles.contains(t)) {
        t = genNewNodeTitleFromOld(t);
      }
      titles.add(t);
      return t;
    }

    final selected = selectedNodes;
    final container =
        selected.length == 1 &&
            (selected.single.type == 'iteration' || selected.single.type == 'loop') &&
            !ids.contains(selected.single.id)
        ? selected.single
        : null;
    const nestedDisallowed = {'end', 'iteration', 'loop', 'datasource', 'knowledge-index'};

    final idMapping = <String, String>{};
    final pasted = <Node>[];

    // A pasted node's Dify JSON: [source] with [data] and [top] fields changed.
    Node build(DifyJson source, String id, Map<String, Object?> data, Map<String, Object?> top, Offset position) {
      final srcData = (source['data'] as Map).cast<String, Object?>();
      final json = <String, Object?>{
        ...source,
        ...top,
        'id': id,
        'position': {'x': position.dx, 'y': position.dy},
        'data': {
          ...srcData,
          'desc': srcData['desc'] is String ? srcData['desc'] : '',
          ...data,
          'title': uniqueTitle(srcData['title'] is String ? srcData['title']! as String : 'Node'),
        },
      };
      json.removeWhere((k, v) => v == null);
      (json['data']! as Map).removeWhere((k, v) => v == null);
      return nodeFromDify(json, doc, id: id);
    }

    for (final root in roots) {
      final type = typeOf(root);
      if (container != null && nestedDisallowed.contains(type)) continue;
      final id = newId('n');
      final isIteration = type == 'iteration', isLoop = type == 'loop';
      final data = <String, Object?>{
        'isInIteration': false,
        'iteration_id': null,
        'isInLoop': false,
        'loop_id': null,
        if (isIteration || isLoop) 'start_node_id': '${id}start',
      };
      final top = <String, Object?>{'zIndex': 0, 'parentId': null, 'extent': null};
      var position = positionOf(root) + offset;
      if (container != null && !isIteration && !isLoop) {
        final inIteration = container.type == 'iteration';
        data
          ..['isInIteration'] = inIteration
          ..['iteration_id'] = inIteration ? container.id : null
          ..['isInLoop'] = !inIteration
          ..['loop_id'] = inIteration ? null : container.id;
        top
          ..['parentId'] = container.id
          ..['zIndex'] = _nestedZ;
        position -= Offset(container.x.toDouble(), container.y.toDouble());
      }
      try {
        pasted.add(build(root, id, data, top, position));
      } on FormatException {
        continue;
      }
      idMapping[root['id']! as String] = id;
      if (!isIteration && !isLoop) continue;

      // getIterationStartNode / getLoopStartNode, then the copied children.
      final startId = '${id}start';
      pasted.add(
        Node(
          id: startId,
          type: isIteration ? 'iteration-start' : 'loop-start',
          x: 24,
          y: 68,
          config: {
            'desc': const VString(''),
            if (isIteration) 'isInIteration': const VBool(true) else 'isInLoop': const VBool(true),
            '_dify_node': VMap({
              'type': VString(isIteration ? 'custom-iteration-start' : 'custom-loop-start'),
              'parentId': VString(id),
              'zIndex': const VInt(_nestedZ),
              'selectable': const VBool(false),
              'draggable': const VBool(false),
              'sourcePosition': const VString('right'),
              'targetPosition': const VString('left'),
            }),
          },
        ),
      );
      for (final n in compatible) {
        if (parentOf(n) == root['id'] && isStart(n)) idMapping[n['id']! as String] = startId;
      }
      for (final child in compatible) {
        if (parentOf(child) != root['id'] || isStart(child)) continue;
        final childId = newId('n');
        try {
          pasted.add(
            build(
              child,
              childId,
              {
                'isInIteration': isIteration,
                'iteration_id': isIteration ? id : null,
                'isInLoop': isLoop,
                'loop_id': isLoop ? id : null,
              },
              {'parentId': id, 'zIndex': _nestedZ},
              positionOf(child),
            ),
          );
          idMapping[child['id']! as String] = childId;
        } on FormatException {
          continue;
        }
      }
    }
    if (pasted.isEmpty) return;

    final edges = <Edge>[];
    for (final e in clipEdges) {
      final s = idMapping[e['source']], t = idMapping[e['target']];
      if (s == null || t == null) continue;
      final sh = e['sourceHandle'] as String? ?? 'source', th = e['targetHandle'] as String? ?? 'target';
      edges.add(Edge(id: '$s-$sh-$t-$th', source: s, sourceHandle: sh, target: t, targetHandle: th));
    }
    _step(HistoryEvent.nodePaste, null, () {
      for (final n in pasted) {
        _submit(AddNode(n));
      }
      for (final e in edges) {
        _submit(AddEdge(e));
      }
    });
  }

  /// handleNodesDuplicate: copy, then paste at the pointer.
  Future<void> duplicateNodes([String? nodeId]) async {
    if (nodesReadOnly) return;
    copyNodes(nodeId);
    await pasteNodes();
  }

  // ----- delete -----

  /// handleNodeDelete: not undeletable nodes; a container's children go with it (asking first when it holds more
  /// than its start node, unless it is box-selected). One undo step.
  void deleteNode(String nodeId) {
    if (nodesReadOnly) return;
    final n = doc.nodes[nodeId];
    if (n == null) return;
    _step(isNoteNode(n) ? HistoryEvent.noteDelete : HistoryEvent.nodeDelete, nodeId, () => _deleteNode(nodeId));
  }

  void _deleteNode(String nodeId) {
    final n = doc.nodes[nodeId];
    if (n == null || (metaOf(n)?.isUndeletable ?? false)) return;
    store.deleteNodeInspectVars(nodeId);
    if (n.type == 'iteration' || n.type == 'loop') {
      final children = [
        for (final c in doc.nodes.values)
          if (parentIdOf(c) == nodeId) c.id,
      ];
      if (children.length > 1 && !_isBundled(nodeId)) {
        if (store.showConfirm.value == null) {
          final kind = n.type == 'iteration' ? 'iteration' : 'loop';
          store.setShowConfirm((
            title: DifyI18n.tr('workflow', 'nodes.$kind.deleteTitle'),
            desc: DifyI18n.tr('workflow', 'nodes.$kind.deleteDesc'),
            onConfirm: () {
              _step(HistoryEvent.nodeDelete, nodeId, () {
                children.forEach(_deleteNode);
                _deleteNode(nodeId);
              });
              store.setShowConfirm(null);
            },
          ));
        }
        return;
      }
      children.forEach(_deleteNode);
    }
    controller.deleteNode(nodeId);
  }

  /// The Delete shortcut (handleNodesDelete, then handleEdgeDelete): the box-selected nodes, else the selected edge,
  /// else the selected node.
  void deleteSelection() {
    if (nodesReadOnly) return;
    final selected = selectedNodes;
    if (selected.length > 1) {
      _step(HistoryEvent.nodeDelete, selected.first.id, () {
        for (final n in selected) {
          _deleteNode(n.id);
        }
      });
      return;
    }
    final edge = canvas.selection.edge ?? controller.selectedEdgeId;
    if (edge != null) return deleteEdge(edge);
    if (selected.length == 1) deleteNode(selected.single.id);
  }

  void _clearEdgeMenu(Iterable<String> edgeIds) {
    final t = store.contextMenuTarget.value;
    if (t is EdgeContextMenuTarget && edgeIds.contains(t.edgeId)) store.setContextMenuTarget(null);
  }

  /// handleEdgeDeleteById.
  void deleteEdge(String edgeId) {
    if (nodesReadOnly || !doc.edges.containsKey(edgeId)) return;
    controller.deleteEdge(edgeId);
    _clearEdgeMenu([edgeId]);
  }

  /// handleEdgeDeleteByDeleteBranch: the edges leaving [nodeId] from [branchId], as one undo step.
  void deleteBranch(String nodeId, String branchId) {
    if (nodesReadOnly) return;
    final ids = [
      for (final e in doc.edges.values)
        if (e.source == nodeId && e.sourceHandle == branchId) e.id,
    ];
    if (ids.isEmpty) return;
    _step(HistoryEvent.edgeDeleteByDeleteBranch, nodeId, () => ids.forEach(controller.deleteEdge));
    _clearEdgeMenu(ids);
  }

  // ----- alignment (selection-contextmenu.tsx handleAlignNodes) -----

  /// Aligns or distributes the selected nodes (not the children of selected containers); one undo step
  /// (NodeDragStop). Returns whether anything moved.
  bool alignNodes(AlignType type) {
    final selected = selectedNodes;
    if (nodesReadOnly || selected.length <= 1) return false;
    store.setNodeAnimation(false);
    final ids = {for (final n in selected) n.id};
    final nodes = [
      for (final n in selected)
        if (!ids.contains(parentIdOf(n))) (id: n.id, position: Offset(n.x.toDouble(), n.y.toDouble()), size: sizeOf(n)),
    ];
    if (nodes.length <= 1) return false;
    final bounds = alignBounds(nodes);
    if (bounds == null) return false;
    final positions = type == AlignType.distributeHorizontal || type == AlignType.distributeVertical
        ? distributePositions(nodes, type)
        : alignPositions(nodes, type, bounds);
    if (positions == null) return false;
    // A box selection outlives the edit only without a node selected for the panel (the canvas would reselect it).
    if (selected.length > 1 && controller.selectedNodeId != null) controller.selectNode(null);
    _step(HistoryEvent.nodeDragStop, null, () {
      for (final MapEntry(key: id, value: p) in positions.entries) {
        final n = doc.nodes[id]!;
        if (n.x != p.dx.round() || n.y != p.dy.round()) controller.moveNode(id, p.dx.round(), p.dy.round());
      }
    });
    store
      ..setHelpLineHorizontal()
      ..setHelpLineVertical();
    return true;
  }
}
