// dify-spec: web/app/components/workflow/hooks/__tests__/use-config-vision.spec.ts
//
// useConfigVision is model_common.dart: isVisionModel (the current text generation model's features),
// visionEnabledChange (handleVisionResolutionEnabledChange), visionAfterModelChange (handleModelChanged); the panels
// write `vision.configs` directly for handleVisionResolutionChange (ConfigVision.onConfigChange).
import 'package:dify_sf_app/src/workflow/model_catalog.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/group_host.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/model_common.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/node_config.dart' show ConfigVision;
import 'package:dify_sf_app/src/workflow_editor/panel_fields/var_picker_model.dart' show VarScope;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../dify_test_i18n.dart';

LlmGroupServices _services(List<String> features) => LlmGroupServices(
  models: ModelCatalog(
    providers: const [
      ModelProvider(provider: 'openai', label: {'en_US': 'OpenAI'}),
    ],
    modelLists: {
      ModelTypeEnum.textGeneration: [
        ProviderWithModels(
          provider: 'openai',
          label: const {'en_US': 'OpenAI'},
          models: [
            ModelItem(
              model: 'gpt-4o',
              label: const {'en_US': 'gpt-4o'},
              features: features,
              modelProperties: const {'mode': 'chat'},
            ),
          ],
        ),
      ],
    },
  ),
);

void main() {
  group('useConfigVision', () {
    test('should expose vision capability and enable default chat configs for vision models', () {
      expect(isVisionModel(_services([ModelFeatureEnum.vision]), 'openai', 'gpt-4o'), isTrue);
      expect(isVisionModel(_services([]), 'openai', 'gpt-4o'), isFalse);
      expect(visionEnabledChange({'enabled': false}, true, isChatMode: true), {
        'enabled': true,
        'configs': {
          'detail': 'high',
          'variable_selector': ['sys', 'files'],
        },
      });
    });

    test('should clear configs when disabling vision resolution', () {
      final payload = {
        'enabled': true,
        'configs': {
          'detail': 'low',
          'variable_selector': ['node', 'files'],
        },
      };
      expect(visionEnabledChange(payload, false, isChatMode: false), {'enabled': false});
    });

    testWidgets('should update the resolution config payload directly', (t) async {
      useDifyTestTranslator();
      // The test translator's keys are long: room for them.
      t.view.physicalSize = const Size(2400, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final changes = <Map<String, Object?>>[];
      await t.pumpWidget(
        MaterialApp(
          home: Material(
            child: ConfigVision(
              isVisionModel: true,
              enabled: true,
              onEnabledChange: (_) {},
              config: const {
                'detail': 'high',
                'variable_selector': ['upstream', 'images'],
              },
              onConfigChange: changes.add,
              scope: const VarScope(),
            ),
          ),
        ),
      );
      await t.tap(find.text('workflow.nodes.llm.resolution.low'));
      expect(changes, [
        {
          'detail': 'low',
          'variable_selector': ['upstream', 'images'],
        },
      ]);
    });

    test('should disable vision settings when the selected model is no longer a vision model', () {
      final payload = {
        'enabled': true,
        'configs': {
          'detail': 'high',
          'variable_selector': ['sys', 'files'],
        },
      };
      final vision = isVisionModel(_services([]), 'openai', 'gpt-4o');
      expect(visionAfterModelChange(payload, isVisionModel: vision, isChatMode: false), {'enabled': false});
    });

    test('should reset enabled vision configs when the model changes but still supports vision', () {
      final payload = {
        'enabled': true,
        'configs': {
          'detail': 'low',
          'variable_selector': ['old', 'files'],
        },
      };
      final vision = isVisionModel(_services([ModelFeatureEnum.vision]), 'openai', 'gpt-4o');
      expect(visionAfterModelChange(payload, isVisionModel: vision, isChatMode: false), {
        'enabled': true,
        'configs': {'detail': 'high', 'variable_selector': <String>[]},
      });
    });
  });
}
