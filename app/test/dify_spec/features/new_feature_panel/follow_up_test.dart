// dify-spec: web/app/components/base/features/new-feature-panel/__tests__/follow-up.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/features/features.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/group_host.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../harness.dart';

import 'package:dify_sf_app/src/design/widgets/widgets.dart';

const llm = LlmGroupServices(defaultModels: {'llm': (provider: 'openai', model: 'gpt-4o-mini', mode: 'chat')});

Future<void> renderFollowUp(WidgetTester t, {bool disabled = false, OnFeaturesChange? onChange, Json? suggested}) =>
    render(
      t,
      FollowUp(disabled: disabled, onChange: onChange),
      features: {
        'suggested': suggested ?? const {'enabled': false},
      },
      llm: llm,
    );

const title = r'feature\.suggestedQuestionsAfterAnswer\.title';

void main() {
  setUp(useDifyTestTranslator);

  group('FollowUp', () {
    testWidgets('should render the follow-up feature card', (t) async {
      await renderFollowUp(t);
      expect(byText(title), findsOneWidget);
    });

    testWidgets('should render description text', (t) async {
      await renderFollowUp(t);
      expect(byText(r'feature\.suggestedQuestionsAfterAnswer\.description'), findsOneWidget);
    });

    testWidgets('should render a switch toggle', (t) async {
      await renderFollowUp(t);
      expect(switchAt(), findsOneWidget);
    });

    testWidgets('should call onChange when toggled', (t) async {
      final onChange = OnChangeSpy();
      await renderFollowUp(t, onChange: onChange.call);
      await tap(t, switchAt());
      expect(onChange.calls, hasLength(1));
    });

    testWidgets('should not throw when onChange is not provided', (t) async {
      await renderFollowUp(t);
      await tap(t, switchAt());
      expect(t.takeException(), isNull);
    });

    testWidgets('should render edit button when enabled and hovering', (t) async {
      await renderFollowUp(t, suggested: const {'enabled': true});
      await hover(t, card(title));
      expect(byText(r'operation\.settings'), findsOneWidget);
    });

    testWidgets('should open settings modal and save follow-up config', (t) async {
      final onChange = OnChangeSpy();
      await renderFollowUp(t, onChange: onChange.call, suggested: const {'enabled': true});
      await hover(t, card(title));
      await tap(t, byText(r'operation\.settings'));
      expect(find.byType(FollowUpSettingModal), findsOneWidget);
      await tap(t, byText(r'modal\.customPromptOption$'));
      await t.enterText(
        find.descendant(of: find.byType(DifyTextarea), matching: find.byType(EditableText)),
        'test prompt',
      );
      await t.pump();
      await tap(t, byText(r'operation\.save'));
      final suggested = featureMap(onChange.calls.single, 'suggested');
      expect(suggested['enabled'], true);
      expect(suggested['prompt'], 'test prompt');
      expect(featureMap(suggested, 'model')['provider'], 'openai');
      expect(featureMap(suggested, 'model')['name'], 'gpt-4o-mini');
    });
  });
}
