/// The block selector's shared pieces: rows (block-selector-row.tsx), the block icon with a provider's icon
/// (block-icon.tsx), the search fields (base/search-input, marketplace/search-box), the hover preview card
/// (preview-card.tsx with dify-ui PreviewCard), the collapsible section header and the empty states.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Material, MaterialType;
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../canvas/node_card.dart' show blockColor;
import '../../design/css_metrics.dart';
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';
import 'block_selector_data.dart';

String wf(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('workflow', key, params);

/// `focus-visible:inset-ring-2 focus-visible:inset-ring-state-accent-solid`.
BoxDecoration? insetFocusRing(bool focused, double radius) => focused
    ? BoxDecoration(
        border: Border.all(color: DifyColors.stateAccentSolid, width: 2),
        borderRadius: BorderRadius.circular(radius),
      )
    : null;

/// BlockSelectorRow: `flex h-8 w-full items-center rounded-lg pr-2 pl-3`, `hover:bg-state-base-hover` unless
/// [disabled]; [label] is its accessible name and [description] its accessible description.
class SelectorRow extends StatelessWidget {
  const SelectorRow({
    super.key,
    required this.child,
    this.onPressed,
    this.disabled = false,
    this.label,
    this.description,
    this.padding = const EdgeInsets.only(left: 12, right: 8),
    this.height = 32,
    this.highlighted = false,
    this.focusableWhenDisabled = true,
  });

  final Widget child;
  final VoidCallback? onPressed;
  final bool disabled;
  final String? label, description;
  final EdgeInsets padding;
  final double? height;

  /// Shows the hover background (an open popup's row).
  final bool highlighted;
  final bool focusableWhenDisabled;

  @override
  Widget build(BuildContext context) => MergeSemantics(
    child: Semantics(
      hint: description,
      child: DifyPressable(
        onPressed: disabled ? null : onPressed,
        disabled: disabled,
        focusableWhenDisabled: focusableWhenDisabled,
        semanticLabel: label,
        builder: (context, hovered, focused) => Container(
          height: height,
          padding: padding,
          alignment: Alignment.centerLeft,
          decoration: BoxDecoration(
            color: (hovered && !disabled) || highlighted ? DifyColors.stateBaseHover : null,
            borderRadius: BorderRadius.circular(DifyRadius.lg),
          ),
          foregroundDecoration: insetFocusRing(focused, DifyRadius.lg),
          child: child,
        ),
      ),
    ),
  );
}

/// BlockIcon sizes: xs 16 px (5 px radius, shadow-xs, 12 px glyph), sm 20 (rounded-md, shadow-xs, 14), md 24
/// (rounded-lg, shadow-md, 16).
enum SelectorIconSize {
  xs(16, 5, 12),
  sm(20, 6, 14),
  md(24, 8, 16);

  const SelectorIconSize(this.box, this.radius, this.glyph);
  final double box, radius, glyph;
}

/// BlockIcon: the block's coloured tile and glyph; a tool, data source or trigger plugin with a provider [toolIcon]
/// shows that instead (a picture filling the tile, or an emoji tile).
class SelectorBlockIcon extends StatelessWidget {
  const SelectorBlockIcon({super.key, required this.type, this.size = SelectorIconSize.sm, this.toolIcon});

  final String type;
  final SelectorIconSize size;
  final ProviderIcon toolIcon;

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(size.radius);
    final shadows = size == SelectorIconSize.md ? DifyShadows.md : DifyShadows.xs;
    if (type == 'start-placeholder') {
      return Container(
        width: size.box,
        height: size.box,
        decoration: BoxDecoration(
          color: DifyColors.stateBaseHover,
          borderRadius: r,
          border: Border.all(color: DifyColors.componentsPanelBorder),
        ),
        child: Center(
          child: Opacity(
            opacity: 0.3,
            child: DifyIcon(blockGlyph(type), size: size.glyph, color: DifyColors.textPrimary),
          ),
        ),
      );
    }
    final custom = const {'tool', 'datasource', 'trigger-plugin'}.contains(type) && toolIcon != null;
    if (custom) {
      final builder = BlockSelectorScope.of(context).iconBuilder;
      return SizedBox.square(
        dimension: size.box,
        child: ClipRRect(
          borderRadius: r,
          child: builder?.call(context, toolIcon, size.box) ?? _defaultProviderIcon(toolIcon, size.box),
        ),
      );
    }
    return Container(
      width: size.box,
      height: size.box,
      decoration: BoxDecoration(
        color: type == 'datasource' ? DifyColors.componentsIconBgMidnightSolid : blockColor(type),
        borderRadius: r,
        border: Border.all(color: const Color(0x05FFFFFF), width: Css.hairline),
        boxShadow: shadows,
      ),
      child: Center(
        child: DifyIcon(blockGlyph(type), size: size.glyph, color: const Color(0xFFFFFFFF)),
      ),
    );
  }
}

Color? _hex(String? s) {
  if (s == null || !s.startsWith('#')) return null;
  final v = int.tryParse(s.substring(1), radix: 16);
  if (v == null) return null;
  return Color(s.length == 7 ? 0xFF000000 | v : v);
}

Widget _defaultProviderIcon(ProviderIcon icon, double size) {
  if (icon is Map) {
    // AppIcon tiny: the emoji on its background.
    return Container(
      color: _hex(icon['background'] as String?) ?? DifyColors.stateBaseHover,
      alignment: Alignment.center,
      child: Text('${icon['content'] ?? ''}', style: TextStyle(fontSize: size * 0.6, height: 1)),
    );
  }
  if (icon is String && (icon.startsWith('http://') || icon.startsWith('https://'))) {
    return Image.network(icon, width: size, height: size, fit: BoxFit.cover, errorBuilder: (_, _, _) => _blank);
  }
  return _blank;
}

ColoredBox get _blank => ColoredBox(color: DifyColors.stateBaseHover);

/// SearchInput (base/search-input): an InputGroup with `i-ri-search-line` in front and a clear button once there
/// is text; its accessible name is [placeholder].
class SelectorSearchInput extends StatelessWidget {
  const SelectorSearchInput({
    super.key,
    required this.value,
    required this.onChanged,
    required this.placeholder,
    this.focusNode,
    this.label,
  });

  final String value;
  final ValueChanged<String> onChanged;
  final String placeholder;
  final FocusNode? focusNode;

  /// The accessible name, when not [placeholder].
  final String? label;

  @override
  Widget build(BuildContext context) => Semantics(
    textField: true,
    label: label ?? placeholder,
    child: DifyInput(
      value: value,
      onChanged: onChanged,
      placeholder: placeholder,
      semanticLabel: label ?? placeholder,
      focusNode: focusNode,
      leading: Padding(
        padding: EdgeInsets.only(left: 7, right: 5),
        child: RemixIcon('search-line', size: 16, color: DifyColors.componentsInputTextPlaceholder),
      ),
      trailing: value.isEmpty
          ? null
          : Padding(
              padding: const EdgeInsets.only(left: 3, right: 5),
              child: DifyIconButton(
                label: DifyI18n.tr('common', 'operation.clear'),
                size: DifyIconButtonSize.sm,
                onPressed: () {
                  onChanged('');
                  focusNode?.requestFocus();
                },
                icon: RemixIcon('close-circle-fill', size: 16, color: DifyColors.textQuaternary),
              ),
            ),
    ),
  );
}

/// marketplace/search-box tagKeys (plugins/constants.ts).
const pluginTagKeys = [
  'agent', 'rag', 'search', 'image', 'videos', 'weather', 'finance', 'design', 'travel', 'social', 'news', //
  'medical', 'productivity', 'education', 'business', 'entertainment', 'utilities', 'other',
];

String _tagLabel(String tag) => DifyI18n.tr('plugin-tags', 'tags.$tag');

/// SearchBox (marketplace/search-box, not in the marketplace): a search field (`h-8`, search icon, ghost clear
/// button) and, after a divider, the tag filter.
class SelectorSearchBox extends StatelessWidget {
  const SelectorSearchBox({
    super.key,
    required this.value,
    required this.onChanged,
    required this.tags,
    required this.onTagsChanged,
    required this.placeholder,
    this.focusNode,
  });

  final String value;
  final ValueChanged<String> onChanged;
  final List<String> tags;
  final ValueChanged<List<String>> onTagsChanged;
  final String placeholder;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) => Semantics(
    textField: true,
    label: placeholder,
    child: DifyInput(
      value: value,
      onChanged: onChanged,
      placeholder: placeholder,
      semanticLabel: placeholder,
      focusNode: focusNode,
      height: 34,
      leading: Padding(
        padding: EdgeInsets.only(left: 8, right: 6),
        child: RemixIcon('search-line', size: 16, color: DifyColors.componentsInputTextPlaceholder),
      ),
      // The clear button, then the tag filter after a divider, inside the same box.
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (value.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 8, right: 8),
              child: DifyIconButton(
                label: DifyI18n.tr('plugin', 'clearSearch', {'label': placeholder}),
                variant: DifyButtonVariant.ghost,
                onPressed: () {
                  onChanged('');
                  focusNode?.requestFocus();
                },
                icon: const RemixIcon('close-line', size: 16),
              ),
            )
          else
            const SizedBox(width: 8),
          SizedBox(width: 1, height: 14, child: ColoredBox(color: DifyColors.dividerRegular)),
          const SizedBox(width: 2),
          _TagsFilter(tags: tags, onChanged: onTagsChanged),
        ],
      ),
    ),
  );
}

/// TagsFilter with the tool-selector trigger: a tag icon button (or the chosen tags with a clear button) opening a
/// searchable checkbox list (`w-60`, bottom-start, 4 px below).
class _TagsFilter extends StatefulWidget {
  const _TagsFilter({required this.tags, required this.onChanged});
  final List<String> tags;
  final ValueChanged<List<String>> onChanged;

  @override
  State<_TagsFilter> createState() => _TagsFilterState();
}

class _TagsFilterState extends State<_TagsFilter> {
  bool _open = false;
  String _search = '';

  @override
  Widget build(BuildContext context) {
    final tags = widget.tags;
    final labels = [for (final t in tags) _tagLabel(t)];
    final triggerLabel = labels.isEmpty ? DifyI18n.tr('plugin-tags', 'allTags') : labels.join(', ');
    final options = [
      for (final t in pluginTagKeys)
        if (_tagLabel(t).toLowerCase().contains(_search.toLowerCase())) t,
    ];
    return DifyPopover(
      open: _open,
      onOpenChange: (o) => setState(() => _open = o),
      placement: DifyPlacement.bottomStart,
      sideOffset: 4,
      alignOffset: -6,
      surface: false,
      builder: (context, c) => Padding(
        padding: const EdgeInsets.only(right: 4),
        child: tags.isEmpty
            ? DifyIconButton(
                label: triggerLabel,
                size: DifyIconButtonSize.lg,
                variant: DifyButtonVariant.ghost,
                onPressed: c.toggle,
                icon: RemixIcon('price-tag-3-line', size: 16, color: DifyColors.textTertiary),
              )
            : Stack(
                alignment: Alignment.centerRight,
                children: [
                  DifyButton(
                    size: DifyButtonSize.small,
                    semanticLabel: triggerLabel,
                    onPressed: c.toggle,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 20),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        spacing: 2,
                        children: [
                          RemixIcon('price-tag-3-line', size: 16, color: DifyColors.textSecondary),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 72),
                            child: DifyText(
                              labels.take(2).join(','),
                              DifyType.systemSmMedium,
                              color: DifyColors.textSecondary,
                            ),
                          ),
                          if (tags.length > 2)
                            DifyText('+${tags.length - 2}', DifyType.systemXsMedium, color: DifyColors.textTertiary),
                        ],
                      ),
                    ),
                  ),
                  DifyIconButton(
                    label: DifyI18n.tr('plugin-tags', 'clearSelectedTags', {'tags': triggerLabel}),
                    variant: DifyButtonVariant.ghost,
                    onPressed: () => widget.onChanged(const []),
                    icon: RemixIcon('close-circle-fill', size: 16, color: DifyColors.textQuaternary),
                  ),
                ],
              ),
      ),
      content: Container(
        width: 240,
        decoration: BoxDecoration(
          color: DifyColors.componentsPanelBgBlur,
          borderRadius: BorderRadius.circular(DifyRadius.xl),
          border: Border.all(color: DifyColors.componentsPanelBorder, width: Css.hairline),
          boxShadow: DifyShadows.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
              child: SelectorSearchInput(
                value: _search,
                onChanged: (v) => setState(() => _search = v),
                placeholder: DifyI18n.tr('plugin-tags', 'searchTags'),
              ),
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 448),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final t in options)
                      SelectorRow(
                        height: 28,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        label: _tagLabel(t),
                        onPressed: () => widget.onChanged(
                          tags.contains(t)
                              ? [
                                  for (final x in tags)
                                    if (x != t) x,
                                ]
                              : [...tags, t],
                        ),
                        child: Row(
                          spacing: 4,
                          children: [
                            _Checkbox(checked: tags.contains(t)),
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 4),
                              child: DifyText(_tagLabel(t), DifyType.systemSmMedium, color: DifyColors.textSecondary),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// dify-ui Checkbox (16 px, 4 px radius): unchecked a white box with a deep border, checked the accent with a check.
class _Checkbox extends StatelessWidget {
  const _Checkbox({required this.checked});
  final bool checked;

  @override
  Widget build(BuildContext context) => Container(
    width: 16,
    height: 16,
    decoration: BoxDecoration(
      color: checked ? DifyColors.componentsCheckboxBg : DifyColors.componentsCheckboxBgUnchecked,
      borderRadius: BorderRadius.circular(4),
      border: checked ? null : Border.all(color: DifyColors.componentsCheckboxBorder),
      boxShadow: DifyShadows.xs,
    ),
    child: checked ? Center(child: RemixIcon('check-line', size: 12, color: DifyColors.componentsCheckboxIcon)) : null,
  );
}

/// A link (Next's Link with `target="_blank"`): [child] that opens [url] through the app.
class SelectorLink extends StatelessWidget {
  const SelectorLink({super.key, required this.url, required this.child, this.label, this.onOpened});
  final String url;
  final Widget child;
  final String? label;
  final VoidCallback? onOpened;

  @override
  Widget build(BuildContext context) => Semantics(
    link: true,
    linkUrl: Uri.tryParse(url),
    child: DifyPressable(
      semanticLabel: label,
      onPressed: () {
        BlockSelectorScope.of(context).open(url);
        onOpened?.call();
      },
      builder: (context, hovered, focused) => Container(
        foregroundDecoration: focused
            ? BoxDecoration(
                border: Border.all(
                  color: DifyColors.stateAccentSolid,
                  width: 2,
                  strokeAlign: BorderSide.strokeAlignOutside,
                ),
                borderRadius: BorderRadius.circular(DifyRadius.md),
              )
            : null,
        child: child,
      ),
    ),
  );
}

/// "Find more in Marketplace ↗" in `text-text-accent-light-mode-only`.
class MarketplaceFooterLink extends StatelessWidget {
  const MarketplaceFooterLink({super.key, required this.url});
  final String url;

  @override
  Widget build(BuildContext context) {
    final label = DifyI18n.tr('plugin', 'findMoreInMarketplace');
    return SelectorLink(
      url: url,
      label: label,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 2,
        children: [
          DifyText(label, DifyType.systemSmMedium, color: DifyColors.textAccentLightModeOnly),
          RemixIcon('arrow-right-up-line', size: 12, color: DifyColors.textAccentLightModeOnly),
        ],
      ),
    );
  }
}

/// The marketplace footer of the Tools and Start tabs: `h-8 border-t border-divider-subtle
/// bg-components-panel-bg-blur px-4 py-1`.
class MarketplaceFooter extends StatelessWidget {
  const MarketplaceFooter({super.key, required this.url});
  final String url;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label: 'contentinfo',
    child: Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        color: DifyColors.componentsPanelBgBlur,
        border: Border(top: BorderSide(color: DifyColors.dividerSubtle)),
      ),
      child: MarketplaceFooterLink(url: url),
    ),
  );
}

/// The no-result state: `i-custom-vender-line-general-search-menu` (32 px, quaternary), a title and an action.
class SelectorEmptyState extends StatelessWidget {
  const SelectorEmptyState({super.key, required this.title, this.action, this.minHeight = 160, this.titleStyle});
  final String title;
  final Widget? action;
  final double minHeight;
  final DifyTextStyle? titleStyle;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: BoxConstraints(minHeight: minHeight),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 48),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        spacing: 12,
        children: [
          DifyIcon('vender/line/general/search-menu', size: 32, color: DifyColors.textQuaternary),
          Semantics(
            liveRegion: true,
            child: DifyText(
              title,
              titleStyle ?? DifyType.systemSmMedium,
              color: DifyColors.textSecondary,
              align: TextAlign.center,
            ),
          ),
          ?action,
        ],
      ),
    ),
  );
}

/// The secondary-accent "Requests to the community" link button (`h-6 px-3 text-xs font-medium`).
class RequestToCommunityLink extends StatelessWidget {
  const RequestToCommunityLink({super.key, this.accentText = false});

  /// The Start tab's plain accent-text variant.
  final bool accentText;

  @override
  Widget build(BuildContext context) {
    final label = wf('tabs.requestToCommunity');
    return SelectorLink(
      url: pluginRequestUrl,
      label: label,
      child: Container(
        height: 24,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.center,
        decoration: accentText
            ? null
            : BoxDecoration(
                color: DifyColors.componentsButtonSecondaryBg,
                borderRadius: BorderRadius.circular(DifyRadius.md),
                border: Border.all(color: DifyColors.componentsButtonSecondaryBorder, width: Css.hairline),
                boxShadow: DifyShadows.xs,
              ),
        child: DifyText(
          label,
          DifyType.systemXsMedium,
          color: accentText ? DifyColors.textAccent : DifyColors.componentsButtonSecondaryAccentText,
        ),
      ),
    );
  }
}

/// A Collapsible trigger with a title and `arrow-down-round-fill` (rotated -90° while closed); [expanded] is its
/// state (`aria-expanded`).
class CollapsibleHeader extends StatelessWidget {
  const CollapsibleHeader({super.key, required this.title, required this.expanded, required this.onToggle, this.color});
  final String title;
  final bool expanded;
  final VoidCallback onToggle;
  final Color? color;

  @override
  Widget build(BuildContext context) => MergeSemantics(
    child: Semantics(
      expanded: expanded,
      child: DifyPressable(
        semanticLabel: title,
        onPressed: onToggle,
        builder: (context, hovered, focused) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          foregroundDecoration: insetFocusRing(focused, DifyRadius.md),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            spacing: 2,
            children: [
              DifyText(title, DifyType.systemXsMedium, color: color ?? DifyColors.textPrimary),
              AnimatedRotation(
                turns: expanded ? 0 : -0.25,
                duration: difyTransitionDuration,
                child: DifyIcon(
                  'vender/solid/arrows/arrow-down-round-fill',
                  size: 16,
                  color: DifyColors.textTertiary,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

// ---- preview card -------------------------------------------------------------------------------------------

/// dify-ui PreviewCard's detached handle: one card per list, shown 150 ms after the pointer (or focus) rests on a
/// trigger and hidden 150 ms after it leaves both trigger and card; moving between triggers moves the card.
class PreviewCardHandle extends ChangeNotifier {
  Object? _key;
  BuildContext? _anchor;
  WidgetBuilder? _builder;
  Rect? _rect;

  /// +1 when the card moved down to the current trigger, -1 up (`data-activation-direction`).
  int direction = 0;
  Timer? _timer;

  bool get isOpen => _builder != null;
  Object? get activeKey => _key;
  WidgetBuilder? get builder => _builder;
  Rect? get rect => _rect;

  static const delay = Duration(milliseconds: 150);

  void enter(Object key, BuildContext anchor, WidgetBuilder builder) {
    _timer?.cancel();
    if (_key == key && isOpen) return;
    if (isOpen) return _show(key, anchor, builder);
    _timer = Timer(delay, () => _show(key, anchor, builder));
  }

  void leave(Object key) {
    if (_key != key && isOpen) return;
    _timer?.cancel();
    _timer = Timer(delay, hide);
  }

  /// The pointer is on the card.
  void hold() => _timer?.cancel();

  void _show(Object key, BuildContext anchor, WidgetBuilder builder) {
    if (!anchor.mounted) return;
    final box = anchor.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    direction = _rect == null ? 0 : (rect.top > _rect!.top ? 1 : (rect.top < _rect!.top ? -1 : 0));
    _set(key, anchor, builder, rect);
    notifyListeners();
  }

  void _set(Object? key, BuildContext? anchor, WidgetBuilder? builder, Rect? rect) {
    _key = key;
    _anchor = anchor;
    _builder = builder;
    _rect = rect;
  }

  void hide() {
    _timer?.cancel();
    if (!isOpen) return;
    _set(null, null, null, null);
    direction = 0;
    notifyListeners();
  }

  /// Hides the card when its trigger goes away.
  void unmounted(Object key) {
    if (_key == key) {
      _timer?.cancel();
      _set(null, null, null, null);
      SchedulerBinding.instance.addPostFrameCallback((_) => _disposed ? null : notifyListeners());
    }
  }

  BuildContext? get anchor => _anchor;

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}

/// Owns a list's [PreviewCardHandle] and shows its card to the right of the hovered row (placement `right`,
/// sideOffset 8): `w-56 rounded-xl bg-components-panel-bg px-3 py-2.5 shadow-lg`, sliding 8 px in the direction it
/// moved and following the rows over 180 ms (`cubic-bezier(0.22,1,0.36,1)`).
class PreviewCardScope extends StatefulWidget {
  const PreviewCardScope({super.key, required this.child});
  final Widget child;

  static PreviewCardHandle? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_PreviewScope>()?.handle;

  @override
  State<PreviewCardScope> createState() => _PreviewCardScopeState();
}

class _PreviewScope extends InheritedWidget {
  const _PreviewScope({required this.handle, required super.child});
  final PreviewCardHandle handle;
  @override
  bool updateShouldNotify(_PreviewScope old) => old.handle != handle;
}

const _previewCurve = Cubic(0.22, 1, 0.36, 1);
const _previewDuration = Duration(milliseconds: 180);

class _PreviewCardScopeState extends State<PreviewCardScope> with SingleTickerProviderStateMixin {
  final _handle = PreviewCardHandle();
  final _portal = OverlayPortalController();
  late final _fade = AnimationController(vsync: this, duration: difyTransitionDuration);

  @override
  void initState() {
    super.initState();
    _handle.addListener(_changed);
    _fade.addStatusListener((s) {
      if (s == AnimationStatus.dismissed && !_handle.isOpen) _portal.hide();
    });
  }

  void _changed() {
    if (!mounted) return;
    if (_handle.isOpen) {
      _portal.show();
      _fade.forward();
    } else {
      _fade.reverse();
    }
    setState(() {});
  }

  @override
  void dispose() {
    _handle.dispose();
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => OverlayPortal(
    controller: _portal,
    overlayChildBuilder: (context) {
      final rect = _handle.rect;
      if (rect == null && _last == null) return const SizedBox.shrink();
      final overlay = Overlay.of(context, rootOverlay: true).context.findRenderObject() as RenderBox?;
      Rect local(Rect r) => overlay == null ? r : overlay.globalToLocal(r.topLeft) & r.size;
      final target = local(rect ?? _last!);
      return IgnorePointer(
        ignoring: !_handle.isOpen,
        child: TweenAnimationBuilder<Rect?>(
          tween: RectTween(begin: _lastShown ?? target, end: target),
          duration: _previewDuration,
          curve: _previewCurve,
          onEnd: () => _lastShown = target,
          builder: (context, anchor, child) => DifyFloatingLayout(
            anchor: anchor ?? target,
            placement: DifyPlacement.right,
            sideOffset: 8,
            animation: _fade,
            child: child,
          ),
          child: MouseRegion(
            onEnter: (_) => _handle.hold(),
            onExit: (_) => _handle.activeKey == null ? null : _handle.leave(_handle.activeKey!),
            child: _card(),
          ),
        ),
      );
    },
    child: _PreviewScope(handle: _handle, child: widget.child),
  );

  Rect? _last, _lastShown;
  Widget? _lastCard;

  Widget _card() {
    if (_handle.rect != null) _last = _handle.rect;
    final builder = _handle.builder;
    if (builder != null) {
      _lastCard = KeyedSubtree(
        key: ValueKey(_handle.activeKey),
        child: Builder(builder: builder),
      );
    }
    final dir = _handle.direction;
    return Container(
      decoration: BoxDecoration(
        color: DifyColors.componentsPanelBg,
        borderRadius: BorderRadius.circular(DifyRadius.xl),
        boxShadow: DifyShadows.lg,
      ),
      clipBehavior: Clip.antiAlias,
      child: AnimatedSize(
        duration: _previewDuration,
        curve: _previewCurve,
        alignment: Alignment.topLeft,
        child: AnimatedSwitcher(
          duration: _previewDuration,
          switchInCurve: _previewCurve,
          switchOutCurve: _previewCurve,
          layoutBuilder: (current, previous) => Stack(alignment: Alignment.topLeft, children: [...previous, ?current]),
          transitionBuilder: (child, animation) {
            final incoming = child.key == _lastCard?.key;
            final from = Offset(0, (incoming ? dir : -dir) * 8.0);
            return FadeTransition(
              opacity: animation,
              child: AnimatedBuilder(
                animation: animation,
                builder: (context, c) => Transform.translate(offset: from * (1 - animation.value), child: c),
                child: child,
              ),
            );
          },
          child: Container(
            key: _lastCard?.key,
            width: 224,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Material(type: MaterialType.transparency, child: _lastCard ?? const SizedBox.shrink()),
          ),
        ),
      ),
    );
  }
}

/// A row with a preview card: hovering it (or focusing it from the keyboard) shows [preview] in the nearest
/// [PreviewCardScope]'s card.
class PreviewCardTrigger extends StatefulWidget {
  const PreviewCardTrigger({super.key, required this.preview, required this.child});
  final WidgetBuilder preview;
  final Widget child;

  @override
  State<PreviewCardTrigger> createState() => _PreviewCardTriggerState();
}

class _PreviewCardTriggerState extends State<PreviewCardTrigger> {
  PreviewCardHandle? _handle;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _handle = PreviewCardScope.of(context);
  }

  @override
  void dispose() {
    _handle?.unmounted(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final h = _handle;
    if (h == null) return widget.child;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      includeSemantics: false,
      onFocusChange: (f) {
        if (f && FocusManager.instance.highlightMode == FocusHighlightMode.traditional) {
          h.enter(this, context, widget.preview);
        } else if (!f) {
          h.leave(this);
        }
      },
      child: MouseRegion(
        onEnter: (_) => h.enter(this, context, widget.preview),
        onExit: (_) => h.leave(this),
        child: widget.child,
      ),
    );
  }
}

/// The preview card's block content: BlockIcon md (`mb-2`), the title (`system-md-medium`, `mb-1`) and the
/// description (`system-xs-regular`).
class BlockPreviewContent extends StatelessWidget {
  const BlockPreviewContent({
    super.key,
    required this.type,
    required this.title,
    required this.description,
    this.toolIcon,
    this.footer,
    this.titleStyle = DifyType.systemMdMedium,
    this._descriptionColor,
  });

  final String type, title, description;
  final ProviderIcon toolIcon;
  final Widget? footer;
  final DifyTextStyle titleStyle;
  final Color? _descriptionColor;
  Color get descriptionColor => _descriptionColor ?? DifyColors.textTertiary;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SelectorBlockIcon(type: type, size: SelectorIconSize.md, toolIcon: toolIcon),
      const SizedBox(height: 8),
      DifyText(title, titleStyle, color: DifyColors.textPrimary, maxLines: null),
      const SizedBox(height: 4),
      DifyText(description, DifyType.systemXsRegular, color: descriptionColor, maxLines: null),
      ?footer,
    ],
  );
}

/// The keys that move focus between radio or tab items.
bool isArrowKey(KeyEvent e, {required bool forward}) =>
    e is KeyDownEvent &&
    (forward
        ? e.logicalKey == LogicalKeyboardKey.arrowRight || e.logicalKey == LogicalKeyboardKey.arrowDown
        : e.logicalKey == LogicalKeyboardKey.arrowLeft || e.logicalKey == LogicalKeyboardKey.arrowUp);

// ---- storage.ts and the marketplace search -------------------------------------------------------------------

/// One of storage.ts's localStorage booleans (foxact createLocalStorageState, `false` until stored): shared by every
/// list that reads it, loaded once, written through on change.
class StoredFlag extends ValueNotifier<bool> {
  StoredFlag._(this.key) : super(false) {
    SharedPreferences.getInstance().then((p) {
      final raw = p.getString(key);
      if (!_written && raw != null) super.value = raw == 'true';
    }, onError: (Object _) {});
  }

  static final _all = <String, StoredFlag>{};

  /// `workflow_tools_featured_collapsed`, `workflow_triggers_featured_collapsed`.
  static StoredFlag of(String key) => _all.putIfAbsent(key, () => StoredFlag._(key));

  /// Forgets the loaded values (tests).
  @visibleForTesting
  static void reset() => _all.clear();

  final String key;
  bool _written = false;

  @override
  set value(bool v) {
    _written = true;
    super.value = v;
    SharedPreferences.getInstance().then((p) => p.setString(key, '$v'), onError: (Object _) => false);
  }
}

/// A section's marketplace search (useDebounce 500 ms + useMarketplacePlugins): [update] with the current query (or
/// null when it should not search); the query is sent once it has not changed for 500 ms. [pending] while waiting or
/// fetching; [plugins] holds the last results.
class MarketplaceSearch extends ChangeNotifier {
  MarketplaceSearch(this._search);

  Future<List<MarketplacePlugin>> Function(MarketplaceQuery query)? _search;
  MarketplaceQuery? _wanted, _sent;
  Timer? _timer;
  bool _fetching = false;
  List<MarketplacePlugin> plugins = const [];

  static const debounce = Duration(milliseconds: 500);

  bool get pending => (_wanted != null && !_same(_wanted, _sent)) || _fetching;

  static bool _same(MarketplaceQuery? a, MarketplaceQuery? b) =>
      a?.query == b?.query && a?.category == b?.category && listEquals(a?.tags, b?.tags);

  void update(MarketplaceQuery? query, Future<List<MarketplacePlugin>> Function(MarketplaceQuery query)? search) {
    _search = search;
    if (_same(query, _wanted)) return;
    _wanted = query;
    _timer?.cancel();
    if (query == null) {
      _sent = null;
      _fetching = false;
      if (plugins.isNotEmpty) plugins = const [];
      return;
    }
    _timer = Timer(debounce, _send);
  }

  Future<void> _send() async {
    final q = _wanted, search = _search;
    if (q == null) return;
    _sent = q;
    if (search == null) {
      plugins = const [];
      notifyListeners();
      return;
    }
    _fetching = true;
    notifyListeners();
    try {
      final r = await search(q);
      if (_same(q, _wanted)) plugins = r;
    } catch (_) {
      if (_same(q, _wanted)) plugins = const [];
    } finally {
      if (_same(q, _wanted)) _fetching = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
