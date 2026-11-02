/// dify-sf's phone step list (a dify-sf divergence: Dify's workflow editor is a canvas only): the parts of the
/// workflow editor's Steps view (mockup 2-steps, gen.py; run states as mockup 7-run). A list of rows, each with the
/// lanes it is nested in drawn as rails on its left ([DifyStepRails]): step cards ([DifyStepCard]), the line with a
/// "+" between steps ([DifyStepConnector]), a lane's label ([DifyStepLaneLabel]), "continues at" links
/// ([DifyStepLinkRow]) and "Add step" rows for empty lanes ([DifyStepAddRow]).
///
/// Every interactive part is a 48 px touch target ([DifyTouch.minTarget]).
library;

import 'package:flutter/widgets.dart';

import '../css_metrics.dart' show CssDashedBorder;
import '../dify_icon.dart';
import '../dify_phone_tokens.dart';
import '../dify_tokens.g.dart';
import 'responsive.dart' show DifyTouch;
import 'button_style.dart' show DifyPressable;
import 'form_control_shared.dart' show DifyFocusDecoration, difyFocusRing;
import 'text.dart';

/// The step list's geometry (gen.py: a lane is `margin-left 14px; padding-left 14px; border-left 2px`, the
/// connector's line is 27 px in, under the cards' 32 px icons).
abstract final class DifyStepMetrics {
  /// How far each nesting level moves the content right.
  static const indent = 30.0;

  /// The left edge of the rail of nesting level [level] (0: the outermost), 2 px wide.
  static double railX(int level) => 14 + indent * level;
  static const railWidth = 2.0;

  /// The middle of the connector's line (and of a card's icon), from the content's left edge.
  static const lineX = 28.0;

  /// A row holding a touch target.
  static const rowHeight = DifyTouch.minTarget;

  /// The space between two lanes of one branch (where the next lane's rail starts).
  static const laneGap = 6.0;
}

/// Draws the rails of the lanes and bodies a row is nested in ([rails]: their colours, outermost first) on its left
/// and moves [child] right by one [DifyStepMetrics.indent] per level. [opensLane] starts the innermost rail
/// [DifyStepMetrics.laneGap] below the row's top: a lane's first row, so that two lanes of one branch read as two.
class DifyStepRails extends StatelessWidget {
  const DifyStepRails({super.key, required this.rails, this.opensLane = false, required this.child});

  final List<Color> rails;
  final bool opensLane;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (rails.isEmpty) return child;
    return CustomPaint(
      painter: _RailsPainter(rails, opensLane, Directionality.of(context)),
      child: Padding(
        padding: EdgeInsetsDirectional.only(start: DifyStepMetrics.indent * rails.length),
        child: child,
      ),
    );
  }
}

class _RailsPainter extends CustomPainter {
  _RailsPainter(this.rails, this.opensLane, this.direction);
  final List<Color> rails;
  final bool opensLane;
  final TextDirection direction;

  @override
  void paint(Canvas canvas, Size size) {
    for (final (i, color) in rails.indexed) {
      final top = opensLane && i == rails.length - 1 ? DifyStepMetrics.laneGap : 0.0;
      final start = DifyStepMetrics.railX(i);
      final left = direction == TextDirection.rtl ? size.width - start - DifyStepMetrics.railWidth : start;
      canvas.drawRect(Rect.fromLTWH(left, top, DifyStepMetrics.railWidth, size.height - top), Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(_RailsPainter old) =>
      old.opensLane != opensLane || old.direction != direction || !_sameColors(old.rails, rails);

  static bool _sameColors(List<Color> a, List<Color> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// A step's card (gen.py: `rounded 14px`, a 1 px components-panel-border border on components-panel-bg, `gap-3 p-3`):
/// [leading] (the block's 32 px icon), the one-line [title] (15 px semibold) over a one-line [subtitle]
/// (system-xs-regular, text-tertiary unless [subtitleColor]), [trailing] status icons, and a chevron unless
/// [chevron] is false. A tap calls [onTap]; a long press (or a secondary click) [onLongPress].
///
/// States: [selected] (a 2 px option-card-selected border, as mockup 2's selected step), [statusColor] (a run status
/// or a checklist error: a 1.5 px border in that colour, as mockup 7), [highlighted] (an accent wash and border, for
/// a step the list just scrolled to), [dimmed] (70 % opacity: a step waiting in a run, as the canvas draws it).
class DifyStepCard extends StatelessWidget {
  const DifyStepCard({
    super.key,
    required this.title,
    this.subtitle,
    this.subtitleColor,
    this.leading,
    this.trailing = const [],
    this.chevron = true,
    this.onTap,
    this.onLongPress,
    this.selected = false,
    this.highlighted = false,
    this.statusColor,
    this.dimmed = false,
    this.semanticLabel,
  });

  final String title;
  final String? subtitle;
  final Color? subtitleColor;
  final Widget? leading;
  final List<Widget> trailing;
  final bool chevron;
  final VoidCallback? onTap, onLongPress;
  final bool selected, highlighted, dimmed;
  final Color? statusColor;
  final String? semanticLabel;

  static const radius = 14.0;

  @override
  Widget build(BuildContext context) {
    final (borderColor, borderWidth) = highlighted
        ? (DifyColors.stateAccentSolid, 2.0)
        : selected
        ? (DifyColors.componentsOptionCardOptionSelectedBorder, 2.0)
        : statusColor != null
        ? (statusColor!, 1.5)
        : (DifyColors.componentsPanelBorder, 1.0);
    Widget card(bool pressed, bool focused) => AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      decoration: DifyFocusDecoration(
        color: highlighted
            ? Color.alphaBlend(DifyColors.stateAccentHover, DifyColors.componentsPanelBg)
            : pressed
            ? Color.alphaBlend(DifyColors.stateBaseHover, DifyColors.componentsPanelBg)
            : DifyColors.componentsPanelBg,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: borderColor, width: borderWidth),
        boxShadow: difyFocusRing(focused),
      ),
      padding: const EdgeInsets.all(12),
      child: Row(
        spacing: 12,
        children: [
          if (leading case final l?)
            ExcludeSemantics(
              child: SizedBox.square(dimension: 32, child: Center(child: l)),
            ),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 2,
              children: [
                DifyText(title, DifyPhoneType.labelStrong),
                if (subtitle case final s? when s.isNotEmpty)
                  DifyText(s, DifyType.systemXsRegular, color: subtitleColor ?? DifyColors.textTertiary),
              ],
            ),
          ),
          ...trailing,
          if (chevron)
            ExcludeSemantics(child: RemixIcon('arrow-right-s-line', size: 20, color: DifyColors.textQuaternary)),
        ],
      ),
    );
    Widget main = DifyPressable(
      onPressed: onTap ?? onLongPress,
      semanticLabel: semanticLabel ?? [title, if (subtitle case final s? when s.isNotEmpty) s].join(', '),
      builder: (context, hovered, focused) => card(hovered, focused),
    );
    if (onLongPress case final long?) {
      // One node for assistive technology: the name, the tap and the long press.
      main = MergeSemantics(
        child: Semantics(
          onLongPress: long,
          child: GestureDetector(onLongPress: long, onSecondaryTap: long, child: main),
        ),
      );
    }
    return Opacity(opacity: dimmed ? 0.7 : 1, child: main);
  }
}

/// The line between two steps (gen.py: 2 px divider-regular, 27 px in) in a [DifyStepMetrics.rowHeight] row, with a
/// 24 px round "+" on it when [onAdd] is given (a 48 px target named [addLabel]). [end]: the line stops at the "+"
/// (after the last step of a flow).
class DifyStepConnector extends StatelessWidget {
  const DifyStepConnector({super.key, this.onAdd, this.addLabel, this.end = false});

  final VoidCallback? onAdd;
  final String? addLabel;
  final bool end;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: DifyStepMetrics.rowHeight,
    child: Stack(
      children: [
        PositionedDirectional(
          start: DifyStepMetrics.lineX - 1,
          top: 0,
          bottom: end ? DifyStepMetrics.rowHeight / 2 : 0,
          width: 2,
          child: ColoredBox(color: DifyColors.dividerRegular),
        ),
        if (onAdd case final add?)
          PositionedDirectional(
            start: DifyStepMetrics.lineX - 24,
            top: 0,
            width: 48,
            height: 48,
            child: DifyPressable(
              onPressed: add,
              semanticLabel: addLabel,
              builder: (context, hovered, focused) => Center(
                child: DecoratedBox(
                  decoration: DifyFocusDecoration(
                    color: hovered
                        ? Color.alphaBlend(DifyColors.stateBaseHover, DifyColors.componentsPanelBg)
                        : DifyColors.componentsPanelBg,
                    shape: BoxShape.circle,
                    border: Border.all(color: DifyColors.dividerRegular),
                    boxShadow: difyFocusRing(focused),
                  ),
                  child: SizedBox.square(
                    dimension: 24,
                    child: Center(child: RemixIcon('add-line', size: 16, color: DifyColors.textTertiary)),
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

/// A lane's label (gen.py: a 22 px `rounded-md px-2` chip, 12 px semibold in [color] on [color] at 13 %, `my 4/6`)
/// under the lane's gap: `IF words > 0`, `ELSE`, a class. One line, ellipsized.
class DifyStepLaneLabel extends StatelessWidget {
  const DifyStepLaneLabel(this.label, {super.key, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: DifyStepMetrics.laneGap + 4, bottom: 6),
    child: Align(
      alignment: AlignmentDirectional.centerStart,
      child: Semantics(
        header: true,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: color.withValues(alpha: color.a * 0.13),
            borderRadius: BorderRadius.circular(DifyRadius.md),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            child: DifyText(label, DifyType.systemXsSemibold, color: color),
          ),
        ),
      ),
    ),
  );
}

/// "Continues at …" ([label]): the flow goes on at a step shown elsewhere in the list; a tap ([onTap]) goes there.
/// A [DifyStepMetrics.rowHeight] row: a corner arrow and the label in text-accent, under the connector's line.
class DifyStepLinkRow extends StatelessWidget {
  const DifyStepLinkRow({super.key, required this.label, this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(minHeight: DifyStepMetrics.rowHeight),
    child: DifyPressable(
      onPressed: onTap,
      semanticLabel: label,
      builder: (context, hovered, focused) => Align(
        alignment: AlignmentDirectional.centerStart,
        child: DecoratedBox(
          decoration: DifyFocusDecoration(
            color: hovered ? DifyColors.stateAccentHover : null,
            borderRadius: BorderRadius.circular(DifyRadius.container),
            boxShadow: difyFocusRing(focused),
          ),
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(DifyStepMetrics.lineX - 9, 8, 12, 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 6,
              children: [
                RemixIcon('corner-down-right-line', size: 16, color: DifyColors.textAccent),
                Flexible(child: DifyText(label, DifyType.systemSmMedium, color: DifyColors.textAccent)),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// "Add step" ([label]) for an empty lane or body: a dashed 40 px box (components-panel-border, `rounded-xl`) with a
/// "+" in a [DifyStepMetrics.rowHeight] row; the whole row is the target for [onTap]. Disabled (text-disabled)
/// without [onTap].
class DifyStepAddRow extends StatelessWidget {
  const DifyStepAddRow({super.key, required this.label, this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final color = enabled ? DifyColors.textTertiary : DifyColors.textDisabled;
    return DifyPressable(
      onPressed: onTap,
      disabled: !enabled,
      semanticLabel: label,
      builder: (context, hovered, focused) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: DecoratedBox(
          decoration: DifyFocusDecoration(
            color: hovered && enabled ? DifyColors.stateBaseHover : null,
            borderRadius: BorderRadius.circular(DifyRadius.xl),
            boxShadow: difyFocusRing(focused),
          ),
          position: DecorationPosition.background,
          child: DecoratedBox(
            decoration: CssDashedBorder(color: DifyColors.componentsPanelBorder, radius: DifyRadius.xl),
            // 40 px inside the row's 4 px margins: a 48 px target that grows with the text.
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: DifyStepMetrics.rowHeight - 8),
              child: Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(DifyStepMetrics.lineX - 8, 4, 12, 4),
                child: Row(
                  spacing: 6,
                  children: [
                    RemixIcon('add-line', size: 16, color: color),
                    Flexible(child: DifyText(label, DifyType.systemSmMedium, color: color)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
