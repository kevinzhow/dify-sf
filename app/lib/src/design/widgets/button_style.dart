import 'package:flutter/widgets.dart';

import '../dify_tokens.g.dart';
import 'form_control_shared.dart' show difyFocusRingShadow;
import 'surface.dart';

/// dify-ui button variants (button/index.tsx, icon-button/variants.ts). [plain] is IconButton's `default` (a bare
/// glyph that tints on hover); Button has no such variant.
enum DifyButtonVariant { plain, primary, secondary, secondaryAccent, tertiary, ghost, ghostAccent }

/// `tone`: Dify's `default` and `destructive`.
enum DifyButtonTone { normal, destructive }

/// The resolved look of a button in one state.
@immutable
class DifyButtonLook {
  const DifyButtonLook({
    required this.foreground,
    this.background,
    this.ring,
    this.shadows = const [],
    this.insetShadows = const [],
    this.blur = 0,
  });

  final Color foreground;
  final Color? background;

  /// `inset-ring-[0.5px]` colour.
  final Color? ring;
  final List<BoxShadow> shadows;

  /// The inset parts of `shadow-primary-button` (BoxShadow can't be inset; painted by [DifyButtonSurface]).
  final List<BoxShadow> insetShadows;

  /// `backdrop-blur-*` in CSS px (the blur's standard deviation).
  final double blur;

  DifyButtonLook copyWith({Color? background, Color? ring, double? blur}) => DifyButtonLook(
    foreground: foreground,
    background: background ?? this.background,
    ring: ring ?? this.ring,
    shadows: shadows,
    insetShadows: insetShadows,
    blur: blur ?? this.blur,
  );
}

/// A call site's classes over a button's look in one state (`className` merged after the variant's), given whether
/// it is hovered; not applied while disabled.
typedef DifyButtonRestyle = DifyButtonLook Function(DifyButtonLook look, bool hovered);

/// The dark theme's glass on the workflow header's buttons (features-trigger.tsx, version-history-button.tsx,
/// header-in-restoring.tsx: `bg-white/10 inset-ring-black/5 backdrop-blur-xs` when `theme === 'dark'`; the
/// variable buttons' open state, `border-black/5 bg-white/10 backdrop-blur-xs`, drawn as the same inset ring). The
/// variant's `hover:` colours still win while hovered. Null in the light theme or when not [on].
DifyButtonRestyle? difyDarkGlass({bool on = true}) => DifyColors.isDark && on
    ? (look, hovered) => hovered
          ? look.copyWith(blur: 4)
          : look.copyWith(background: const Color(0x1AFFFFFF), ring: const Color(0x0D000000), blur: 4)
    : null;

// `shadow-xs shadow-shadow-shadow-3`: Tailwind's shadow colour utility replaces the colour of shadow-xs.
List<BoxShadow> get _xs3 => [for (final s in DifyShadows.xs) s.copyWith(color: DifyColors.shadowShadow3)];

// `shadow-primary-button` (styles.css): the generated tokens hold the two plain parts; the 0.5 px ring in
// shadow-10 and the three inset parts are added here.
List<BoxShadow> get _primaryShadows => [
  ...DifyShadows.primaryButton,
  BoxShadow(spreadRadius: 0.5, color: DifyColors.shadowShadow10),
];
List<BoxShadow> get _primaryInset => [
  BoxShadow(offset: Offset(0, -6), blurRadius: 12, spreadRadius: -4, color: DifyColors.shadowShadow5),
  BoxShadow(blurRadius: 1, color: Color.fromRGBO(255, 255, 255, 0.16)),
  BoxShadow(offset: Offset(0, 0.5), color: Color.fromRGBO(255, 255, 255, 0.08)),
];

/// The look of [variant] in [tone] (CVA variants plus compound variants; hover is ignored when disabled, as
/// Tailwind orders `data-disabled:` after `hover:`).
DifyButtonLook difyButtonLook(
  DifyButtonVariant variant,
  DifyButtonTone tone, {
  bool hovered = false,
  bool disabled = false,
}) {
  final d = tone == DifyButtonTone.destructive;
  final h = hovered && !disabled;
  switch (variant) {
    case DifyButtonVariant.plain:
      if (disabled) return DifyButtonLook(foreground: DifyColors.textDisabled);
      if (!h) return DifyButtonLook(foreground: DifyColors.textTertiary);
      return d
          ? DifyButtonLook(foreground: DifyColors.textDestructive, background: DifyColors.stateDestructiveHover)
          : DifyButtonLook(foreground: DifyColors.textSecondary, background: DifyColors.stateBaseHover);
    case DifyButtonVariant.primary:
      if (disabled) {
        return d
            ? DifyButtonLook(
                foreground: DifyColors.componentsButtonDestructivePrimaryTextDisabled,
                background: DifyColors.componentsButtonDestructivePrimaryBgDisabled,
                ring: DifyColors.componentsButtonDestructivePrimaryBgDisabled,
              )
            : DifyButtonLook(
                foreground: DifyColors.componentsButtonPrimaryTextDisabled,
                background: DifyColors.componentsButtonPrimaryBgDisabled,
                ring: DifyColors.componentsButtonPrimaryBorderDisabled,
              );
      }
      return DifyButtonLook(
        foreground: d ? DifyColors.componentsButtonDestructivePrimaryText : DifyColors.componentsButtonPrimaryText,
        background: switch ((d, h)) {
          (true, true) => DifyColors.componentsButtonDestructivePrimaryBgHover,
          (true, false) => DifyColors.componentsButtonDestructivePrimaryBg,
          (false, true) => DifyColors.componentsButtonPrimaryBgHover,
          (false, false) => DifyColors.componentsButtonPrimaryBg,
        },
        ring: switch ((d, h)) {
          (true, true) => DifyColors.componentsButtonDestructivePrimaryBorderHover,
          (true, false) => DifyColors.componentsButtonDestructivePrimaryBorder,
          (false, true) => DifyColors.componentsButtonPrimaryBorderHover,
          (false, false) => DifyColors.componentsButtonPrimaryBorder,
        },
        shadows: h ? _xs3 : _primaryShadows,
        insetShadows: h ? const [] : _primaryInset,
      );
    case DifyButtonVariant.secondary:
    case DifyButtonVariant.secondaryAccent:
      final accent = variant == DifyButtonVariant.secondaryAccent;
      final dd = d && !accent; // secondary-accent has no destructive compound
      if (disabled) {
        return DifyButtonLook(
          foreground: dd
              ? DifyColors.componentsButtonDestructiveSecondaryTextDisabled
              : accent
              ? DifyColors.componentsButtonSecondaryAccentTextDisabled
              : DifyColors.componentsButtonSecondaryTextDisabled,
          background: DifyColors.componentsButtonSecondaryBgDisabled,
          ring: DifyColors.componentsButtonSecondaryBorderDisabled,
          blur: 4,
        );
      }
      return DifyButtonLook(
        foreground: dd
            ? DifyColors.componentsButtonDestructiveSecondaryText
            : accent
            ? DifyColors.componentsButtonSecondaryAccentText
            : DifyColors.componentsButtonSecondaryText,
        background: switch ((dd, h)) {
          (true, true) => DifyColors.componentsButtonDestructiveSecondaryBgHover,
          (true, false) => DifyColors.componentsButtonDestructiveSecondaryBg,
          (false, true) => DifyColors.componentsButtonSecondaryBgHover,
          (false, false) => DifyColors.componentsButtonSecondaryBg,
        },
        ring: switch ((dd, h)) {
          (true, true) => DifyColors.componentsButtonDestructiveSecondaryBorderHover,
          (true, false) => DifyColors.componentsButtonDestructiveSecondaryBorder,
          (false, true) => DifyColors.componentsButtonSecondaryBorderHover,
          (false, false) => DifyColors.componentsButtonSecondaryBorder,
        },
        shadows: _xs3,
        blur: 5,
      );
    case DifyButtonVariant.tertiary:
      if (disabled) {
        return d
            ? DifyButtonLook(
                foreground: DifyColors.componentsButtonDestructiveTertiaryTextDisabled,
                background: DifyColors.componentsButtonDestructiveTertiaryBgDisabled,
              )
            : DifyButtonLook(
                foreground: DifyColors.componentsButtonTertiaryTextDisabled,
                background: DifyColors.componentsButtonTertiaryBgDisabled,
              );
      }
      return DifyButtonLook(
        foreground: d ? DifyColors.componentsButtonDestructiveTertiaryText : DifyColors.componentsButtonTertiaryText,
        background: switch ((d, h)) {
          (true, true) => DifyColors.componentsButtonDestructiveTertiaryBgHover,
          (true, false) => DifyColors.componentsButtonDestructiveTertiaryBg,
          (false, true) => DifyColors.componentsButtonTertiaryBgHover,
          (false, false) => DifyColors.componentsButtonTertiaryBg,
        },
      );
    case DifyButtonVariant.ghost:
      if (disabled) {
        return DifyButtonLook(
          foreground: d
              ? DifyColors.componentsButtonDestructiveGhostTextDisabled
              : DifyColors.componentsButtonGhostTextDisabled,
        );
      }
      return DifyButtonLook(
        foreground: d ? DifyColors.componentsButtonDestructiveGhostText : DifyColors.componentsButtonGhostText,
        background: !h
            ? null
            : d
            ? DifyColors.componentsButtonDestructiveGhostBgHover
            : DifyColors.componentsButtonGhostBgHover,
      );
    case DifyButtonVariant.ghostAccent:
      if (disabled) return DifyButtonLook(foreground: DifyColors.componentsButtonSecondaryAccentTextDisabled);
      return DifyButtonLook(
        foreground: DifyColors.componentsButtonSecondaryAccentText,
        background: h ? DifyColors.stateAccentHover : null,
      );
  }
}

/// Paints a [DifyButtonLook]: background, 0.5 px inset ring, outer and inset shadows, backdrop blur and the
/// `focus-visible:ring-2 ring-state-accent-solid` focus ring. Text and icons inside take the foreground colour.
class DifyButtonSurface extends StatelessWidget {
  const DifyButtonSurface({
    super.key,
    required this.look,
    required this.radius,
    required this.child,
    this.focused = false,
  });

  final DifyButtonLook look;
  final double radius;
  final bool focused;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(radius);
    Widget box = DecoratedBox(
      decoration: BoxDecoration(
        color: look.background,
        borderRadius: r,
        boxShadow: [
          ...look.shadows,
          if (focused) difyFocusRingShadow(),
        ],
      ),
      position: DecorationPosition.background,
      child: CustomPaint(
        foregroundPainter: look.ring != null || look.insetShadows.isNotEmpty
            ? _InsetPainter(r, look.ring, look.insetShadows)
            : null,
        child: child,
      ),
    );
    box = DifyBlurredBox(blur: look.blur, borderRadius: r, child: box);
    return IconTheme.merge(
      data: IconThemeData(color: look.foreground),
      child: DefaultTextStyle.merge(
        style: TextStyle(color: look.foreground),
        child: box,
      ),
    );
  }
}

class _InsetPainter extends CustomPainter {
  _InsetPainter(this.radius, this.ring, this.insets);
  final BorderRadius radius;
  final Color? ring;
  final List<BoxShadow> insets;

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = radius.toRRect(Offset.zero & size);
    canvas.save();
    canvas.clipRRect(rrect);
    // An inset shadow: the area outside the box (offset and shrunk by the spread), blurred, inside the box.
    for (final s in insets) {
      final hole = rrect.shift(s.offset).deflate(s.spreadRadius);
      final path = Path()
        ..fillType = PathFillType.evenOdd
        ..addRect((Offset.zero & size).inflate(s.blurRadius * 2 + 20))
        ..addRRect(hole);
      final paint = Paint()..color = s.color;
      if (s.blurRadius > 0) paint.maskFilter = MaskFilter.blur(BlurStyle.normal, s.blurRadius / 2);
      canvas.drawPath(path, paint);
    }
    canvas.restore();
    if (ring != null) {
      canvas.drawRRect(
        rrect.deflate(0.25),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.5
          ..color = ring!,
      );
    }
  }

  @override
  bool shouldRepaint(_InsetPainter old) => old.ring != ring || old.insets != insets || old.radius != radius;
}

/// Pointer, keyboard and focus handling shared by the buttons (Base UI Button): hover and press tracking, Enter and
/// Space activation, focus-visible tracking; [disabled] blocks activation and, unless [focusableWhenDisabled], focus.
class DifyPressable extends StatefulWidget {
  const DifyPressable({
    super.key,
    required this.builder,
    this.onPressed,
    this.disabled = false,
    this.focusableWhenDisabled = false,
    this.focusNode,
    this.autofocus = false,
    this.semanticLabel,
  });

  final Widget Function(BuildContext context, bool hovered, bool focused) builder;
  final VoidCallback? onPressed;
  final bool disabled;
  final bool focusableWhenDisabled;
  final FocusNode? focusNode;
  final bool autofocus;
  final String? semanticLabel;

  @override
  State<DifyPressable> createState() => _DifyPressableState();
}

class _DifyPressableState extends State<DifyPressable> {
  bool _hovered = false;
  bool _pressed = false;
  bool _focused = false;

  bool get _enabled => !widget.disabled && widget.onPressed != null;

  void _activate() {
    if (_enabled) widget.onPressed!();
  }

  @override
  Widget build(BuildContext context) {
    final focusable = !widget.disabled || widget.focusableWhenDisabled;
    return MergeSemantics(
      child: Semantics(
        button: true,
        enabled: !widget.disabled,
        label: widget.semanticLabel,
        onTap: _enabled ? _activate : null,
        child: FocusableActionDetector(
          focusNode: widget.focusNode,
          autofocus: widget.autofocus,
          enabled: focusable,
          mouseCursor: widget.disabled ? SystemMouseCursors.forbidden : SystemMouseCursors.click,
          actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => _activate())},
          onShowFocusHighlight: (v) => setState(() => _focused = v),
          child: MouseRegion(
            onEnter: (_) => setState(() => _hovered = true),
            onExit: (_) => setState(() => _hovered = false),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              excludeFromSemantics: true,
              onTapDown: _enabled ? (_) => setState(() => _pressed = true) : null,
              onTapUp: _enabled ? (_) => setState(() => _pressed = false) : null,
              onTapCancel: _enabled ? () => setState(() => _pressed = false) : null,
              onTap: _enabled ? _activate : null,
              child: widget.semanticLabel == null
                  ? widget.builder(context, _hovered || _pressed, _focused)
                  : ExcludeSemantics(child: widget.builder(context, _hovered || _pressed, _focused)),
            ),
          ),
        ),
      ),
    );
  }
}
