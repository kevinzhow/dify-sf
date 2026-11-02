/// dify-sf's phone bottom navigation (a dify-sf divergence: Dify's console navigates from a 248 px side bar).
library;

import 'package:flutter/widgets.dart';

import '../dify_palette.dart';
import '../dify_tokens.g.dart';
import '../dify_type_tw.dart';
import 'button_style.dart';
import 'form_control_shared.dart' show DifyFocusDecoration, difyFocusRing;
import 'text.dart';

/// One destination of a [DifyNavigationBar]: an [icon] (22 px by convention, without a colour of its own so it takes
/// the bar's), an optional [selectedIcon], a short [label] and an optional [badgeCount] (hidden at 0 or null).
@immutable
class DifyNavigationDestination {
  const DifyNavigationDestination({required this.icon, required this.label, this.selectedIcon, this.badgeCount});

  final Widget icon;
  final Widget? selectedIcon;
  final String label;
  final int? badgeCount;
}

/// The phone's bottom navigation (mockup 1, gen.py `.navbar`): 3 to 5 equal [destinations] in a [height] 64 px bar,
/// `bg-components-panel-bg` with a 1 px divider-subtle top border. Each destination is an icon in a 56x30 pill over a
/// 12 px label (`gap-[3px]`): text-tertiary, or for the [selectedIndex] text-accent, semibold, on a
/// state-accent-active pill. The whole column is the touch target.
///
/// Edge to edge: the background reaches the window's bottom and side edges; the destinations stay above the
/// bottom inset and clear of the side insets (`MediaQuery.padding`; with the keyboard open that inset is zero, so
/// the keyboard is never added to it).
class DifyNavigationBar extends StatelessWidget {
  const DifyNavigationBar({
    super.key,
    required this.destinations,
    required this.selectedIndex,
    this.onDestinationSelected,
  });

  /// The bar's height above the bottom inset.
  static const height = 64.0;

  final List<DifyNavigationDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int>? onDestinationSelected;

  @override
  Widget build(BuildContext context) {
    assert(destinations.length >= 3 && destinations.length <= 5, 'A navigation bar has 3 to 5 destinations');
    final insets = MediaQuery.paddingOf(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: DifyColors.componentsPanelBg,
        border: Border(top: BorderSide(color: DifyColors.dividerSubtle)),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(insets.left, 0, insets.right, insets.bottom),
        // As tall as the tallest destination (scaled text grows the bar), at least [height]; every cell fills it.
        child: IntrinsicHeight(
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: height),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (i, d) in destinations.indexed)
                  Expanded(
                    child: _Destination(
                      destination: d,
                      selected: i == selectedIndex,
                      onPressed: onDestinationSelected == null ? null : () => onDestinationSelected!(i),
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

class _Destination extends StatelessWidget {
  const _Destination({required this.destination, required this.selected, this.onPressed});

  final DifyNavigationDestination destination;
  final bool selected;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final d = destination;
    final color = selected ? DifyColors.textAccent : DifyColors.textTertiary;
    final count = d.badgeCount ?? 0;
    return DifyPressable(
      onPressed: onPressed,
      builder: (context, hovered, focused) => Semantics(
        selected: selected,
        value: count > 0 ? DifyCountBadge.text(count) : null,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          spacing: 3,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                DecoratedBox(
                  decoration: DifyFocusDecoration(
                    color: selected
                        ? DifyColors.stateAccentActive
                        : hovered
                        ? DifyColors.stateBaseHover
                        : null,
                    borderRadius: BorderRadius.circular(15),
                    boxShadow: difyFocusRing(focused),
                  ),
                  child: SizedBox(
                    width: 56,
                    height: 30,
                    child: Center(
                      child: IconTheme.merge(
                        data: IconThemeData(color: color),
                        child: DefaultTextStyle.merge(
                          style: TextStyle(color: color),
                          child: ExcludeSemantics(child: selected ? d.selectedIcon ?? d.icon : d.icon),
                        ),
                      ),
                    ),
                  ),
                ),
                if (count > 0) Positioned(left: 34, top: -4, child: ExcludeSemantics(child: DifyCountBadge(count))),
              ],
            ),
            DifyText(d.label, selected ? DifyType.systemXsSemibold : DifyType.systemXsRegular, color: color),
          ],
        ),
      ),
    );
  }
}

/// The count badge dify-sf already draws on the workflow checklist (`h-4.5 min-w-4.5 rounded-full
/// bg-text-warning-secondary text-[11px] font-semibold text-white`), ringed in the panel colour so it reads over an
/// icon. Counts above 99 show as 99+.
class DifyCountBadge extends StatelessWidget {
  const DifyCountBadge(this.count, {super.key});

  final int count;

  /// The badge's text for [count].
  static String text(int count) => count > 99 ? '99+' : '$count';

  @override
  Widget build(BuildContext context) => Container(
    height: 18,
    constraints: const BoxConstraints(minWidth: 18),
    padding: const EdgeInsets.symmetric(horizontal: 4),
    decoration: BoxDecoration(
      color: DifyColors.textWarningSecondary,
      border: Border.all(color: DifyColors.componentsPanelBg),
      borderRadius: BorderRadius.circular(9),
    ),
    alignment: Alignment.center,
    child: DifyTextLine(
      text(count),
      style: difyTextStyle(DifyTw.text11Semibold, DifyTailwind.white).copyWith(height: 1),
    ),
  );
}
