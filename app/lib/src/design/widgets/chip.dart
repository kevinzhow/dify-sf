/// Dify's Chip (web/app/components/base/chip).
library;

import 'package:flutter/widgets.dart';

import '../../i18n/dify_i18n.dart';
import '../css_metrics.dart';
import '../dify_icon.dart';
import '../dify_tokens.g.dart';
import 'widgets.dart';

String _c(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('common', key, params);

/// A chip option (`Item`): its value and name.
typedef ChipItem = ({String value, String name});

/// base/chip: a select whose trigger shows the selected item's name (with a filter icon, or [leftIcon]); with a value
/// it turns into a secondary button with a clear button on its right (`aria-label` "Clear `name`"), else it shows a
/// down arrow. The popup (`w-60`, or [panelWidth]) lists the items with a check on the selected one.
class DifyChip extends StatefulWidget {
  const DifyChip({
    super.key,
    required this.value,
    required this.items,
    required this.onSelect,
    required this.onClear,
    this.showLeftIcon = true,
    this.leftIcon,
    this.minWidth,
    this.panelWidth = 240,
  });

  final String value;
  final List<ChipItem> items;
  final ValueChanged<ChipItem> onSelect;
  final VoidCallback onClear;
  final bool showLeftIcon;
  final Widget? leftIcon;

  /// A call site's `min-w-*` (`min-w-37.5` for the period and annotation chips).
  final double? minWidth;
  final double panelWidth;

  @override
  State<DifyChip> createState() => _DifyChipState();
}

class _DifyChipState extends State<DifyChip> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.items.where((i) => i.value == widget.value).firstOrNull;
    final trigger = selected?.name ?? '';
    final hasValue = selected != null && widget.value.isNotEmpty;
    final clearLabel = trigger.isNotEmpty ? '${_c('operation.clear')} $trigger' : _c('operation.clear');
    return Stack(
      children: [
        DifyDropdownMenu(
          placement: DifyPlacement.bottomStart,
          width: widget.panelWidth,
          open: _open,
          onOpenChange: (v) => setState(() => _open = v),
          builder: (context, controller) => Semantics(
            expanded: _open,
            child: DifyPressable(
              semanticLabel: trigger.isNotEmpty ? trigger : _c('placeholder.select'),
              onPressed: controller.toggle,
              builder: (context, hovered, focused) {
                final active = hovered || _open;
                final chip = Container(
                  constraints: BoxConstraints(minHeight: 32, minWidth: widget.minWidth ?? 0),
                  padding: EdgeInsets.fromLTRB(8, 4, hasValue ? 24 : 8, 4),
                  decoration: DifyFocusDecoration(
                    color: hasValue
                        ? (active
                              ? DifyColors.componentsButtonSecondaryBgHover
                              : DifyColors.componentsButtonSecondaryBg)
                        : (active ? DifyColors.stateBaseHoverAlt : DifyColors.componentsInputBgNormal),
                    borderRadius: BorderRadius.circular(DifyRadius.lg),
                    border: Border.all(
                      color: hasValue
                          ? (active
                                ? DifyColors.componentsButtonSecondaryBorderHover
                                : DifyColors.componentsButtonSecondaryBorder)
                          : const Color(0x00000000),
                      width: Css.hairline,
                    ),
                    boxShadow: [if (hasValue) ...DifyShadows.xs, if (focused) difyFocusRingShadow()],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    spacing: 4,
                    children: [
                      if (widget.showLeftIcon)
                        Padding(
                          padding: const EdgeInsets.all(2),
                          child:
                              widget.leftIcon ??
                              RemixIcon(
                                'filter-3-line',
                                size: 16,
                                color: hasValue ? DifyColors.textSecondary : DifyColors.textTertiary,
                              ),
                        ),
                      Flexible(
                        fit: widget.minWidth == null ? FlexFit.loose : FlexFit.tight,
                        // `first-line:p-1`: ::first-line takes no padding, so none.
                        child: DifyTextLine(
                          trigger,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: difyTextStyle(
                            DifyType.systemSmRegular,
                            hasValue ? DifyColors.textSecondary : DifyColors.textTertiary,
                          ),
                        ),
                      ),
                      if (!hasValue) RemixIcon('arrow-down-s-line', size: 16, color: DifyColors.textTertiary),
                    ],
                  ),
                );
                // `min-w-*`: at least that wide, else as wide as its content (not the whole row).
                return widget.minWidth == null ? chip : IntrinsicWidth(child: chip);
              },
            ),
          ),
          children: [
            DifyMenuRadioGroup<String>(
              value: widget.value,
              onValueChange: (v) {
                final item = widget.items.where((i) => i.value == v).firstOrNull;
                if (item != null) widget.onSelect(item);
              },
              children: [
                for (final item in widget.items)
                  DifyMenuRadioItem<String>(
                    key: ValueKey('chip-option-${item.value}'),
                    value: item.value,
                    closeOnClick: true,
                    child: DifyTextLine(item.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
              ],
            ),
          ],
        ),
        if (hasValue)
          Positioned(
            right: 6,
            top: 0,
            bottom: 0,
            child: Center(
              child: DifyPressable(
                semanticLabel: clearLabel,
                onPressed: widget.onClear,
                builder: (context, hovered, focused) => SizedBox.square(
                  dimension: 20,
                  child: Center(
                    child: RemixIcon(
                      'close-circle-fill',
                      size: 14,
                      color: hovered ? DifyColors.textTertiary : DifyColors.textQuaternary,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
