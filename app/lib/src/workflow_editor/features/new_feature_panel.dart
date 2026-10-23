/// The features drawer (base/features/new-feature-panel: index.tsx, feature-panel-drawer.tsx, feature-card.tsx):
/// the header and the cards of the features the app mode offers in a workflow editor.
library;

import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../design/css_metrics.dart';
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';
import '../../workflow/model_catalog.dart' show ModelTypeEnum;
import '../node_panel/bodies/llm/group_host.dart';
import 'conversation_opener.dart';
import 'features_services.dart';
import 'features_store.dart';
import 'file_upload.dart';
import 'follow_up.dart';
import 'moderation.dart';
import 'simple_features.dart';
import 'text_to_speech.dart';

/// NewFeaturePanel as the workflow editor uses it (`inWorkflow`): a chatflow offers the conversation opener,
/// follow-up, text to speech and speech to text (with a default model of their type), file upload, citations and
/// content moderation; a workflow offers the (legacy) image upload. [onChange] runs after each change of the store.
class NewFeaturePanel extends StatelessWidget {
  const NewFeaturePanel({
    super.key,
    required this.show,
    required this.isChatMode,
    required this.disabled,
    required this.onClose,
    this.onChange,
    this.showFileUpload = true,
    this.showModeration = true,
    this.promptVariables = const [],
    this.workflowVariables = const [],
    this.onAutoAddPromptVariable,
    this.title,
    this.description,
    this.top = 112,
  });

  final bool show, isChatMode, disabled, showFileUpload, showModeration;
  final VoidCallback onClose;
  final OnFeaturesChange? onChange;
  final List<Json> promptVariables, workflowVariables;
  final void Function(List<Json> variables)? onAutoAddPromptVariable;
  final String? title, description;

  /// Where the drawer starts below the top of the editor (Dify's `top-28`, 112 px: under the header).
  final double top;

  @override
  Widget build(BuildContext context) {
    final defaults = LlmGroupScope.of(context).defaultModels;
    final tts = defaults[ModelTypeEnum.tts] != null, stt = defaults[ModelTypeEnum.speech2text] != null;
    return FeaturePanelDrawer(
      show: show,
      onClose: onClose,
      top: top,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      DifyText(
                        title ?? DifyI18n.tr('workflow', 'common.features'),
                        DifyType.systemXlSemibold,
                        maxLines: null,
                      ),
                      DifyText(
                        description ?? DifyI18n.tr('workflow', 'common.featuresDescription'),
                        DifyType.bodyXsRegular,
                        color: DifyColors.textTertiary,
                        maxLines: null,
                      ),
                    ],
                  ),
                ),
                DifyIconButton(
                  label: tc('operation.close'),
                  size: DifyIconButtonSize.lg,
                  icon: const RemixIcon('close-line', size: 16),
                  onPressed: onClose,
                ),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (isChatMode) ...[
                    ConversationOpener(
                      disabled: disabled,
                      onChange: onChange,
                      promptVariables: promptVariables,
                      workflowVariables: workflowVariables,
                      onAutoAddPromptVariable: onAutoAddPromptVariable,
                    ),
                    FollowUp(disabled: disabled, onChange: onChange),
                    if (tts) TextToSpeech(disabled: disabled, onChange: onChange),
                    if (stt) SpeechToText(disabled: disabled, onChange: onChange),
                    if (showFileUpload) FileUpload(disabled: disabled, onChange: onChange),
                    Citation(disabled: disabled, onChange: onChange),
                    if (showModeration) Moderation(disabled: disabled, onChange: onChange),
                  ] else if (showFileUpload)
                    ImageUpload(disabled: disabled, onChange: onChange),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// FeaturePanelDrawer: dify-ui's Drawer from the right, modal: a `bg-black/25` backdrop over the editor (a click on
/// it closes), the popup [top] below the top, 8 px above the bottom, 420 px wide (at most the width less 2 rem),
/// `rounded-l-2xl border-[0.5px] bg-components-panel-bg-alt shadow-xl`, sliding in over 200 ms. Escape closes it, and
/// so does swiping it to the right (touch). Nothing is drawn while not [show]n.
class FeaturePanelDrawer extends StatefulWidget {
  const FeaturePanelDrawer({super.key, required this.show, required this.child, this.onClose, this.top = 112});

  final bool show;
  final Widget child;
  final VoidCallback? onClose;
  final double top;

  @override
  State<FeaturePanelDrawer> createState() => _FeaturePanelDrawerState();
}

class _FeaturePanelDrawerState extends State<FeaturePanelDrawer> with SingleTickerProviderStateMixin {
  late final _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 200));

  /// How far the popup has been swiped to the right.
  double _swipe = 0;

  @override
  void initState() {
    super.initState();
    if (widget.show) _anim.forward();
  }

  @override
  void didUpdateWidget(FeaturePanelDrawer old) {
    super.didUpdateWidget(old);
    if (widget.show && !old.show) {
      _swipe = 0;
      _anim.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  void _close() => widget.onClose?.call();

  @override
  Widget build(BuildContext context) {
    if (!widget.show) return const SizedBox.shrink();
    final curve = CurvedAnimation(parent: _anim, curve: Curves.ease);
    return LayoutBuilder(
      builder: (context, c) {
        final width = math.min(420.0, c.maxWidth - 32);
        return Stack(
          fit: StackFit.expand,
          children: [
            FadeTransition(
              opacity: curve,
              child: DifyDrawerBackdrop(
                color: difyDrawerBlackBackdrop,
                opacity: 1 - (_swipe / width).clamp(0.0, 1.0),
                onTap: _close,
              ),
            ),
            Positioned(
              top: widget.top,
              bottom: 8,
              // The right border sits outside the window (`border-r-0`).
              right: -Css.hairline,
              width: width + Css.hairline,
              child: AnimatedBuilder(
                animation: curve,
                builder: (context, child) =>
                    Transform.translate(offset: Offset((1 - curve.value) * (width + 2) + _swipe, 0), child: child),
                child: _popup(width),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _popup(double width) => RawGestureDetector(
    gestures: {
      HorizontalDragGestureRecognizer: GestureRecognizerFactoryWithHandlers<HorizontalDragGestureRecognizer>(
        () => HorizontalDragGestureRecognizer(supportedDevices: {PointerDeviceKind.touch, PointerDeviceKind.stylus}),
        (r) => r
          ..onUpdate = (d) {
            setState(() => _swipe = math.max(0, _swipe + d.delta.dx));
          }
          ..onEnd = (d) {
            if (_swipe > width / 2 || d.velocity.pixelsPerSecond.dx > 500) {
              _close();
            } else {
              setState(() => _swipe = 0);
            }
          },
      ),
    },
    child: CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): _close},
      child: FocusScope(
        autofocus: true,
        child: DifyDrawerPopup(
          color: DifyColors.componentsPanelBgAlt,
          material: true,
          child: widget.child,
        ),
      ),
    ),
  );
}

/// FeatureCard: `mb-1 rounded-xl border-t-[0.5px] border-l-[0.5px] border-effects-highlight
/// bg-background-section-burn p-3` with the [icon], the [title] (and its [tooltip]), the switch, the [description]
/// (two lines at most) and [child]. [onMouseEnter] / [onMouseLeave] report hovering; a touch on the card counts as
/// entering it and a touch elsewhere as leaving (as browsers emulate hover on touch screens).
class FeatureCard extends StatelessWidget {
  const FeatureCard({
    super.key,
    required this.icon,
    required this.title,
    required this.value,
    this.tooltip,
    this.description,
    this.child,
    this.disabled = false,
    this.onChange,
    this.onMouseEnter,
    this.onMouseLeave,
  });

  final Widget icon;

  /// A string or a widget.
  final Object title;
  final String? tooltip;
  final bool value;
  final String? description;
  final Widget? child;
  final bool disabled;
  final ValueChanged<bool>? onChange;
  final VoidCallback? onMouseEnter, onMouseLeave;

  @override
  Widget build(BuildContext context) {
    final t = title;
    final titleText = t is String ? t : '';
    Widget card = Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: EdgeInsets.only(top: Css.hairline, left: Css.hairline),
      decoration: BoxDecoration(
        color: DifyColors.effectsHighlight,
        borderRadius: BorderRadius.circular(DifyRadius.xl),
      ),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: DifyColors.backgroundSectionBurn,
          borderRadius: BorderRadius.circular(DifyRadius.xl),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                spacing: 8,
                children: [
                  icon,
                  Expanded(
                    child: Row(
                      children: [
                        if (t is String)
                          Flexible(child: DifyText(t, DifyType.systemSmSemibold, color: DifyColors.textSecondary))
                        else if (t is Widget)
                          Flexible(child: t),
                        if (tooltip != null)
                          Padding(
                            padding: const EdgeInsets.only(left: 2),
                            child: DifyInfotip(label: tooltip!, content: DifyTextLine(tooltip!)),
                          ),
                      ],
                    ),
                  ),
                  DifySwitch(
                    checked: value,
                    disabled: disabled,
                    semanticLabel: titleText,
                    onCheckedChange: (v) => onChange?.call(v),
                  ),
                ],
              ),
            ),
            if (description != null && description!.isNotEmpty) FeatureDescription(description!),
            ?child,
          ],
        ),
      ),
    );
    if (onMouseEnter == null && onMouseLeave == null) return card;
    return TapRegion(
      onTapOutside: (e) {
        if (e.kind != PointerDeviceKind.mouse) onMouseLeave?.call();
      },
      child: Listener(
        onPointerDown: (e) {
          if (e.kind != PointerDeviceKind.mouse) onMouseEnter?.call();
        },
        child: MouseRegion(onEnter: (_) => onMouseEnter?.call(), onExit: (_) => onMouseLeave?.call(), child: card),
      ),
    );
  }
}

/// A card's text under the title: `line-clamp-2 min-h-8 system-xs-regular text-text-tertiary`.
class FeatureDescription extends StatelessWidget {
  const FeatureDescription(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(minHeight: 32),
    child: DifyText(text, DifyType.systemXsRegular, color: DifyColors.textTertiary, maxLines: 2),
  );
}

/// A card's icon: `shrink-0 rounded-lg border-[0.5px] border-divider-subtle p-1 shadow-xs` on [color], the 16 px
/// glyph in `text-text-primary-on-surface`.
class FeatureIcon extends StatelessWidget {
  const FeatureIcon({super.key, required this.color, this.dify, this.remix});
  final Color color;

  /// A Dify icon (`vender/features/...`) or a Remix one.
  final String? dify, remix;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(4),
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(DifyRadius.lg),
      border: Border.all(color: DifyColors.dividerSubtle, width: Css.hairline),
      boxShadow: DifyShadows.xs,
    ),
    child: dify != null
        ? DifyIcon(dify!, size: 16, color: DifyColors.textPrimaryOnSurface)
        : RemixIcon(remix!, size: 16, color: DifyColors.textPrimaryOnSurface),
  );
}

/// The settings summary of an enabled card (`flex items-center gap-4 pt-0.5`): label / value pairs split by a
/// slanted `h-6.75 w-px rotate-12 bg-divider-subtle` line.
class FeatureInfo extends StatelessWidget {
  const FeatureInfo(this.items, {super.key});
  final List<(String label, String value)> items;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 2),
    child: Row(
      spacing: 16,
      children: [
        for (final (i, (label, value)) in items.indexed) ...[
          if (i > 0)
            Transform.rotate(
              angle: 12 * math.pi / 180,
              child: Container(width: 1, height: 27, color: DifyColors.dividerSubtle),
            ),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: DifyText(label, DifyType.system2xsMediumUppercase, color: DifyColors.textTertiary),
                ),
                DifyText(value, DifyType.systemXsRegular, color: DifyColors.textSecondary),
              ],
            ),
          ),
        ],
      ],
    ),
  );
}

/// The full-width button an enabled card shows while hovered (`Button className="w-full"` with a 16 px icon).
class FeatureCardButton extends StatelessWidget {
  const FeatureCardButton({super.key, required this.icon, required this.label, this.onPressed, this.disabled = false});
  final String icon, label;
  final VoidCallback? onPressed;
  final bool disabled;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: double.infinity,
    child: DifyButton(
      onPressed: onPressed,
      disabled: disabled,
      leading: RemixIcon(icon, size: 16),
      child: DifyTextLine(label),
    ),
  );
}

/// A card's hover state (`const [isHovering, setIsHovering] = useState(false)`).
mixin FeatureHover<T extends StatefulWidget> on State<T> {
  bool isHovering = false;
  void setHovering(bool v) {
    if (isHovering != v) setState(() => isHovering = v);
  }
}

/// A dialog's or popover's buttons at the end of a row (`flex justify-end gap-2`); long labels shrink rather than
/// overflow.
class FeatureFooter extends StatelessWidget {
  const FeatureFooter(this.buttons, {super.key});
  final List<Widget> buttons;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisAlignment: MainAxisAlignment.end,
    spacing: 8,
    children: [for (final b in buttons) Flexible(child: b)],
  );
}
