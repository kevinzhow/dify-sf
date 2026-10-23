// dify-spec: web/app/components/base/features/new-feature-panel/text-to-speech/__tests__/voice-settings.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/features/features.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../harness.dart';

final features = {
  ...specDefaultFeatures,
  'text2speech': {'enabled': true, 'language': 'en-US', 'voice': 'alloy'},
};

final opened = <bool>[];

Future<void> renderSettings(WidgetTester t, {required bool open, bool disabled = false}) async {
  opened.clear();
  await render(
    t,
    VoiceSettings(
      open: open,
      disabled: disabled,
      onOpen: opened.add,
      child: const Text('Settings'),
    ),
    features: features,
    services: FeaturesServices(voices: (_) async => [(name: 'alloy', value: 'alloy')]),
  );
  await settle(t);
}

void main() {
  setUp(useDifyTestTranslator);

  group('VoiceSettings', () {
    testWidgets('should render children in trigger', (t) async {
      await renderSettings(t, open: false);
      expect(find.text('Settings'), findsOneWidget);
    });

    testWidgets('should render ParamConfigContent in portal', (t) async {
      await renderSettings(t, open: true);
      expect(byText(r'voice\.voiceSettings\.title'), findsOneWidget);
    });

    testWidgets('should call onOpen with toggle function when trigger is clicked', (t) async {
      await renderSettings(t, open: false);
      await tap(t, find.text('Settings'));
      expect(opened, [true]);
    });

    testWidgets('should not call onOpen when disabled and trigger is clicked', (t) async {
      await renderSettings(t, open: false, disabled: true);
      await tap(t, find.text('Settings'));
      expect(opened, isEmpty);
    });

    testWidgets('should call onOpen with false when close is clicked', (t) async {
      await renderSettings(t, open: true);
      await tap(t, button('common.operation.close'));
      expect(opened, [false]);
    });
  });
}
