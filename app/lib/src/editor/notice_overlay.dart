import 'package:dify_sf_app/src/design/dify_icon.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import 'editor_controller.dart';
import 'notices.dart';

/// Non-modal notices about edits that were not applied, stacked at the bottom-left of the canvas.
class NoticeOverlay extends StatelessWidget {
  const NoticeOverlay({super.key, required this.controller});

  final EditorController controller;

  @override
  Widget build(BuildContext context) {
    if (controller.notices.isEmpty) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.bottomLeft,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final n in controller.notices)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: _NoticeCard(key: ValueKey('notice-${n.id}'), notice: n, controller: controller),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NoticeCard extends StatefulWidget {
  const _NoticeCard({super.key, required this.notice, required this.controller});
  final Notice notice;
  final EditorController controller;

  @override
  State<_NoticeCard> createState() => _NoticeCardState();
}

class _NoticeCardState extends State<_NoticeCard> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    widget.notice.addListener(_changed);
    _tick = Timer.periodic(const Duration(seconds: 15), (_) => _changed()); // "just now" -> "1 min ago"
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.notice.removeListener(_changed);
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.notice;
    final scheme = Theme.of(context).colorScheme;
    final (bg, fg, icon) = switch (n.kind) {
      NoticeKind.conflict => (Colors.amber.shade50, Colors.amber.shade900, 'git-merge-line'),
      NoticeKind.refused => (scheme.errorContainer, scheme.onErrorContainer, 'forbid-line'),
      NoticeKind.lost => (scheme.errorContainer, scheme.onErrorContainer, 'error-warning-line'),
      NoticeKind.info => (scheme.secondaryContainer, scheme.onSecondaryContainer, 'information-line'),
    };
    return DifySurface(
      elevation: 3,
      color: bg,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                RemixIcon(icon, size: 20, color: fg),
                const SizedBox(width: 8),
                Expanded(
                  child: DifyTextLine(
                    n.message,
                    key: const Key('notice-message'),
                    style: TextStyle(color: fg, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            if (n.detail != null && n.detail!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 28, top: 4),
                child: DifyTextLine(n.detail!, style: TextStyle(color: fg.withValues(alpha: 0.85), fontSize: 12)),
              ),
            Padding(
              padding: const EdgeInsets.only(left: 20, top: 4),
              child: Wrap(
                spacing: 4,
                children: [
                  if (n.awaitingVerdict)
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: DifyTextLine(
                        'Waiting for the server to confirm…',
                        style: TextStyle(color: fg, fontSize: 12, fontStyle: FontStyle.italic),
                      ),
                    ),
                  if (n.canReapply)
                    DifyButton(
                      variant: DifyButtonVariant.ghost,
                      key: const Key('reapply'),
                      onPressed: () => widget.controller.reapply(n),
                      child: const DifyTextLine('Re-apply on latest'),
                    ),
                  if (!n.awaitingVerdict)
                    DifyButton(
                      variant: DifyButtonVariant.ghost,
                      key: const Key('discard'),
                      onPressed: () => widget.controller.removeNotice(n),
                      child: DifyTextLine(n.op == null ? 'Dismiss' : 'Discard'),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
