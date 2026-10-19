/// The comment list on the right in comment mode (panel/comments-panel/index.tsx): every thread with its
/// participants, author, time, text and reply count; filters (all / only yours, show resolved), resolving, and
/// opening a thread.
library;

import 'package:flutter/widgets.dart';

import '../../canvas/canvas_controller.dart';
import '../../canvas/canvas_input.dart' show ControlMode;
import '../../design/css_metrics.dart';
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../header/format.dart' as fmt;
import '../panel_fields/controls.dart' show DifySwitch;
import '../store/workflow_store.dart';
import '../store/workflow_store_scope.dart';
import 'comment_icon.dart' show UserAvatarList;
import 'workflow_comment.dart';

/// Shown in comment mode only (workflow-panel.tsx `controlMode === 'comment' && <CommentsPanel />`).
class CommentsPanel extends StatelessWidget {
  const CommentsPanel({super.key, required this.canvas, this.formatTimeFromNow});
  final CanvasController canvas;
  final String Function(int milliseconds)? formatTimeFromNow;

  @override
  Widget build(BuildContext context) {
    final store = WorkflowStoreScope.of(context);
    final source = CommentsScope.maybeOf(context);
    if (source == null) return const SizedBox.shrink();
    return ValueListenableBuilder(
      valueListenable: store.controlMode,
      builder: (context, mode, _) => mode != ControlMode.comment
          ? const SizedBox.shrink()
          : CommentsPanelBody(source: source, store: store, canvas: canvas, formatTimeFromNow: formatTimeFromNow),
    );
  }
}

/// The panel itself (`w-105 rounded-l-2xl border bg-components-panel-bg`).
class CommentsPanelBody extends StatefulWidget {
  const CommentsPanelBody({
    super.key,
    required this.source,
    required this.store,
    required this.canvas,
    this.formatTimeFromNow,
  });
  final CommentsStore source;
  final WorkflowStore store;
  final CanvasController canvas;
  final String Function(int milliseconds)? formatTimeFromNow;

  @override
  State<CommentsPanelBody> createState() => _CommentsPanelBodyState();
}

class _CommentsPanelBodyState extends State<CommentsPanelBody> {
  late WorkflowComments _actions = _make();
  bool _onlyMine = false, _showFilter = false;

  WorkflowComments _make() => WorkflowComments(source: widget.source, store: widget.store, canvas: widget.canvas);

  @override
  void didUpdateWidget(CommentsPanelBody old) {
    super.didUpdateWidget(old);
    if (old.source != widget.source || old.store != widget.store || old.canvas != widget.canvas) {
      _actions.dispose();
      _actions = _make();
    }
  }

  @override
  void dispose() {
    _actions.dispose();
    super.dispose();
  }

  Future<void> _resolve(Comment c) async {
    if (c.resolved) return;
    await _actions.resolve(c.id);
    widget.store.setActiveCommentId(c.id);
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store, source = widget.source;
    return ListenableBuilder(
      listenable: Listenable.merge([source, store.activeCommentId, store.showResolvedComments]),
      builder: (context, _) {
        final showResolved = store.showResolvedComments.value;
        final me = source.currentUserId;
        final list = [
          for (final c in source.comments)
            if ((showResolved || !c.resolved) && (!_onlyMine || c.createdBy == me)) c,
        ];
        final hasFilter = _onlyMine || !showResolved;
        final header = Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  tw('comments.panelTitle'),
                  style: difyTextStyle(DifyType.systemXlSemibold, DifyColors.textPrimary),
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                spacing: 8,
                children: [
                  DifyPressable(
                    semanticLabel: tw('comments.aria.filterComments'),
                    onPressed: () => setState(() => _showFilter = !_showFilter),
                    builder: (context, hovered, focused) => Container(
                      width: 24,
                      height: 24,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: hovered || hasFilter ? DifyColors.stateAccentActive : null,
                        borderRadius: BorderRadius.circular(DifyRadius.md),
                      ),
                      child: RemixIcon(
                        'filter-3-line',
                        size: 16,
                        color: hovered || hasFilter ? DifyColors.textAccent : DifyColors.textSecondary,
                      ),
                    ),
                  ),
                  const DifyDivider.vertical(length: 14, margin: EdgeInsets.zero),
                  DifyPressable(
                    semanticLabel: tw('comments.aria.closeComment'),
                    onPressed: () {
                      store
                        ..setControlMode(ControlMode.pointer)
                        ..setActiveCommentId(null);
                    },
                    builder: (context, hovered, focused) => SizedBox.square(
                      dimension: 24,
                      child: Center(child: RemixIcon('close-line', size: 16, color: DifyColors.textTertiary)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
        return Container(
          width: 420,
          decoration: BoxDecoration(
            color: DifyColors.componentsPanelBg,
            border: Border.all(color: DifyColors.componentsPanelBorder),
            borderRadius: const BorderRadius.horizontal(left: Radius.circular(DifyRadius.xxl)),
          ),
          child: Stack(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  header,
                  Expanded(
                    child: list.isEmpty
                        ? (source.loading && !source.loaded
                              ? const SizedBox.shrink()
                              : Padding(
                                  padding: const EdgeInsets.only(top: 24),
                                  child: Text(
                                    tw('comments.noComments'),
                                    textAlign: TextAlign.center,
                                    style: difyTextStyle(DifyType.systemSmRegular, DifyColors.textTertiary),
                                  ),
                                ))
                        : ListView(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            children: [
                              for (final c in list)
                                _CommentCard(
                                  key: ValueKey(c.id),
                                  comment: c,
                                  source: source,
                                  active: store.activeCommentId.value == c.id,
                                  formatTimeFromNow: widget.formatTimeFromNow,
                                  onSelect: () => _actions.open(c),
                                  onResolve: () => _resolve(c),
                                ),
                            ],
                          ),
                  ),
                ],
              ),
              if (_showFilter)
                Positioned(
                  top: 16 + 36,
                  right: 16 + 40,
                  child: _FilterMenu(
                    onlyMine: _onlyMine,
                    showResolved: showResolved,
                    onOnlyMine: (v) => setState(() {
                      _onlyMine = v;
                      _showFilter = false;
                    }),
                    onShowResolved: store.setShowResolvedComments,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// The filter popup (`min-w-46 rounded-xl border-[0.5px] bg-components-panel-bg-blur p-1 shadow-lg`).
class _FilterMenu extends StatelessWidget {
  const _FilterMenu({
    required this.onlyMine,
    required this.showResolved,
    required this.onOnlyMine,
    required this.onShowResolved,
  });
  final bool onlyMine, showResolved;
  final ValueChanged<bool> onOnlyMine, onShowResolved;

  @override
  Widget build(BuildContext context) {
    final label = TextStyle(fontSize: 14, height: 20 / 14, color: DifyColors.textSecondary);
    Widget option(String text, bool checked, VoidCallback onPressed) => DifyPressable(
      onPressed: onPressed,
      builder: (context, hovered, focused) => Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: hovered
              ? DifyColors.stateBaseHover
              : checked
              ? DifyColors.componentsPanelOnPanelItemBg
              : null,
          borderRadius: BorderRadius.circular(DifyRadius.md),
        ),
        child: Row(
          children: [
            Expanded(child: Text(text, style: label)),
            if (checked) const RemixIcon('check-line', size: 16, color: Color(0xFF155AEF)),
          ],
        ),
      ),
    );
    return DifyBlurredBox(
      blur: 10,
      borderRadius: BorderRadius.circular(DifyRadius.xl),
      decoration: BoxDecoration(
        color: DifyColors.componentsPanelBgBlur,
        border: Border.all(color: DifyColors.componentsPanelBorder, width: Css.hairline),
        borderRadius: BorderRadius.circular(DifyRadius.xl),
        boxShadow: DifyShadows.lg,
      ),
      padding: const EdgeInsets.all(4),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 184 - 8 - 1),
        child: IntrinsicWidth(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              option(tw('comments.filter.all'), !onlyMine, () => onOnlyMine(false)),
              const SizedBox(height: 4),
              option(tw('comments.filter.onlyYourThreads'), onlyMine, () => onOnlyMine(true)),
              const DifyDivider(margin: EdgeInsets.symmetric(vertical: 4)),
              Padding(
                padding: const EdgeInsets.all(8),
                child: Row(
                  spacing: 8,
                  children: [
                    Expanded(child: Text(tw('comments.filter.showResolved'), style: label)),
                    DifySwitch(
                      checked: showResolved,
                      onCheckedChange: onShowResolved,
                      semanticLabel: tw('comments.filter.showResolved'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A thread in the list (`group mb-2 rounded-xl bg-components-panel-bg p-3`, hovered or open:
/// `bg-components-panel-on-panel-item-bg-hover`).
class _CommentCard extends StatefulWidget {
  const _CommentCard({
    super.key,
    required this.comment,
    required this.source,
    required this.active,
    required this.onSelect,
    required this.onResolve,
    this.formatTimeFromNow,
  });
  final Comment comment;
  final CommentsStore source;
  final bool active;
  final VoidCallback onSelect, onResolve;
  final String Function(int milliseconds)? formatTimeFromNow;

  @override
  State<_CommentCard> createState() => _CommentCardState();
}

class _CommentCardState extends State<_CommentCard> {
  bool _hovered = false, _resolveHovered = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.comment, source = widget.source;
    final when = (widget.formatTimeFromNow ?? fmt.formatTimeFromNow)(c.updatedAt.millisecondsSinceEpoch);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onSelect,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: _hovered || widget.active
                ? DifyColors.componentsPanelOnPanelItemBgHover
                : DifyColors.componentsPanelBg,
            borderRadius: BorderRadius.circular(DifyRadius.xl),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    UserAvatarList(users: participantsOf(source, c), currentUserId: source.currentUserId),
                    const Spacer(),
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: c.resolved
                          ? RemixIcon('checkbox-circle-fill', size: 16, color: DifyColors.textSecondary)
                          : Semantics(
                              button: true,
                              label: tw('comments.aria.resolveComment'),
                              child: MouseRegion(
                                cursor: SystemMouseCursors.click,
                                onEnter: (_) => setState(() => _resolveHovered = true),
                                onExit: (_) => setState(() => _resolveHovered = false),
                                child: GestureDetector(
                                  onTap: widget.onResolve,
                                  child: RemixIcon(
                                    'checkbox-circle-line',
                                    size: 16,
                                    color: _resolveHovered ? DifyColors.textSecondary : DifyColors.textTertiary,
                                  ),
                                ),
                              ),
                            ),
                    ),
                  ],
                ),
              ),
              Row(
                spacing: 8,
                children: [
                  Flexible(
                    child: Text(
                      nameOf(source, c.createdBy, c.createdByName),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: difyTextStyle(DifyType.systemSmMedium, DifyColors.textPrimary),
                    ),
                  ),
                  Text(when, style: difyTextStyle(DifyType.system2xsRegular, DifyColors.textTertiary)),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  c.content,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: difyTextStyle(DifyType.systemSmRegular, DifyColors.textSecondary),
                ),
              ),
              if (c.replyCount > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    '${c.replyCount} ${tw('comments.reply')}',
                    style: difyTextStyle(DifyType.system2xsRegular, DifyColors.textTertiary),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
