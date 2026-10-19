/// The comments over the canvas (components/workflow/index.tsx's comment parts and comment-manager.tsx): the pins,
/// the comment cursor (comment/cursor.tsx), the box that follows the pointer while placing, the new comment's box
/// and the open thread.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import '../../canvas/canvas_controller.dart';
import '../../canvas/canvas_input.dart' show ControlMode;
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../node_panel/bodies/core/core_kit.dart' show showDifyConfirm;
import '../store/workflow_store.dart';
import '../store/workflow_store_scope.dart';
import 'comment_icon.dart';
import 'comment_input.dart';
import 'comment_thread.dart';
import 'workflow_comment.dart';

/// cursor.tsx CommentCursor: in comment mode (and not while placing), the comment icon centred on the pointer in
/// place of the system cursor. A [Stack] child over the canvas.
class CommentCursor extends StatelessWidget {
  const CommentCursor({super.key});

  @override
  Widget build(BuildContext context) {
    final store = WorkflowStoreScope.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([store.controlMode, store.mousePosition, store.isCommentPlacing]),
      builder: (context, _) {
        if (store.controlMode.value != ControlMode.comment || store.isCommentPlacing.value) {
          return const SizedBox.shrink();
        }
        final m = store.mousePosition.value;
        return Positioned(
          left: m.elementX - 12,
          top: m.elementY - 12,
          child: IgnorePointer(
            child: SizedBox.square(
              dimension: 24,
              child: Center(child: DifyIcon('public/other/comment', size: 14, color: DifyColors.textPrimary)),
            ),
          ),
        );
      },
    );
  }
}

/// The comments over the canvas; put it over the canvas, the same size (the editor's overlay). Clicks on the canvas
/// place comments in comment mode (and the comment being placed from the pane menu); pins show where
/// `showUserComments` or comment mode says (the open one always). The boxes and the thread float over the editor's
/// chrome, clipped to the canvas, as Dify's do.
class CommentLayer extends StatefulWidget {
  const CommentLayer({super.key, required this.canvas, this.formatTimeFromNow});

  final CanvasController canvas;
  final String Function(int milliseconds)? formatTimeFromNow;

  @override
  State<CommentLayer> createState() => _CommentLayerState();
}

class _CommentLayerState extends State<CommentLayer> {
  late final WorkflowStore _store = WorkflowStoreScope.of(context);
  CommentsStore? _source;
  WorkflowComments? _actions;
  final _popups = OverlayPortalController();
  final _pinFocus = <String, FocusNode>{};
  bool _overPane = false;
  int? _down;

  late final Listenable _pendingChanges = Listenable.merge([
    _store.controlMode,
    _store.isCommentQuickAdd,
    _store.pendingComment,
    _store.isCommentPlacing,
  ]);

  @override
  void initState() {
    super.initState();
    _pendingChanges.addListener(_syncPending);
    _popups.show();
    // useWorkflowComment's effects also run on mount.
    WidgetsBinding.instance.addPostFrameCallback((_) => mounted ? _syncPending() : null);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final source = CommentsScope.maybeOf(context);
    if (source == _source) return;
    _source = source;
    _actions?.focusToRestore.removeListener(_restoreFocus);
    _actions?.dispose();
    _actions = source == null
        ? null
        : (WorkflowComments(source: source, store: _store, canvas: widget.canvas, globalToLocal: _globalToLocal)
            ..focusToRestore.addListener(_restoreFocus));
  }

  @override
  void dispose() {
    _pendingChanges.removeListener(_syncPending);
    _actions?.dispose();
    for (final f in _pinFocus.values) {
      f.dispose();
    }
    super.dispose();
  }

  Offset _globalToLocal(Offset global) => (context.findRenderObject() as RenderBox?)?.globalToLocal(global) ?? global;

  void _syncPending() => _actions?.syncPending();

  /// handleActiveCommentClose: the closed thread's marker gets focus back once it is rebuilt.
  void _restoreFocus() {
    final id = _actions?.focusToRestore.value;
    if (id == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _store.activeCommentId.value != null) return;
      final node = _pinFocus[id];
      if (node != null && node.context != null) node.requestFocus();
    });
  }

  FocusNode _focusOf(String id) => _pinFocus[id] ??= FocusNode(debugLabel: 'comment marker $id');

  /// Drops the markers' focus nodes of deleted comments (after the frame that unmounted their pins).
  void _pruneFocus(CommentsStore source) {
    if (_pinFocus.length <= source.comments.length) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ids = {for (final c in source.comments) c.id};
      _pinFocus.removeWhere((id, node) {
        if (ids.contains(id)) return false;
        node.dispose();
        return true;
      });
    });
  }

  MousePosition _track(PointerEvent e) {
    final at = (pageX: e.position.dx, pageY: e.position.dy, elementX: e.localPosition.dx, elementY: e.localPosition.dy);
    _store.setMousePosition(at);
    return at;
  }

  // comment-manager.tsx: a click (primary press and release) on the canvas, a right click.
  void _pointerDown(PointerDownEvent e) {
    _track(e);
    if (e.kind == PointerDeviceKind.mouse && e.buttons == kSecondaryButton) {
      _actions?.contextMenu();
      return;
    }
    _down = e.buttons == kPrimaryButton ? e.pointer : null;
  }

  void _pointerUp(PointerUpEvent e) {
    final at = _track(e);
    if (_down != e.pointer) return;
    _down = null;
    _actions?.canvasClick(at);
  }

  void _setOverPane(bool v) {
    if (v != _overPane) setState(() => _overPane = v);
  }

  Future<void> _confirmDelete(String title, String desc, Future<void> Function() run) async {
    if (await showDifyConfirm(context, title: tw(title), content: tw(desc))) await run();
  }

  @override
  Widget build(BuildContext context) {
    final source = _source, actions = _actions;
    if (source == null || actions == null) return const SizedBox.shrink();
    final store = _store, view = widget.canvas.view;
    _pruneFocus(source);
    return OverlayPortal.overlayChildLayoutBuilder(
      controller: _popups,
      overlayChildBuilder: (context, info) => _popupsLayer(
        source,
        actions,
        MatrixUtils.transformRect(info.childPaintTransform, Offset.zero & info.childSize),
      ),
      child: ListenableBuilder(
        listenable: Listenable.merge([
          store.controlMode,
          store.isCommentPlacing,
          store.activeCommentId,
          store.showResolvedComments,
          store.showUserComments,
        ]),
        builder: (context, _) {
          final commentMode = store.controlMode.value == ControlMode.comment;
          final activeId = store.activeCommentId.value;
          final showAll = store.showUserComments.value || commentMode;
          return Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              Positioned.fill(
                child: Listener(
                  behavior: HitTestBehavior.translucent,
                  onPointerDown: _pointerDown,
                  onPointerUp: _pointerUp,
                  onPointerCancel: (_) => _down = null,
                  onPointerMove: _track,
                  child: MouseRegion(
                    opaque: false,
                    hitTestBehavior: HitTestBehavior.translucent,
                    cursor: commentMode ? SystemMouseCursors.none : MouseCursor.defer,
                    onEnter: (_) => _setOverPane(true),
                    onExit: (_) => _setOverPane(false),
                    onHover: _track,
                  ),
                ),
              ),
              for (final c in actions.visibleComments)
                if (showAll || c.id == activeId)
                  CommentIcon(
                    key: ValueKey(c.id),
                    comment: c,
                    source: source,
                    view: view,
                    isActive: c.id == activeId,
                    focusNode: _focusOf(c.id),
                    formatTimeFromNow: widget.formatTimeFromNow,
                    onClick: () => actions.open(c),
                    onPositionUpdate: (to) => actions.move(c.id, to),
                  ),
              // Only over the canvas itself (index.tsx `isMouseOverCanvas`).
              if (_overPane) const CommentCursor(),
            ],
          );
        },
      ),
    );
  }

  /// The boxes and the thread, over the editor's chrome (in the overlay), at the canvas's place and clipped to it.
  Widget _popupsLayer(CommentsStore source, WorkflowComments actions, Rect canvasRect) {
    final store = _store, view = widget.canvas.view;
    final me = (id: source.currentUserId, name: nameOf(source, source.currentUserId));
    return Stack(
      children: [
        Positioned.fromRect(
          rect: canvasRect,
          child: ClipRect(
            child: ListenableBuilder(
              listenable: Listenable.merge([
                source,
                view,
                store.isCommentPlacing,
                store.pendingComment,
                store.activeCommentId,
                store.showResolvedComments,
                store.activeCommentDetailLoading,
                store.replySubmitting,
                store.replyUpdating,
              ]),
              builder: (context, _) {
                final pending = store.pendingComment.value;
                final visible = actions.visibleComments;
                final activeId = store.activeCommentId.value;
                final index = visible.indexWhere((c) => c.id == activeId);
                final active = index < 0 ? null : visible[index];
                final users = mentionUsersOf(source);
                return Stack(
                  clipBehavior: Clip.none,
                  children: [
                    // CommentPlacementPreview: the box follows the pointer until a click places it.
                    if (store.isCommentPlacing.value && pending == null)
                      ValueListenableBuilder(
                        valueListenable: store.mousePosition,
                        builder: (context, m, _) => Stack(
                          clipBehavior: Clip.none,
                          children: [
                            Positioned(
                              left: m.elementX,
                              top: m.elementY,
                              child: CommentInput(
                                position: Offset(m.elementX, m.elementY),
                                onSubmit: actions.submit,
                                onCancel: () => store
                                  ..setPendingComment(null)
                                  ..setCommentPlacing(false)
                                  ..setCommentQuickAdd(false),
                                users: users,
                                currentUser: me,
                                autoFocus: false,
                                disabled: true,
                              ),
                            ),
                          ],
                        ),
                      ),
                    if (pending != null)
                      Positioned(
                        left: pending.elementX,
                        top: pending.elementY,
                        child: CommentInput(
                          position: Offset(pending.elementX, pending.elementY),
                          onSubmit: actions.submit,
                          onCancel: actions.cancel,
                          users: users,
                          currentUser: me,
                          onPositionChange: store.setPendingComment,
                        ),
                      ),
                    if (active != null) _thread(source, actions, active, index, visible),
                  ],
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _thread(CommentsStore source, WorkflowComments actions, Comment c, int index, List<Comment> visible) {
    final store = _store;
    final at = widget.canvas.view.toScreen(Offset(c.positionX, c.positionY));
    final canGoPrev = index > 0, canGoNext = index < visible.length - 1;
    // `left: x + 40, top: y, translateY(-20%)` of its 360 px.
    return Positioned(
      left: at.dx + 40,
      top: at.dy - 72,
      child: CommentThread(
        key: ValueKey('${c.id}-thread'),
        comment: c,
        source: source,
        loading: store.activeCommentDetailLoading.value,
        replySubmitting: store.replySubmitting.value,
        replyUpdating: store.replyUpdating.value,
        formatTimeFromNow: widget.formatTimeFromNow,
        onClose: actions.close,
        onResolve: () => actions.resolve(c.id),
        onDelete: () => _confirmDelete(
          'comments.confirm.deleteThreadTitle',
          'comments.confirm.deleteThreadDesc',
          () => actions.delete(c.id),
        ),
        onCommentEdit: (content, ids) => actions.update(c.id, content, ids),
        onPrev: canGoPrev ? () => actions.navigate(false, visible) : null,
        onNext: canGoNext ? () => actions.navigate(true, visible) : null,
        canGoPrev: canGoPrev,
        canGoNext: canGoNext,
        onReply: (content, ids) => actions.reply(c.id, content, ids),
        onReplyEdit: (replyId, content, ids) => actions.updateReply(c.id, replyId, content, ids),
        onReplyDelete: (replyId) => _confirmDelete(
          'comments.confirm.deleteReplyTitle',
          'comments.confirm.deleteReplyDesc',
          () => actions.deleteReply(c.id, replyId),
        ),
        onReplyDeleteDirect: (replyId) => actions.deleteReply(c.id, replyId),
      ),
    );
  }
}
