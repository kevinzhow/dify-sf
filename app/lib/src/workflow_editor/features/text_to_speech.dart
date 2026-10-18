/// Text to speech (text-to-speech/index.tsx, voice-settings.tsx, param-config-content.tsx).
library;

import 'package:flutter/material.dart';

import '../../cards/card_kit.dart';
import '../../design/css_metrics.dart';
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../panel_fields/controls.dart' show DifySwitch, Infotip;
import '../panel_fields/selectors.dart' show DifySelect;
import 'features_services.dart';
import 'features_store.dart';
import 'new_feature_panel.dart';
import 'simple_features.dart' show toggleFeature;

/// TextToSpeech: the switch, the language / voice / autoplay summary and, while hovered or while its popover is
/// open, the "Voice Settings" button opening [VoiceSettings].
class TextToSpeech extends StatefulWidget {
  const TextToSpeech({super.key, this.disabled = false, this.onChange});
  final bool disabled;
  final OnFeaturesChange? onChange;

  @override
  State<TextToSpeech> createState() => _TextToSpeechState();
}

class _TextToSpeechState extends State<TextToSpeech> with FeatureHover {
  bool _modalOpen = false;

  @override
  Widget build(BuildContext context) => FeaturesBuilder(
    builder: (context, features) {
      final tts = featureMap(features, FeatureEnum.text2speech);
      final enabled = tts['enabled'] == true;
      final languages = FeaturesServicesScope.of(context).languages;
      final language = languages.where((l) => l.value == tts['language']).firstOrNull;
      final voice = tts['voice'];
      return FeatureCard(
        icon: const FeatureIcon(color: DifyColors.utilColorsVioletViolet600, dify: 'vender/features/text-to-audio'),
        title: ad('feature.textToSpeech.title'),
        value: enabled,
        disabled: widget.disabled,
        onChange: (v) => toggleFeature(context, FeatureEnum.text2speech, v, widget.onChange),
        onMouseEnter: () => setHovering(true),
        onMouseLeave: () => setHovering(false),
        child: !enabled
            ? FeatureDescription(ad('feature.textToSpeech.description'))
            : (isHovering || _modalOpen)
            ? VoiceSettings(
                open: _modalOpen && !widget.disabled,
                onOpen: (v) => setState(() => _modalOpen = v),
                onChange: widget.onChange,
                child: FeatureCardButton(
                  icon: 'equalizer-2-line',
                  label: ad('voice.voiceSettings.title'),
                  disabled: widget.disabled,
                ),
              )
            : FeatureInfo([
                (ad('voice.voiceSettings.language'), language?.name ?? '-'),
                (
                  ad('voice.voiceSettings.voice'),
                  voice is String && voice.isNotEmpty ? voice : ad('voice.defaultDisplay'),
                ),
                (
                  ad('voice.voiceSettings.autoPlay'),
                  tts['autoPlay'] == TtsAutoPlay.enabled
                      ? ad('voice.voiceSettings.autoPlayEnabled')
                      : ad('voice.voiceSettings.autoPlayDisabled'),
                ),
              ]),
      );
    },
  );
}

/// VoiceSettings: a popover 32 px to the left of [child] (its trigger: a click asks [onOpen] to toggle, unless
/// [disabled]) holding [ParamConfigContent] in a `w-90 rounded-2xl p-4 shadow-2xl` panel.
class VoiceSettings extends StatelessWidget {
  const VoiceSettings({
    super.key,
    required this.open,
    required this.onOpen,
    required this.child,
    this.onChange,
    this.disabled = false,
    this.placementLeft = true,
  });

  final bool open, disabled, placementLeft;
  final ValueChanged<bool> onOpen;
  final OnFeaturesChange? onChange;
  final Widget child;

  @override
  Widget build(BuildContext context) => FeaturePopover(
    open: open,
    onOpenChange: (v) {
      if (!disabled) onOpen(v);
    },
    placement: placementLeft ? DifyPlacement.left : DifyPlacement.top,
    sideOffset: placementLeft ? 32 : 4,
    trigger: child,
    content: ParamConfigContent(onClose: () => onOpen(false), onChange: onChange),
  );
}

/// The settings popover of a feature card (Popover with a `<div className="flex">` trigger around [trigger], whose
/// clicks toggle it): a `w-90 rounded-2xl border-[0.5px] border-components-panel-border bg-components-panel-bg p-4
/// shadow-2xl` panel ([maxHeight]: `max-h-[calc(100vh-20px)] overflow-y-auto`).
class FeaturePopover extends StatelessWidget {
  const FeaturePopover({
    super.key,
    required this.open,
    required this.onOpenChange,
    required this.trigger,
    required this.content,
    this.placement = DifyPlacement.left,
    this.sideOffset = 32,
    this.scrollable = false,
  });

  final bool open;
  final ValueChanged<bool> onOpenChange;
  final Widget trigger, content;
  final DifyPlacement placement;
  final double sideOffset;
  final bool scrollable;

  @override
  Widget build(BuildContext context) => DifyFloating(
    open: open,
    onOpenChange: onOpenChange,
    placement: placement,
    sideOffset: sideOffset,
    constrainHeight: scrollable,
    // `<div className="flex">`: the trigger keeps the card's full width.
    builder: (context, c) => SizedBox(
      width: double.infinity,
      child: GestureDetector(behavior: HitTestBehavior.translucent, onTap: c.toggle, child: trigger),
    ),
    popupBuilder: (context) {
      final maxHeight = MediaQuery.sizeOf(context).height - 20;
      return Container(
        width: 360,
        constraints: scrollable ? BoxConstraints(maxHeight: maxHeight) : null,
        decoration: BoxDecoration(
          color: DifyColors.componentsPanelBg,
          border: Border.all(color: DifyColors.componentsPanelBorder, width: Css.hairline),
          borderRadius: BorderRadius.circular(DifyRadius.xxl),
          boxShadow: DifyShadows.n2xl,
        ),
        child: Material(
          type: MaterialType.transparency,
          child: scrollable
              ? SingleChildScrollView(padding: const EdgeInsets.all(16), child: content)
              : Padding(padding: const EdgeInsets.all(16), child: content),
        ),
      );
    },
  );
}

/// A popover's title row (`mb-4 flex items-center justify-between`, `system-xl-semibold`) with its close icon.
class FeaturePopoverHeader extends StatelessWidget {
  const FeaturePopoverHeader({super.key, required this.title, required this.onClose});
  final String title;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Row(
      children: [
        Expanded(child: DifyText(title, DifyType.systemXlSemibold)),
        DifyPressable(
          onPressed: onClose,
          semanticLabel: tc('operation.close'),
          builder: (context, hovered, focused) => Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: hovered || focused ? DifyColors.stateBaseHover : null,
              borderRadius: BorderRadius.circular(DifyRadius.md),
            ),
            child: const RemixIcon('close-line', size: 16, color: DifyColors.textTertiary),
          ),
        ),
      ],
    ),
  );
}

/// ParamConfigContent (VoiceParamConfig): the language (Dify's languages; the first when none is set), the voice
/// (the app's voices for that language; the first when the set one is not among them), the audition button and
/// autoplay. Each change goes to the store, then [onChange].
class ParamConfigContent extends StatefulWidget {
  const ParamConfigContent({super.key, required this.onClose, this.onChange});
  final VoidCallback onClose;
  final OnFeaturesChange? onChange;

  @override
  State<ParamConfigContent> createState() => _ParamConfigContentState();
}

class _ParamConfigContentState extends State<ParamConfigContent> {
  String? _voicesFor;
  List<({String value, String name})>? _voices;

  void _loadVoices(FeaturesServices services, String language) {
    if (_voicesFor == language) return;
    _voicesFor = language;
    final load = services.voices;
    if (load == null) return;
    load(language).then((v) {
      if (mounted && _voicesFor == language) setState(() => _voices = v);
    });
  }

  void _change(Map<String, Object?> value) {
    final store = FeaturesScope.of(context);
    final f = store.features.value;
    store.setFeatures(withFeature(f, FeatureEnum.text2speech, value));
    widget.onChange?.call();
  }

  String _languageName(DifyLanguage l) {
    final key = 'voice.language.${l.value.replaceFirst('-', '')}';
    final t = tc(key);
    return t == key ? l.name : t;
  }

  @override
  Widget build(BuildContext context) {
    final services = FeaturesServicesScope.of(context);
    return FeaturesBuilder(
      builder: (context, features) {
        final tts = featureMap(features, FeatureEnum.text2speech);
        final languages = services.languages;
        final languageItem = languages.where((l) => l.value == tts['language']).firstOrNull ?? languages.firstOrNull;
        _loadVoices(services, languageItem?.value ?? 'en-US');
        final voices = _voices;
        final voiceItem = voices == null
            ? null
            : (voices.where((v) => v.value == tts['voice']).firstOrNull ?? voices.firstOrNull);
        final placeholder = tc('placeholder.select');
        final label = DifyType.systemSmSemibold;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            FeaturePopoverHeader(title: ad('voice.voiceSettings.title'), onClose: widget.onClose),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Flexible(child: DifyText(ad('voice.voiceSettings.language'), label, color: DifyColors.textSecondary)),
                  Infotip(
                    label: ad('voice.voiceSettings.resolutionTooltip'),
                    width: 180,
                    content: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [for (final l in ad('voice.voiceSettings.resolutionTooltip').split('\n')) Text(l)],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            DifySelect<String>(
              value: languageItem?.value,
              placeholder: placeholder,
              semanticLabel: ad('voice.voiceSettings.language'),
              options: [for (final l in languages) (value: l.value, label: _languageName(l))],
              onChanged: (v) => _change({'language': v}),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 8),
              child: DifyText(ad('voice.voiceSettings.voice'), label, color: DifyColors.textSecondary),
            ),
            Row(
              spacing: 4,
              children: [
                Expanded(
                  child: DifySelect<String>(
                    value: voiceItem?.value,
                    placeholder: voiceItem?.name ?? placeholder,
                    semanticLabel: ad('voice.voiceSettings.voice'),
                    disabled: languageItem == null,
                    options: [
                      for (final v in voices ?? const <({String value, String name})>[])
                        (value: v.value, label: v.name),
                    ],
                    onChanged: (v) {
                      if (v.isNotEmpty) _change({'voice': v});
                    },
                  ),
                ),
                if (languageItem != null && languageItem.example.isNotEmpty && services.playAudition != null)
                  Semantics(
                    container: true,
                    label: 'Play',
                    child: Container(
                      height: 32,
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: DifyColors.componentsButtonTertiaryBg,
                        borderRadius: BorderRadius.circular(DifyRadius.lg),
                      ),
                      child: DifyIconButton(
                        label: 'Play',
                        icon: const RemixIcon('volume-up-line', size: 16),
                        onPressed: () => services.playAudition!(languageItem.example, tts['voice'] as String?),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 8),
              child: DifyText(ad('voice.voiceSettings.autoPlay'), label, color: DifyColors.textSecondary),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: DifySwitch(
                checked: tts['autoPlay'] == TtsAutoPlay.enabled,
                semanticLabel: ad('voice.voiceSettings.autoPlay'),
                onCheckedChange: (v) => _change({'autoPlay': v ? TtsAutoPlay.enabled : TtsAutoPlay.disabled}),
              ),
            ),
          ],
        );
      },
    );
  }
}
