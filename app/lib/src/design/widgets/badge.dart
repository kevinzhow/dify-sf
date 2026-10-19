/// Dify's Badge (web/app/components/base/badge).
library;

import 'package:flutter/material.dart';

import '../dify_tokens.g.dart';
import 'widgets.dart';

/// Badge (base/badge.tsx): `inline-flex h-5 items-center rounded-[5px] border border-divider-deep px-1.25
/// text-text-tertiary`, `system-2xs-medium-uppercase` (or `system-xs-medium` without [uppercase]).
class DifyBadge extends StatelessWidget {
  const DifyBadge(this.text, {super.key, this.uppercase = true, this.capitalize = false, this.color});
  final String text;
  final bool uppercase;

  /// The text and border colour of a call site's classes (`border-text-accent-secondary text-text-accent-secondary`).
  final Color? color;

  /// `capitalize` (the picker's type placeholders).
  final bool capitalize;

  @override
  Widget build(BuildContext context) => Container(
    height: 20,
    padding: const EdgeInsets.symmetric(horizontal: 5),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(DifyRadius.badge),
      border: Border.all(color: color ?? DifyColors.dividerDeep),
    ),
    child: Center(
      widthFactor: 1,
      child: DifyText(
        capitalize ? cssCapitalize(text) : text,
        uppercase ? DifyType.system2xsMediumUppercase : DifyType.systemXsMedium,
        color: color ?? DifyColors.textTertiary,
      ),
    ),
  );
}
