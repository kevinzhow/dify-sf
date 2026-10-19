import 'dart:math' as math;

import 'package:collab_client/collab_client.dart';
import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../canvas/canvas_controller.dart';
import '../../canvas/canvas_graph.dart';
import '../../cards/bodies/note_body.dart'
    show NoteResizeGlyph, isNoteCard, noteMinHeight, noteMinWidth, noteResizeButton;
import '../../design/dify_tokens.g.dart';
import '../../editor/editor_controller.dart';
import '../../editor/undo_manager.dart' show HistoryEvent;
import '../../i18n/dify_i18n.dart';
import '../context_menu/context_menu.dart' show WorkflowActions, WorkflowMenuOptions;
import '../node_panel/resize_handle.dart' show ResizeSide, keyboardResizeValue;
import '../note_node/note_node.dart' show NoteActions;
import '../store/store.dart';

/// NodeResizer's limits for containers (`minWidth = 258`, `minHeight = 152`).
const containerMinWidth = 258.0, containerMinHeight = 152.0;

/// `ITERATION_PADDING` / `LOOP_PADDING`: the room a container keeps right of and below its children.
const _containerPaddingRight = 16.0, _containerPaddingBottom = 20.0;

/// The canvas nodes that carry a NodeResizer: iterations and loops (node.tsx), and notes (note-node/index.tsx).
bool hasNodeResizer(CanvasNode n) => n.type == 'iteration' || n.type == 'loop' || isNoteCard(n.node.value);

/// The node's size as React Flow has it (`width`/`height`, kept in `_dify_node`; a note's `data.width`/`height`),
/// which NodeResizer resizes; the card's layout size when the document has none.
Size nodeResizerSize(CanvasNode node) {
  double? num(Value? v) => switch (v) {
    VInt(:final value) => value.toDouble(),
    VDouble(:final value) => value,
    _ => null,
  };
  final config = node.node.value.config, extra = config['_dify_node'];
  final rf = extra is VMap ? extra.entries : const <String, Value>{};
  return Size(
    num(rf['width']) ?? num(config['width']) ?? node.size.width,
    num(rf['height']) ?? num(config['height']) ?? node.size.height,
  );
}

/// handleNodeResize's writes for [nodeId]: a note's through [NoteActions.writeSize]; a container's `width`/`height`
/// both in its data and in `_dify_node` (React Flow's size, which its card is drawn at).
void writeNodeResizerSize(EditorController controller, String nodeId, Size size) {
  final n = controller.doc.nodes[nodeId];
  if (n == null) return;
  if (isNoteCard(n)) return NoteActions(controller, nodeId).writeSize(size);
  final w = VInt(size.width.round()), h = VInt(size.height.round());
  for (final (path, v) in [
    (const ['_dify_node', 'width'], w),
    (const ['_dify_node', 'height'], h),
    (const ['width'], w),
    (const ['height'], h),
  ]) {
    if (ConfigTree.get(n.config, path) != v) controller.setConfig(nodeId, path, v);
  }
}

/// NodeResizer's keyboard limits for [node]: its minimum, raised to fit its children (with the container padding).
Size nodeResizerMinSize(CanvasNode node, Iterable<CanvasNode> children) {
  final note = isNoteCard(node.node.value);
  var w = note ? noteMinWidth : containerMinWidth, h = note ? noteMinHeight : containerMinHeight;
  for (final c in children) {
    w = math.max(w, c.rect.right - node.rect.left + _containerPaddingRight);
    h = math.max(h, c.rect.bottom - node.rect.top + _containerPaddingBottom);
  }
  return Size(w, h);
}

/// The resize controls of the canvas (nodes/_base/components/node-resizer.tsx), for iteration and loop containers and
/// for notes the canvas draws (the selected note, edited live, has its own): a 24 px button at the node's bottom-right
/// corner, shown while the node is hovered, selected or the button has the keyboard focus (it stays in the tab
/// order). Dragging it resizes the node from that corner (one undo step), not below its minimum; the arrow keys
/// resize by 8 px (32 with Shift), Home shrinks the node as far as its children allow, a click does too. None on a
/// read-only canvas.
class NodeResizers extends StatelessWidget {
  const NodeResizers({super.key, required this.controller, required this.canvas, this.options});

  final EditorController controller;
  final CanvasController canvas;
  final WorkflowMenuOptions? options;

  @override
  Widget build(BuildContext context) {
    final graph = canvas.graph;
    final actions = WorkflowActions(
      controller: controller,
      canvas: canvas,
      store: WorkflowStoreScope.of(context),
      options: options ?? const WorkflowMenuOptions(),
    );
    if (graph == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: Listenable.merge([
        canvas.view,
        canvas.selection,
        canvas.liveCard,
        controller,
        actions.readOnlyChanges,
      ]),
      builder: (context, _) {
        if (actions.nodesReadOnly) return const SizedBox.shrink();
        final live = canvas.liveCard.value?.nodeId;
        final view = canvas.view;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            for (final n in graph.nodes)
              if (hasNodeResizer(n) && n.id != live)
                () {
                  final button = noteResizeButton(n.size).shift(n.rect.topLeft);
                  final rect = Rect.fromPoints(view.toScreen(button.topLeft), view.toScreen(button.bottomRight));
                  return Positioned.fromRect(
                    key: ValueKey('resizer-${n.id}'),
                    rect: rect,
                    child: _NodeResizer(
                      node: n,
                      controller: controller,
                      canvas: canvas,
                      children: [
                        for (final c in graph.nodes)
                          if (c.parentId == n.id) c,
                      ],
                    ),
                  );
                }(),
          ],
        );
      },
    );
  }
}

class _NodeResizer extends StatefulWidget {
  const _NodeResizer({required this.node, required this.controller, required this.canvas, required this.children});
  final CanvasNode node;
  final EditorController controller;
  final CanvasController canvas;
  final List<CanvasNode> children;

  @override
  State<_NodeResizer> createState() => _NodeResizerState();
}

class _NodeResizerState extends State<_NodeResizer> {
  final _focus = FocusNode(debugLabel: 'node resizer');
  bool _hovered = false;
  Size? _from;
  Offset _start = Offset.zero;
  bool _dragged = false;

  void _write(Size size) => writeNodeResizerSize(widget.controller, widget.node.id, size);

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  bool get _isNote => isNoteCard(widget.node.node.value);
  Size get _min =>
      _isNote ? const Size(noteMinWidth, noteMinHeight) : const Size(containerMinWidth, containerMinHeight);

  /// `resizeWithKeyboard`: the next size for [key] (Home: the smallest that fits the children), one undo step.
  bool _keyboardResize(LogicalKeyboardKey key) {
    final kb = HardwareKeyboard.instance;
    final size = nodeResizerSize(widget.node), min = nodeResizerMinSize(widget.node, widget.children);
    double? next(ResizeSide side, double value, double lower) => keyboardResizeValue(
      key,
      side: side,
      value: value,
      min: lower,
      shift: kb.isShiftPressed,
      alt: kb.isAltPressed,
      ctrl: kb.isControlPressed,
      meta: kb.isMetaPressed,
    );
    final w = next(ResizeSide.right, size.width, min.width), h = next(ResizeSide.bottom, size.height, min.height);
    if (w == null && h == null) return false;
    widget.controller.undo.begin(HistoryEvent.nodeResize, nodeId: widget.node.id);
    try {
      _write(Size(w ?? size.width, h ?? size.height));
    } finally {
      widget.controller.undo.end();
    }
    return true;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    // Enter / Space click the button (a click shrinks to fit), and go no further.
    if (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.space || k == LogicalKeyboardKey.numpadEnter) {
      _keyboardResize(LogicalKeyboardKey.home);
      return KeyEventResult.handled;
    }
    return _keyboardResize(k) ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  void _panStart(DragStartDetails d) {
    _from = nodeResizerSize(widget.node);
    _start = d.globalPosition;
    _dragged = false;
    widget.controller.undo.begin(HistoryEvent.nodeResize, nodeId: widget.node.id);
  }

  void _panUpdate(DragUpdateDetails d) {
    final from = _from;
    if (from == null) return;
    _dragged = true;
    final drag = (d.globalPosition - _start) / widget.canvas.view.scale;
    _write(
      Size(math.max(_min.width, from.width + drag.dx), math.max(_min.height, from.height + drag.dy)),
    );
  }

  void _panEnd([Object? _]) {
    if (_from == null) return;
    _from = null;
    widget.controller.undo.end();
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.node;
    final shown =
        _hovered ||
        _focus.hasFocus ||
        _from != null ||
        widget.canvas.selection.hovered == n.slot ||
        widget.canvas.selection.nodes.contains(n.slot);
    final size = nodeResizerSize(n);
    final help =
        '${DifyI18n.tr('common', 'resize.size', {'width': size.width.round(), 'height': size.height.round()})} '
        '${DifyI18n.tr('common', 'resize.nodeHelp')}';
    final glyph = !_isNote || !(widget.canvas.selection.hovered == n.slot || _hovered);
    // Hidden, it takes no pointer (the node under it does) but stays focusable and named.
    return Opacity(
      opacity: shown ? 1 : 0,
      alwaysIncludeSemantics: true,
      child: Focus(
        focusNode: _focus,
        onKeyEvent: _onKey,
        child: Semantics(
          button: true,
          label: DifyI18n.tr('common', 'resize.node'),
          hint: help,
          onTap: () => _keyboardResize(LogicalKeyboardKey.home),
          child: IgnorePointer(
            ignoring: !shown,
            child: MouseRegion(
              cursor: SystemMouseCursors.resizeDownRight,
              onEnter: (_) => setState(() => _hovered = true),
              onExit: (_) => setState(() => _hovered = false),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                excludeFromSemantics: true,
                dragStartBehavior: DragStartBehavior.down,
                onPanStart: _panStart,
                onPanUpdate: _panUpdate,
                onPanEnd: _panEnd,
                onPanCancel: _panEnd,
                onTap: () {
                  _focus.requestFocus();
                  if (_dragged) {
                    _dragged = false;
                    return;
                  }
                  _keyboardResize(LogicalKeyboardKey.home);
                },
                child: Container(
                  decoration: BoxDecoration(
                    color: _hovered ? DifyColors.stateBaseHover : null,
                    borderRadius: BorderRadius.circular(DifyRadius.md),
                    boxShadow: _focus.hasFocus
                        ? [BoxShadow(color: DifyColors.stateAccentSolid, spreadRadius: 2)]
                        : null,
                  ),
                  alignment: Alignment.center,
                  // A hovered note's card draws the glyph itself.
                  child: glyph ? const NoteResizeGlyph() : null,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
