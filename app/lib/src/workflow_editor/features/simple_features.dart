/// The features that are only a switch: citation.tsx and speech-to-text.tsx.
library;

import 'package:flutter/widgets.dart';

import '../../design/dify_tokens.g.dart';
import 'features_services.dart';
import 'features_store.dart';
import 'new_feature_panel.dart';

/// `handleChange(type, enabled)` of the feature cards: `{...features[type], enabled}`, then [onChange].
void toggleFeature(BuildContext context, String type, bool enabled, OnFeaturesChange? onChange, {bool pass = false}) {
  final store = FeaturesScope.of(context);
  final next = withFeature(store.features.value, type, {'enabled': enabled});
  store.setFeatures(next);
  pass ? onChange?.call(next) : onChange?.call();
}

/// A card with a description that only switches [type] on and off.
class _SwitchFeature extends StatelessWidget {
  const _SwitchFeature({
    required this.type,
    required this.icon,
    required this.title,
    required this.description,
    required this.disabled,
    this.onChange,
    this.pass = false,
  });
  final String type, title, description;
  final Widget icon;
  final bool disabled, pass;
  final OnFeaturesChange? onChange;

  @override
  Widget build(BuildContext context) => FeaturesBuilder(
    builder: (context, features) => FeatureCard(
      icon: icon,
      title: title,
      value: featureEnabled(features, type),
      description: description,
      disabled: disabled,
      onChange: (v) => toggleFeature(context, type, v, onChange, pass: pass),
    ),
  );
}

/// Citation (citation.tsx): "Citations and Attributions".
class Citation extends StatelessWidget {
  const Citation({super.key, this.disabled = false, this.onChange});
  final bool disabled;
  final OnFeaturesChange? onChange;

  @override
  Widget build(BuildContext context) => _SwitchFeature(
    type: FeatureEnum.citation,
    icon: FeatureIcon(color: DifyColors.utilColorsWarningWarning500, dify: 'vender/features/citations'),
    title: ad('feature.citation.title'),
    description: ad('feature.citation.description'),
    disabled: disabled,
    onChange: onChange,
    pass: true,
  );
}

/// SpeechToText (speech-to-text.tsx).
class SpeechToText extends StatelessWidget {
  const SpeechToText({super.key, this.disabled = false, this.onChange});
  final bool disabled;
  final OnFeaturesChange? onChange;

  @override
  Widget build(BuildContext context) => _SwitchFeature(
    type: FeatureEnum.speech2text,
    icon: FeatureIcon(color: DifyColors.utilColorsVioletViolet600, dify: 'vender/features/microphone-01'),
    title: ad('feature.speechToText.title'),
    description: ad('feature.speechToText.description'),
    disabled: disabled,
    onChange: onChange,
  );
}
