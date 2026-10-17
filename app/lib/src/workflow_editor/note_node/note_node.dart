/// Dify's note node (note-node/**): the sticky note on the canvas. The canvas draws notes read-only (NoteCard, for
/// both renderers); the selected note is edited in place by [NoteNodeOverlay], a live [NoteNode] over its card at
/// the card's position and scale, with the toolbar above it and the resize handle at its corner.
library;

import 'dart:async';
import 'dart:math';

import 'package:collab_client/collab_client.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import '../../canvas/canvas_controller.dart';
import '../../cards/bodies/note_body.dart';
import '../../cards/bodies/note_text.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../editor/editor_controller.dart';
import '../../editor/undo_manager.dart';
import '../../i18n/dify_i18n.dart';
import '../block_selector/block_defaults.dart' show generateNewNode;
import '../context_menu/workflow_actions.dart';
import '../store/store.dart';
import 'note_editor.dart';
import 'note_toolbar.dart';

export '../../cards/bodies/note_body.dart' show NoteCardView, NoteData, NoteTheme, customNoteNode, isNoteCard;
export 'note_editor.dart';
export 'note_editor_controller.dart';
export 'note_toolbar.dart';

/// operator/hooks.ts handleAddNote: the note a click will place (a candidate), blue, by [author], showing the author
/// unless the stored preference says not to.
DifyJson noteCandidate({required String author, required bool showAuthor, String? id}) => generateNewNode(
  id: id,
  type: customNoteNode,
  data: {
    'title': '',
    'desc': '',
    'type': '',
    'text': '',
    'theme': NoteTheme.blue.name,
    'author': author,
    'showAuthor': showAuthor,
    'width': noteMinWidth.toInt(),
    'height': noteMinHeight.toInt(),
    '_isCandidate': true,
  },
  position: (x: 0, y: 0),
).node;

/// The control bar's and the pane menu's Add Note: puts a [noteCandidate] by this session's user in the store.
void addNoteCandidate(BuildContext context, EditorController controller) {
  final prefs = WorkflowStoreScope.preferencesOf(context);
  WorkflowStoreScope.of(context).setCandidateNode(
    noteCandidate(
      author: controller.session.displayName ?? '',
      showAuthor: prefs?.workflowNoteShowAuthor.value != 'false',
    ),
  );
}

/// note-node/hooks.ts useNote, plus the resizer's handleNodeResize: a note's edits through [controller]. Theme and
/// author visibility are undo steps (NoteChange; the visibility is also stored as the next notes' default), a size
/// change is one (NodeResize, however many writes the drag sends); text is written as typed and, as in Dify, is not
/// in the workflow's history (the editor has its own).
class NoteActions {
  NoteActions(this.controller, this.nodeId, {this.preferences});

  final EditorController controller;
  final String nodeId;
  final WorkflowPreferences? preferences;

  void _step(HistoryEvent event, void Function() edit) {
    controller.undo.begin(event, nodeId: nodeId);
    try {
      edit();
    } finally {
      controller.undo.end();
    }
  }

  /// handleThemeChange.
  void themeChange(NoteTheme theme) =>
      _step(HistoryEvent.noteChange, () => controller.setConfig(nodeId, const ['theme'], VString(theme.name)));

  /// handleShowAuthorChange.
  void showAuthorChange(bool showAuthor) {
    preferences?.workflowNoteShowAuthor.value = '$showAuthor';
    _step(HistoryEvent.noteChange, () => controller.setConfig(nodeId, const ['showAuthor'], VBool(showAuthor)));
  }

  /// handleEditorChange: the editor state as JSON, '' when empty; [base] is the version the typing began on.
  void editorChange(NoteText text, {int? base}) =>
      controller.setConfig(nodeId, const ['text'], VString(text.toLexical()), base: base);

  /// handleNodeResize's writes: `data.width`/`height`, and React Flow's when the node carries them.
  void writeSize(Size size) {
    final n = controller.doc.nodes[nodeId];
    if (n == null) return;
    final w = VInt(size.width.round()), h = VInt(size.height.round());
    final extra = n.config['_dify_node'];
    final hasRf = extra is VMap && extra.entries.containsKey('width');
    for (final (path, v) in [
      (const ['width'], w),
      (const ['height'], h),
      if (hasRf) (const ['_dify_node', 'width'], w),
      if (hasRf) (const ['_dify_node', 'height'], h),
    ]) {
      if (ConfigTree.get(n.config, path) != v) controller.setConfig(nodeId, path, v);
    }
  }

  /// One resize, as one undo step.
  void resize(Size size) => _step(HistoryEvent.nodeResize, () => writeSize(size));
}

/// note-node/index.tsx NoteNode: the note card with its editor (editable unless temporary), and while [selected]
/// (not temporary) the toolbar 41 px above it and the resize handle at its bottom-right corner. Laid out at the
/// note's size; the toolbar and link popup are drawn in the overlay, following the card's transform.
class NoteNode extends StatefulWidget {
  const NoteNode({
    super.key,
    required this.data,
    this.selected = false,
    this.onThemeChange,
    this.onEditorChange,
    this.onShowAuthorChange,
    this.onCopy,
    this.onDuplicate,
    this.onDelete,
    this.setHistoryShortcutsEnabled,
    this.onResize,
    this.onResizeEnd,
    this.openUrl,
    this.onInvalidUrl,
    this.initialTap,
  });

  final NoteData data;
  final bool selected;
  final ValueChanged<NoteTheme>? onThemeChange;
  final ValueChanged<NoteText>? onEditorChange;
  final ValueChanged<bool>? onShowAuthorChange;
  final VoidCallback? onCopy, onDuplicate, onDelete;
  final ValueChanged<bool>? setHistoryShortcutsEnabled;

  /// The resize handle was dragged to this size (at least 240 × 88); [onResizeEnd] when let go.
  final ValueChanged<Size>? onResize;
  final VoidCallback? onResizeEnd;
  final void Function(String url)? openUrl;
  final VoidCallback? onInvalidUrl;
  final Offset? initialTap;

  @override
  State<NoteNode> createState() => _NoteNodeState();
}

class _NoteNodeState extends State<NoteNode> {
  final _toolbar = OverlayPortalController()..show();
  Size? _resizeFrom;
  Offset _drag = Offset.zero;

  void _resize(DragUpdateDetails d) {
    final from = _resizeFrom;
    if (from == null) return;
    _drag += d.delta;
    widget.onResize?.call(
      Size(max(noteMinWidth, from.width + _drag.dx), max(noteMinHeight, from.height + _drag.dy)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final editable = !data.temp;
    final editorRect = noteEditorRect(data);
    final showToolbar = widget.selected && editable;
    return NoteEditorProvider(
      value: data.text,
      editable: editable,
      openUrl: widget.openUrl,
      onInvalidUrl: widget.onInvalidUrl,
      child: Builder(
        builder: (context) => OverlayPortal.overlayChildLayoutBuilder(
          controller: _toolbar,
          overlayChildBuilder: (_, info) {
            if (!showToolbar) return const SizedBox.shrink();
            // `absolute -top-10.25 left-1/2 -translate-x-1/2`, scaled with the card.
            final card = MatrixUtils.transformRect(info.childPaintTransform, Offset.zero & info.childSize);
            final scale = info.childSize.width == 0 ? 1.0 : card.width / info.childSize.width;
            return Stack(
              children: [
                Positioned(
                  left: card.center.dx,
                  top: card.top - 41 * scale,
                  child: Transform.scale(
                    scale: scale,
                    alignment: Alignment.topLeft,
                    child: FractionalTranslation(
                      translation: const Offset(-0.5, 0),
                      child: NoteEditorScope(
                        controller: NoteEditorScope.of(context).controller,
                        focusNode: NoteEditorScope.of(context).focusNode,
                        child: NoteEditorToolbar(
                          theme: data.theme,
                          onThemeChange: (t) => widget.onThemeChange?.call(t),
                          onCopy: () => widget.onCopy?.call(),
                          onDuplicate: () => widget.onDuplicate?.call(),
                          onDelete: () => widget.onDelete?.call(),
                          showAuthor: data.showAuthor,
                          onShowAuthorChange: (v) => widget.onShowAuthorChange?.call(v),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
          child: SizedBox.fromSize(
            size: data.size,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                IgnorePointer(
                  child: NoteCardView(data: data, selected: widget.selected, shadow: false, editor: const SizedBox()),
                ),
                Positioned.fromRect(
                  rect: editorRect,
                  child: NoteEditor(
                    placeholder: DifyI18n.tr('workflow', 'nodes.note.editor.placeholder'),
                    onChange: widget.onEditorChange,
                    setHistoryShortcutsEnabled: widget.setHistoryShortcutsEnabled,
                    initialTap: widget.initialTap,
                  ),
                ),
                if (editable)
                  Positioned.fromRect(
                    rect: noteResizeButton(data.size),
                    child: GestureDetector(
                      onPanStart: (_) {
                        _resizeFrom = data.size;
                        _drag = Offset.zero;
                      },
                      onPanUpdate: _resize,
                      onPanEnd: (_) {
                        _resizeFrom = null;
                        widget.onResizeEnd?.call();
                      },
                      child: DifyPressable(
                        semanticLabel: DifyI18n.tr('common', 'resize.node'),
                        builder: (context, hovered, focused) => Container(
                          decoration: BoxDecoration(
                            color: hovered ? DifyColors.stateBaseHover : null,
                            borderRadius: BorderRadius.circular(DifyRadius.md),
                          ),
                          alignment: Alignment.center,
                          child: const NoteResizeGlyph(),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The selected note, live over its card on the canvas: shown while exactly one note is selected and the workflow
/// is editable, at the card's position and the view's scale, following drags of it. Its text is written to the
/// document one op per typing pause (700 ms, on blur and when it closes), against the version the typing began on;
/// what others write while nothing is pending comes in.
///
/// Put it over the canvas, the same size (the editor's overlay slot), inside the editor's store scope.
class NoteNodeOverlay extends StatefulWidget {
  const NoteNodeOverlay({
    super.key,
    required this.controller,
    required this.canvas,
    this.options = const WorkflowMenuOptions(),
    this.debounce = const Duration(milliseconds: 700),
  });

  final EditorController controller;
  final CanvasController canvas;
  final WorkflowMenuOptions options;
  final Duration debounce;

  @override
  State<NoteNodeOverlay> createState() => _NoteNodeOverlayState();
}

class _NoteNodeOverlayState extends State<NoteNodeOverlay> {
  late final WorkflowStore _store = WorkflowStoreScope.of(context);

  /// Repaints the live note while its card is dragged (the canvas moves cards without telling anyone).
  final _moved = ValueNotifier(0);
  ({Offset at, DateTime time})? _lastDown;

  @override
  void initState() {
    super.initState();
    GestureBinding.instance.pointerRouter.addGlobalRoute(_pointer);
  }

  @override
  void dispose() {
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_pointer);
    _moved.dispose();
    super.dispose();
  }

  void _pointer(PointerEvent e) {
    if (e is PointerDownEvent) _lastDown = (at: e.position, time: DateTime.now());
    if (e is PointerMoveEvent && (widget.canvas.graph?.dragging.isNotEmpty ?? false)) _moved.value++;
  }

  WorkflowActions get _actions => WorkflowActions(
    controller: widget.controller,
    canvas: widget.canvas,
    store: _store,
    options: widget.options,
  );

  /// The selected note, when it is the only selected node and the workflow can be edited.
  String? _selectedNote() {
    final sel = widget.canvas.selection.nodes;
    final g = widget.canvas.graph;
    if (sel.length != 1 || g == null || _actions.nodesReadOnly) return null;
    final n = g.slots.elementAtOrNull(sel.single);
    return n != null && isNoteCard(n.node.value) ? n.id : null;
  }

  @override
  Widget build(BuildContext context) {
    final a = _actions;
    return ListenableBuilder(
      listenable: Listenable.merge([widget.canvas.selection, widget.controller, a.readOnlyChanges]),
      builder: (context, _) {
        final id = _selectedNote();
        if (id == null) return const SizedBox.shrink();
        final down = _lastDown;
        return Stack(
          fit: StackFit.expand,
          children: [
            _LiveNote(
              key: ValueKey(id),
              nodeId: id,
              overlay: this,
              // The click that selected the note (a moment ago) also places the caret.
              initialTap: down != null && DateTime.now().difference(down.time) < const Duration(milliseconds: 500)
                  ? down.at
                  : null,
            ),
          ],
        );
      },
    );
  }
}

class _LiveNote extends StatefulWidget {
  const _LiveNote({super.key, required this.nodeId, required this.overlay, this.initialTap});
  final String nodeId;
  final _NoteNodeOverlayState overlay;
  final Offset? initialTap;

  @override
  State<_LiveNote> createState() => _LiveNoteState();
}

class _LiveNoteState extends State<_LiveNote> {
  _NoteNodeOverlayState get o => widget.overlay;
  EditorController get c => o.widget.controller;
  late final actions = NoteActions(c, widget.nodeId, preferences: WorkflowStoreScope.preferencesOf(context));

  Timer? _timer, _resizeTimer;
  int? _draftBase;
  NoteText? _latest;

  /// The document's text the editor shows; held while a draft is pending so it is not replaced under the typing.
  String _value = '';
  Size? _resizing;

  @override
  void dispose() {
    _flush();
    _endResize();
    super.dispose();
  }

  void _changed(NoteText t) {
    _latest = t;
    _draftBase ??= c.seenVersion;
    _timer?.cancel();
    _timer = Timer(o.widget.debounce, _flush);
  }

  void _flush() {
    _timer?.cancel();
    final base = _draftBase, t = _latest;
    _draftBase = null;
    if (base == null || t == null) return;
    final n = c.doc.nodes[widget.nodeId];
    if (n != null && NoteData.of(n).text != t.toLexical()) actions.editorChange(t, base: base);
  }

  void _resize(Size s) {
    if (_resizing == null) {
      c.undo.begin(HistoryEvent.nodeResize, nodeId: widget.nodeId);
      // Others see the size change as it is dragged, a few times a second.
      _resizeTimer = Timer.periodic(const Duration(milliseconds: 125), (_) {
        if (_resizing != null) actions.writeSize(_resizing!);
      });
    }
    setState(() => _resizing = s);
  }

  void _endResize() {
    final s = _resizing;
    if (s == null) return;
    _resizeTimer?.cancel();
    actions.writeSize(s);
    c.undo.end();
    _resizing = null;
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final n = c.doc.nodes[widget.nodeId];
    final canvas = o.widget.canvas;
    if (n == null) return const SizedBox.shrink();
    var data = NoteData.of(n);
    if (_draftBase == null) _value = data.text;
    final size = _resizing ?? data.size;
    data = NoteData(
      text: _value,
      theme: data.theme,
      author: data.author,
      showAuthor: data.showAuthor,
      width: size.width,
      height: size.height,
    );
    final wa = o._actions;
    final store = o._store;
    final note = NoteNode(
      data: data,
      selected: true,
      initialTap: widget.initialTap,
      onThemeChange: actions.themeChange,
      onShowAuthorChange: actions.showAuthorChange,
      onEditorChange: _changed,
      setHistoryShortcutsEnabled: (enabled) {
        store.setHistoryShortcutsEnabled(enabled);
        if (enabled) _flush();
      },
      onCopy: () => wa.copyNodes(widget.nodeId),
      onDuplicate: () => unawaited(wa.duplicateNodes(widget.nodeId)),
      onDelete: () => wa.deleteNode(widget.nodeId),
      onResize: _resize,
      onResizeEnd: _endResize,
      openUrl: o.widget.options.openUrl,
    );
    return ListenableBuilder(
      listenable: Listenable.merge([canvas.view, o._moved]),
      builder: (context, child) {
        final card = canvas.graph?[widget.nodeId];
        if (card == null) return const SizedBox.shrink();
        final at = canvas.view.toScreen(card.rect.topLeft);
        return Positioned(
          left: at.dx,
          top: at.dy,
          child: Transform.scale(scale: canvas.view.scale, alignment: Alignment.topLeft, child: child),
        );
      },
      child: note,
    );
  }
}
