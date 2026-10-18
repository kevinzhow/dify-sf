import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../canvas/canvas_controller.dart';
import '../canvas/workflow_canvas.dart';
import '../editor/editor_controller.dart';
import 'context_menu/context_menu.dart';
import 'hooks/use_helpline.dart';
import 'hooks/use_workflow.dart';
import 'operator/actions.dart' show OperatorReadOnly;
import 'store/store.dart';
import 'workflow_confirm.dart';

/// Dify's workflow editor page (components/workflow/index.tsx and workflow-app): the canvas filling the area, with
/// the header, the left control bar, the bottom operator bar and the right panels floating over it. The chrome only
/// talks to the canvas through [CanvasController], to the document through [EditorController], and shares the
/// editor's UI state through the [WorkflowStore] it finds with `WorkflowStoreScope.of(context)` (the store's control
/// mode is the canvas's; panel sizes and the control mode are kept in the stored preferences).
///
/// Slots are filled as the chrome is ported; an empty slot draws nothing.
class WorkflowEditor extends StatefulWidget {
  const WorkflowEditor({
    super.key,
    required this.controller,
    this.header,
    this.control,
    this.operator,
    this.panels,
    this.menuOptions = const WorkflowMenuOptions(),
    this.overlay,
    this.modal,
    this.scope,
    this.canEdit = true,
  });

  final EditorController controller;

  /// Dify's `accessControl.canEdit`: false (normal members, dataset operators) makes the canvas read-only
  /// (`nodesReadOnly`, through the store's `canvasReadOnly`).
  final bool canEdit;

  /// header/index.tsx: `absolute top-7 left-0 z-10 flex h-0 w-full items-center justify-between px-3`.
  final Widget Function(BuildContext context, CanvasController canvas)? header;

  /// operator/control.tsx in `absolute top-0 left-0 z-10 flex w-12 items-center justify-center p-1 pl-2`, centred on
  /// the canvas height above the bottom panel.
  final Widget Function(BuildContext context, CanvasController canvas)? control;

  /// operator/index.tsx: `absolute inset-x-0 bottom-0 z-10 px-1`.
  final Widget Function(BuildContext context, CanvasController canvas)? operator;

  /// panel/index.tsx: `absolute top-14 right-0 bottom-1 z-10 flex`.
  final Widget Function(BuildContext context, CanvasController canvas)? panels;

  /// Drawn over the canvas, under the chrome (the candidate node that follows the pointer).
  final Widget Function(BuildContext context, CanvasController canvas)? overlay;

  /// Drawn over everything, chrome included (the features drawer and its backdrop).
  final Widget Function(BuildContext context, CanvasController canvas)? modal;

  /// Wraps everything inside the store's scope (editor-wide services every slot shares: the run host, the variable
  /// inspect data).
  final Widget Function(BuildContext context, CanvasController canvas, Widget child)? scope;

  /// What the context menus, the node "…" bar and the edit shortcuts call for actions that leave the canvas.
  final WorkflowMenuOptions menuOptions;

  @override
  State<WorkflowEditor> createState() => _WorkflowEditorState();
}

class _WorkflowEditorState extends State<WorkflowEditor> {
  final canvas = CanvasController();
  late final store = WorkflowStore(controlMode: canvas.controlMode);
  final preferences = WorkflowPreferences();
  late final bridge = WorkflowLocalStorageBridge(store, preferences);

  @override
  void initState() {
    super.initState();
    bridge; // hydrate the store from the stored preferences as soon as they load
    store.setCanvasReadOnly(!widget.canEdit);
    canvas.isReadOnly = () => store.nodesReadOnly;
    canvas.animatePositions = () => store.nodeAnimation.value;
    canvas.onInteraction = () => store.setNodeAnimation(false);
    // useWorkflow().isValidConnection, with handleNodeConnect's checks.
    canvas.isValidConnection = (source, handle, target) {
      final doc = widget.controller.doc;
      return canConnect(doc, source: source, target: target, sourceHandle: handle) &&
          isValidConnection(doc, source: source, target: target, chatMode: widget.menuOptions.isChatMode);
    };
    // handleNodeDrag's helplines (and the snap onto them), cleared by handleNodeDragStop.
    canvas.onNodeDrag = (id, position) {
      final nodes = helplineNodesOf(canvas);
      final node = nodes.where((n) => n.id == id).firstOrNull;
      if (node == null) return null;
      final dragged = (
        id: node.id,
        type: node.type,
        x: position.dx,
        y: position.dy,
        width: node.width,
        height: node.height,
        inContainer: node.inContainer,
      );
      return snapToHelplines(dragged, handleSetHelpline(store, nodes, dragged));
    };
    canvas.onNodeDragStop = () => store
      ..setHelpLineHorizontal()
      ..setHelpLineVertical();
    // handleNodeConnectStart / handleNodeConnectEnd: who is being connected, for the nodes that react to it.
    canvas.onConnectStart = (id, handle) {
      final n = widget.controller.doc.nodes[id];
      if (store.nodesReadOnly || n == null || isNoteNode(n)) return;
      store.setConnectingNodePayload((nodeId: id, nodeType: n.type, handleType: 'source', handleId: handle));
    };
    canvas.onConnectEnd = () => store
      ..setConnectingNodePayload()
      ..setEnteringNodePayload();
  }

  @override
  void didUpdateWidget(WorkflowEditor old) {
    super.didUpdateWidget(old);
    if (old.canEdit != widget.canEdit) store.setCanvasReadOnly(!widget.canEdit);
  }

  @override
  void dispose() {
    bridge.dispose();
    preferences.dispose();
    store.dispose();
    canvas.dispose();
    super.dispose();
  }

  /// index.tsx: the container's size goes to the store on the next frame, only when it changed.
  void _measured(Size size) {
    if (store.workflowCanvasWidth.value == size.width && store.workflowCanvasHeight.value == size.height) return;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      store
        ..setWorkflowCanvasWidth(size.width)
        ..setWorkflowCanvasHeight(size.height);
    });
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    return WorkflowStoreScope(
      store: store,
      preferences: preferences,
      child: LayoutBuilder(
        builder: (context, constraints) {
          _measured(constraints.biggest);
          final stack = Stack(
            fit: StackFit.expand,
            children: [
              WorkflowShortcuts(
                controller: w.controller,
                canvas: canvas,
                options: w.menuOptions,
                child: WorkflowContextMenus(
                  controller: w.controller,
                  canvas: canvas,
                  options: w.menuOptions,
                  child: WorkflowCanvas(controller: w.controller, canvas: canvas),
                ),
              ),
              Positioned.fill(child: HelpLine(canvas: canvas)),
              if (w.overlay != null) Positioned.fill(child: w.overlay!(context, canvas)),
              if (w.header != null)
                // `absolute top-7 h-0 items-center`: centred 28 px from the top. A 56 px band (not a zero-height box,
                // which hit testing would ignore) lets the controls take clicks; empty parts of it pass them on.
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  height: 56,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Align(alignment: Alignment.center, child: w.header!(context, canvas)),
                  ),
                ),
              if (w.control != null)
                // index.tsx `controlHeight`: the canvas height above the bottom panel once both are known.
                ListenableBuilder(
                  listenable: Listenable.merge([store.workflowCanvasHeight, store.bottomPanelHeight]),
                  builder: (context, child) => Positioned(
                    top: 0,
                    left: 0,
                    bottom: store.workflowCanvasHeight.value == null ? 0 : store.bottomPanelHeight.value,
                    width: 48,
                    child: child!,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
                    // The bar (38 px: 33 px buttons with their 1 px margins, p-0.5, the border) is wider than the
                    // 36 px left for it: like the centred flex item, it overflows both sides evenly.
                    child: OverflowBox(
                      minWidth: 0,
                      maxWidth: double.infinity,
                      minHeight: 0,
                      child: w.control!(context, canvas),
                    ),
                  ),
                ),
              if (w.operator != null)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: w.operator!(context, canvas),
                  ),
                ),
              if (w.panels != null) Positioned(top: 56, right: 0, bottom: 4, child: w.panels!(context, canvas)),
              if (w.modal != null) Positioned.fill(child: w.modal!(context, canvas)),
              // The store's showConfirm, over everything.
              const Positioned.fill(child: WorkflowConfirm()),
            ],
          );
          return w.scope?.call(context, canvas, stack) ?? stack;
        },
      ),
    );
  }
}
