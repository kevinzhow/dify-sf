/// The comment handlers (hooks/use-workflow-comment.ts and comment-manager.tsx): placing, opening, navigating,
/// replying to, editing, resolving, moving and deleting canvas comments. The comments themselves are the store's
/// ([CommentsStore]); the UI state is the editor's [WorkflowStore] (comment-slice, the comment fields of
/// workflow-slice and panel-slice).
library;

import 'dart:math' as math;

import 'package:collab_client/collab_client.dart' show Comment;
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../canvas/canvas_controller.dart';
import '../../canvas/canvas_input.dart' show ControlMode;
import '../../i18n/dify_i18n.dart';
import '../store/workflow_store.dart';
import 'comments_store.dart';

export 'package:collab_client/collab_client.dart' show Comment, CommentMention, CommentReply;

export 'comments_store.dart' show CommentsScope, CommentsStore;

String tw(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('workflow', key, params);

/// A user as the comment UI shows one (Dify's UserProfile): a client id and its display name.
typedef CommentUser = ({String id, String name});

/// The display name of [client]: what the comment says, else the clients directory, else Dify's "User".
String nameOf(CommentsStore source, String client, [String? given]) =>
    (given?.isNotEmpty ?? false) ? given! : source.names[client] ?? tw('comments.fallback.user');

/// The comment's participants with the author first (comment-icon.tsx / comment-preview.tsx `participants`), as
/// Dify's server lists them: the author, the repliers, then the mentioned users, each once.
List<CommentUser> participantsOf(CommentsStore source, Comment c) {
  final seen = <String>{};
  final out = <CommentUser>[];
  void add(String id, [String? name]) {
    if (seen.add(id)) out.add((id: id, name: nameOf(source, id, name)));
  }

  add(c.createdBy, c.createdByName);
  for (final r in c.replies) {
    add(r.createdBy, r.createdByName);
  }
  // Dify drops mentioned users it has no account for.
  for (final m in [...c.mentions, for (final r in c.replies) ...r.mentions]) {
    final name = (m.name?.isNotEmpty ?? false) ? m.name : source.names[m.client];
    if (name != null) add(m.client, name);
  }
  return out;
}

/// The mention candidates (Dify's mentionable users): the clients directory.
List<CommentUser> mentionUsersOf(CommentsStore source) => [
  for (final e in source.names.entries) (id: e.key, name: e.value),
];

/// utils/keyboard-movement.ts getKeyboardMovement: an arrow key moves 5 (20 with Shift); none with Alt, Ctrl or
/// Meta.
Offset? keyboardMovement(KeyEvent e) {
  final k = HardwareKeyboard.instance;
  if (k.isAltPressed || k.isControlPressed || k.isMetaPressed) return null;
  final step = k.isShiftPressed ? 20.0 : 5.0;
  return switch (e.logicalKey) {
    LogicalKeyboardKey.arrowLeft => Offset(-step, 0),
    LogicalKeyboardKey.arrowRight => Offset(step, 0),
    LogicalKeyboardKey.arrowUp => Offset(0, -step),
    LogicalKeyboardKey.arrowDown => Offset(0, step),
    _ => null,
  };
}

/// The runs of [content] that mention one of [names] (`@name` at the start or after whitespace, the longest name
/// winning), as the thread and the mention input highlight them: (start, end) pairs.
List<(int, int)> mentionRanges(String content, Iterable<String> names) {
  final list = {for (final n in names) n.trim()}.where((n) => n.isNotEmpty).toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  final out = <(int, int)>[];
  if (list.isEmpty) return out;
  var cursor = 0;
  while (cursor < content.length) {
    var start = -1;
    var matched = '';
    for (final name in list) {
      final i = content.indexOf('@$name', cursor);
      if (i == -1) continue;
      if (i > 0 && !RegExp(r'\s').hasMatch(content[i - 1])) continue;
      if (start == -1 || i < start || (i == start && name.length > matched.length)) {
        start = i;
        matched = name;
      }
    }
    if (start == -1) break;
    final end = start + matched.length + 1;
    out.add((start, end));
    cursor = end;
  }
  return out;
}

/// The view animation of a canvas (one at a time).
final _viewAnimations = Expando<Ticker>();

/// React Flow's `setCenter(x, y, {zoom, duration})`: the canvas point ([x], [y]) moves to the middle of the view at
/// [zoom], animated with d3's default cubic in-out easing.
Ticker? setCanvasCenter(CanvasController canvas, double x, double y, {double zoom = 1, Duration? duration}) {
  final view = canvas.view;
  _viewAnimations[view]?.dispose();
  _viewAnimations[view] = null;
  final to = Offset(x, y);
  if (duration == null || duration == Duration.zero) {
    view
      ..scale = zoom
      ..center = to;
    return null;
  }
  final from = view.center, fromScale = view.scale;
  late final Ticker ticker;
  ticker = Ticker((elapsed) {
    final t = Curves.easeInOutCubic.transform((elapsed.inMicroseconds / duration.inMicroseconds).clamp(0.0, 1.0));
    view
      ..scale = fromScale + (zoom - fromScale) * t
      ..center = Offset.lerp(from, to, t)!;
    if (elapsed >= duration) {
      ticker.dispose();
      if (_viewAnimations[view] == ticker) _viewAnimations[view] = null;
    }
  });
  _viewAnimations[view] = ticker;
  ticker.start();
  return ticker;
}

/// useWorkflowComment: the handlers over the comments [source], the editor's [store] and the [canvas]. Create one
/// where the handlers are needed (it keeps no state of its own but the marker to focus after a close).
class WorkflowComments {
  WorkflowComments({
    required this.source,
    required this.store,
    required this.canvas,
    this.globalToLocal,
    this.hasSelectedNode,
  });

  final CommentsStore source;
  final WorkflowStore store;
  final CanvasController canvas;

  /// From the page to the canvas's own coordinates (the pending comment's page position is where the pin goes).
  final Offset Function(Offset global)? globalToLocal;

  /// Whether a node's panel is open (a node `data.selected`); default: one node selected on the canvas.
  final bool Function()? hasSelectedNode;

  /// The comment whose marker gets focus back once the thread closed (handleActiveCommentClose).
  final focusToRestore = ValueNotifier<String?>(null);

  List<Comment> get comments => source.comments;

  /// The open thread's comment.
  Comment? get activeComment {
    final id = store.activeCommentId.value;
    if (id == null) return null;
    for (final c in source.comments) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// The comments shown on the canvas and navigated by the thread (index.tsx `visibleComments`).
  List<Comment> get visibleComments => store.showResolvedComments.value
      ? source.comments
      : [
          for (final c in source.comments)
            if (!c.resolved) c,
        ];

  bool get _commentMode => store.controlMode.value == ControlMode.comment;

  void _log(String what, Object error) => debugPrint('$what: $error');

  /// handleCommentSubmit: the pending comment, at the canvas point under its page position, then no pending comment.
  Future<void> submit(String content, [List<String> mentionedUserIds = const []]) async {
    final pending = store.pendingComment.value;
    if (pending == null) return;
    try {
      final page = Offset(pending.pageX, pending.pageY);
      final local = globalToLocal?.call(page) ?? Offset(pending.elementX, pending.elementY);
      final at = canvas.view.toCanvas(local);
      await source.create(x: at.dx, y: at.dy, content: content, mentions: mentionedUserIds);
    } catch (e) {
      _log('Failed to create comment', e);
    }
    store
      ..setPendingComment(null)
      ..setCommentQuickAdd(false);
  }

  /// handleCommentCancel.
  void cancel() => store
    ..setPendingComment(null)
    ..setCommentQuickAdd(false);

  /// handleCreateComment: a pending comment where the click was, in comment mode.
  void createAt(MousePosition at) {
    if (_commentMode) store.setPendingComment(at);
  }

  /// The two effects of useWorkflowComment: leaving comment mode (outside quick add) drops the pending comment; a
  /// quick add ends once nothing is pending or being placed.
  void syncPending() {
    if (!_commentMode && !store.isCommentQuickAdd.value) store.setPendingComment(null);
    if (store.pendingComment.value == null && !store.isCommentPlacing.value && store.isCommentQuickAdd.value) {
      store.setCommentQuickAdd(false);
    }
  }

  /// handleCommentIconClick: opens [c]'s thread and centres the view on it (zoom 1, 600 ms), the pin left of the
  /// middle by 220 px plus half the right panels' width.
  void open(Comment c) {
    focusToRestore.value = null;
    store
      ..setPendingComment(null)
      ..setActiveCommentId(c.id);
    final nodeSelected = hasSelectedNode?.call() ?? canvas.selection.nodes.length == 1;
    final commentPanelWidth = _commentMode ? 420.0 : 0.0;
    final fallback = (nodeSelected ? store.nodePanelWidth.value : 0) + commentPanelWidth;
    final effective = math.max(store.rightPanelWidth.value ?? 0, fallback);
    final maxOffset = math.max(0.0, canvas.view.viewport.width / 2 - 60);
    final offset = math.min(220 + effective / 2, maxOffset);
    _centering = setCanvasCenter(
      canvas,
      c.positionX + offset,
      c.positionY,
      zoom: 1,
      duration: const Duration(milliseconds: 600),
    );
  }

  /// handleActiveCommentClose.
  void close() {
    focusToRestore.value = store.activeCommentId.value;
    store
      ..setActiveCommentDetailLoading(false)
      ..setActiveCommentId(null);
  }

  /// handleCommentNavigate over [list] (the visible comments in the editor).
  void navigate(bool next, [List<Comment>? list]) {
    final current = store.activeCommentId.value;
    if (current == null) return;
    final l = list ?? comments;
    final i = l.indexWhere((c) => c.id == current);
    if (i == -1) return;
    final j = next ? i + 1 : i - 1;
    if (j >= 0 && j < l.length) open(l[j]);
  }

  Future<void> _loading(ValueNotifier<bool> flag, String what, Future<void> Function() run) async {
    flag.value = true;
    try {
      await run();
    } catch (e) {
      _log(what, e);
    } finally {
      flag.value = false;
    }
  }

  /// handleCommentResolve.
  Future<void> resolve(String id) =>
      _loading(store.activeCommentDetailLoading, 'Failed to resolve comment', () => source.resolve(id));

  /// handleCommentDelete: then the next comment's thread opens (else the previous, else the first left, else none).
  Future<void> delete(String id) => _loading(store.activeCommentDetailLoading, 'Failed to delete comment', () async {
    final before = comments;
    await source.delete(id);
    final i = before.indexWhere((c) => c.id == id);
    final fallback = i >= 0 ? (i + 1 < before.length ? before[i + 1] : (i > 0 ? before[i - 1] : null)) : null;
    final rest = [
      for (final c in before)
        if (c.id != id) c,
    ];
    if (fallback != null) {
      open(fallback);
    } else if (rest.isNotEmpty) {
      open(rest.first);
    } else {
      store.setActiveCommentId(null);
    }
  });

  /// handleCommentPositionUpdate (optimistic in the store, rolled back when the server refuses).
  Future<void> move(String id, Offset to) async {
    if (!comments.any((c) => c.id == id)) return;
    try {
      await source.move(id, to.dx, to.dy);
    } catch (e) {
      _log('Failed to update comment position', e);
    }
  }

  /// handleCommentUpdate.
  Future<void> update(String id, String content, [List<String> mentionedUserIds = const []]) async {
    final trimmed = content.trim();
    if (trimmed.isEmpty) return;
    try {
      await source.update(id, content: trimmed, mentions: mentionedUserIds);
    } catch (e) {
      _log('Failed to update comment', e);
    }
  }

  /// handleCommentReply.
  Future<void> reply(String id, String content, [List<String> mentionedUserIds = const []]) async {
    final trimmed = content.trim();
    if (trimmed.isEmpty) return;
    await _loading(
      store.replySubmitting,
      'Failed to create reply',
      () => source.reply(id, content: trimmed, mentions: mentionedUserIds),
    );
  }

  /// handleCommentReplyUpdate.
  Future<void> updateReply(
    String id,
    String replyId,
    String content, [
    List<String> mentionedUserIds = const [],
  ]) async {
    final trimmed = content.trim();
    if (trimmed.isEmpty) return;
    await _loading(
      store.replyUpdating,
      'Failed to update reply',
      () => source.editReply(id, replyId, content: trimmed, mentions: mentionedUserIds),
    );
  }

  /// handleCommentReplyDelete.
  Future<void> deleteReply(String id, String replyId) => _loading(
    store.activeCommentDetailLoading,
    'Failed to delete reply',
    () => source.deleteReply(id, replyId),
  );

  /// comment-manager.tsx, a click on the canvas: places the comment being placed (the pane menu's Add Comment);
  /// in comment mode, cancels the pending comment or starts one where the click was.
  void canvasClick(MousePosition at) {
    if (store.isCommentPlacing.value) {
      store
        ..setPendingComment(at)
        ..setCommentPlacing(false);
      return;
    }
    if (!_commentMode) return;
    if (store.pendingComment.value != null) {
      cancel();
    } else {
      createAt(at);
    }
  }

  /// comment-manager.tsx, a right click anywhere: stops placing.
  void contextMenu() {
    if (!store.isCommentPlacing.value) return;
    store
      ..setCommentPlacing(false)
      ..setCommentQuickAdd(false);
  }

  /// The view animation [open] started (stopped when this goes away with the canvas).
  Ticker? _centering;

  void dispose() {
    if (_centering?.isActive ?? false) _centering!.dispose();
    focusToRestore.dispose();
  }
}
