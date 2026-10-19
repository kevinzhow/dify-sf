/// The thread of an open comment (comment/thread.tsx): the comment and its replies, editing and deleting your own,
/// resolving, moving to the previous or next comment, and the reply box.
library;

import 'dart:async';

import 'package:flutter/material.dart' show Colors;
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../../design/css_metrics.dart';
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../header/format.dart' as fmt;
import '../header/online_users.dart' show getUserColor;
import '../store/workflow_store_scope.dart';
import 'comment_icon.dart' show CommentAvatar;
import 'comment_input.dart';
import 'workflow_comment.dart';

/// ThreadMessage: the author's 32 px avatar (in their user colour, primary for you), name, time, and the text with
/// its mentions in primary.
class ThreadMessage extends StatelessWidget {
  const ThreadMessage({
    super.key,
    required this.authorId,
    required this.authorName,
    required this.createdAt,
    required this.content,
    required this.mentionableNames,
    required this.currentUserId,
    this.formatTimeFromNow,
  });

  final String authorId, authorName, content, currentUserId;
  final DateTime createdAt;
  final List<String> mentionableNames;
  final String Function(int milliseconds)? formatTimeFromNow;

  @override
  Widget build(BuildContext context) {
    final ranges = mentionRanges(content, mentionableNames);
    final style = difyTextStyle(DifyType.systemSmRegular, DifyColors.textSecondary);
    var at = 0;
    final spans = <TextSpan>[];
    for (final (s, e) in ranges) {
      if (s > at) spans.add(TextSpan(text: content.substring(at, s)));
      spans.add(
        TextSpan(
          text: content.substring(s, e),
          style: TextStyle(color: DifyColors.primary600),
        ),
      );
      at = e;
    }
    if (at < content.length) spans.add(TextSpan(text: content.substring(at)));
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 12,
        children: [
          CommentAvatar(
            name: authorName,
            size: 32,
            color: authorId == currentUserId ? null : getUserColor(authorId),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(authorName, style: difyTextStyle(DifyType.systemSmMedium, DifyColors.textPrimary)),
                    Text(
                      (formatTimeFromNow ?? fmt.formatTimeFromNow)(createdAt.millisecondsSinceEpoch),
                      style: difyTextStyle(DifyType.system2xsRegular, DifyColors.textTertiary),
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text.rich(TextSpan(style: style, children: spans)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// thread.tsx CommentThread: 360 × 360 at 40 px right of the pin, a fifth of its height above it. Escape closes it
/// (unless something is being edited or a mention list is open); the reply box takes focus when it opens.
class CommentThread extends StatefulWidget {
  const CommentThread({
    super.key,
    required this.comment,
    required this.source,
    required this.onClose,
    this.loading = false,
    this.replySubmitting = false,
    this.replyUpdating = false,
    this.onDelete,
    this.onResolve,
    this.onPrev,
    this.onNext,
    this.canGoPrev = false,
    this.canGoNext = false,
    this.onCommentEdit,
    this.onReply,
    this.onReplyEdit,
    this.onReplyDelete,
    this.onReplyDeleteDirect,
    this.formatTimeFromNow,
  });

  final Comment comment;
  final CommentsStore source;
  final bool loading, replySubmitting, replyUpdating;
  final VoidCallback onClose;
  final VoidCallback? onDelete, onResolve, onPrev, onNext;
  final bool canGoPrev, canGoNext;
  final Future<void> Function(String content, List<String> mentionedUserIds)? onCommentEdit;
  final Future<void> Function(String content, List<String> mentionedUserIds)? onReply;
  final Future<void> Function(String replyId, String content, List<String> mentionedUserIds)? onReplyEdit;
  final void Function(String replyId)? onReplyDelete;
  final void Function(String replyId)? onReplyDeleteDirect;
  final String Function(int milliseconds)? formatTimeFromNow;

  @override
  State<CommentThread> createState() => _CommentThreadState();
}

class _CommentThreadState extends State<CommentThread> {
  late final _store = WorkflowStoreScope.of(context);
  final _replyFocus = FocusNode(debugLabel: 'comment reply');
  final _scroll = ScrollController();
  String _reply = '', _editingComment = '';
  String? _menuFor, _deletingReply;
  ({String id, String content}) _editingReply = (id: '', content: '');
  bool _commentEditing = false, _submittingEdit = false;
  int? _replyCount;

  @override
  void initState() {
    super.initState();
    _store; // looked up while mounted: dispose uses it
    _scroll.addListener(() {
      if (_menuFor != null) setState(() => _menuFor = null);
    });
    _focusReplySoon();
    _scrollToEndSoon();
  }

  @override
  void didUpdateWidget(CommentThread old) {
    super.didUpdateWidget(old);
    if (old.comment.id != widget.comment.id) {
      _reply = '';
      _editingComment = '';
      _commentEditing = false;
      _editingReply = (id: '', content: '');
      _menuFor = null;
      _deletingReply = null;
      _focusReplySoon();
      _scrollToEndSoon();
    } else if (_replyCount != null && widget.comment.replies.length > _replyCount!) {
      _scrollToEndSoon();
    }
    _replyCount = widget.comment.replies.length;
  }

  @override
  void dispose() {
    // Unmounted before the editor (and its store) goes; nothing rebuilds on this flag.
    if (_store.isCommentPreviewHovering.value) _store.setCommentPreviewHovering(false);
    _focusTimer?.cancel();
    _replyFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  bool get _canReply => widget.onReply != null;

  /// Focus goes to the reply box 100 ms after the thread opens or an edit ends.
  void _focusReplySoon([Duration delay = const Duration(milliseconds: 100)]) {
    _focusTimer?.cancel();
    _focusTimer = Timer(delay, () {
      if (mounted && _canReply && _editingReply.id.isEmpty && !_commentEditing) _replyFocus.requestFocus();
    });
  }

  Timer? _focusTimer;

  void _scrollToEndSoon() => SchedulerBinding.instance.addPostFrameCallback((_) {
    if (!mounted || !_scroll.hasClients) return;
    _scroll.animateTo(
      _scroll.position.maxScrollExtent,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  });

  Future<void> _submitReply(String content, List<String> ids) async {
    if (!_canReply || widget.replySubmitting) return;
    setState(() => _reply = '');
    try {
      await widget.onReply!(content, ids);
      _focusReplySoon(Duration.zero);
    } catch (e) {
      debugPrint('Failed to send reply: $e');
      if (mounted) setState(() => _reply = content);
    }
  }

  Future<void> _submitCommentEdit(String content, List<String> ids) async {
    final trimmed = content.trim();
    if (widget.onCommentEdit == null || trimmed.isEmpty) return;
    setState(() => _submittingEdit = true);
    try {
      await widget.onCommentEdit!(trimmed, ids);
      if (!mounted) return;
      setState(() {
        _editingComment = '';
        _commentEditing = false;
      });
      _focusReplySoon(Duration.zero);
    } catch (e) {
      debugPrint('Failed to edit comment: $e');
    } finally {
      if (mounted) setState(() => _submittingEdit = false);
    }
  }

  Future<void> _submitReplyEdit(String content, List<String> ids) async {
    final trimmed = content.trim();
    if (widget.onReplyEdit == null || trimmed.isEmpty) return;
    setState(() => _submittingEdit = true);
    try {
      await widget.onReplyEdit!(_editingReply.id, trimmed, ids);
      if (!mounted) return;
      setState(() => _editingReply = (id: '', content: ''));
      _focusReplySoon(Duration.zero);
    } catch (e) {
      debugPrint('Failed to edit reply: $e');
    } finally {
      if (mounted) setState(() => _submittingEdit = false);
    }
  }

  List<String> get _mentionableNames => {
    for (final n in widget.source.names.values)
      if (n.trim().isNotEmpty) n.trim(),
  }.toList();

  @override
  Widget build(BuildContext context) {
    final c = widget.comment, source = widget.source, me = source.currentUserId;
    final users = mentionUsersOf(source);
    final names = _mentionableNames;
    Widget editor({
      required String authorName,
      required String value,
      required ValueChanged<String> onChange,
      required Future<void> Function(String, List<String>) onSubmit,
      required VoidCallback onCancel,
      required String placeholder,
      required bool loading,
    }) => Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 12,
        children: [
          CommentAvatar(name: authorName, size: 32),
          Expanded(
            child: DifyBlurredBox(
              blur: 10,
              borderRadius: BorderRadius.circular(DifyRadius.xl),
              decoration: BoxDecoration(
                color: DifyColors.componentsPanelBgBlur,
                border: Border.all(color: DifyColors.componentsChatInputBorder),
                borderRadius: BorderRadius.circular(DifyRadius.xl),
                boxShadow: DifyShadows.md,
              ),
              padding: const EdgeInsets.all(4),
              child: MentionInput(
                value: value,
                onChange: onChange,
                onSubmit: onSubmit,
                onCancel: onCancel,
                users: users,
                placeholder: placeholder,
                disabled: widget.loading,
                loading: loading,
                isEditing: true,
                autoFocus: true,
              ),
            ),
          ),
        ],
      ),
    );

    final rootName = nameOf(source, c.createdBy, c.createdByName);
    final root = _Item(
      menu: c.createdBy == me && !_commentEditing
          ? _ActionsMenu(
              label: tw('comments.aria.commentActions'),
              open: _menuFor == c.id,
              onOpenChange: (open) => setState(() => _menuFor = open ? c.id : null),
              children: [
                _MenuButton(
                  label: tw('comments.actions.editComment'),
                  radius: BorderRadius.circular(DifyRadius.xl),
                  onPressed: () => setState(() {
                    _editingComment = c.content;
                    _editingReply = (id: '', content: '');
                    _commentEditing = true;
                    _menuFor = null;
                  }),
                ),
              ],
            )
          : null,
      menuOpen: _menuFor == c.id,
      child: _commentEditing
          ? editor(
              authorName: rootName,
              value: _editingComment,
              onChange: (v) => _editingComment = v,
              onSubmit: _submitCommentEdit,
              onCancel: () {
                setState(() {
                  _editingComment = '';
                  _commentEditing = false;
                });
                _focusReplySoon(Duration.zero);
              },
              placeholder: tw('comments.placeholder.editComment'),
              loading: _submittingEdit,
            )
          : ThreadMessage(
              authorId: c.createdBy,
              authorName: rootName,
              createdAt: c.createdAt,
              content: c.content,
              mentionableNames: names,
              currentUserId: me,
              formatTimeFromNow: widget.formatTimeFromNow,
            ),
    );

    final replies = [
      for (final r in c.replies)
        _Item(
          menuOpen: _menuFor == r.id,
          menu: r.createdBy == me && _editingReply.id != r.id
              ? _ActionsMenu(
                  label: tw('comments.aria.replyActions'),
                  open: _menuFor == r.id,
                  onOpenChange: (open) => setState(() {
                    if (!open) _deletingReply = null;
                    _menuFor = open ? r.id : null;
                  }),
                  children: _deletingReply == r.id
                      ? [
                          DifyInlineDeleteConfirm(
                            title: tw('comments.actions.deleteReply'),
                            onConfirm: () {
                              setState(() {
                                _deletingReply = null;
                                _menuFor = null;
                              });
                              widget.onReplyDeleteDirect?.call(r.id);
                            },
                            onCancel: () => setState(() => _deletingReply = null),
                          ),
                        ]
                      : [
                          _MenuButton(
                            label: tw('comments.actions.editReply'),
                            radius: const BorderRadius.vertical(top: Radius.circular(DifyRadius.xl)),
                            onPressed: () => setState(() {
                              _editingReply = (id: r.id, content: r.content);
                              _commentEditing = false;
                              _menuFor = null;
                            }),
                          ),
                          _MenuButton(
                            label: tw('comments.actions.deleteReply'),
                            radius: const BorderRadius.vertical(bottom: Radius.circular(DifyRadius.xl)),
                            onPressed: () {
                              if (widget.onReplyDeleteDirect != null) {
                                setState(() => _deletingReply = r.id);
                              } else {
                                setState(() => _menuFor = null);
                                widget.onReplyDelete?.call(r.id);
                              }
                            },
                          ),
                        ],
                )
              : null,
          child: _editingReply.id == r.id
              ? editor(
                  authorName: nameOf(source, r.createdBy, r.createdByName),
                  value: _editingReply.content,
                  onChange: (v) => _editingReply = (id: _editingReply.id, content: v),
                  onSubmit: _submitReplyEdit,
                  onCancel: () {
                    setState(() => _editingReply = (id: '', content: ''));
                    _focusReplySoon(Duration.zero);
                  },
                  placeholder: tw('comments.placeholder.editReply'),
                  loading: widget.replyUpdating || _submittingEdit,
                )
              : ThreadMessage(
                  authorId: r.createdBy,
                  authorName: nameOf(source, r.createdBy, r.createdByName),
                  createdAt: r.createdAt,
                  content: r.content,
                  mentionableNames: names,
                  currentUserId: me,
                  formatTimeFromNow: widget.formatTimeFromNow,
                ),
        ),
    ];

    Widget headerButton({
      required String label,
      required Widget icon,
      VoidCallback? onPressed,
      bool disabled = false,
      bool destructive = false,
      bool tooltip = true,
    }) {
      final button = _HeaderButton(
        label: label,
        icon: icon,
        onPressed: onPressed,
        disabled: disabled,
        destructive: destructive,
      );
      if (!tooltip) return button;
      return DifyTooltip(
        content: Text(label),
        child: button,
      );
    }

    final header = Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: DifyColors.componentsPanelBgBlur,
        border: Border(bottom: BorderSide(color: DifyColors.componentsPanelBorder)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              tw('comments.panelTitle').toUpperCase(),
              style: difyTextStyle(DifyType.systemXlSemibold, DifyColors.textPrimary),
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            spacing: 4,
            children: [
              headerButton(
                label: tw('comments.aria.deleteComment'),
                icon: const RemixIcon('delete-bin-line', size: 16),
                onPressed: widget.onDelete,
                disabled: widget.loading,
                destructive: true,
              ),
              headerButton(
                label: tw('comments.aria.resolveComment'),
                icon: RemixIcon(c.resolved ? 'checkbox-circle-fill' : 'checkbox-circle-line', size: 16),
                onPressed: widget.onResolve,
                disabled: c.resolved || widget.loading,
              ),
              const DifyDivider.vertical(length: 14),
              headerButton(
                label: tw('comments.aria.previousComment'),
                icon: const RemixIcon('arrow-up-s-line', size: 16),
                onPressed: widget.onPrev,
                disabled: !widget.canGoPrev || widget.loading,
              ),
              headerButton(
                label: tw('comments.aria.nextComment'),
                icon: const RemixIcon('arrow-down-s-line', size: 16),
                onPressed: widget.onNext,
                disabled: !widget.canGoNext || widget.loading,
              ),
              headerButton(
                label: tw('comments.aria.closeComment'),
                icon: const RemixIcon('close-line', size: 16),
                onPressed: widget.onClose,
                tooltip: false,
              ),
            ],
          ),
        ],
      ),
    );

    final list = SingleChildScrollView(
      controller: _scroll,
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          root,
          if (replies.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8 + 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 12,
                children: replies,
              ),
            ),
        ],
      ),
    );

    return EscapeListener(
      when: () => _editingReply.id.isEmpty && !_commentEditing && openMentionDropdowns.value == 0,
      onEscape: widget.onClose,
      child: FocusTraversalGroup(
        policy: WidgetOrderTraversalPolicy(),
        child: MouseRegion(
          onEnter: (_) => _store.setCommentPreviewHovering(true),
          onExit: (_) => _store.setCommentPreviewHovering(false),
          child: Semantics(
            scopesRoute: true,
            explicitChildNodes: true,
            label: tw('comments.panelTitle'),
            child: Container(
              width: 360,
              height: 360,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: DifyColors.componentsPanelBg,
                border: Border.all(color: DifyColors.componentsPanelBorder),
                borderRadius: BorderRadius.circular(DifyRadius.xxl),
                boxShadow: DifyShadows.xl,
              ),
              child: Stack(
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      header,
                      Expanded(
                        child: Padding(padding: const EdgeInsets.only(top: 8), child: list),
                      ),
                      if (_canReply)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          decoration: BoxDecoration(
                            border: Border(top: BorderSide(color: DifyColors.componentsPanelBorder)),
                          ),
                          child: Row(
                            spacing: 12,
                            children: [
                              CommentAvatar(name: source.names[me] ?? tw('you'), size: 32),
                              Expanded(
                                child: Container(
                                  padding: const EdgeInsets.all(2),
                                  decoration: BoxDecoration(
                                    color: DifyColors.componentsPanelBgBlur,
                                    border: Border.all(color: DifyColors.componentsChatInputBorder),
                                    borderRadius: BorderRadius.circular(DifyRadius.xl),
                                    boxShadow: DifyShadows.sm,
                                  ),
                                  child: MentionInput(
                                    value: _reply,
                                    onChange: (v) => _reply = v,
                                    onSubmit: _submitReply,
                                    users: users,
                                    focusNode: _replyFocus,
                                    placeholder: tw('comments.placeholder.reply'),
                                    disabled: widget.loading,
                                    loading: widget.replySubmitting,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                  if (widget.loading)
                    Positioned.fill(
                      child: ColoredBox(
                        color: DifyColors.componentsPanelBg.withValues(alpha: DifyColors.componentsPanelBg.a * 0.7),
                        child: Center(
                          child: Text(
                            tw('comments.loading'),
                            style: difyTextStyle(DifyType.systemMdRegular, DifyColors.textTertiary),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A message row (`group relative -mx-4 rounded-lg px-4 py-2 hover:bg-components-panel-on-panel-item-bg-hover`)
/// with its actions at the top right while hovered or while their menu is open.
class _Item extends StatefulWidget {
  const _Item({required this.child, this.menu, this.menuOpen = false});
  final Widget child;
  final Widget? menu;
  final bool menuOpen;

  @override
  State<_Item> createState() => _ItemState();
}

class _ItemState extends State<_Item> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => setState(() => _hovered = true),
    onExit: (_) => setState(() => _hovered = false),
    child: Stack(
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: _hovered ? DifyColors.componentsPanelOnPanelItemBgHover : Colors.transparent,
            borderRadius: BorderRadius.circular(DifyRadius.lg),
          ),
          child: widget.child,
        ),
        if (widget.menu != null && (_hovered || widget.menuOpen)) Positioned(top: 4, right: 4, child: widget.menu!),
      ],
    ),
  );
}

/// The `…` trigger of a message's actions and its menu (`w-36 rounded-xl border-[0.5px] bg-components-panel-bg-blur
/// shadow-lg backdrop-blur-[10px]`, bottom-end, 4 px below).
class _ActionsMenu extends StatelessWidget {
  const _ActionsMenu({required this.label, required this.open, required this.onOpenChange, required this.children});
  final String label;
  final bool open;
  final ValueChanged<bool> onOpenChange;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => DifyFloating(
    open: open,
    onOpenChange: onOpenChange,
    placement: DifyPlacement.bottomEnd,
    sideOffset: 4,
    collision: DifyCollision.dropdown,
    builder: (context, c) => _HeaderButton(
      label: label,
      icon: const RemixIcon('more-fill', size: 16),
      radius: DifyRadius.md,
      onPressed: () => onOpenChange(!open),
    ),
    popupBuilder: (context) => DifyBlurredBox(
      blur: 10,
      borderRadius: BorderRadius.circular(DifyRadius.xl),
      decoration: BoxDecoration(
        color: DifyColors.componentsPanelBgBlur,
        border: Border.all(color: DifyColors.componentsPanelBorder, width: Css.hairline),
        borderRadius: BorderRadius.circular(DifyRadius.xl),
        boxShadow: DifyShadows.lg,
      ),
      child: SizedBox(
        width: 144 - 2 * Css.hairline,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    ),
  );
}

/// A menu entry (`flex w-full rounded-xl px-3 py-2 text-left text-sm text-text-secondary hover:bg-state-base-hover`).
class _MenuButton extends StatelessWidget {
  const _MenuButton({required this.label, required this.onPressed, required this.radius});
  final String label;
  final VoidCallback onPressed;
  final BorderRadius radius;

  @override
  Widget build(BuildContext context) => DifyPressable(
    onPressed: onPressed,
    builder: (context, hovered, focused) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(color: hovered ? DifyColors.stateBaseHover : null, borderRadius: radius),
      child: Text(
        label,
        style: difyTextStyle(DifyType.systemMdRegular, DifyColors.textSecondary),
      ),
    ),
  );
}

/// A 24 px header button (`size-6 rounded-lg text-text-tertiary hover:bg-state-base-hover
/// hover:text-text-secondary`, destructive: `hover:bg-state-destructive-hover hover:text-text-destructive`, disabled:
/// `text-text-disabled`, no hover).
class _HeaderButton extends StatelessWidget {
  const _HeaderButton({
    required this.label,
    required this.icon,
    this.onPressed,
    this.disabled = false,
    this.destructive = false,
    this.radius = DifyRadius.lg,
  });
  final String label;
  final Widget icon;
  final VoidCallback? onPressed;
  final bool disabled, destructive;
  final double radius;

  @override
  Widget build(BuildContext context) => DifyPressable(
    onPressed: onPressed,
    disabled: disabled,
    semanticLabel: label,
    builder: (context, hovered, focused) {
      final on = hovered && !disabled;
      final color = disabled
          ? DifyColors.textDisabled
          : on
          ? (destructive ? DifyColors.textDestructive : DifyColors.textSecondary)
          : DifyColors.textTertiary;
      return Container(
        width: 24,
        height: 24,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: on ? (destructive ? DifyColors.stateDestructiveHover : DifyColors.stateBaseHover) : null,
          borderRadius: BorderRadius.circular(radius),
          boxShadow: difyFocusRing(focused, width: 1),
        ),
        child: IconTheme.merge(
          data: IconThemeData(color: color),
          child: DefaultTextStyle.merge(
            style: TextStyle(color: color),
            child: icon,
          ),
        ),
      );
    },
  );
}
