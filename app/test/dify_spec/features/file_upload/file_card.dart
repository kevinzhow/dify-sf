import 'package:dify_sf_app/src/workflow_editor/features/features.dart';

import 'package:flutter_test/flutter_test.dart';

import '../harness.dart';

/// Renders FileUpload (or ImageUpload) with the specs' features and [file].
Future<void> renderFile(
  WidgetTester t, {
  required bool image,
  bool disabled = false,
  OnFeaturesChange? onChange,
  Json? file,
}) => render(
  t,
  image ? ImageUpload(disabled: disabled, onChange: onChange) : FileUpload(disabled: disabled, onChange: onChange),
  features: {...specDefaultFeatures, 'file': ?file},
);

/// Hovers the card titled [title] and clicks "Settings".
Future<void> openSettings(WidgetTester t, String title) async {
  await hover(t, card(title));
  await tap(t, byText(r'operation\.settings'));
}
