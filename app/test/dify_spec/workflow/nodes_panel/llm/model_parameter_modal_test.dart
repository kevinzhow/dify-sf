// dify-spec: web/app/components/header/account-setting/model-provider-page/model-parameter-modal/__tests__/index.spec.tsx
// dify-spec: web/app/components/header/account-setting/model-provider-page/model-parameter-modal/__tests__/model-settings-trigger.spec.tsx
//
// The modal with its real parts (Dify mocks ParameterItem, the selector and the presets): parameter rules come from
// the services' `parameterRules`, the model lists from the services' catalog.
import 'dart:async';

import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/workflow/model_catalog.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/group_host.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/model_parameter_modal.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/var_picker_model.dart';
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/prompt_editor_types.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'model_fixtures.dart';

const _settings = 'common.modelProvider.modelSettings';
const _selectorTrigger = 'plugin.detailPanel.configureModel';

const _temperature = {
  'name': 'temperature',
  'label': {'en_US': 'Temperature'},
  'type': 'float',
  'default': 0.7,
  'min': 0,
  'max': 1,
  'help': {'en_US': 'Control randomness'},
};

void main() {
  late List<Map<String, Object?>> parameterRules;
  late Future<List<Map<String, Object?>>>? pendingRules;
  late String modelStatus;
  late List<ModelChoice> setModel;
  late List<Map<String, Object?>> paramsChanges;
  late int debugToggles;
  late String providerId;

  setUp(() {
    providerId = 'openai';
    useDifyTestTranslator();
    parameterRules = [_temperature];
    pendingRules = null;
    modelStatus = ModelStatusEnum.active;
    setModel = [];
    paramsChanges = [];
    debugToggles = 0;
  });

  ModelCatalog catalog() => catalogOf([
    makeModel(
      provider: providerId,
      models: [
        makeModelItem(
          model: 'gpt-3.5-turbo',
          label: const {'en_US': 'GPT-3.5'},
          status: modelStatus,
          modelProperties: const {'mode': 'chat'},
          features: const ['vision'],
        ),
        makeModelItem(
          model: 'gpt-4.1',
          label: const {'en_US': 'GPT-4.1'},
          modelProperties: const {'mode': 'chat'},
          features: const ['vision', 'tool-call'],
        ),
      ],
    ),
  ]);

  Future<void> render(
    WidgetTester t, {
    String? provider,
    String modelId = 'gpt-3.5-turbo',
    Map<String, Object?> completionParams = const {'temperature': 0.7},
    bool readonly = false,
    bool isAdvancedMode = false,
    bool isInWorkflow = false,
    bool hideDebugWithMultipleModel = false,
    bool debugWithMultipleModel = false,
    ModelPredicate? modelPredicate,
    DifyTriggerBuilder? trigger,
    List<VarGroup> nodesOutputVars = const [],
    Map<String, WorkflowNodeInfo> availableNodes = const {},
    VoidCallback? openModelProviderSettings,
  }) => pumpHost(
    t,
    services: LlmGroupServices(
      models: catalog(),
      parameterRules: (p, m) => pendingRules ?? Future.value(parameterRules),
      openModelProviderSettings: openModelProviderSettings,
    ),
    ModelParameterModal(
      provider: provider ?? providerId,
      modelId: modelId,
      completionParams: completionParams,
      onModelChange: setModel.add,
      onCompletionParamsChange: paramsChanges.add,
      isAdvancedMode: isAdvancedMode,
      isInWorkflow: isInWorkflow,
      readonly: readonly,
      modelPredicate: modelPredicate,
      trigger: trigger,
      nodesOutputVars: nodesOutputVars,
      availableNodes: availableNodes,
      hideDebugWithMultipleModel: hideDebugWithMultipleModel,
      debugWithMultipleModel: debugWithMultipleModel,
      onDebugWithMultipleModelChange: () => debugToggles++,
    ),
  );

  Future<void> openSettings(WidgetTester t) async {
    await t.tap(named(_settings));
    await settle(t);
  }

  Future<void> pickGpt41(WidgetTester t) async {
    await t.tap(named(_selectorTrigger).first);
    await settle(t);
    await t.tap(find.text('GPT-4.1'));
    await settle(t);
  }

  group('ModelParameterModal', () {
    testWidgets('should render trigger and open modal content when trigger is clicked', (t) async {
      await render(t);
      await openSettings(t);
      expect(find.byType(SplitModelSelector), findsOneWidget);
      expect(find.text('Temperature'), findsOneWidget);
    });

    testWidgets('should keep model selection and model settings as separate actions', (t) async {
      await render(t);
      expect(find.byType(SplitModelSelector), findsOneWidget);
      expect(find.text('Temperature'), findsNothing);

      await pickGpt41(t);
      expect(setModel.map(_choice), ['openai/gpt-4.1 chat [vision, tool-call]']);
      expect(modelProviderPluginId('openai'), 'langgenius/openai');
      expect(find.text('Temperature'), findsNothing);

      await openSettings(t);
      expect(find.text('Temperature'), findsOneWidget);
    });

    testWidgets('should disable model settings when no model is selected', (t) async {
      await render(t, provider: '', modelId: '');
      expect(find.byType(SplitModelSelector), findsOneWidget);
      expect(isDisabled(t, _settings), isTrue);
    });

    testWidgets('should disable model settings for an incompatible model without disabling selection', (t) async {
      await render(t, modelPredicate: (_, _) => false);
      expect(isDisabled(t, _settings), isTrue);
      expect(isDisabled(t, _selectorTrigger), isFalse);
    });

    testWidgets('should disable model settings when the selected model is inactive', (t) async {
      modelStatus = ModelStatusEnum.disabled;
      await render(t);
      expect(find.byType(SplitModelSelector), findsOneWidget);
      expect(isDisabled(t, _settings), isTrue);
    });

    testWidgets('should call onCompletionParamsChange when parameter changes and switch actions happen', (t) async {
      await render(t);
      await openSettings(t);
      final input = find.descendant(of: find.byType(ParameterItem), matching: find.byType(EditableText));
      await t.enterText(input, '0.9');
      expect(paramsChanges.last, {'temperature': 0.9});

      await t.tap(find.byType(DifySwitch));
      expect(paramsChanges.last, <String, Object?>{});

      await t.pumpWidget(const SizedBox());
      await render(t, completionParams: const {});
      await openSettings(t);
      await t.tap(find.byType(DifySwitch));
      expect(paramsChanges.last, {'temperature': 0.7});
    });

    testWidgets('should call onCompletionParamsChange when preset is selected', (t) async {
      providerId = 'langgenius/openai/openai';
      await render(t);
      await openSettings(t);
      await t.tap(named('common.modelProvider.loadPresets'));
      await settle(t);
      await t.tap(find.text('common.model.tone.Creative'));
      await settle(t);
      expect(paramsChanges.last, {'temperature': 0.8});
    });

    testWidgets('should not render preset control when visible parameters do not support preset keys', (t) async {
      parameterRules = [
        {
          'name': 'max_tokens',
          'label': {'en_US': 'Max Tokens'},
          'type': 'int',
          'default': 256,
          'min': 1,
          'max': 4096,
        },
      ];
      await render(t);
      await openSettings(t);
      expect(find.text('Max Tokens'), findsOneWidget);
      expect(named('common.modelProvider.loadPresets'), findsNothing);
    });

    testWidgets('should call setModel when model selector picks another model', (t) async {
      await render(t);
      await openSettings(t);
      await t.tapAt(const Offset(5, 5));
      await settle(t);
      await pickGpt41(t);
      expect(setModel.map(_choice), ['openai/gpt-4.1 chat [vision, tool-call]']);
    });

    testWidgets('should toggle debug mode when debug footer is clicked', (t) async {
      await render(t);
      await openSettings(t);
      await t.tap(named('app-debug.debugAsMultipleModel'));
      expect(debugToggles, 1);
    });

    testWidgets('should render loading state when parameter rules are loading', (t) async {
      pendingRules = Completer<List<Map<String, Object?>>>().future;
      await render(t);
      await openSettings(t);
      expect(find.byType(ModelLoading), findsOneWidget);
    });

    testWidgets(
      'should not render parameter loading when model is not configured and parameter rules query is pending but disabled',
      (t) async {
        pendingRules = Completer<List<Map<String, Object?>>>().future;
        parameterRules = [];
        await render(t, provider: '', modelId: '', trigger: _customTrigger);
        await t.tap(find.text('Custom Trigger'));
        await settle(t);
        expect(find.byType(ModelLoading), findsNothing);
        expect(find.byType(ModelSelector), findsOneWidget);
      },
    );

    testWidgets('should not open content when readonly is true', (t) async {
      await render(t, readonly: true);
      expect(isDisabled(t, _settings), isTrue);
      await t.tap(named(_settings));
      await settle(t);
      expect(find.text('Temperature'), findsNothing);
    });

    testWidgets('should render no parameter items when rules are undefined', (t) async {
      parameterRules = [];
      await render(t);
      await openSettings(t);
      expect(find.byType(ParameterItem), findsNothing);
      expect(find.byType(SplitModelSelector), findsOneWidget);
    });

    testWidgets('should pass nodesOutputVars and availableNodes to ParameterItem', (t) async {
      const vars = [VarGroup(nodeId: 'n1', title: 'Node', vars: [])];
      const nodes = {'n1': WorkflowNodeInfo(title: 'Node', type: 'llm')};
      await render(t, isInWorkflow: true, nodesOutputVars: vars, availableNodes: nodes);
      await openSettings(t);
      final item = t.widget<ParameterItem>(find.byType(ParameterItem));
      expect(item.nodesOutputVars, vars);
      expect(item.availableNodes, nodes);
    });

    testWidgets('should support a custom trigger element and missing default model values', (t) async {
      var settings = 0;
      await render(
        t,
        provider: '',
        modelId: '',
        isInWorkflow: true,
        trigger: _customTrigger,
        openModelProviderSettings: () => settings++,
      );
      expect(find.byType(ModelSelector), findsNothing);
      await t.tap(find.text('Custom Trigger'));
      await settle(t);
      expect(find.byType(ModelSelector), findsOneWidget);

      // The selector asks the modal to hide (here: on its way to the provider settings).
      await t.tap(named(_selectorTrigger));
      await settle(t);
      await t.tap(named('common.modelProvider.selector.modelProviderSettings'));
      await settle(t);
      expect(settings, 1);
      expect(find.byType(ModelSelector), findsNothing);
    });

    testWidgets('should append the stop parameter in advanced mode and show the single-model debug label', (t) async {
      await render(t, isAdvancedMode: true, debugWithMultipleModel: true);
      await openSettings(t);
      expect(find.text('Stop sequences'), findsOneWidget);
      expect(find.text('app-debug.debugAsSingleModel'), findsOneWidget);
    });

    testWidgets('should render the empty loading fallback when rules resolve to an empty list', (t) async {
      parameterRules = [];
      pendingRules = Completer<List<Map<String, Object?>>>().future;
      await render(t);
      await openSettings(t);
      expect(find.byType(ModelLoading), findsOneWidget);
      expect(find.text('Temperature'), findsNothing);
    });

    testWidgets('should support custom trigger placement outside workflow mode', (t) async {
      await render(t, trigger: _customTrigger);
      await t.tap(find.text('Custom Trigger'));
      await settle(t);
      expect(find.byType(ModelSelector), findsOneWidget);
    });
  });

  group('ModelSettingsTrigger', () {
    testWidgets('should compose the popover behavior onto the final icon button', (t) async {
      await pumpHost(t, ModelSettingsTrigger(onPressed: () {}));
      expect(named(_settings), findsOneWidget);
      expect(find.byType(DifyPressable), findsOneWidget);
    });

    testWidgets('should put the disabled state on the final icon button', (t) async {
      await pumpHost(t, const ModelSettingsTrigger(disabled: true));
      expect(isDisabled(t, _settings), isTrue);
    });
  });
}

Widget _customTrigger(BuildContext context, DifyFloatingController controller) =>
    TextButton(onPressed: controller.toggle, child: const Text('Custom Trigger'));

String _choice(ModelChoice c) => '${c.provider}/${c.modelId} ${c.mode} ${c.features}';
