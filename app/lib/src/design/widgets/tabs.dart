/// dify-ui's Tabs (packages/dify-ui/src/tabs/index.tsx): [DifyTabsList] and [DifyTab].
library;

import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';

import '../dify_tokens.g.dart';
import 'widgets.dart';

/// The looks of a [DifyTab]: dify-ui's own TabsTab classes, and the variants Dify's screens give it by className.
enum DifyTabStyle {
  /// TabsTab: `border-b-2 border-transparent pt-2.5 pb-2 system-md-semibold text-text-tertiary`; active
  /// `border-components-tab-active text-text-primary`.
  underline,

  /// The access point's environment tabs (app/access-point/index.tsx): `h-8 rounded-lg border-b-0 px-2.5 py-0
  /// system-sm-medium`; active `bg-state-base-active system-sm-semibold text-text-secondary`.
  pill,
}

/// How tall a [DifyTab] is at least.
enum DifyTabSize {
  /// Dify's own geometry (the style's padding, or the tab's [DifyTab.builder]).
  regular,

  /// dify-sf phones: at least [DifyTab.touchHeight] (44 px), so a finger hits the tab anywhere on its row; the look is
  /// the regular one, its bottom (the underline) at the bottom of the taller box.
  touch,
}

/// TabsList: a row of tabs, `flex gap-4` ([gap]). [size] applies to every tab in it that sets none of its own.
class DifyTabsList extends StatelessWidget {
  const DifyTabsList({
    super.key,
    required this.children,
    this.gap = 16,
    this.label,
    this.size = DifyTabSize.regular,
  });

  final List<Widget> children;
  final double gap;

  /// The tablist's accessible name (`aria-label`).
  final String? label;
  final DifyTabSize size;

  @override
  Widget build(BuildContext context) => _DifyTabSizeScope(
    size: size,
    child: Semantics(
      container: true,
      label: label,
      explicitChildNodes: true,
      child: Row(mainAxisSize: MainAxisSize.min, spacing: gap, children: children),
    ),
  );
}

class _DifyTabSizeScope extends InheritedWidget {
  const _DifyTabSizeScope({required this.size, required super.child});
  final DifyTabSize size;

  @override
  bool updateShouldNotify(_DifyTabSizeScope oldWidget) => size != oldWidget.size;
}

/// TabsTab: a pressable tab (`role="tab"`), `selected` when [active]. Disabled tabs are `opacity-30` (an active one keeps its
/// colour); a keyboard focus draws `focus-visible:ring-2 ring-state-accent-solid`. [builder] replaces the look (for
/// tabs Dify restyles beyond [DifyTabStyle]) and gets hover and focus.
class DifyTab extends StatelessWidget {
  const DifyTab({
    super.key,
    this.label,
    required this.active,
    this.onPressed,
    this.disabled = false,
    this.focusableWhenDisabled = false,
    this.focusNode,
    this.style = DifyTabStyle.underline,
    this.padding,
    this.height,
    this.semanticLabel,
    this.builder,
    this.onKeyEvent,
    this.size,
  }) : assert(label != null || builder != null);

  /// The tab's text (with [style]).
  final String? label;
  final bool active;
  final VoidCallback? onPressed;
  final bool disabled, focusableWhenDisabled;
  final FocusNode? focusNode;
  final DifyTabStyle style;

  /// Overrides the style's padding (for example `h-full pt-0 pb-0`).
  final EdgeInsetsGeometry? padding;

  /// A fixed height (`h-*`).
  final double? height;

  /// Defaults to [label].
  final String? semanticLabel;
  final Widget Function(BuildContext context, bool hovered, bool focused)? builder;

  /// Keys pressed while the tab has the focus (the tablist's arrow-key navigation).
  final KeyEventResult Function(KeyEvent event)? onKeyEvent;

  /// How tall it is at least; null: its [DifyTabsList]'s size (regular outside one).
  final DifyTabSize? size;

  /// The touch size's least height ([DifyTabSize.touch]).
  static const touchHeight = 44.0;

  Widget _look(bool hovered, bool focused) {
    if (builder case final b?) return Builder(builder: (context) => b(context, hovered, focused));
    final text = switch (style) {
      DifyTabStyle.underline => DifyText(
        label!,
        DifyType.systemMdSemibold,
        color: active ? DifyColors.textPrimary : DifyColors.textTertiary,
      ),
      DifyTabStyle.pill =>
        active
            ? DifyText(label!, DifyType.systemSmSemibold, color: DifyColors.textSecondary)
            : DifyText(label!, DifyType.systemSmMedium, color: DifyColors.textTertiary),
    };
    final Widget box = switch (style) {
      DifyTabStyle.underline => Container(
        height: height,
        padding: padding ?? const EdgeInsets.only(top: 10, bottom: 8),
        alignment: height == null ? null : Alignment.center,
        decoration: DifyFocusDecoration(
          border: Border(
            bottom: BorderSide(color: active ? DifyColors.componentsTabActive : const Color(0x00000000), width: 2),
          ),
          boxShadow: difyFocusRing(focused),
        ),
        child: text,
      ),
      DifyTabStyle.pill => Container(
        height: height ?? 32,
        padding: padding ?? const EdgeInsets.symmetric(horizontal: 10),
        decoration: DifyFocusDecoration(
          color: active ? DifyColors.stateBaseActive : null,
          borderRadius: BorderRadius.circular(DifyRadius.lg),
          boxShadow: difyFocusRing(focused),
        ),
        child: Center(widthFactor: 1, child: text),
      ),
    };
    return disabled ? Opacity(opacity: 0.3, child: box) : box;
  }

  @override
  Widget build(BuildContext context) {
    Widget pressable = DifyPressable(
      focusNode: focusNode,
      semanticLabel: semanticLabel ?? label,
      disabled: disabled,
      focusableWhenDisabled: focusableWhenDisabled,
      onPressed: onPressed,
      builder: (context, hovered, focused) => DifyControlLabelScope(child: _look(hovered, focused)),
    );
    final size =
        this.size ?? context.dependOnInheritedWidgetOfExactType<_DifyTabSizeScope>()?.size ?? DifyTabSize.regular;
    if (size == DifyTabSize.touch) {
      pressable = ConstrainedBox(
        constraints: const BoxConstraints(minHeight: touchHeight),
        child: pressable,
      );
    }
    if (onKeyEvent case final onKey?) {
      pressable = Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: (_, e) => onKey(e),
        child: pressable,
      );
    }
    return MergeSemantics(
      child: Semantics(role: SemanticsRole.tab, selected: active, enabled: !disabled, child: pressable),
    );
  }
}
