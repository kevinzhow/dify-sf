/// dify-sf's phone app bar (a dify-sf divergence: Dify's console has no phone header).
library;

import 'package:flutter/widgets.dart';

import '../dify_icon.dart';
import '../dify_phone_tokens.dart';
import '../dify_tokens.g.dart';
import '../../i18n/dify_i18n.dart';
import 'text.dart';
import 'touch_target.dart';

/// The phone app bar (mockups 2-4 and 7, gen.py `.appbar`): [height] 56 px, `gap-1 px-2`, then [leading], the title
/// block (`px-1`: a one-line [title] in [DifyPhoneType.title] and an optional one-line [subtitle] in
/// system-xs-regular text-tertiary, both ellipsized) and the trailing [actions] (usually [DifyTouchIconButton]s and a
/// [DifyButton]). Without a [leading], a back button ([DifyAppBarBackButton]) appears when the route can be popped.
///
/// [DifyTopAppBar.large] is a top-level page's bar (mockup 1 "Studio"): a [DifyPhoneType.largeTitle] title 18 px from
/// the edge, no back button.
///
/// [DifyTopAppBar.search] is a page's inline search (mockup 1's search action, opened): a back button that closes the
/// search ([onBack]) and the search [field] in place of the title.
///
/// Edge to edge: the bar reads `MediaQuery.padding` (zero inside a safe page) and paints its [backgroundColor]
/// (none by default: the page shows through) under the status bar and the side insets, while its content stays
/// below and between them. It grows past 56 px rather than clip when the text is scaled up. Its row is 56 px tall and
/// reaches 2 px past the outer buttons, so every [DifyTouchIconButton]'s 48 px target responds whole.
class DifyTopAppBar extends StatelessWidget {
  const DifyTopAppBar({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.actions = const [],
    this.backgroundColor,
    this.automaticallyImplyLeading = true,
    this.onBack,
    this.dense = false,
  }) : large = false,
       field = null;

  const DifyTopAppBar.large({super.key, required this.title, this.actions = const [], this.backgroundColor})
    : large = true,
      subtitle = null,
      leading = null,
      automaticallyImplyLeading = false,
      onBack = null,
      dense = false,
      field = null;

  const DifyTopAppBar.search({
    super.key,
    required Widget this.field,
    required VoidCallback this.onBack,
    this.actions = const [],
    this.backgroundColor,
  }) : large = false,
       dense = false,
       title = '',
       subtitle = null,
       leading = null,
       automaticallyImplyLeading = false;

  /// The bar's height below the status bar.
  static const height = 56.0;

  /// A [dense] bar's height: a short window's (a phone in landscape), where every row the content loses counts. Its
  /// 44 px buttons still have their whole 48 px targets.
  static const denseHeight = 48.0;

  /// [denseHeight] instead of [height].
  final bool dense;

  final String title;
  final String? subtitle;
  final Widget? leading;
  final List<Widget> actions;
  final Color? backgroundColor;

  /// Shows [DifyAppBarBackButton] when there is no [leading] and the route can be popped.
  final bool automaticallyImplyLeading;

  /// The implied back button's action ([Navigator.maybePop] by default).
  final VoidCallback? onBack;
  final bool large;

  /// The search mode's field ([DifyTopAppBar.search]).
  final Widget? field;

  @override
  Widget build(BuildContext context) {
    final insets = MediaQuery.paddingOf(context);
    final lead = field != null
        ? DifyAppBarBackButton(onPressed: onBack)
        : leading ??
              (automaticallyImplyLeading && (ModalRoute.of(context)?.impliesAppBarDismissal ?? false)
                  ? DifyAppBarBackButton(onPressed: onBack)
                  : null);
    final titleBlock =
        field ??
        Padding(
          padding: EdgeInsets.only(left: large ? 10 : 4, right: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(
                header: true,
                child: DifyText(
                  title,
                  large ? DifyPhoneType.largeTitle : DifyPhoneType.title,
                  color: DifyColors.textPrimary,
                ),
              ),
              if (subtitle case final s?) DifyText(s, DifyType.systemXsRegular, color: DifyColors.textTertiary),
            ],
          ),
        );
    final items = [?lead, Expanded(child: titleBlock), ...actions];
    Widget bar = Padding(
      padding: EdgeInsets.fromLTRB(insets.left, insets.top, insets.right, 0),
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: dense ? denseHeight : height),
        // `gap-1 px-2`, with the row reaching 2 px past the outer buttons: a 44 px button's 48 px target
        // ([DifyTouchIconButton]) stays inside the row, which is what forwards a tap to it.
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Row(
            children: [
              const SizedBox(width: 2),
              for (final (i, w) in items.indexed) ...[if (i > 0) const SizedBox(width: 4), w],
              const SizedBox(width: 2),
            ],
          ),
        ),
      ),
    );
    if (backgroundColor case final c?) bar = ColoredBox(color: c, child: bar);
    return bar;
  }
}

/// The app bar's back button: a [DifyTouchIconButton] with `arrow-left-line` that calls [onPressed], or
/// [Navigator.maybePop] (so a route's PopScope still decides).
class DifyAppBarBackButton extends StatelessWidget {
  const DifyAppBarBackButton({super.key, this.onPressed, this.label});

  final VoidCallback? onPressed;

  /// The accessible name (common `operation.back` by default).
  final String? label;

  @override
  Widget build(BuildContext context) => DifyTouchIconButton(
    label: label ?? DifyI18n.tr('common', 'operation.back'),
    icon: const RemixIcon('arrow-left-line', size: 22),
    onPressed: onPressed ?? () => Navigator.maybePop(context),
  );
}
