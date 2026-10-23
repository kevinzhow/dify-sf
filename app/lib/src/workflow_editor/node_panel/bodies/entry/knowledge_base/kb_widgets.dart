/// The Knowledge Base panel's controls: OptionCard (knowledge-base/components/option-card.tsx), dify-ui's
/// NumberField with its stepper controls, the WeightedScore slider, the multimodal TipCard, a Textarea and the
/// ModelSelector (trigger in its medium size and the model popup).
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../../../cards/model_chip.dart';
import '../../../../../design/css_metrics.dart';
import '../../../../../design/dify_icon.dart';
import '../../../../../design/dify_tokens.g.dart';
import '../../../../../design/widgets/widgets.dart';
import '../../../../../i18n/dify_i18n.dart';
import '../../../../../workflow/model_catalog.dart';
import 'knowledge_base_logic.dart';

// ---- OptionCard --------------------------------------------------------------------------------------------------

/// The effect blobs of public/knowledge/option-card-effect-*.svg: a 28 px circle at (26, 26), blurred by 80 px.
Map<String, (Color, double)> get _effects => {
  'blue': (DifyOptionCardEffectColors.blue, 0.5),
  'blue-light': (DifyOptionCardEffectColors.blueLight, 0.8),
  'orange': (DifyOptionCardEffectColors.orange, 0.8),
  'purple': (DifyOptionCardEffectColors.purple, 0.8),
  'teal': (DifyOptionCardEffectColors.teal, 0.8),
};

class _EffectPainter extends CustomPainter {
  const _EffectPainter(this.color, this.opacity);
  final Color color;
  final double opacity;

  @override
  void paint(Canvas canvas, Size size) => canvas.drawCircle(
    const Offset(26, 26),
    28,
    Paint()
      ..color = color.withValues(alpha: opacity)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 80),
  );

  @override
  bool shouldRepaint(_EffectPainter old) => old.color != color || old.opacity != opacity;
}

/// The header effect (`absolute -top-0.5 -left-0.5 h-14 w-14`, shown on hover or when active).
class KbOptionEffect extends StatelessWidget {
  const KbOptionEffect(this.name, {super.key});
  final String name;

  @override
  Widget build(BuildContext context) {
    final e = _effects[name];
    if (e == null) return const SizedBox.shrink();
    return IgnorePointer(
      child: CustomPaint(size: const Size(214, 124), painter: _EffectPainter(e.$1, e.$2)),
    );
  }
}

/// An option's icon: `text-text-tertiary`, its colour when [highlighted] (active or the card hovered).
class KbOptionIcon extends StatelessWidget {
  const KbOptionIcon({
    super.key,
    required this.icon,
    required this.activeColor,
    required this.highlighted,
    this.size = 18,
  });
  final String icon;
  final Color activeColor;
  final bool highlighted;
  final double size;

  Color get color => highlighted ? activeColor : DifyColors.textTertiary;

  @override
  Widget build(BuildContext context) => DifyIcon(icon, size: size, color: color);
}

/// Badge (`ml-1 h-4 border-text-accent-secondary text-text-accent-secondary`): "Recommend".
class KbRecommendBadge extends StatelessWidget {
  const KbRecommendBadge({super.key});

  @override
  Widget build(BuildContext context) => Container(
    height: 16,
    margin: const EdgeInsets.only(left: 4),
    padding: const EdgeInsets.symmetric(horizontal: 5),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(DifyRadius.badge),
      border: Border.all(color: DifyColors.textAccentSecondary),
    ),
    child: Center(
      widthFactor: 1,
      child: DifyText(
        kbT('dataset-creation', 'stepTwo.recommend'),
        DifyType.system2xsMediumUppercase,
        color: DifyColors.textAccentSecondary,
      ),
    ),
  );
}

/// The `relative rounded-b-xl bg-components-panel-bg p-3` block under an active card, with the ArrowShape notch
/// (`absolute -top-2.75 left-3.5 h-4 w-4 text-components-panel-bg`).
class KbCardBody extends StatelessWidget {
  const KbCardBody({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Stack(
    clipBehavior: Clip.none,
    children: [
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: DifyColors.componentsPanelBg,
          borderRadius: BorderRadius.vertical(bottom: Radius.circular(12)),
        ),
        child: child,
      ),
      Positioned(
        top: -11,
        left: 14,
        child: DifyIcon('vender/knowledge/arrow-shape', size: 16, color: DifyColors.componentsPanelBg),
      ),
    ],
  );
}

/// OptionCard: `group overflow-hidden rounded-xl border` with the header (`relative flex rounded-t-xl p-2`: effect,
/// 18 px icon, title + "Recommend", optional radio, description) and [child] below while active. A click reports
/// [onClick] unless [readonly] or not [enableSelect].
class KbOptionCard extends StatefulWidget {
  const KbOptionCard({
    super.key,
    required this.id,
    this.selectedId,
    this.enableSelect = true,
    this.enableHighlightBorder = true,
    this.enableRadio = false,
    this.icon,
    required this.title,
    this.description,
    this.isRecommended = false,
    this.child,
    this.effect,
    this.onClick,
    this.readonly = false,
  });

  final String id;
  final String? selectedId;
  final bool enableSelect, enableHighlightBorder, enableRadio, isRecommended, readonly;

  /// The icon, given whether it is highlighted (the card active or hovered).
  final Widget Function(bool highlighted)? icon;
  final String title;
  final String? description;
  final Widget? child;
  final String? effect;
  final ValueChanged<String>? onClick;

  @override
  State<KbOptionCard> createState() => _KbOptionCardState();
}

class _KbOptionCardState extends State<KbOptionCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final active = w.id == w.selectedId;
    final highlighted = active || _hovered;
    final header = Stack(
      clipBehavior: Clip.none,
      children: [
        if (w.effect != null && highlighted) Positioned(left: -2, top: -2, child: KbOptionEffect(w.effect!)),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (w.icon != null)
                Container(
                  width: 18,
                  height: 18,
                  margin: const EdgeInsets.only(right: 4),
                  alignment: Alignment.center,
                  child: w.icon!(highlighted),
                ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 1, bottom: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Row(
                              children: [
                                Flexible(
                                  child: DifyText(w.title, DifyType.systemSmMedium, color: DifyColors.textSecondary),
                                ),
                                if (w.isRecommended) const Flexible(child: KbRecommendBadge()),
                              ],
                            ),
                          ),
                          if (w.enableRadio) ...[const SizedBox(width: 8), DifyRadioControl(checked: active)],
                        ],
                      ),
                      if (w.description != null && w.description!.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: DifyText(
                            w.description!,
                            DifyType.systemXsRegular,
                            color: DifyColors.textTertiary,
                            maxLines: null,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
    final highlight = active && w.enableHighlightBorder;
    return Semantics(
      button: w.enableSelect,
      selected: active,
      child: MouseRegion(
        cursor: w.readonly
            ? SystemMouseCursors.forbidden
            : (w.enableSelect ? SystemMouseCursors.click : MouseCursor.defer),
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            if (!w.readonly && w.enableSelect) w.onClick?.call(w.id);
          },
          child: Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: DifyColors.componentsOptionCardOptionBg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: highlight
                    ? DifyColors.componentsOptionCardOptionSelectedBorder
                    : DifyColors.componentsOptionCardOptionBorder,
                width: highlight ? 1.5 : 1,
              ),
              boxShadow: w.enableSelect && _hovered ? DifyShadows.xs : null,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                header,
                if (w.child != null && active) KbCardBody(child: w.child!),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---- NumberField with controls -----------------------------------------------------------------------------------

/// dify-ui's NumberField (Group + Input + Controls): [DifyNumberField] with the `w-6 border-l border-divider-subtle`
/// column of Increment / Decrement buttons (`i-ri-arrow-up-s-line` / `i-ri-arrow-down-s-line`, 12 px) at its end.
class KbNumberField extends StatelessWidget {
  const KbNumberField({
    super.key,
    required this.value,
    required this.onChanged,
    this.min,
    this.max,
    this.step = 1,
    this.disabled = false,
    this.semanticLabel,
  });

  final num value;
  final ValueChanged<num?> onChanged;
  final num? min, max;
  final num step;
  final bool disabled;
  final String? semanticLabel;

  num _clamp(num v) {
    var n = v;
    if (min != null && n < min!) n = min!;
    if (max != null && n > max!) n = max!;
    // Floating steps (0.01) would leave 0.30000000000000004.
    final digits = step is int ? 0 : (step.toString().split('.').last.length);
    final rounded = num.parse(n.toStringAsFixed(digits));
    return rounded == rounded.roundToDouble() ? rounded.round() : rounded;
  }

  Widget _button(String label, String icon, num next, bool enabled) => Expanded(
    child: DifyPressable(
      semanticLabel: label,
      disabled: !enabled,
      onPressed: enabled ? () => onChanged(_clamp(next)) : null,
      builder: (context, hovered, focused) => Container(
        width: 24,
        color: hovered && enabled ? DifyColors.componentsInputBgHover : null,
        alignment: Alignment.center,
        child: RemixIcon(icon, size: 12, color: DifyColors.textTertiary),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      DifyNumberField(
        value: value,
        onChanged: onChanged,
        min: min,
        max: max,
        step: step,
        disabled: disabled,
        semanticLabel: semanticLabel,
        inputPaddingRight: 12 + 24,
      ),
      Positioned(
        top: 1,
        bottom: 1,
        right: 1,
        child: Container(
          width: 24,
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: DifyColors.dividerSubtle)),
          ),
          child: Column(
            children: [
              _button('Increment value', 'arrow-up-s-line', value + step, !disabled && (max == null || value < max!)),
              _button('Decrement value', 'arrow-down-s-line', value - step, !disabled && (min == null || value > min!)),
            ],
          ),
        ),
      ),
    ],
  );
}

// ---- WeightedScore -----------------------------------------------------------------------------------------------

/// weighted-score.tsx `formatNumber`.
String formatWeight(num value) {
  if (value > 0 && value < 1) return '0.${(value * 10).round()}';
  if (value == 1) return '1.0';
  return '${value is double && value == value.roundToDouble() ? value.round() : value}';
}

/// WeightedScore (app/configuration/dataset-config/params-config/weighted-score.tsx): a 0..1 slider (step 0.1) in
/// a `rounded-lg border border-components-panel-border px-3 pt-5 pb-2` box, the track teal (keyword), the range
/// blue-light (semantic); below, "SEMANTIC 0.7" and "0.3 KEYWORD". Reports `[v, (10 - v * 10) / 10]`.
class KbWeightedScore extends StatelessWidget {
  const KbWeightedScore({super.key, required this.value, required this.onChange, this.readonly = false});
  final List<num> value;
  final ValueChanged<List<num>> onChange;
  final bool readonly;

  void _set(double fraction) {
    if (readonly) return;
    final v = (fraction.clamp(0.0, 1.0) * 10).round() / 10;
    if (v != value[0]) onChange([v, (10 - v * 10) / 10]);
  }

  @override
  Widget build(BuildContext context) {
    final semantic = kbT('dataset', 'weightedScore.semantic'), keyword = kbT('dataset', 'weightedScore.keyword');
    final v = value[0].toDouble();
    final valueText = '$semantic: ${formatWeight(v)}, $keyword: ${formatWeight((10 - v * 10) / 10)}';
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 20, 12, 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(DifyRadius.lg),
        border: Border.all(color: DifyColors.componentsPanelBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            slider: true,
            label: semantic,
            value: valueText,
            enabled: !readonly,
            child: Opacity(
              opacity: readonly ? 0.3 : 1,
              child: LayoutBuilder(
                builder: (context, c) => GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (d) => _set(d.localPosition.dx / c.maxWidth),
                  onHorizontalDragUpdate: (d) => _set(d.localPosition.dx / c.maxWidth),
                  child: SizedBox(
                    height: 20,
                    child: Stack(
                      clipBehavior: Clip.none,
                      alignment: Alignment.centerLeft,
                      children: [
                        Container(
                          height: 4,
                          decoration: BoxDecoration(
                            color: DifyColors.utilColorsTealTeal500,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        Container(
                          width: c.maxWidth * v,
                          height: 4,
                          decoration: BoxDecoration(
                            color: DifyColors.utilColorsBlueLightBlueLight500,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        Positioned(
                          left: c.maxWidth * v - 4,
                          child: Container(
                            width: 8,
                            height: 20,
                            decoration: BoxDecoration(
                              color: readonly
                                  ? DifyColors.componentsSliderKnobDisabled
                                  : DifyColors.componentsSliderKnob,
                              borderRadius: BorderRadius.circular(3),
                              border: Border.all(color: DifyColors.componentsSliderKnobBorder, width: Css.hairline),
                              boxShadow: readonly ? null : DifyShadows.sm,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _label(semantic, formatWeight(v), DifyColors.utilColorsBlueLightBlueLight500, leading: true),
              _label(keyword, formatWeight(value[1]), DifyColors.utilColorsTealTeal500, leading: false),
            ],
          ),
        ],
      ),
    );
  }

  /// `flex w-22.5 shrink-0 items-center system-xs-semibold-uppercase` with the name (titled, truncated).
  Widget _label(String name, String number, Color color, {required bool leading}) {
    final title = DifyTooltip(
      content: DifyTextLine(name),
      child: Semantics(
        label: name,
        excludeSemantics: true,
        child: DifyText(name, DifyType.systemXsSemiboldUppercase, color: color),
      ),
    );
    final n = DifyText(number, DifyType.systemXsSemiboldUppercase, color: color);
    return SizedBox(
      width: 90,
      child: Row(
        mainAxisAlignment: leading ? MainAxisAlignment.start : MainAxisAlignment.end,
        children: leading
            ? [Flexible(child: title), const SizedBox(width: 4), n]
            : [n, const SizedBox(width: 4), Flexible(child: title)],
      ),
    );
  }
}

// ---- Multimodal retrieval TipCard --------------------------------------------------------------------------------

const _pictureFrame =
    '''<svg width="48" height="48" viewBox="0 0 48 48" fill="none" xmlns="http://www.w3.org/2000/svg"> <g filter="url(#filter0_dd)"> <path d="M8 13C8 8.58172 11.5817 5 16 5H32C36.4183 5 40 8.58172 40 13V29C40 33.4183 36.4183 37 32 37H16C11.5817 37 8 33.4183 8 29V13Z" fill="url(#paint0_linear)"/> <path d="M16 5.5H32C36.1421 5.5 39.5 8.85786 39.5 13V29C39.5 33.1421 36.1421 36.5 32 36.5H16C11.8579 36.5 8.5 33.1421 8.5 29V13C8.5 8.85786 11.8579 5.5 16 5.5Z" stroke="#5925DC" stroke-opacity="0.2"/> <g clip-path="url(#clip0)"> <path d="M31.0557 18.2448L31.2612 17.7734C31.6274 16.9329 32.2871 16.2637 33.1103 15.8975L33.7433 15.616C34.0856 15.4638 34.0856 14.9657 33.7433 14.8134L33.1457 14.5476C32.3014 14.1721 31.6299 13.4781 31.2699 12.609L31.0589 12.0996C30.9119 11.7446 30.4215 11.7446 30.2744 12.0996L30.0634 12.609C29.7035 13.4781 29.032 14.1721 28.1877 14.5476L27.59 14.8134C27.2478 14.9657 27.2478 15.4638 27.59 15.616L28.2231 15.8975C29.0463 16.2637 29.7059 16.9329 30.0722 17.7734L30.2776 18.2448C30.428 18.5899 30.9054 18.5899 31.0557 18.2448ZM24 14.3333C20.3181 14.3333 17.3334 17.3181 17.3334 21C17.3334 23.053 18.2613 24.8892 19.7207 26.1121L25.9104 19.9225C26.2359 19.597 26.7635 19.597 27.0889 19.9225L30.3134 23.147C30.3144 23.1441 30.3154 23.1411 30.3164 23.1381C30.5435 22.467 30.6667 21.7479 30.6667 21C30.6667 20.7304 30.6508 20.4649 30.6198 20.2043L32.2749 20.0078C32.3135 20.3335 32.3334 20.6646 32.3334 21C32.3334 25.6023 28.6024 29.3333 24 29.3333C19.3976 29.3333 15.6667 25.6023 15.6667 21C15.6667 16.3976 19.3976 12.6666 24 12.6666C24.7179 12.6666 25.4156 12.7576 26.0819 12.929L25.6667 14.5431C25.1349 14.4063 24.5766 14.3333 24 14.3333ZM23.0109 27.5937C23.3334 27.6417 23.6635 27.6665 23.9997 27.6665C26.3011 27.6665 28.3327 26.5002 29.5316 24.7221L26.4997 21.6902L21.1577 27.0321L21.1611 27.0337C21.7373 27.3053 22.3587 27.4967 23.0109 27.5937ZM23.1667 19.3333C23.1667 20.2538 22.4205 21 21.5 21C20.5795 21 19.8334 20.2538 19.8334 19.3333C19.8334 18.4128 20.5795 17.6666 21.5 17.6666C22.4205 17.6666 23.1667 18.4128 23.1667 19.3333Z" fill="white"/> </g> </g> <defs> <filter id="filter0_dd" x="-2" y="-2" width="52" height="52" filterUnits="userSpaceOnUse" color-interpolation-filters="sRGB"> <feFlood flood-opacity="0" result="BackgroundImageFix"/> <feColorMatrix in="SourceAlpha" type="matrix" values="0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 127 0" result="hardAlpha"/> <feMorphology radius="2" operator="erode" in="SourceAlpha" result="effect1_dropShadow"/> <feOffset dy="2"/> <feGaussianBlur stdDeviation="2"/> <feComposite in2="hardAlpha" operator="out"/> <feColorMatrix type="matrix" values="0 0 0 0 0.0352941 0 0 0 0 0.0352941 0 0 0 0 0.0431373 0 0 0 0.06 0"/> <feBlend mode="normal" in2="BackgroundImageFix" result="effect1_dropShadow"/> <feColorMatrix in="SourceAlpha" type="matrix" values="0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 127 0" result="hardAlpha"/> <feMorphology radius="2" operator="erode" in="SourceAlpha" result="effect2_dropShadow"/> <feOffset dy="3"/> <feGaussianBlur stdDeviation="5"/> <feComposite in2="hardAlpha" operator="out"/> <feColorMatrix type="matrix" values="0 0 0 0 0.0352941 0 0 0 0 0.0352941 0 0 0 0 0.0431373 0 0 0 0.08 0"/> <feBlend mode="normal" in2="effect1_dropShadow" result="effect2_dropShadow"/> <feBlend mode="normal" in="SourceGraphic" in2="effect2_dropShadow" result="shape"/> </filter> <linearGradient id="paint0_linear" x1="24" y1="5" x2="24" y2="37" gradientUnits="userSpaceOnUse"> <stop stop-color="#9B8AFB"/> <stop offset="1" stop-color="#7A5AF8"/> </linearGradient> <clipPath id="clip0"> <rect width="20" height="20" fill="white" transform="translate(14 11)"/> </clipPath> </defs> </svg>''';

/// The multimodal retrieval guidance (datasets/common/multimodal-retrieval-guidance, variant `pipeline`): TipCard
/// (`relative flex gap-3 overflow-hidden rounded-xl border border-divider-regular bg-linear-to-b
/// from-components-chat-input-audio-bg-alt to-components-chat-input-audio-bg py-3 pr-0.75 pl-3 shadow-xs`) with the
/// picture frame, title, description ("Vision" in semibold) and a dismiss button.
class KbTipCard extends StatelessWidget {
  const KbTipCard({super.key, required this.title, required this.description, required this.onDismiss});
  final String title, description;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final body = difyStyle(DifyType.bodyMdRegular, DifyColors.textSecondary);
    final parts = description.split('Vision');
    final dismiss = kbT('dataset-settings', 'form.multimodalRetrievalGuidance.dismiss');
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 3, 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: DifyColors.dividerRegular),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [DifyColors.componentsChatInputAudioBgAlt, DifyColors.componentsChatInputAudioBg],
        ),
        boxShadow: DifyShadows.xs,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox.square(
            dimension: 36,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(left: -6, top: -6, child: SvgPicture.string(_frameSvg, width: 48, height: 48)),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 6,
              children: [
                DifyTextLine(
                  title,
                  style: difyStyle(
                    DifyType.bodyMdRegular,
                    DifyColors.textPrimary,
                  ).copyWith(fontSize: 15, height: 1.2, fontWeight: FontWeight.w600),
                ),
                DifyTextLine.rich(
                  TextSpan(
                    style: body,
                    children: parts.length < 2
                        ? [TextSpan(text: description)]
                        : [
                            TextSpan(text: parts.first),
                            TextSpan(
                              text: 'Vision',
                              style: difyTextStyle(DifyTw.fontSemibold, DifyColors.textPrimary),
                            ),
                            TextSpan(text: parts.sublist(1).join('Vision')),
                          ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 4),
          Transform.translate(
            offset: const Offset(0, -6),
            child: DifyIconButton(
              label: dismiss,
              onPressed: onDismiss,
              icon: const RemixIcon('close-line', size: 16),
            ),
          ),
        ],
      ),
    );
  }
}

/// assets/picture-frame.svg (flutter_svg draws it without its drop-shadow filters).
const _frameSvg = _pictureFrame;

/// MultimodalRetrievalGuidanceLearnMore / the Retrieval Setting subtitle: `flex items-center body-xs-regular
/// text-text-tertiary` with the accent "Learn more" link and the trailing text.
class KbLearnMore extends StatelessWidget {
  const KbLearnMore({super.key, required this.link, required this.text, required this.onOpen});
  final String link, text;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Flexible(
        child: Semantics(
          link: true,
          label: link,
          excludeSemantics: true,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: onOpen,
              child: DifyText(link, DifyType.bodyXsRegular, color: DifyColors.textAccent),
            ),
          ),
        ),
      ),
      Flexible(child: DifyText(' $text', DifyType.bodyXsRegular, color: DifyColors.textTertiary)),
    ],
  );
}

// ---- Textarea ----------------------------------------------------------------------------------------------------

/// dify-ui's Textarea ([DifyTextarea]) committed on blur with the document version its draft began on.
class KbTextarea extends StatefulWidget {
  const KbTextarea({
    super.key,
    required this.value,
    required this.onCommit,
    required this.currentVersion,
    this.placeholder,
    this.semanticLabel,
    this.disabled = false,
  });

  final String value;
  final void Function(String text, int base) onCommit;
  final int Function() currentVersion;
  final String? placeholder, semanticLabel;
  final bool disabled;

  @override
  State<KbTextarea> createState() => _KbTextareaState();
}

class _KbTextareaState extends State<KbTextarea> {
  /// The version the draft began on (its first keystroke), and the draft; the draft is kept after the commit until
  /// the document's value changes, so the text does not flash back.
  int? _base;
  String? _draft;

  void _commit() {
    final base = _base, text = _draft;
    _base = null;
    if (base == null || text == null) return;
    if (text == widget.value) {
      _draft = null;
    } else {
      widget.onCommit(text, base);
    }
  }

  @override
  void didUpdateWidget(KbTextarea old) {
    super.didUpdateWidget(old);
    if (_base == null && widget.value != old.value) _draft = null;
  }

  @override
  void dispose() {
    _commit();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    return DifyTextarea(
      value: _draft ?? w.value,
      placeholder: w.placeholder,
      semanticLabel: w.semanticLabel,
      disabled: w.disabled,
      onChanged: (text) {
        _base ??= w.currentVersion();
        _draft = text;
      },
      onFocusChange: (focused) {
        if (!focused) _commit();
      },
    );
  }
}

// ---- ModelSelector -----------------------------------------------------------------------------------------------

/// ModelSelector (model-provider-page/model-selector, size medium, standalone): the trigger (`h-8 rounded-lg p-1
/// gap-0.5`, the model's icon and name with its status badge, a chevron) opening the model list below it (a
/// search box, the providers' models grouped under their labels, the selected one checked). Only active models
/// can be picked.
class KbModelSelector extends StatefulWidget {
  const KbModelSelector({
    super.key,
    required this.value,
    required this.models,
    required this.catalog,
    this.onValueChange,
    this.disabled = false,
    this.showDeprecatedWarnIcon = true,
  });

  final DefaultModel? value;
  final List<ProviderWithModels> models;
  final ModelCatalog catalog;
  final ValueChanged<DefaultModel>? onValueChange;
  final bool disabled, showDeprecatedWarnIcon;

  @override
  State<KbModelSelector> createState() => _KbModelSelectorState();
}

class _KbModelSelectorState extends State<KbModelSelector> {
  final _floating = DifyFloatingController();
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final w = widget;
    return LayoutBuilder(
      builder: (context, c) => DifyPopover(
        controller: _floating,
        placement: DifyPlacement.bottomStart,
        sideOffset: 4,
        semanticLabel: ModelSelectorTrigger.configureModel,
        onOpenChange: (open) {
          if (!open) setState(() => _query = '');
        },
        builder: (context, controller) => DifyPressable(
          semanticLabel: ModelSelectorTrigger.configureModel,
          disabled: w.disabled,
          onPressed: w.disabled ? null : controller.toggle,
          builder: (context, hovered, focused) => _trigger(hovered || controller.isOpen),
        ),
        content: SizedBox(
          width: c.maxWidth.isFinite ? c.maxWidth.clamp(0, 448) : 320,
          child: _popup(),
        ),
      ),
    );
  }

  Widget _trigger(bool hovered) {
    final w = widget;
    final (:currentProvider, :currentModel) = getCurrentProviderAndModel(w.models, w.value);
    final selected = currentProvider != null && currentModel != null;
    final deprecated = !selected && w.value != null;
    final empty = !selected && w.value == null;
    final providerId = selected ? currentProvider.provider : w.value?.provider;
    final resolved = w.catalog.provider(providerId);
    final status = deriveModelStatus(
      selected ? currentModel.model : w.value?.model,
      providerId,
      resolved,
      currentModel,
      w.catalog.credentialPanelState(resolved),
    );
    final active = status == DerivedModelStatus.active;
    final badge = status.badge ?? DerivedModelStatus.incompatibleLabel;
    final Color bg = switch (status) {
      DerivedModelStatus.active || DerivedModelStatus.empty =>
        hovered && !w.disabled ? DifyColors.stateBaseHoverAlt : DifyColors.componentsInputBgNormal,
      _ => DifyColors.componentsInputBgDisabled,
    };
    final Widget icon = empty
        ? SizedBox.square(
            dimension: 24,
            child: Center(
              child: Container(
                width: 20,
                height: 20,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: DifyColors.backgroundDefaultSubtle,
                  borderRadius: BorderRadius.circular(DifyRadius.md),
                  border: Border.all(color: DifyColors.componentsPanelBorderSubtle, width: Css.hairline),
                ),
                child: RemixIcon('brain-2-line', size: 14, color: DifyColors.textQuaternary),
              ),
            ),
          )
        : Padding(
            padding: const EdgeInsets.all(2),
            child: ModelIcon(
              provider: selected ? currentProvider.provider : resolved?.provider,
              iconSmall: selected ? currentProvider.iconSmall : resolved?.iconSmall,
              iconSmallDark: selected ? currentProvider.iconSmallDark : resolved?.iconSmallDark,
              modelName: selected ? currentModel.model : w.value?.model,
              language: w.catalog.language,
            ),
          );
    final Widget name = selected
        ? ModelName(
            modelItem: currentModel,
            language: w.catalog.language,
            lineThrough: currentModel.deprecated,
            showMode: active,
            showFeatures: active,
          )
        : deprecated
        ? ModelText(w.value!.model, lineThrough: true)
        : DifyTextLine(
            ModelSelectorTrigger.configureModel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: difyStyle(
              DifyType.systemSmRegular,
              DifyColors.componentsInputTextPlaceholder,
            ).copyWith(fontSize: 13),
          );
    final Widget? status_ = selected && !w.disabled && !active && status.badge != null
        ? ModelStatusBadge(badge, dimm: status == DerivedModelStatus.creditsExhausted)
        : deprecated && w.showDeprecatedWarnIcon
        ? ModelStatusBadge(badge, dimm: true)
        : null;
    return Container(
      height: 32,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(DifyRadius.lg)),
      child: Row(
        children: [
          icon,
          const SizedBox(width: 2),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: TruncatedRow(gap: 4, fillLead: true, lead: name, trail: status_),
            ),
          ),
          if (!w.disabled && (active || empty))
            RemixIcon(
              'arrow-down-s-line',
              size: 16,
              color: hovered ? DifyColors.textSecondary : DifyColors.textQuaternary,
            ),
        ],
      ),
    );
  }

  Widget _popup() {
    final w = widget;
    final q = _query.trim().toLowerCase();
    bool matches(ModelItem m) =>
        q.isEmpty ||
        m.model.toLowerCase().contains(q) ||
        renderI18nObject(m.label, w.catalog.language).toLowerCase().contains(q);
    final groups = [
      for (final p in w.models)
        if (p.models.where(matches).toList() case final models when models.isNotEmpty) (provider: p, models: models),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
          child: DifyInput(
            value: _query,
            onChanged: (v) => setState(() => _query = v),
            placeholder: DifyI18n.tr('common', 'modelProvider.searchModel'),
            leading: Padding(
              padding: EdgeInsets.only(left: 8, right: 4),
              child: RemixIcon('search-line', size: 16, color: DifyColors.componentsInputTextPlaceholder),
            ),
          ),
        ),
        Flexible(
          child: groups.isEmpty
              ? Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: DifyText(
                    DifyI18n.tr('common', 'modelProvider.selector.noModelFound', {'model': _query}),
                    DifyType.systemXsRegular,
                    color: DifyColors.textTertiary,
                    maxLines: null,
                  ),
                )
              : ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 540),
                  child: ListView(
                    shrinkWrap: true,
                    padding: const EdgeInsets.only(bottom: 4),
                    children: [
                      for (final g in groups) ...[
                        Container(
                          constraints: const BoxConstraints(minHeight: 22),
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          alignment: Alignment.centerLeft,
                          child: DifyTextLine(
                            renderI18nObject(g.provider.label, w.catalog.language),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: difyTextStyle(DifyType.systemXsMedium, DifyColors.textTertiary),
                          ),
                        ),
                        for (final m in g.models) _row(g.provider, m),
                        const SizedBox(height: 4),
                      ],
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  Widget _row(ProviderWithModels provider, ModelItem m) {
    final w = widget;
    final selectable = m.status == ModelStatusEnum.active;
    final selected = w.value?.model == m.model && w.value?.provider == provider.provider;
    return DifyPressable(
      disabled: !selectable,
      semanticLabel: renderI18nObject(m.label, w.catalog.language),
      onPressed: selectable
          ? () {
              _floating.close();
              setState(() => _query = '');
              w.onValueChange?.call((provider: provider.provider, model: m.model));
            }
          : null,
      builder: (context, hovered, focused) => Container(
        height: 32,
        margin: const EdgeInsets.symmetric(horizontal: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: hovered ? (selectable ? DifyColors.stateBaseHover : DifyColors.stateBaseHoverAlt) : null,
          borderRadius: BorderRadius.circular(DifyRadius.lg),
        ),
        child: Row(
          children: [
            ModelIcon(
              provider: provider.provider,
              iconSmall: provider.iconSmall,
              iconSmallDark: provider.iconSmallDark,
              modelName: m.model,
              language: w.catalog.language,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Opacity(
                opacity: selectable ? 1 : 0.6,
                child: ModelName(modelItem: m, language: w.catalog.language, lineThrough: m.deprecated),
              ),
            ),
            if (selected) DifyIcon('vender/line/general/check', size: 16, color: DifyColors.textAccent),
          ],
        ),
      ),
    );
  }
}
