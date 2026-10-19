/// header/account-setting/collapse (Dify 1.17.1, `Collapse`): a titled list that opens and closes (the account page's
/// "Show N apps").
library;

import 'package:flutter/widgets.dart';

import '../dify_icon.dart';
import '../dify_tokens.g.dart';
import 'button_style.dart';
import 'text.dart';

/// Collapse: `overflow-hidden rounded-xl bg-background-section-burn` with the toggle (`px-3 py-2 text-xs leading-4.5
/// font-medium text-text-secondary`, drawn `system-xs-medium` in a `py-[9px]` row, a heroicons chevron right / down `size-3` in `text-components-button-tertiary-text`,
/// named by [title]) and, open, the items on `mx-1 mb-1 rounded-lg border-t border-divider-subtle
/// bg-components-panel-on-panel-item-bg py-1`, each a button reporting [onSelect].
class DifyCollapse<T> extends StatefulWidget {
  const DifyCollapse({
    super.key,
    required this.title,
    required this.items,
    required this.itemBuilder,
    this.onSelect,
  });

  final String title;
  final List<T> items;
  final Widget Function(BuildContext context, T item) itemBuilder;
  final ValueChanged<T>? onSelect;

  @override
  State<DifyCollapse<T>> createState() => _DifyCollapseState<T>();
}

class _DifyCollapseState<T> extends State<DifyCollapse<T>> {
  bool _open = false;

  @override
  Widget build(BuildContext context) => Container(
    clipBehavior: Clip.antiAlias,
    decoration: BoxDecoration(
      color: DifyColors.backgroundSectionBurn,
      borderRadius: BorderRadius.circular(DifyRadius.xl),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DifyPressable(
          key: const ValueKey('collapse-toggle'),
          semanticLabel: widget.title,
          onPressed: () => setState(() => _open = !_open),
          builder: (context, hovered, focused) => Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: focused
                ? BoxDecoration(
                    border: Border.all(color: DifyColors.componentsInputBorderActive),
                    borderRadius: BorderRadius.circular(DifyRadius.xl),
                  )
                : null,
            child: Row(
              children: [
                Expanded(
                  child: Text(widget.title, style: difyTextStyle(DifyType.systemXsMedium, DifyColors.textSecondary)),
                ),
                HeroIcon(
                  _open ? 'chevron-down' : 'chevron-right',
                  size: 12,
                  color: DifyColors.componentsButtonTertiaryText,
                ),
              ],
            ),
          ),
        ),
        if (_open)
          Container(
            margin: const EdgeInsets.fromLTRB(4, 0, 4, 4),
            padding: const EdgeInsets.symmetric(vertical: 4),
            decoration: BoxDecoration(
              color: DifyColors.componentsPanelOnPanelItemBg,
              borderRadius: BorderRadius.circular(DifyRadius.lg),
              border: Border(top: BorderSide(color: DifyColors.dividerSubtle)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final item in widget.items)
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: widget.onSelect == null ? null : () => widget.onSelect!(item),
                    child: widget.itemBuilder(context, item),
                  ),
              ],
            ),
          ),
      ],
    ),
  );
}
