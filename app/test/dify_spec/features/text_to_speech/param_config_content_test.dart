// dify-spec: web/app/components/base/features/new-feature-panel/text-to-speech/__tests__/param-config-content.spec.tsx
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/workflow_editor/features/features.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../harness.dart';

List<DifyLanguage> mockLanguages = [];
List<({String value, String name})>? mockVoiceItems;
var closed = 0;

Features withTts(Json tts) => {...specDefaultFeatures, 'text2speech': tts};

final defaultTts = {'enabled': true, 'language': 'en-US', 'voice': 'alloy', 'autoPlay': 'disabled'};

Future<void> renderContent(WidgetTester t, {OnFeaturesChange? onChange, Json? tts}) async {
  await render(
    t,
    ParamConfigContent(onClose: () => closed++, onChange: onChange),
    features: withTts(tts ?? defaultTts),
    services: FeaturesServices(
      languages: mockLanguages,
      voices: mockVoiceItems == null ? null : (_) async => mockVoiceItems!,
      playAudition: (_, _) async {},
    ),
  );
  await settle(t);
}

Finder get languageSelect => find.byWidgetPredicate(
  (w) => w is DifySelect<String> && (w.semanticLabel ?? '').contains('voice.voiceSettings.language'),
);
Finder get voiceSelect => find.byWidgetPredicate(
  (w) => w is DifySelect<String> && (w.semanticLabel ?? '').contains('voice.voiceSettings.voice'),
);
Finder get options => find.byWidgetPredicate((w) => w is DifyMenuRadioItem<String>);
String? selectedOf(WidgetTester t, Finder select) => t.widget<DifySelect<String>>(select).value;

void main() {
  setUp(() {
    useDifyTestTranslator();
    closed = 0;
    mockLanguages = const [
      (value: 'en-US', name: 'English', example: 'Hello world'),
      (value: 'zh-Hans', name: '中文', example: '你好'),
    ];
    mockVoiceItems = const [(value: 'alloy', name: 'Alloy'), (value: 'echo', name: 'Echo')];
  });

  group('ParamConfigContent', () {
    group('Rendering', () {
      testWidgets('should render voice settings title', (t) async {
        await renderContent(t);
        expect(byText(r'voice\.voiceSettings\.title'), findsOneWidget);
      });

      testWidgets('should render language label', (t) async {
        await renderContent(t);
        expect(byText(r'voice\.voiceSettings\.language'), findsOneWidget);
      });

      testWidgets('should render voice label', (t) async {
        await renderContent(t);
        expect(byText(r'voice\.voiceSettings\.voice$'), findsOneWidget);
      });

      testWidgets('should render autoPlay toggle', (t) async {
        await renderContent(t);
        expect(byText(r'voice\.voiceSettings\.autoPlay'), findsOneWidget);
        expect(switchAt(), findsOneWidget);
      });

      testWidgets('should render tooltip icon for language', (t) async {
        await renderContent(t);
        expect(byText(r'voice\.voiceSettings\.language'), findsOneWidget);
        expect(find.bySemanticsLabel(RegExp(r'voice\.voiceSettings\.resolutionTooltip')), findsOneWidget);
      });

      testWidgets('should display language listbox button', (t) async {
        await renderContent(t);
        expect(languageSelect, findsOneWidget);
      });

      testWidgets('should display current voice in listbox button', (t) async {
        await renderContent(t);
        expect(find.descendant(of: voiceSelect, matching: find.text('Alloy')), findsOneWidget);
      });

      testWidgets('should render audition button when language has example', (t) async {
        await renderContent(t);
        expect(find.bySemanticsLabel('Play'), findsWidgets);
      });

      testWidgets('should not render audition button when language has no example', (t) async {
        mockLanguages = const [
          (value: 'en-US', name: 'English', example: ''),
          (value: 'zh-Hans', name: '中文', example: ''),
        ];
        await renderContent(t);
        expect(find.bySemanticsLabel('Play'), findsNothing);
      });

      testWidgets('should render with no language set and use first as default', (t) async {
        await renderContent(t, tts: {'enabled': true, 'language': '', 'voice': '', 'autoPlay': 'disabled'});
        expect(languageSelect, findsOneWidget);
        expect(selectedOf(t, languageSelect), 'en-US');
      });

      testWidgets('should render with no voice set and use first as default', (t) async {
        await renderContent(
          t,
          tts: {'enabled': true, 'language': 'en-US', 'voice': 'nonexistent', 'autoPlay': 'disabled'},
        );
        expect(find.descendant(of: voiceSelect, matching: find.text('Alloy')), findsOneWidget);
      });
    });

    group('User Interactions', () {
      testWidgets('should call onClose when close button is clicked', (t) async {
        await renderContent(t);
        await tap(t, button('common.operation.close'));
        expect(closed, 1);
      });

      testWidgets('should call onClose when close button receives Enter key', (t) async {
        await renderContent(t);
        await tap(t, button('common.operation.close'));
        closed = 0;
        await focusOn(t, button('common.operation.close'));
        await t.sendKeyEvent(LogicalKeyboardKey.enter);
        expect(closed, 1);
      });

      testWidgets('should not call onClose when close button receives unrelated key', (t) async {
        await renderContent(t);
        await t.sendKeyEvent(LogicalKeyboardKey.escape);
        expect(closed, 0);
      });

      testWidgets('should toggle autoPlay switch and call onChange', (t) async {
        final onChange = OnChangeSpy();
        await renderContent(t, onChange: onChange.call);
        await tap(t, switchAt());
        expect(onChange.called, isTrue);
      });

      testWidgets('should set autoPlay to disabled when toggled off from enabled state', (t) async {
        final onChange = OnChangeSpy();
        await renderContent(t, onChange: onChange.call, tts: {...defaultTts, 'autoPlay': 'enabled'});
        expect(switchChecked(t), isTrue);
        await tap(t, switchAt());
        expect(switchChecked(t), isFalse);
        expect(onChange.called, isTrue);
      });

      testWidgets('should call feature update without onChange callback', (t) async {
        await renderContent(t);
        await tap(t, switchAt());
        expect(switchAt(), findsOneWidget);
      });

      testWidgets('should open language listbox and show options', (t) async {
        await renderContent(t);
        await tap(t, languageSelect);
        expect(options.evaluate().length, greaterThanOrEqualTo(2));
      });

      testWidgets('should handle language change', (t) async {
        final onChange = OnChangeSpy();
        await renderContent(t, onChange: onChange.call);
        await tap(t, languageSelect);
        expect(options.evaluate().length, greaterThan(1));
        await tap(t, options.at(1));
        expect(onChange.called, isTrue);
      });

      testWidgets('should handle voice change', (t) async {
        final onChange = OnChangeSpy();
        await renderContent(t, onChange: onChange.call);
        await tap(t, voiceSelect);
        expect(options.evaluate().length, greaterThan(1));
        await tap(t, options.at(1));
        expect(onChange.called, isTrue);
      });

      testWidgets('should show selected language option in listbox', (t) async {
        await renderContent(t);
        await tap(t, languageSelect);
        expect(options.evaluate(), isNotEmpty);
        final selected = find.descendant(of: options, matching: byText(r'voice\.language\.enUS'));
        expect(selected, findsOneWidget);
        expect(selectedOf(t, languageSelect), 'en-US');
      });

      testWidgets('should show selected voice option in listbox', (t) async {
        await renderContent(t);
        await tap(t, voiceSelect);
        expect(options.evaluate(), isNotEmpty);
        expect(find.descendant(of: options, matching: find.text('Alloy')), findsOneWidget);
        expect(selectedOf(t, voiceSelect), 'alloy');
      });
    });

    group('Edge Cases', () {
      testWidgets('should show placeholder and disable voice selection when no languages are available', (t) async {
        mockLanguages = const [];
        mockVoiceItems = null;
        await renderContent(t);
        expect(byText(r'placeholder\.select').evaluate().length, greaterThanOrEqualTo(2));
        expect(t.widget<DifySelect<String>>(voiceSelect).disabled, isTrue);
      });

      testWidgets('should render language text when selected language value is empty string', (t) async {
        mockLanguages = const [(value: '', name: 'Unknown Language', example: '')];
        await renderContent(t, tts: {'enabled': true, 'language': '', 'voice': '', 'autoPlay': 'disabled'});
        expect(byText(r'voice\.language\.'), findsOneWidget);
      });
    });
  });
}
