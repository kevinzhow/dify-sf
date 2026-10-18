// dify-spec: web/app/components/base/features/new-feature-panel/__tests__/follow-up-setting-modal.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/features/features.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/entry/knowledge_base/kb_widgets.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/group_host.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/model_parameter_modal.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/form_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../harness.dart';

const llm = LlmGroupServices(defaultModels: {'llm': (provider: 'openai', model: 'gpt-4o-mini', mode: 'chat')});

final saved = <Json>[];

Future<void> renderModal(WidgetTester t, [Json data = const {'enabled': true}]) async {
  saved.clear();
  await render(
    t,
    FollowUpSettingModal(data: data, onSave: saved.add, onCancel: () {}),
    llm: llm,
    fill: true,
  );
  await settle(t);
}

ModelParameterModal parameters(WidgetTester t) => t.widget<ModelParameterModal>(find.byType(ModelParameterModal));

/// The option card holding [pattern]'s text, and whether its radio is checked (`data-checked`).
bool checked(WidgetTester t, String pattern) => t
    .widget<KbRadio>(
      find.descendant(
        of: find
            .ancestor(
              of: byText(pattern),
              matching: find.byWidgetPredicate((w) => w is Semantics && w.properties.checked != null),
            )
            .first,
        matching: find.byType(KbRadio),
      ),
    )
    .checked;

const defaultOption = r'modal\.defaultPromptOption$';
const customOption = r'modal\.customPromptOption$';

void main() {
  setUp(useDifyTestTranslator);

  group('FollowUpSettingModal', () {
    group('Model Parameters', () {
      testWidgets('should keep max tokens disabled after its switch is turned off', (t) async {
        await renderModal(t, {
          'enabled': true,
          'model': {
            'provider': 'openai',
            'name': 'gpt-4o-mini',
            'mode': 'chat',
            'completion_params': {
              'temperature': 0.7,
              'max_tokens': 0,
              'top_p': 0,
              'echo': false,
              'stop': <Object?>[],
              'presence_penalty': 0,
              'frequency_penalty': 0,
            },
          },
        });
        expect(parameters(t).completionParams.containsKey('max_tokens'), isTrue);
        final params = {...parameters(t).completionParams}..remove('max_tokens');
        parameters(t).onCompletionParamsChange(params);
        await t.pump();
        expect(parameters(t).completionParams.containsKey('max_tokens'), isFalse);
      });

      testWidgets('should keep max tokens disabled when saved model parameters omit it', (t) async {
        await renderModal(t, {
          'enabled': true,
          'model': {
            'provider': 'openai',
            'name': 'gpt-4o-mini',
            'mode': 'chat',
            'completion_params': {'temperature': 0.7},
          },
        });
        expect(parameters(t).completionParams.containsKey('max_tokens'), isFalse);
      });
    });

    group('Default Prompt', () {
      testWidgets(
        'should show the system default prompt and save without a custom prompt when no custom prompt is configured',
        (t) async {
          await renderModal(t);
          expect(
            find.text('app-debug.feature.suggestedQuestionsAfterAnswer.modal.defaultPromptOption'),
            findsOneWidget,
          );
          expect(byText('Please predict the three most likely follow-up questions a user would ask'), findsOneWidget);
          await tap(t, byText(r'common\.operation\.save'));
          expect(saved.single.containsKey('prompt'), isFalse);
          expect(featureMap(saved.single, 'model')['provider'], 'openai');
          expect(featureMap(saved.single, 'model')['name'], 'gpt-4o-mini');
        },
      );
    });

    group('Custom Prompt', () {
      testWidgets('should expose the selected prompt mode through RadioItem state attributes', (t) async {
        await renderModal(t);
        expect(checked(t, defaultOption), isTrue);
        expect(checked(t, customOption), isFalse);
        await tap(t, byText(customOption));
        expect(checked(t, defaultOption), isFalse);
        expect(checked(t, customOption), isTrue);
      });

      testWidgets('should enable custom prompt input and save the custom prompt when selected', (t) async {
        await renderModal(t);
        await tap(t, byText(customOption));
        final textarea = byPlaceholder(r'modal\.promptPlaceholder');
        expect(
          t.widget<DifyTextarea>(find.ancestor(of: textarea, matching: find.byType(DifyTextarea))).maxLength,
          1000,
        );
        await t.enterText(textarea, 'Use a custom follow-up prompt.');
        await t.pump();
        await tap(t, byText(r'common\.operation\.save'));
        expect(saved.single['prompt'], 'Use a custom follow-up prompt.');
      });

      testWidgets('should disable save when custom prompt is selected but empty', (t) async {
        await renderModal(t);
        await tap(t, byText(customOption));
        expect(isDisabled(t, r'common\.operation\.save'), isTrue);
      });
    });
  });
}
