// dify-spec: web/app/components/base/features/new-feature-panel/text-to-speech/__tests__/index.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/features/features.dart';
import 'package:flutter_test/flutter_test.dart';

import '../harness.dart';

const languages = <DifyLanguage>[
  (value: 'en-US', name: 'English', example: 'Hello world'),
  (value: 'zh-Hans', name: '中文', example: '你好'),
];

Future<void> renderTts(WidgetTester t, {bool disabled = false, OnFeaturesChange? onChange, Features? overrides}) =>
    render(
      t,
      TextToSpeech(disabled: disabled, onChange: onChange),
      features: {...specDefaultFeatures, ...?overrides},
      services: const FeaturesServices(languages: languages),
    );

const title = r'feature\.textToSpeech\.title';

void main() {
  setUp(useDifyTestTranslator);

  group('TextToSpeech', () {
    testWidgets('should render the text-to-speech title', (t) async {
      await renderTts(t);
      expect(byText(title), findsOneWidget);
    });

    testWidgets('should render description when disabled', (t) async {
      await renderTts(t);
      expect(byText(r'feature\.textToSpeech\.description'), findsOneWidget);
    });

    testWidgets('should render a switch toggle', (t) async {
      await renderTts(t);
      expect(switchAt(), findsOneWidget);
    });

    testWidgets('should call onChange when toggled', (t) async {
      final onChange = OnChangeSpy();
      await renderTts(t, onChange: onChange.call);
      await tap(t, switchAt());
      expect(onChange.called, isTrue);
    });

    testWidgets('should toggle without onChange callback', (t) async {
      await renderTts(t);
      await tap(t, switchAt());
      expect(switchAt(), findsOneWidget);
    });

    testWidgets('should show language and voice info when enabled and not hovering', (t) async {
      await renderTts(
        t,
        overrides: const {
          'text2speech': {'enabled': true, 'language': 'en-US', 'voice': 'alloy'},
        },
      );
      expect(find.text('English'), findsOneWidget);
      expect(find.text('alloy'), findsOneWidget);
    });

    testWidgets('should show default display text when voice is not set', (t) async {
      await renderTts(
        t,
        overrides: const {
          'text2speech': {'enabled': true, 'language': 'en-US'},
        },
      );
      expect(byText(r'voice\.defaultDisplay'), findsOneWidget);
    });

    testWidgets('should show voice settings button when hovering', (t) async {
      await renderTts(
        t,
        overrides: const {
          'text2speech': {'enabled': true},
        },
      );
      await hover(t, card(title));
      expect(byText(r'voice\.voiceSettings\.title'), findsOneWidget);
    });

    testWidgets('should hide voice settings button after mouse leave', (t) async {
      await renderTts(
        t,
        overrides: const {
          'text2speech': {'enabled': true},
        },
      );
      await hover(t, card(title));
      expect(byText(r'voice\.voiceSettings\.title'), findsOneWidget);
      await unhover(t);
      expect(byText(r'voice\.voiceSettings\.title'), findsNothing);
    });

    testWidgets('should show autoPlay enabled text when autoPlay is enabled', (t) async {
      await renderTts(
        t,
        overrides: const {
          'text2speech': {'enabled': true, 'language': 'en-US', 'autoPlay': 'enabled'},
        },
      );
      expect(byText(r'voice\.voiceSettings\.autoPlayEnabled'), findsOneWidget);
    });

    testWidgets('should show autoPlay disabled text when autoPlay is not enabled', (t) async {
      await renderTts(
        t,
        overrides: const {
          'text2speech': {'enabled': true, 'language': 'en-US'},
        },
      );
      expect(byText(r'voice\.voiceSettings\.autoPlayDisabled'), findsOneWidget);
    });

    testWidgets('should pass open false to voice settings when disabled and modal is opened', (t) async {
      await renderTts(
        t,
        disabled: true,
        overrides: const {
          'text2speech': {'enabled': true},
        },
      );
      await hover(t, card(title));
      await tap(t, byText(r'voice\.voiceSettings\.title'));
      expect(t.widget<VoiceSettings>(find.byType(VoiceSettings)).open, isFalse);
      expect(find.byType(ParamConfigContent), findsNothing);
    });
  });
}
