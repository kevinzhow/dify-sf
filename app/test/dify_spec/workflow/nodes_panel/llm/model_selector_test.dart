// dify-spec: web/app/components/header/account-setting/model-provider-page/model-selector/__tests__/index.spec.tsx
// dify-spec: web/app/components/header/account-setting/model-provider-page/model-selector/__tests__/popup-item.spec.tsx
// dify-spec: web/app/components/header/account-setting/model-provider-page/model-selector/__tests__/popup.spec.tsx
//
// The selector, its popup and popup items with their real parts (Dify mocks the popup and the items): installed
// providers come from the catalog's summary, provider labels show instead of Dify's mocked provider ids.
import 'package:dify_sf_app/src/design/dify_icon.dart';
import 'package:dify_sf_app/src/design/dify_tokens.g.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/workflow/model_catalog.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/group_host.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/model_selector.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'model_fixtures.dart';

const _trigger = 'plugin.detailPanel.configureModel';
const _noModel = 'common.modelProvider.selector.noModelFoundForSearch';

/// The popup with its own search state (Dify's PopupHarness).
class PopupHarness extends StatefulWidget {
  const PopupHarness({
    super.key,
    required this.modelList,
    required this.catalog,
    this.defaultModel,
    this.scopeFeatures = const [],
    this.modelPredicate,
    this.onOpenProviderSettings,
    this.onConfigureEmptyState,
  });
  final List<ProviderWithModels> modelList;
  final ModelCatalog catalog;
  final DefaultModel? defaultModel;
  final List<String> scopeFeatures;
  final ModelPredicate? modelPredicate;
  final VoidCallback? onOpenProviderSettings, onConfigureEmptyState;

  @override
  State<PopupHarness> createState() => _PopupHarnessState();
}

class _PopupHarnessState extends State<PopupHarness> {
  String _input = '';

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 600,
    child: ModelSelectorPopup(
      defaultModel: widget.defaultModel,
      inputValue: _input,
      modelList: widget.modelList,
      catalog: widget.catalog,
      scopeFeatures: widget.scopeFeatures,
      modelPredicate: widget.modelPredicate,
      onOpenProviderSettings: widget.onOpenProviderSettings,
      onConfigureEmptyState: widget.onConfigureEmptyState,
      onInputValueChange: (v) => setState(() => _input = v),
      onSelect: (_, _) {},
      onHide: () {},
    ),
  );
}

Finder get _searchField => find.descendant(of: find.byType(ModelSearchInput), matching: find.byType(EditableText));

/// The rows shown, by model id (Dify's mocked PopupItem prints them).
List<String> shownModels(WidgetTester t) => [
  for (final e in find.byType(ModelSelectorModelRow).evaluate()) (e.widget as ModelSelectorModelRow).model.model,
];

/// The provider sections shown, by provider id.
List<String> shownProviders(WidgetTester t) => [
  for (final e in find.byType(ModelSelectorPopupItem).evaluate())
    if (find.descendant(of: find.byWidget(e.widget), matching: find.byType(DifyPressable)).evaluate().isNotEmpty)
      (e.widget as ModelSelectorPopupItem).model.provider,
];

Future<void> renderPopup(
  WidgetTester t,
  List<ProviderWithModels> modelList, {
  DefaultModel? defaultModel,
  List<String> scopeFeatures = const [],
  ModelPredicate? modelPredicate,
  VoidCallback? onOpenProviderSettings,
  VoidCallback? onConfigureEmptyState,
  String language = 'en_US',
}) => pumpHost(
  t,
  PopupHarness(
    modelList: modelList,
    catalog: catalogOf(modelList, language: language),
    defaultModel: defaultModel,
    scopeFeatures: scopeFeatures,
    modelPredicate: modelPredicate,
    onOpenProviderSettings: onOpenProviderSettings,
    onConfigureEmptyState: onConfigureEmptyState,
  ),
);

Future<void> search(WidgetTester t, String query) async {
  await t.enterText(_searchField, query);
  await settle(t);
}

Finder textContaining(String s) => find.textContaining(s);

void main() {
  setUp(useDifyTestTranslator);

  group('ModelSelector', () {
    Future<void> render(
      WidgetTester t, {
      DefaultModel? value,
      List<ProviderWithModels>? models,
      ValueChanged<({String provider, String model})>? onChange,
      VoidCallback? onHide,
      VoidCallback? onConfigureEmptyState,
      VoidCallback? openModelProviderSettings,
      bool disabled = false,
      bool split = false,
    }) {
      final list = models ?? [makeModel()];
      return pumpHost(
        t,
        services: LlmGroupServices(models: catalogOf(list), openModelProviderSettings: openModelProviderSettings),
        split
            ? SplitModelSelector(value: value, models: list, onChange: onChange)
            : ModelSelector(
                value: value,
                models: list,
                onChange: onChange,
                onHide: onHide,
                onConfigureEmptyState: onConfigureEmptyState,
                disabled: disabled,
              ),
      );
    }

    bool open() => find.byType(ModelSelectorPopup).evaluate().isNotEmpty;

    testWidgets('should toggle popup and close it after selecting a model', (t) async {
      await render(t);
      await t.tap(named(_trigger));
      await settle(t);
      expect(open(), isTrue);
      expect(find.text('GPT-4'), findsOneWidget);
      await t.tap(find.text('GPT-4'));
      await settle(t);
      expect(open(), isFalse);
    });

    testWidgets('should call onValueChange when provided', (t) async {
      final changes = <({String provider, String model})>[];
      await render(t, onChange: changes.add);
      await t.tap(named(_trigger));
      await settle(t);
      await t.tap(find.text('GPT-4'));
      expect(changes, [(provider: 'openai', model: 'gpt-4')]);
      expect(modelProviderPluginId('openai'), 'langgenius/openai');
    });

    testWidgets('should close popup when popup requests hide', (t) async {
      var hides = 0;
      await render(t, onHide: () => hides++, openModelProviderSettings: () {});
      await t.tap(named(_trigger));
      await settle(t);
      expect(open(), isTrue);
      await t.tap(named('common.modelProvider.selector.modelProviderSettings'));
      await settle(t);
      expect(open(), isFalse);
      expect(hides, 1);
    });

    testWidgets('should close popup before running the empty-state configure action', (t) async {
      var configured = 0;
      await render(t, models: const [], onConfigureEmptyState: () => configured++);
      await t.tap(named(_trigger));
      await settle(t);
      expect(open(), isTrue);
      await t.tap(find.text('common.modelProvider.selector.configure'));
      await settle(t);
      expect(open(), isFalse);
      expect(configured, 1);
    });

    testWidgets('should close the popup before opening provider settings', (t) async {
      var hides = 0, settings = 0;
      await render(t, onHide: () => hides++, openModelProviderSettings: () => settings++);
      await t.tap(named(_trigger));
      await settle(t);
      await t.tap(named('common.modelProvider.selector.modelProviderSettings'));
      await settle(t);
      expect(open(), isFalse);
      expect(hides, 1);
      expect(settings, 1);
    });

    testWidgets('should not open popup when disabled', (t) async {
      await render(t, disabled: true);
      await t.tap(named(_trigger), warnIfMissed: false);
      await settle(t);
      expect(open(), isFalse);
    });

    testWidgets('should let the split trigger own the combobox interaction', (t) async {
      await render(t, split: true);
      expect(t.widget<ModelSelectorButton>(find.byType(ModelSelectorButton)).shape, ModelSelectorShape.split);
    });

    testWidgets('should render deprecated trigger when value is not in list', (t) async {
      await render(t, value: (provider: 'openai', model: 'missing-model'));
      expect(find.text('missing-model'), findsOneWidget);
    });

    testWidgets('should render model trigger when value matches', (t) async {
      await render(t, value: (provider: 'openai', model: 'gpt-4'));
      expect(find.text('GPT-4'), findsOneWidget);
    });
  });

  group('PopupItem', () {
    Future<void> render(
      WidgetTester t,
      ProviderWithModels model, {
      List<ModelProvider>? providers,
      ModelCatalog? catalog,
      DefaultModel? defaultModel,
      ModelPredicate? modelPredicate,
      ModelPredicate? modelSuggestionPredicate,
      void Function(String, ModelItem)? onSelect,
    }) => pumpHost(
      t,
      ModelSelectorPopupItem(
        model: model,
        catalog: catalog ?? catalogOf([model], providers: providers),
        defaultModel: defaultModel,
        modelPredicate: modelPredicate,
        modelSuggestionPredicate: modelSuggestionPredicate,
        onSelect: onSelect ?? (_, _) {},
      ),
    );

    TextStyle? styleOf(WidgetTester t, String text) => t.widget<Text>(find.text(text)).style;

    testWidgets('should render nothing when provider is not found in modelProviders', (t) async {
      await render(t, makeModel(), providers: const []);
      expect(find.text('OpenAI'), findsNothing);
      expect(find.text('GPT-4'), findsNothing);
    });

    testWidgets('should select the model when clicking an active model', (t) async {
      final selected = <String>[];
      await render(t, makeModel(), onSelect: (p, m) => selected.add('$p/${m.model}'));
      await t.tap(find.text('GPT-4'));
      expect(selected, ['openai/gpt-4']);
    });

    testWidgets('should not select the combobox value when model is not active', (t) async {
      final selected = <String>[];
      await render(
        t,
        makeModel(models: [makeModelItem(status: ModelStatusEnum.disabled)]),
        onSelect: (p, m) => selected.add(m.model),
      );
      await t.tap(find.text('GPT-4'));
      expect(selected, isEmpty);
    });

    testWidgets('should strike through deprecated model name', (t) async {
      await render(t, makeModel(models: [makeModelItem(deprecated: true)]));
      expect(styleOf(t, 'GPT-4')!.decoration, TextDecoration.lineThrough);
    });

    testWidgets('should render incompatible model names with tertiary text color', (t) async {
      await render(
        t,
        makeModel(
          models: [
            makeModelItem(model: 'gpt-4o', label: const {'en_US': 'GPT-4o', 'zh_Hans': 'GPT-4o'}),
            makeModelItem(),
          ],
        ),
        modelPredicate: (_, m) => m.model != 'gpt-4',
      );
      expect(styleOf(t, 'GPT-4o')!.color, DifyColors.textSecondary);
      expect(styleOf(t, 'GPT-4')!.color, DifyColors.textQuaternary);
    });

    testWidgets('should expose the suggestion in the model name and on hover', (t) async {
      await render(
        t,
        makeModel(
          models: [
            makeModelItem(model: 'gpt-5.5', label: const {'en_US': 'GPT-5.5', 'zh_Hans': 'GPT-5.5'}),
            makeModelItem(model: 'gpt-5', label: const {'en_US': 'GPT-5', 'zh_Hans': 'GPT-5'}),
          ],
        ),
        modelSuggestionPredicate: (_, m) => m.model == 'gpt-5.5',
      );
      expect(find.text('GPT-5.5'), findsOneWidget);
      expect(find.text('GPT-5'), findsOneWidget);
      expect(named('GPT-5.5 common.modelProvider.selector.suggestionTip'), findsOneWidget);
      final mark = find.byWidgetPredicate((w) => w is RemixIcon && w.name == 'shield-star-line');
      expect(mark, findsOneWidget);
      final gesture = await t.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      await gesture.moveTo(t.getCenter(mark));
      await t.pump(const Duration(milliseconds: 400));
      await settle(t);
      expect(find.text('common.modelProvider.selector.suggestionTip'), findsOneWidget);
      await gesture.removePointer();
    });

    testWidgets('should show selected state when defaultModel matches', (t) async {
      await render(t, makeModel(), defaultModel: (provider: 'openai', model: 'gpt-4'));
      expect(t.widget<ModelSelectorModelRow>(find.byType(ModelSelectorModelRow)).selected, isTrue);
      expect(find.byWidgetPredicate((w) => w is DifyIcon && w.name == 'vender/line/general/check'), findsOneWidget);
    });

    testWidgets('should fall back to english labels when the current language is unavailable', (t) async {
      final model = makeModel(
        label: const {'en_US': 'OpenAI only'},
        models: [
          makeModelItem(label: const {'en_US': 'GPT-4 only'}),
        ],
      );
      await render(t, model, catalog: catalogOf([model], language: 'zh_Hans'));
      expect(find.text('OpenAI only'), findsOneWidget);
      expect(find.text('GPT-4 only'), findsOneWidget);
    });

    testWidgets('should toggle collapsed state when clicking provider header', (t) async {
      await render(t, makeModel());
      expect(find.text('GPT-4'), findsOneWidget);
      await t.tap(named('OpenAI'));
      await settle(t);
      expect(find.text('GPT-4'), findsNothing);
      await t.tap(named('OpenAI'));
      await settle(t);
      expect(find.text('GPT-4'), findsOneWidget);
    });

    testWidgets('should show credential name when using custom provider', (t) async {
      final model = makeModel();
      await render(t, model, providers: [summaryOf(model, credentialName: 'my-api-key')]);
      expect(find.text('my-api-key'), findsOneWidget);
      expect(t.widget<StatusDot>(find.byType(StatusDot)).status, StatusDotKind.success);
    });

    testWidgets('should render the inactive credential badge when the api key is not active', (t) async {
      final model = makeModel();
      await render(t, model, providers: [summaryOf(model, credentialName: 'stale-key', usable: false)]);
      expect(find.text('stale-key'), findsOneWidget);
      expect(t.widget<StatusDot>(find.byType(StatusDot)).status, StatusDotKind.error);
    });

    testWidgets('should show configure required when no credential name', (t) async {
      await render(t, makeModel());
      expect(find.text('common.modelProvider.selector.configureRequired'), findsOneWidget);
    });

    ModelCatalog creditsCatalog(ProviderWithModels model, {required bool exhausted}) => ModelCatalog(
      providers: [
        summaryOf(model, preferredProviderType: PreferredProviderTypeEnum.system, systemConfigurationEnabled: true),
      ],
      modelLists: {
        ModelTypeEnum.textGeneration: [model],
      },
      deploymentEdition: 'CLOUD',
      trialModels: const ['openai'],
      trialCredits: TrialCredits(credits: exhausted ? 0 : 200, totalCredits: 200, isExhausted: exhausted),
    );

    testWidgets('should show credits info when using system provider with remaining credits', (t) async {
      final model = makeModel();
      await render(t, model, catalog: creditsCatalog(model, exhausted: false));
      expect(find.text('common.modelProvider.selector.aiCredits'), findsOneWidget);
    });

    testWidgets('should show credits exhausted when system provider has no credits', (t) async {
      final model = makeModel();
      await render(t, model, catalog: creditsCatalog(model, exhausted: true));
      expect(find.text('common.modelProvider.selector.creditsExhausted'), findsOneWidget);
    });
  });

  group('Popup', () {
    final anthropic = makeModel(
      provider: 'anthropic',
      label: const {'en_US': 'Anthropic', 'zh_Hans': 'Anthropic'},
      models: [
        makeModelItem(model: 'claude-3', label: const {'en_US': 'Claude 3', 'zh_Hans': 'Claude 3'}),
      ],
    );
    final openai2 = makeModel(
      models: [
        makeModelItem(),
        makeModelItem(model: 'gpt-4o', label: const {'en_US': 'GPT-4o', 'zh_Hans': 'GPT-4o'}),
      ],
    );

    testWidgets('should filter models by search and allow clearing search without blurring the input', (t) async {
      await renderPopup(t, [makeModel()]);
      expect(shownProviders(t), ['openai']);
      await t.tap(_searchField);
      await search(t, 'not-found');
      expect(textContaining(_noModel), findsOneWidget);
      await t.tap(named('common.operation.clear'));
      await settle(t);
      expect(t.widget<EditableText>(_searchField).controller.text, '');
      expect(t.widget<EditableText>(_searchField).focusNode.hasFocus, isTrue);
    });

    Future<void> byModelName(WidgetTester t) async {
      await renderPopup(t, [makeModel(), anthropic]);
      await search(t, 'claude');
      expect(shownProviders(t), ['anthropic']);
      expect(shownModels(t), ['claude-3']);
      expect(textContaining(_noModel), findsNothing);
    }

    Future<void> noMatch(WidgetTester t) async {
      await renderPopup(t, [makeModel()]);
      await search(t, 'mistral');
      expect(textContaining(_noModel), findsOneWidget);
      expect(textContaining('mistral'), findsWidgets);
      expect(shownProviders(t), isEmpty);
      expect(shownModels(t), isEmpty);
    }

    Future<void> byProviderLabel(WidgetTester t) async {
      await renderPopup(t, [openai2, anthropic]);
      await search(t, 'openai');
      expect(shownProviders(t), ['openai']);
      expect(shownModels(t), ['gpt-4', 'gpt-4o']);
    }

    Future<void> byProviderKey(WidgetTester t) async {
      await renderPopup(t, [
        makeModel(provider: 'azure_openai', label: const {'en_US': 'Azure', 'zh_Hans': 'Azure'}),
      ]);
      await search(t, 'openai');
      expect(shownProviders(t), ['azure_openai']);
      expect(shownModels(t), ['gpt-4']);
    }

    Future<void> scopeOnProviderMatch(WidgetTester t) async {
      await renderPopup(
        t,
        [
          makeModel(
            models: [
              makeModelItem(features: const [ModelFeatureEnum.vision]),
              makeModelItem(model: 'gpt-4-tool', features: const ['unknown-tool-feature']),
            ],
          ),
        ],
        scopeFeatures: const [ModelFeatureEnum.toolCall],
      );
      await search(t, 'openai');
      expect(textContaining(_noModel), findsOneWidget);
      expect(shownModels(t), isEmpty);
    }

    testWidgets('should show matching models when searching by model name with direct props', byModelName);
    testWidgets('should show empty search placeholder when direct props have no provider or model match', noMatch);
    testWidgets(
      'should show all models of a provider when searching by provider label with direct props',
      byProviderLabel,
    );
    testWidgets(
      'should match by model provider key when direct props model label does not contain the search text',
      byProviderKey,
    );
    testWidgets('should still apply scope features when direct props match by provider label', scopeOnProviderMatch);
    testWidgets('should show matching models when searching by model name', byModelName);
    testWidgets('should show empty search placeholder when no provider or model name matches', noMatch);
    testWidgets('should show all models of a provider when searching by provider label', byProviderLabel);
    testWidgets('should match by model provider key when model label does not contain the search text', byProviderKey);
    testWidgets('should still apply scope features when matching by provider label', scopeOnProviderMatch);

    testWidgets('should fuzzy match provider labels and keep all compatible provider models visible', (t) async {
      await renderPopup(t, [openai2, anthropic]);
      await search(t, 'opnai');
      expect(shownProviders(t), ['openai']);
      expect(shownModels(t), ['gpt-4', 'gpt-4o']);
    });

    testWidgets('should match model labels without expanding unmatched provider models', (t) async {
      await renderPopup(t, [
        makeModel(),
        makeModel(
          provider: 'anthropic',
          label: const {'en_US': 'Anthropic', 'zh_Hans': 'Anthropic'},
          models: [
            makeModelItem(model: 'claude-3', label: const {'en_US': 'Claude 3', 'zh_Hans': 'Claude 3'}),
            makeModelItem(
              model: 'claude-instant',
              label: const {'en_US': 'Claude Instant', 'zh_Hans': 'Claude Instant'},
            ),
          ],
        ),
      ]);
      await search(t, 'claude3');
      expect(shownProviders(t), ['anthropic']);
      expect(shownModels(t), ['claude-3']);
    });

    testWidgets('should match model names without separators', (t) async {
      final ids = [
        'gpt-5.4',
        'gpt-5.4-2026-03-05',
        'gpt-5.4-mini',
        'gpt-5.4-nano',
        'gpt-5.3-chat-latest',
        'gpt-5.2',
        'gpt-4.1',
      ];
      await renderPopup(t, [
        makeModel(
          provider: 'langgenius/openai/openai',
          models: [
            for (final id in ids) makeModelItem(model: id, label: {'en_US': id, 'zh_Hans': id}),
          ],
        ),
      ]);
      await search(t, 'gpt5.4');
      expect(shownModels(t), ['gpt-5.4', 'gpt-5.4-2026-03-05', 'gpt-5.4-mini', 'gpt-5.4-nano']);
    });

    testWidgets('should not fuzzy match unrelated providers that share the langgenius namespace', (t) async {
      await renderPopup(t, [
        makeModel(provider: 'langgenius/openai/openai'),
        makeModel(
          provider: 'langgenius/openrouter/openrouter',
          label: const {'en_US': 'OpenRouter', 'zh_Hans': 'OpenRouter'},
          models: [
            makeModelItem(model: 'openrouter-model', label: const {'en_US': 'OpenRouter Model'}),
          ],
        ),
        makeModel(
          provider: 'langgenius/openai_api_compatible/openai_api_compatible',
          label: const {'en_US': 'OpenAI-API-compatible', 'zh_Hans': 'OpenAI-API-compatible'},
          models: [
            makeModelItem(model: 'compatible-model', label: const {'en_US': 'Compatible Model'}),
          ],
        ),
      ]);
      await search(t, 'openai');
      expect(shownProviders(t), [
        'langgenius/openai/openai',
        'langgenius/openai_api_compatible/openai_api_compatible',
      ]);
    });

    testWidgets('should fuzzy match provider names without matching every langgenius provider', (t) async {
      await renderPopup(t, [
        makeModel(
          provider: 'langgenius/zhipuai/zhipuai',
          label: const {'en_US': 'ZHIPU AI', 'zh_Hans': '智谱 AI'},
          models: [
            makeModelItem(model: 'glm-4.7', label: const {'en_US': 'GLM-4.7'}),
          ],
        ),
        makeModel(
          provider: 'langgenius/gemini/google',
          label: const {'en_US': 'Gemini', 'zh_Hans': 'Gemini'},
          models: [
            makeModelItem(model: 'gemini-3-flash-preview', label: const {'en_US': 'gemini-3-flash-preview'}),
          ],
        ),
        makeModel(
          provider: 'langgenius/tongyi/tongyi',
          label: const {'en_US': 'Tongyi', 'zh_Hans': '通义'},
          models: [
            makeModelItem(model: 'qwen-plus', label: const {'en_US': 'qwen-plus'}),
          ],
        ),
      ]);
      await search(t, 'gemni');
      expect(shownProviders(t), ['langgenius/gemini/google']);
    });

    testWidgets('should toggle incompatible models from the reveal action', (t) async {
      await renderPopup(t, [
        makeModel(
          models: [
            makeModelItem(model: 'gpt-4o', label: const {'en_US': 'GPT-4o', 'zh_Hans': 'GPT-4o'}),
            makeModelItem(),
          ],
        ),
      ], modelPredicate: (_, m) => m.model != 'gpt-4');
      expect(shownModels(t), ['gpt-4o']);
      await t.tap(named('common.modelProvider.selector.showIncompatibleModels'));
      await settle(t);
      expect(shownModels(t), ['gpt-4o', 'gpt-4']);
      expect(named('common.modelProvider.selector.showIncompatibleModels'), findsNothing);
      await t.tap(named('common.modelProvider.selector.hideIncompatibleModels'));
      await settle(t);
      expect(shownModels(t), ['gpt-4o']);
      expect(named('common.modelProvider.selector.showIncompatibleModels'), findsOneWidget);
    });

    testWidgets('should not show compatible-only helper text when no scope features are applied', (t) async {
      await renderPopup(t, [makeModel()]);
      expect(find.text('common.modelProvider.selector.onlyCompatibleModelsShown'), findsNothing);
    });

    testWidgets('should show compatible-only helper text when scope features are applied', (t) async {
      await renderPopup(t, [makeModel()], scopeFeatures: const [ModelFeatureEnum.vision]);
      expect(find.text('common.modelProvider.selector.onlyCompatibleModelsShown'), findsOneWidget);
    });

    testWidgets('should keep search and footer outside the scrollable model list', (t) async {
      await renderPopup(
        t,
        [makeModel()],
        onOpenProviderSettings: () {},
        scopeFeatures: const [ModelFeatureEnum.vision],
      );
      final scroll = find.byType(SingleChildScrollView);
      expect(find.descendant(of: scroll, matching: find.byType(ModelSearchInput)), findsNothing);
      expect(
        find.descendant(of: scroll, matching: named('common.modelProvider.selector.modelProviderSettings')),
        findsNothing,
      );
      expect(
        find.descendant(of: scroll, matching: find.text('common.modelProvider.selector.onlyCompatibleModelsShown')),
        findsOneWidget,
      );
    });

    testWidgets('should filter by scope features including toolCall and non-toolCall checks', (t) async {
      final both = [
        makeModel(
          models: [
            makeModelItem(features: const [ModelFeatureEnum.toolCall, ModelFeatureEnum.vision]),
          ],
        ),
      ];
      final noTool = [
        makeModel(
          models: [
            makeModelItem(features: const [ModelFeatureEnum.vision]),
          ],
        ),
      ];
      await renderPopup(t, noTool, scopeFeatures: const [ModelFeatureEnum.toolCall, ModelFeatureEnum.vision]);
      expect(textContaining(_noModel), findsOneWidget);
      await renderPopup(t, both, scopeFeatures: const [ModelFeatureEnum.toolCall, ModelFeatureEnum.vision]);
      expect(shownProviders(t), ['openai']);
      await renderPopup(t, both, scopeFeatures: const [ModelFeatureEnum.vision]);
      expect(shownProviders(t), ['openai']);
      await renderPopup(t, [makeModel()], scopeFeatures: const [ModelFeatureEnum.vision]);
      expect(textContaining(_noModel), findsOneWidget);
    });

    testWidgets('should match model labels from fallback languages when current language key is missing', (t) async {
      await renderPopup(t, [
        makeModel(
          models: [
            makeModelItem(label: const {'en_US': 'OpenAI GPT', 'zh_Hans': 'OpenAI GPT'}),
          ],
        ),
      ], language: 'fr_FR');
      await search(t, 'openai');
      expect(shownProviders(t), ['openai']);
    });

    testWidgets('should hide the provider settings action when requested by the owner', (t) async {
      await renderPopup(t, [makeModel()]);
      expect(find.text('common.modelProvider.selector.modelProviderSettings'), findsNothing);
    });

    testWidgets('should expose popup actions in the dialog tab sequence without a listbox', (t) async {
      await renderPopup(t, const [], onConfigureEmptyState: () {}, onOpenProviderSettings: () {});
      await t.tap(_searchField);
      await settle(t);
      String? focusedLabel() {
        String? label;
        FocusManager.instance.primaryFocus?.context?.visitAncestorElements((e) {
          if (e.widget is DifyPressable) {
            label = (e.widget as DifyPressable).semanticLabel;
            return false;
          }
          return true;
        });
        return label;
      }

      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await settle(t);
      expect(focusedLabel(), 'common.modelProvider.selector.configure');
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await settle(t);
      expect(focusedLabel(), 'common.modelProvider.selector.modelProviderSettings');
    });

    testWidgets('should open provider settings from empty state when no providers are configured', (t) async {
      var configured = 0;
      await renderPopup(t, const [], onConfigureEmptyState: () => configured++);
      expect(find.text('common.modelProvider.selector.noProviderConfigured'), findsOneWidget);
      expect(find.text('common.modelProvider.selector.noProviderConfiguredDesc'), findsOneWidget);
      await t.tap(find.text('common.modelProvider.selector.configure'));
      expect(configured, 1);
    });

    testWidgets('should sort the selected provider to the top when a default model is provided', (t) async {
      await renderPopup(
        t,
        [
          makeModel(),
          makeModel(provider: 'anthropic', label: const {'en_US': 'Anthropic', 'zh_Hans': 'Anthropic'}),
        ],
        defaultModel: (provider: 'anthropic', model: 'claude-3'),
      );
      expect(shownProviders(t).first, 'anthropic');
    });
  });
}
