import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../../canvas/canvas_controller.dart';
import '../../design/css_metrics.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';
import 'header_data.dart';
import 'header_widgets.dart';

/// collaboration/utils/user-color.ts `getUserColor`: a stable colour per user id (a JS string hash, mod 11).
Color getUserColor(String id) {
  const colors = [
    Color(0xFF155AEF), Color(0xFF0BA5EC), Color(0xFF444CE7), Color(0xFF7839EE), Color(0xFF4CA30D), //
    Color(0xFF0E9384), Color(0xFFDD2590), Color(0xFFFF4405), Color(0xFFD92D20), Color(0xFFF79009), Color(0xFF828DAD),
  ];
  var hash = 0;
  for (final c in id.codeUnits) {
    hash = ((hash << 5) - hash + c).toSigned(32);
  }
  return colors[hash.abs() % colors.length];
}

/// dify-ui's Avatar `sm` (24 px, `rounded-full bg-primary-600`, the initial in 10 px medium white) with the image.
class UserAvatar extends StatelessWidget {
  const UserAvatar({super.key, required this.name, this.url, this.color, this.ring = false});
  final String name;
  final String? url;
  final Color? color;

  /// `ring-1 ring-components-panel-bg`.
  final bool ring;

  @override
  Widget build(BuildContext context) => Container(
    width: 24,
    height: 24,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: color ?? const Color(0xFF155AEF),
      boxShadow: ring ? [BoxShadow(color: DifyColors.componentsPanelBg, spreadRadius: 1)] : null,
    ),
    clipBehavior: Clip.antiAlias,
    alignment: Alignment.center,
    child: url == null || url!.isEmpty
        ? Text(
            name.isEmpty ? '' : name[0].toUpperCase(),
            style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w500, color: Color(0xFFFFFFFF)),
          )
        : Image.network(url!, width: 24, height: 24, fit: BoxFit.cover, errorBuilder: (_, _, _) => const SizedBox()),
  );
}

/// header/online-users.tsx: the people editing this workflow, as overlapping avatars (all of 1–3, else two and
/// "+N" with the full list in a popover). Clicking someone else centres the canvas on their cursor (zoom 1, 800 ms).
class OnlineUsers extends StatefulWidget {
  const OnlineUsers({super.key});

  @override
  State<OnlineUsers> createState() => _OnlineUsersState();
}

class _OnlineUsersState extends State<OnlineUsers> with SingleTickerProviderStateMixin {
  Ticker? _ticker;
  bool _open = false;

  @override
  void dispose() {
    _ticker?.dispose();
    super.dispose();
  }

  void _jumpTo(WorkflowHeaderData data, CanvasController? canvas, String userId) {
    final cursor = data.cursorOf?.call(userId);
    if (cursor == null || canvas == null) return;
    final view = canvas.view;
    final from = view.center, fromScale = view.scale;
    const duration = Duration(milliseconds: 800);
    _ticker?.dispose();
    _ticker = createTicker((elapsed) {
      final t = Curves.easeInOutCubic.transform((elapsed.inMicroseconds / duration.inMicroseconds).clamp(0.0, 1.0));
      view
        ..scale = fromScale + (1 - fromScale) * t
        ..center = Offset.lerp(from, cursor, t)!;
      if (elapsed >= duration) _ticker?.stop();
    })..start();
  }

  @override
  Widget build(BuildContext context) {
    final data = WorkflowHeaderScope.of(context);
    final canvas = WorkflowHeaderScope.canvasOf(context);
    final users = data.onlineUsers;
    if (users == null) return const SizedBox.shrink();
    return ValueListenableBuilder(
      valueListenable: users,
      builder: (context, online, _) {
        if (online.isEmpty) return const SizedBox.shrink();
        final fallback = DifyI18n.tr('workflow', 'comments.fallback.user');
        final you = DifyI18n.tr('common', 'members.you');
        final showCount = online.length >= 4;
        final visible = online.take(showCount ? 2 : 3).toList();
        final remaining = online.length - visible.length;
        String nameOf(OnlineUser u) => u.username.isNotEmpty ? u.username : fallback;
        bool isMe(OnlineUser u) => u.userId == data.currentUserId;
        Widget displayName(OnlineUser u, Color suffix) => Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 4,
          children: [
            Flexible(
              child: Text(
                nameOf(u),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: difyTextStyle(DifyType.systemXsMedium, DifyColors.textSecondary),
              ),
            ),
            if (isMe(u)) Text(you, style: difyTextStyle(DifyType.systemXsMedium, suffix)),
          ],
        );
        Widget avatar(OnlineUser u, {bool ring = false}) =>
            UserAvatar(name: nameOf(u), url: u.avatar, color: isMe(u) ? null : getUserColor(u.userId), ring: ring);

        final avatars = <Widget>[];
        for (final u in visible) {
          Widget a = avatar(u, ring: true);
          if (!isMe(u)) {
            a = HeaderPressable(
              onPressed: () => _jumpTo(data, canvas, u.userId),
              builder: (context, hovered) => AnimatedScale(
                scale: hovered ? 1.1 : 1,
                duration: const Duration(milliseconds: 150),
                child: avatar(u, ring: true),
              ),
            );
          }
          avatars.add(
            DifyTooltip(
              placement: DifyPlacement.bottom,
              sideOffset: 4,
              surface: false,
              content: _NameTip(child: displayName(u, DifyColors.textQuaternary)),
              child: a,
            ),
          );
        }
        // `-ml-1.5` overlap; earlier avatars on top (`zIndex: visibleUsers.length - index`).
        Widget row = SizedBox(
          height: 24,
          width: 24.0 + (avatars.length - 1) * 18,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              for (var i = avatars.length - 1; i >= 0; i--) Positioned(left: i * 18.0, top: 0, child: avatars[i]),
            ],
          ),
        );
        if (remaining > 0) {
          row = Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              row,
              DifyPopover(
                open: _open,
                onOpenChange: (v) => setState(() => _open = v),
                placement: DifyPlacement.bottomStart,
                sideOffset: 14,
                alignOffset: -48,
                surface: false,
                builder: (context, c) => HeaderPressable(
                  onPressed: c.toggle,
                  builder: (context, _) => Row(
                    mainAxisSize: MainAxisSize.min,
                    spacing: 4,
                    children: [
                      Container(
                        width: 24,
                        height: 24,
                        transform: Matrix4.translationValues(-4, 0, 0),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: DifyColors.componentsIconBgMidnightSolid,
                          boxShadow: [BoxShadow(color: DifyColors.componentsPanelBg, spreadRadius: 1)],
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          '+$remaining',
                          style: const TextStyle(
                            fontSize: 10,
                            height: 12 / 10,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFFFFFFFF),
                          ),
                        ),
                      ),
                      const _Chevron(),
                    ],
                  ),
                ),
                content: Container(
                  width: 240,
                  constraints: const BoxConstraints(maxHeight: 200),
                  padding: const EdgeInsets.all(4),
                  decoration: headerPopupDecoration(color: DifyColors.componentsPanelBgBlur, shadow: DifyShadows.lg),
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final u in online)
                          HeaderPressable(
                            disabled: isMe(u),
                            onPressed: () {
                              _jumpTo(data, canvas, u.userId);
                              setState(() => _open = false);
                            },
                            builder: (context, hovered) => Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                              decoration: BoxDecoration(
                                color: hovered ? DifyColors.componentsPanelOnPanelItemBgHover : null,
                                borderRadius: BorderRadius.circular(DifyRadius.lg),
                              ),
                              child: Row(
                                spacing: 8,
                                children: [
                                  avatar(u),
                                  Expanded(child: displayName(u, DifyColors.textTertiary)),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        }
        return DifyBlurredBox(
          blur: 10,
          borderRadius: BorderRadius.circular(16),
          decoration: BoxDecoration(
            color: DifyColors.componentsPanelBg,
            border: Border.all(color: DifyColors.componentsPanelBorder, width: Css.hairline),
            borderRadius: BorderRadius.circular(16),
            boxShadow: DifyShadows.xs,
          ),
          padding: remaining > 0 ? const EdgeInsets.fromLTRB(4, 4, 6, 4) : const EdgeInsets.symmetric(horizontal: 6),
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: remaining > 0 ? 87 - 10 : 0, minHeight: 32 - 1, maxHeight: 32 - 1),
            child: Row(mainAxisSize: MainAxisSize.min, children: [row]),
          ),
        );
      },
    );
  }
}

/// The tooltip box: `flex h-7 max-w-55 items-center rounded-md border-[0.5px] border-components-panel-border
/// bg-components-tooltip-bg px-3 py-1.5 shadow-lg`.
class _NameTip extends StatelessWidget {
  const _NameTip({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => DifyBlurredBox(
    blur: 10,
    borderRadius: BorderRadius.circular(DifyRadius.md),
    decoration: BoxDecoration(
      color: DifyColors.componentsTooltipBg,
      border: Border.all(color: DifyColors.componentsPanelBorder, width: Css.hairline),
      borderRadius: BorderRadius.circular(DifyRadius.md),
      boxShadow: DifyShadows.lg,
    ),
    padding: const EdgeInsets.symmetric(horizontal: 12),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 220 - 24, minHeight: 28),
      child: Center(widthFactor: 1, child: child),
    ),
  );
}

/// Heroicons' 20 px solid chevron-down at 12 px in gray-500.
class _Chevron extends StatelessWidget {
  const _Chevron();

  @override
  Widget build(BuildContext context) => const SizedBox.square(
    dimension: 12,
    child: CustomPaint(painter: _ChevronPainter()),
  );
}

class _ChevronPainter extends CustomPainter {
  const _ChevronPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / 20;
    final p = Path()
      ..moveTo(5.22 * k, 8.22 * k)
      ..lineTo(6.28 * k, 7.16 * k)
      ..lineTo(10 * k, 10.94 * k)
      ..lineTo(13.72 * k, 7.16 * k)
      ..lineTo(14.78 * k, 8.22 * k)
      ..lineTo(10 * k, 13.06 * k)
      ..close();
    canvas.drawPath(p, Paint()..color = const Color(0xFF667085));
  }

  @override
  bool shouldRepaint(_ChevronPainter old) => false;
}
