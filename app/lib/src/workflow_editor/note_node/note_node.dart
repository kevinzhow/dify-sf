/// Dify's note node (note-node/**): the sticky note on the canvas. The canvas draws notes read-only (NoteCard, for
/// both renderers); the selected note is edited in place: [LiveNoteBinding] has the canvas draw a live [NoteNode]
/// in its place (in the notes' layer), with the toolbar above it and the resize handle at its corner.
library;

import 'dart:async';
import 'dart:math';

import 'package:collab_client/collab_client.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../../canvas/canvas_controller.dart';
import '../../canvas/canvas_graph.dart' show CanvasNode;
import '../../canvas/live_card.dart';
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
/// note's size; the toolbar and the editor's link popup are drawn outside it and take pointer events there (an
/// [OverflowHitStack]), so on the canvas they belong to the note's layer like Dify's (under later nodes and edges,
/// clipped to the canvas).
class NoteNode extends StatefulWidget {
  const NoteNode({
    super.key,
    required this.data,
    this.selected = false,
    this.hovered = false,
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
  final bool selected, hovered;
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
    return NoteEditorProvider(
      value: data.text,
      editable: editable,
      openUrl: widget.openUrl,
      onInvalidUrl: widget.onInvalidUrl,
      child: OverflowHitStack(
        children: [
          IgnorePointer(
            child: NoteCardView(
              data: data,
              selected: widget.selected,
              hovered: widget.hovered,
              editor: const SizedBox(),
            ),
          ),
          Positioned.fromRect(
            rect: noteEditorRect(data),
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
                // Resize from the actual pointer-down corner, including travel
                // before this handle wins against the canvas gesture recognizer.
                dragStartBehavior: DragStartBehavior.down,
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
          // `absolute -top-10.25 left-1/2 z-40 -translate-x-1/2`.
          if (widget.selected && editable)
            Positioned(
              left: data.width / 2,
              top: -41,
              child: FractionalTranslation(
                translation: const Offset(-0.5, 0),
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
        ],
      ),
    );
  }
}

/// The selected note, edited in place: while exactly one note is selected and the workflow is editable, the canvas
/// draws it as a live [NoteNode] ([CanvasController.liveCard]) in the note's own layer, under the edges and the
/// other nodes and clipped to the canvas, as Dify draws its notes (`.react-flow__node-custom-note { z-index: -1 }`).
/// Its text is written to the document one op per typing pause (700 ms, on blur and when it closes), against the
/// version the typing began on; what others write while nothing is pending comes in.
///
/// Put it inside the editor's store scope, next to the canvas; it draws nothing itself.
class LiveNoteBinding extends StatefulWidget {
  const LiveNoteBinding({
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
  State<LiveNoteBinding> createState() => _LiveNoteBindingState();
}

class _LiveNoteBindingState extends State<LiveNoteBinding> {
  late final WorkflowStore _store = WorkflowStoreScope.of(context);
  late final Listenable _changes = Listenable.merge([
    widget.canvas.selection,
    widget.controller,
    _actions.readOnlyChanges,
  ]);
  ({Offset at, DateTime time})? _lastDown;

  @override
  void initState() {
    super.initState();
    GestureBinding.instance.pointerRouter.addGlobalRoute(_pointer);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _changes
      ..removeListener(_sync)
      ..addListener(_sync);
    // Not while building: the canvas listens.
    SchedulerBinding.instance.addPostFrameCallback((_) => mounted ? _sync() : null);
  }

  @override
  void dispose() {
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_pointer);
    _changes.removeListener(_sync);
    super.dispose();
  }

  void _pointer(PointerEvent e) {
    if (e is PointerDownEvent) _lastDown = (at: e.position, time: DateTime.now());
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

  void _sync() {
    final id = _selectedNote(), live = widget.canvas.liveCard;
    if (live.value?.nodeId == id) return;
    live.value = id == null
        ? null
        : LiveCard(
            nodeId: id,
            builder: (context, node) => _LiveNote(key: ValueKey(id), node: node, binding: this, initialTap: _recentTap),
          );
  }

  /// The click that selected the note (a moment ago) also places the caret (read when the live note first builds).
  Offset? get _recentTap {
    final down = _lastDown;
    return down != null && DateTime.now().difference(down.time) < const Duration(milliseconds: 500) ? down.at : null;
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

class _LiveNote extends StatefulWidget {
  const _LiveNote({super.key, required this.node, required this.binding, this.initialTap});
  final CanvasNode node;
  final _LiveNoteBindingState binding;
  final Offset? initialTap;

  @override
  State<_LiveNote> createState() => _LiveNoteState();
}

class _LiveNoteState extends State<_LiveNote> {
  _LiveNoteBindingState get o => widget.binding;
  EditorController get c => o.widget.controller;
  String get id => widget.node.id;
  late final actions = NoteActions(c, id, preferences: WorkflowStoreScope.preferencesOf(context));

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
    final n = c.doc.nodes[id];
    if (n != null && NoteData.of(n).text != t.toLexical()) actions.editorChange(t, base: base);
  }

  void _resize(Size s) {
    if (_resizing == null) {
      c.undo.begin(HistoryEvent.nodeResize, nodeId: id);
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
    final n = c.doc.nodes[id];
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
    return ValueListenableBuilder(
      valueListenable: widget.node.hovered,
      builder: (context, hovered, _) => NoteNode(
        data: data,
        selected: true,
        hovered: hovered,
        initialTap: widget.initialTap,
        onThemeChange: actions.themeChange,
        onShowAuthorChange: actions.showAuthorChange,
        onEditorChange: _changed,
        setHistoryShortcutsEnabled: (enabled) {
          store.setHistoryShortcutsEnabled(enabled);
          if (enabled) _flush();
        },
        onCopy: () => wa.copyNodes(id),
        onDuplicate: () => unawaited(wa.duplicateNodes(id)),
        onDelete: () => wa.deleteNode(id),
        onResize: _resize,
        onResizeEnd: _endResize,
        openUrl: o.widget.options.openUrl,
        // link-editor-plugin/hooks.ts useLink: toast.error(invalidUrl).
        onInvalidUrl: () => toast.error(DifyI18n.tr('workflow', 'nodes.note.editor.invalidUrl')),
      ),
    );
  }
}
