/// Dify's TabSliderPlain (web/app/components/base/tab-slider-plain).
library;

import 'package:flutter/widgets.dart';

import '../dify_tokens.g.dart';
import 'widgets.dart';

/// base/tab-slider-plain: the options side by side (`space-x-6`), each `pb-2.5 system-xl-semibold` (tertiary, the
/// active one primary with a 2 px brand line under it).
class DifyTabSliderPlain extends StatelessWidget {
  const DifyTabSliderPlain({
    super.key,
    required this.value,
    required this.onChange,
    required this.options,
    this.itemPaddingBottom = 10,
  });

  final String value;
  final ValueChanged<String> onChange;
  final List<({String value, Widget text})> options;

  /// `pb-2.5`, or a call site's `pb-3.5!`.
  final double itemPaddingBottom;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    spacing: 24,
    children: [
      for (final o in options)
        Flexible(
          child: GestureDetector(
            key: ValueKey('tab-slider-item-${o.value}'),
            behavior: HitTestBehavior.opaque,
            onTap: o.value == value ? null : () => onChange(o.value),
            child: MouseRegion(
              cursor: o.value == value ? MouseCursor.defer : SystemMouseCursors.click,
              child: Stack(
                children: [
                  Padding(
                    padding: EdgeInsets.only(bottom: itemPaddingBottom),
                    child: DefaultTextStyle.merge(
                      style: difyTextStyle(
                        DifyType.systemXlSemibold,
                        o.value == value ? DifyColors.textPrimary : DifyColors.textTertiary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      child: o.text,
                    ),
                  ),
                  if (o.value == value)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      height: 2,
                      child: ColoredBox(color: DifyColors.utilColorsBlueBrandBlueBrand600),
                    ),
                ],
              ),
            ),
          ),
        ),
    ],
  );
}
