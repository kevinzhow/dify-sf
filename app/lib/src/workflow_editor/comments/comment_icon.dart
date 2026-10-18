/// The pin of a comment on the canvas (comment/comment-icon.tsx), its hover preview (comment-preview.tsx) and the
/// avatars they show (base/user-avatar-list, dify-ui's Avatar).
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart' show RenderStack;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../canvas/canvas_view_state.dart';
import '../../design/css_metrics.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../header/format.dart' as fmt;
import '../header/online_users.dart' show getUserColor;
import '../store/workflow_store_scope.dart';
import 'workflow_comment.dart';

/// `bg-primary-600`, the Avatar fallback's colour.
const primary600 = Color(0xFF155AEF);

/// `primary-500`.
const primary500 = Color(0xFF2970FF);

/// dify-ui's Avatar: the initial on [color] (`bg-primary-600` unless given), `font-medium text-white` at
/// [fontSize] (Dify's `sm` 10 px; the comment UI widens `sm` avatars with `size-8`).
class CommentAvatar extends StatelessWidget {
  const CommentAvatar({super.key, required this.name, this.color, this.size = 24, this.fontSize = 10});
  final String name;
  final Color? color;
  final double size, fontSize;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(shape: BoxShape.circle, color: color ?? primary600),
    alignment: Alignment.center,
    child: Text(
      name.isEmpty ? '' : name.characters.first.toUpperCase(),
      maxLines: 1,
      style: TextStyle(fontSize: fontSize, height: 1, fontWeight: FontWeight.w500, color: const Color(0xFFFFFFFF)),
    ),
  );
}

/// base/user-avatar-list: up to [maxVisible] 24 px avatars overlapping by 4 px (`-space-x-1`), the earlier on top,
/// each in a 2 px `ring-components-panel-bg`; past that, one fewer and a gray "+N". Others in their user colour,
/// [currentUserId] in primary.
class UserAvatarList extends StatelessWidget {
  const UserAvatarList({super.key, required this.users, required this.currentUserId, this.maxVisible = 3});
  final List<CommentUser> users;
  final String currentUserId;
  final int maxVisible;

  static const _ring = BoxDecoration(
    shape: BoxShape.circle,
    boxShadow: [BoxShadow(color: DifyColors.componentsPanelBg, spreadRadius: 2)],
  );

  @override
  Widget build(BuildContext context) {
    if (users.isEmpty) return const SizedBox.shrink();
    final showCount = users.length > maxVisible;
    final visible = users.take(showCount ? (maxVisible - 1).clamp(1, maxVisible) : maxVisible).toList();
    final remaining = users.length - visible.length;
    final items = <Widget>[
      for (final u in visible)
        DecoratedBox(
          decoration: _ring,
          child: CommentAvatar(name: u.name, color: u.id == currentUserId ? null : getUserColor(u.id)),
        ),
      if (showCount && remaining > 0)
        DecoratedBox(
          decoration: _ring.copyWith(color: const Color(0xFF667085)),
          child: SizedBox.square(
            dimension: 24,
            child: Center(
              child: Text(
                '+$remaining',
                style: const TextStyle(fontSize: 10, height: 1, color: Color(0xFFFFFFFF)),
              ),
            ),
          ),
        ),
    ];
    return SizedBox(
      width: 24.0 + (items.length - 1) * 20,
      height: 24,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (var i = items.length - 1; i >= 0; i--) Positioned(left: i * 20.0, top: 0, child: items[i]),
        ],
      ),
    );
  }
}

/// comment-preview.tsx: the hover card of a pin, with the participants, the author, when it was last changed and
/// the text. Hovering it counts as hovering a comment preview (the store's `isCommentPreviewHovering`).
class CommentPreview extends StatefulWidget {
  const CommentPreview({super.key, required this.comment, required this.source, this.onClick, this.formatTimeFromNow});
  final Comment comment;
  final CommentsStore source;
  final VoidCallback? onClick;

  /// useFormatTimeFromNow (milliseconds); tests replace it.
  final String Function(int milliseconds)? formatTimeFromNow;

  @override
  State<CommentPreview> createState() => _CommentPreviewState();
}

class _CommentPreviewState extends State<CommentPreview> {
  late final _store = WorkflowStoreScope.of(context);
  bool _hovered = false;

  @override
  void initState() {
    super.initState();
    _store; // looked up while mounted: dispose uses it
  }

  @override
  void dispose() {
    // Unmounted before the editor (and its store) goes; nothing rebuilds on this flag.
    if (_store.isCommentPreviewHovering.value) _store.setCommentPreviewHovering(false);
    super.dispose();
  }

  void _hover(bool v) {
    setState(() => _hovered = v);
    _store.setCommentPreviewHovering(v);
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.comment;
    final when = (widget.formatTimeFromNow ?? fmt.formatTimeFromNow)(c.updatedAt.millisecondsSinceEpoch);
    const radius = BorderRadius.only(
      topLeft: Radius.circular(24),
      topRight: Radius.circular(24),
      bottomRight: Radius.circular(24),
      bottomLeft: Radius.circular(3),
    );
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => _hover(true),
      onExit: (_) => _hover(false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onClick,
        child: DifyBlurredBox(
          blur: 10,
          borderRadius: radius,
          decoration: BoxDecoration(
            color: _hovered ? DifyColors.componentsPanelOnPanelItemBgHover : DifyColors.componentsPanelBgBlur,
            border: Border.all(color: DifyColors.componentsPanelBorder, width: Css.hairline),
            borderRadius: radius,
            boxShadow: DifyShadows.lg,
          ),
          padding: const EdgeInsets.all(16),
          child: SizedBox(
            width: 320 - 32 - 2 * Css.hairline,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: UserAvatarList(
                    users: participantsOf(widget.source, c),
                    currentUserId: widget.source.currentUserId,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    spacing: 8,
                    children: [
                      Flexible(
                        child: Text(
                          nameOf(widget.source, c.createdBy, c.createdByName),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: difyTextStyle(DifyType.systemSmMedium, DifyColors.textPrimary),
                        ),
                      ),
                      Text(when, style: difyTextStyle(DifyType.system2xsRegular, DifyColors.textTertiary)),
                    ],
                  ),
                ),
                Text(c.content, style: difyTextStyle(DifyType.systemSmRegular, DifyColors.textSecondary)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// comment-icon.tsx: a comment's pin, centred on its canvas point (scaled with nothing: the view moves it), with the
/// participants' avatars. Clicking opens the thread; the author drags it (past 4 px) or moves it with the arrow keys
/// (5 px, 20 with Shift; saved when the key is released) and [onPositionUpdate] gets the canvas point. Hovering an
/// inactive pin shows its [CommentPreview] over it (which drags and opens like the pin).
///
/// Put it in a [Stack] over the canvas, the canvas's size and position.
class CommentIcon extends StatefulWidget {
  const CommentIcon({
    super.key,
    required this.comment,
    required this.source,
    required this.view,
    required this.onClick,
    this.isActive = false,
    this.onPositionUpdate,
    this.focusNode,
    this.formatTimeFromNow,
  });

  final Comment comment;
  final CommentsStore source;
  final CanvasViewState view;
  final VoidCallback onClick;
  final bool isActive;
  final ValueChanged<Offset>? onPositionUpdate;
  final FocusNode? focusNode;
  final String Function(int milliseconds)? formatTimeFromNow;

  /// The pin's size for [participants] (`dynamicWidth`, `h-10`).
  static Size sizeFor(int participants) {
    final maxVisible = participants < 3 ? participants : 3;
    final extra = participants > 3 ? 2 : (maxVisible - 1 < 0 ? 0 : maxVisible - 1);
    final w = 8.0 + 24 + extra * 20 + 8;
    return Size(w < 40 ? 40 : w, 40);
  }

  @override
  State<CommentIcon> createState() => _CommentIconState();
}

class _CommentIconState extends State<CommentIcon> {
  final _preview = OverlayPortalController();
  final _link = LayerLink();
  FocusNode? _ownFocus;
  FocusNode get _focus => widget.focusNode ?? (_ownFocus ??= FocusNode(debugLabel: 'comment marker'));

  bool _hoverPin = false, _hoverPreview = false;
  bool _dragging = false;

  /// The pin's centre (in the stack) while it is dragged or moved with the keys.
  Offset? _dragPosition;
  ({Offset offset, Offset start, bool moved})? _drag;
  Offset? _keyboardPosition;

  bool get _isAuthor => widget.comment.createdBy == widget.source.currentUserId;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_focusChanged);
  }

  @override
  void didUpdateWidget(CommentIcon old) {
    super.didUpdateWidget(old);
    if (old.focusNode != widget.focusNode) {
      (old.focusNode ?? _ownFocus)?.removeListener(_focusChanged);
      _focus.addListener(_focusChanged);
    }
    if (widget.isActive && _preview.isShowing) _preview.hide();
  }

  @override
  void dispose() {
    _focus.removeListener(_focusChanged);
    _ownFocus?.dispose();
    super.dispose();
  }

  void _focusChanged() {
    if (!_focus.hasFocus) _finishKeyboardMove();
  }

  Offset get _screen => widget.view.toScreen(Offset(widget.comment.positionX, widget.comment.positionY));

  /// From the page to the stack the pin is in (the canvas's coordinates).
  Offset _local(Offset global) =>
      context.findAncestorRenderObjectOfType<RenderStack>()?.globalToLocal(global) ?? global;

  void _hovered({bool? pin, bool? preview}) {
    _hoverPin = pin ?? _hoverPin;
    _hoverPreview = preview ?? _hoverPreview;
    final show = (_hoverPin || _hoverPreview) && !widget.isActive && !_dragging;
    if (show == _preview.isShowing) return;
    show ? _preview.show() : _preview.hide();
  }

  void _finishKeyboardMove() {
    final p = _keyboardPosition;
    if (p == null) return;
    _keyboardPosition = null;
    setState(() => _dragPosition = null);
    widget.onPositionUpdate?.call(p);
  }

  // ----- pointer (handlePointerDown/Move/Up/Cancel), shared by the pin and its preview -----

  void _down(PointerDownEvent e, {bool fromPreview = false}) {
    if (e.buttons != kPrimaryButton) return;
    if (!fromPreview) _hovered(pin: false, preview: false);
    final screen = _screen;
    _drag = (offset: _local(e.position) - screen, start: e.position, moved: false);
    if (_isAuthor) setState(() => _dragPosition = screen);
  }

  void _move(PointerMoveEvent e) {
    final d = _drag;
    if (d == null || !_isAuthor) return;
    if (!d.moved && (e.position - d.start).distance > 4) {
      _drag = (offset: d.offset, start: d.start, moved: true);
      _dragging = true;
      _hovered(pin: false, preview: false);
    }
    setState(() => _dragPosition = _local(e.position) - d.offset);
  }

  void _up(PointerUpEvent e) {
    final d = _drag;
    if (d == null) return;
    final end = _dragPosition ?? _screen;
    _end();
    _hovered(pin: false, preview: false);
    if (d.moved && _isAuthor) {
      widget.onPositionUpdate?.call(widget.view.toCanvas(end));
    } else if (!widget.isActive) {
      widget.onClick();
    }
  }

  void _end() {
    _drag = null;
    setState(() {
      _dragPosition = null;
      _dragging = false;
    });
  }

  KeyEventResult _key(FocusNode node, KeyEvent e) {
    final delta = keyboardMovement(e);
    if (delta != null) {
      // Arrow keys never move focus off the marker (as in a browser).
      if (!_isAuthor || widget.onPositionUpdate == null) return KeyEventResult.handled;
      if (e is KeyUpEvent) {
        _finishKeyboardMove();
        return KeyEventResult.handled;
      }
      final next = (_keyboardPosition ?? Offset(widget.comment.positionX, widget.comment.positionY)) + delta;
      _keyboardPosition = next;
      setState(() => _dragPosition = widget.view.toScreen(next));
      return KeyEventResult.handled;
    }
    if (e is KeyDownEvent && (e.logicalKey == LogicalKeyboardKey.enter || e.logicalKey == LogicalKeyboardKey.space)) {
      if (!widget.isActive) {
        _finishKeyboardMove();
        widget.onClick();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.view,
    builder: (context, _) {
      final c = widget.comment, source = widget.source;
      final users = participantsOf(source, c);
      final size = CommentIcon.sizeFor(users.length);
      final center = _dragPosition ?? _screen;
      final cursor = !_isAuthor
          ? SystemMouseCursors.click
          : _dragging
          ? SystemMouseCursors.grabbing
          : widget.isActive
          ? MouseCursor.defer
          : SystemMouseCursors.click;
      Widget handlers(Widget child, {bool preview = false}) => Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (e) => _down(e, fromPreview: preview),
        onPointerMove: _move,
        onPointerUp: _up,
        onPointerCancel: (_) => _end(),
        child: MouseRegion(
          cursor: preview ? MouseCursor.defer : cursor,
          onEnter: (_) => preview ? _hovered(preview: true) : _hovered(pin: true),
          onExit: (_) => preview ? _hovered(preview: false) : _hovered(pin: false),
          child: child,
        ),
      );
      final movable = _isAuthor && widget.onPositionUpdate != null;
      return Positioned(
        left: center.dx - size.width / 2,
        top: center.dy - size.height / 2,
        child: Semantics(
          button: true,
          label: tw('keyboard.openComment', {'name': nameOf(source, c.createdBy, c.createdByName)}),
          hint: movable
              ? '${tw('keyboard.moveHelp')} ${tw('keyboard.position', {'x': c.positionX, 'y': c.positionY})}'
              : null,
          onTap: widget.isActive ? null : widget.onClick,
          child: Focus(
            focusNode: _focus,
            onKeyEvent: _key,
            child: CompositedTransformTarget(
              link: _link,
              child: OverlayPortal(
                controller: _preview,
                // `left: x - dynamicWidth / 2, top: y + 20, translateY(-100%)`: over the pin, bottom-left aligned.
                overlayChildBuilder: (context) => Align(
                  alignment: Alignment.topLeft,
                  child: CompositedTransformFollower(
                    link: _link,
                    targetAnchor: Alignment.bottomLeft,
                    followerAnchor: Alignment.bottomLeft,
                    child: handlers(
                      preview: true,
                      CommentPreview(comment: c, source: source, formatTimeFromNow: widget.formatTimeFromNow),
                    ),
                  ),
                ),
                child: handlers(
                  ExcludeSemantics(
                    child: SizedBox.fromSize(
                      size: size,
                      child: _PinBody(users: users, active: widget.isActive, me: source.currentUserId),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

/// The pin's look: `h-10` around an `inset-1.5` box rounded but at the bottom left, `border` in
/// `components-panel-border` (active: `border-primary-500 ring-1 ring-primary-500`) on `components-panel-bg`, with
/// the avatars centred and raised 1.5 px.
class _PinBody extends StatelessWidget {
  const _PinBody({required this.users, required this.active, required this.me});
  final List<CommentUser> users;
  final bool active;
  final String me;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(6),
    child: Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: DifyColors.componentsPanelBg,
        borderRadius: _radius,
        border: Border.all(color: active ? primary500 : DifyColors.componentsPanelBorder),
        // The ring under the box shows outside it only.
        boxShadow: active ? const [BoxShadow(color: primary500, spreadRadius: 1)] : null,
      ),
      alignment: Alignment.center,
      child: Transform.translate(
        offset: const Offset(0, -1.5),
        child: UserAvatarList(users: users, currentUserId: me),
      ),
    ),
  );

  static const _radius = BorderRadius.only(
    topLeft: Radius.circular(14),
    topRight: Radius.circular(14),
    bottomRight: Radius.circular(14),
  );
}
