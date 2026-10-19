import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';

import '../../../design/css_metrics.dart';
import '../../../design/dify_icon.dart';
import '../../../design/dify_tokens.g.dart';
import '../../../design/widgets/widgets.dart';

/// Opens a link of the publisher: [external] ones (the web app) in a new tab / the browser, the others
/// (`/app/<id>/access-point`, `/app/<id>/deploy`, `/integrations/tools/workflow`) in the console.
typedef PublisherLinkHandler = void Function(String link, {required bool external});

/// `focus-visible:ring-2 ring-state-accent-solid`.

/// A native `<button>` or `<a>` of the publisher: hover and focus-visible tracking, Enter / Space / tap activation,
/// and its accessible name ([label]), description ([hint]) and role (a link when [link] is set). With a [label] the
/// content's semantics are dropped, unless [keepChildSemantics] (the content then excludes its texts itself and
/// keeps nodes of its own, e.g. role `status` badges). [disabled] blocks
/// activation and, unless [focusableWhenDisabled] (`aria-disabled`), focus.
class PublisherPressable extends StatefulWidget {
  const PublisherPressable({
    super.key,
    required this.builder,
    this.onPressed,
    this.disabled = false,
    this.focusableWhenDisabled = false,
    this.label,
    this.hint,
    this.link,
    this.waitCursorWhenDisabled = false,
    this.keepChildSemantics = false,
    this.expanded,
  });

  final Widget Function(BuildContext context, bool hovered, bool focused) builder;
  final VoidCallback? onPressed;
  final bool disabled;
  final bool focusableWhenDisabled;
  final String? label;
  final String? hint;
  final String? link;

  /// `disabled:cursor-wait` instead of `cursor-not-allowed`.
  final bool waitCursorWhenDisabled;
  final bool keepChildSemantics;

  /// `aria-expanded` of a popup trigger.
  final bool? expanded;

  @override
  State<PublisherPressable> createState() => _PublisherPressableState();
}

class _PublisherPressableState extends State<PublisherPressable> {
  bool _hovered = false;
  bool _focused = false;

  bool get _enabled => !widget.disabled && widget.onPressed != null;

  void _activate() {
    if (_enabled) widget.onPressed!();
  }

  @override
  Widget build(BuildContext context) {
    final link = widget.link;
    final cursor = widget.disabled
        ? (widget.waitCursorWhenDisabled ? SystemMouseCursors.wait : SystemMouseCursors.forbidden)
        : SystemMouseCursors.click;
    return Semantics(
      container: true,
      button: link == null,
      link: link != null,
      linkUrl: link == null ? null : Uri.tryParse(link),
      enabled: !widget.disabled,
      expanded: widget.expanded,
      label: widget.label,
      hint: widget.hint,
      onTap: _enabled ? _activate : null,
      child: FocusableActionDetector(
        enabled: !widget.disabled || widget.focusableWhenDisabled,
        mouseCursor: cursor,
        actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => _activate())},
        onShowFocusHighlight: (v) => setState(() => _focused = v),
        onShowHoverHighlight: (v) => setState(() => _hovered = v),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          excludeFromSemantics: true,
          onTap: _enabled ? _activate : null,
          child: widget.label != null && !widget.keepChildSemantics
              ? ExcludeSemantics(child: widget.builder(context, _hovered && !widget.disabled, _focused))
              : widget.builder(context, _hovered && !widget.disabled, _focused),
        ),
      ),
    );
  }
}

/// SuggestedAction's trailing button (`actionButton`).
class SuggestedActionButton {
  const SuggestedActionButton({required this.label, required this.icon, required this.onPressed});

  /// `ariaLabel`.
  final String label;
  final Widget icon;
  final VoidCallback onPressed;
}

/// app-publisher/suggested-action.tsx: a publisher quick action, an icon tile, a [label] and an [endIcon] (default
/// `i-ri-arrow-right-up-line`), whose [description] unfolds on hover and keyboard focus. With a [link] it opens it
/// through [onOpenLink] (after [onPressed]); disabled it is a disabled button (focusable with
/// [focusableWhenDisabled], so a tooltip can explain why). [actionButton] adds a separate trailing button.
class SuggestedAction extends StatelessWidget {
  const SuggestedAction({
    super.key,
    required this.label,
    this.icon,
    this.link,
    this.external = false,
    this.disabled = false,
    this.focusableWhenDisabled = false,
    this.description,
    this.endIcon,
    this.actionButton,
    this.onPressed,
    this.onOpenLink,
  });

  final String label;
  final Widget? icon;
  final String? link;
  final bool external;
  final bool disabled;
  final bool focusableWhenDisabled;
  final String? description;
  final Widget? endIcon;
  final SuggestedActionButton? actionButton;
  final VoidCallback? onPressed;
  final PublisherLinkHandler? onOpenLink;

  void _open() {
    onPressed?.call();
    onOpenLink?.call(link!, external: external);
  }

  @override
  Widget build(BuildContext context) {
    final hasDescription = description != null && description!.isNotEmpty;
    final split = actionButton != null;
    final left = split ? const Radius.circular(DifyRadius.lg) : Radius.zero;
    final radius = split ? BorderRadius.horizontal(left: left) : BorderRadius.circular(DifyRadius.lg);
    Widget main = PublisherPressable(
      disabled: disabled,
      focusableWhenDisabled: focusableWhenDisabled,
      label: label,
      hint: hasDescription ? description : null,
      link: disabled ? null : link,
      keepChildSemantics: true,
      onPressed: disabled ? null : (link != null ? _open : onPressed),
      builder: (context, hovered, focused) {
        final active = !disabled && (hovered || focused);
        return AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          constraints: const BoxConstraints(minHeight: 40),
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: active ? DifyColors.stateBaseHover : const Color(0x00000000),
            borderRadius: radius,
            boxShadow: difyFocusRing(focused && (!disabled || focusableWhenDisabled)),
          ),
          child: Row(
            spacing: 8,
            children: [
              PublisherIconTile(icon: icon, color: active ? DifyColors.textAccent : DifyColors.textSecondary),
              Expanded(
                child: ExcludeSemantics(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: difyTextStyle(
                          DifyType.systemSmMedium,
                          active ? DifyColors.textPrimary : DifyColors.textSecondary,
                        ),
                      ),
                      if (hasDescription) _Reveal(open: active, text: description!),
                    ],
                  ),
                ),
              ),
              ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                child: Center(
                  widthFactor: 1,
                  heightFactor: 1,
                  child: IconTheme.merge(
                    data: IconThemeData(color: DifyColors.textQuaternary),
                    child: DefaultTextStyle.merge(
                      style: TextStyle(color: DifyColors.textQuaternary),
                      child: endIcon ?? RemixIcon('arrow-right-up-line', size: 14, color: DifyColors.textQuaternary),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
    if (!split) return disabled ? Opacity(opacity: 0.3, child: main) : main;
    final button = actionButton!;
    Widget row = IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: main),
          PublisherPressable(
            disabled: disabled,
            label: button.label,
            onPressed: button.onPressed,
            builder: (context, hovered, focused) {
              final active = !disabled && (hovered || focused);
              final color = active ? DifyColors.textAccent : DifyColors.textTertiary;
              return Container(
                width: 36,
                decoration: BoxDecoration(
                  color: active ? DifyColors.stateBaseHover : null,
                  border: Border(
                    left: BorderSide(color: DifyColors.dividerSubtle, width: Css.hairline),
                  ),
                  borderRadius: const BorderRadius.horizontal(right: Radius.circular(DifyRadius.lg)),
                  boxShadow: difyFocusRing(focused && !disabled),
                ),
                alignment: Alignment.center,
                child: IconTheme.merge(
                  data: IconThemeData(color: color, size: 16),
                  child: DefaultTextStyle.merge(
                    style: TextStyle(color: color),
                    child: SizedBox.square(dimension: 16, child: Center(child: button.icon)),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
    if (disabled) row = Opacity(opacity: 0.3, child: row);
    return row;
  }
}

/// The description: `grid-rows-[0fr] opacity-0` → `grid-rows-[1fr] opacity-100` over 200 ms ease-out (none with
/// reduced motion).
class _Reveal extends StatelessWidget {
  const _Reveal({required this.open, required this.text});
  final bool open;
  final String text;

  @override
  Widget build(BuildContext context) {
    final duration = (MediaQuery.maybeDisableAnimationsOf(context) ?? false)
        ? Duration.zero
        : const Duration(milliseconds: 200);
    return ClipRect(
      child: AnimatedAlign(
        alignment: AlignmentDirectional.topStart,
        heightFactor: open ? 1 : 0,
        duration: duration,
        curve: Curves.easeOut,
        child: AnimatedOpacity(
          opacity: open ? 1 : 0,
          duration: duration,
          curve: Curves.easeOut,
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textTertiary),
          ),
        ),
      ),
    );
  }
}

/// The action's icon tile: `size-8 rounded-lg border-[0.5px] border-divider-regular
/// bg-components-panel-on-panel-item-bg shadow-xs`, the 16 px icon in [color].
class PublisherIconTile extends StatelessWidget {
  const PublisherIconTile({super.key, this.icon, this._color});
  final Widget? icon;
  final Color? _color;
  Color get color => _color ?? DifyColors.textSecondary;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Container(
      width: 32,
      height: 32,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: DifyColors.componentsPanelOnPanelItemBg,
        border: Border.all(color: DifyColors.dividerRegular, width: Css.hairline),
        borderRadius: BorderRadius.circular(DifyRadius.lg),
        boxShadow: DifyShadows.xs,
      ),
      child: IconTheme.merge(
        data: IconThemeData(color: color, size: 16),
        child: DefaultTextStyle.merge(
          style: TextStyle(color: color),
          child: icon ?? const SizedBox.shrink(),
        ),
      ),
    ),
  );
}

/// `role="status"` with an accessible name.
Widget publisherStatus(String label, Widget child) => Semantics(
  container: true,
  role: SemanticsRole.status,
  label: label,
  child: ExcludeSemantics(child: child),
);
