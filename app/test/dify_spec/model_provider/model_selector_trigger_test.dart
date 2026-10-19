// dify-spec: web/app/components/header/account-setting/model-provider-page/model-selector/__tests__/model-selector-trigger.spec.tsx

import 'package:dify_sf_app/src/cards/model_chip.dart';
import 'package:dify_sf_app/src/design/dify_tokens.g.dart';
import 'package:dify_sf_app/src/workflow/model_catalog.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ModelItem createModelItem({String status = ModelStatusEnum.active}) => ModelItem(
  model: 'gpt-4',
  label: const {'en_US': 'GPT-4', 'zh_Hans': 'GPT-4'},
  features: const [ModelFeatureEnum.vision],
  status: status,
  modelProperties: const {'mode': 'chat', 'context_size': 4096},
);

const _icons = (
  light: {'en_US': 'https://example.com/openai-light.png', 'zh_Hans': 'https://example.com/openai-light.png'},
  dark: {'en_US': 'https://example.com/openai-dark.png', 'zh_Hans': 'https://example.com/openai-dark.png'},
);

ProviderWithModels createModel() => ProviderWithModels(
  provider: 'openai',
  iconSmall: _icons.light,
  iconSmallDark: _icons.dark,
  label: const {'en_US': 'OpenAI', 'zh_Hans': 'OpenAI'},
  models: [createModelItem()],
);

/// What the mocked summary query resolves the provider to.
const mockResolvedProvider = ModelProvider(
  provider: 'openai',
  iconSmall: {'en_US': 'https://example.com/openai-light.png', 'zh_Hans': 'https://example.com/openai-light.png'},
  label: {'en_US': 'OpenAI', 'zh_Hans': 'OpenAI'},
);

CredentialPanelState state({
  CardVariant variant = CardVariant.creditsActive,
  UsagePriority priority = UsagePriority.credits,
  bool supportsCredits = true,
  bool hasCredentials = false,
  bool isCreditsExhausted = false,
  String? credentialName,
  num credits = 100,
}) => CredentialPanelState(
  variant: variant,
  priority: priority,
  supportsCredits: supportsCredits,
  showPrioritySwitcher: true,
  hasCredentials: hasCredentials,
  isCreditsExhausted: isCreditsExhausted,
  credentialName: credentialName,
  credits: credits,
);

late CredentialPanelState Function(ModelProvider?) mockUseCredentialPanelState;
final credentialPanelCalls = <ModelProvider?>[];

Future<void> render(
  WidgetTester t, {
  ProviderWithModels? currentProvider,
  ModelItem? currentModel,
  DefaultModel? defaultModel,
  bool disabled = false,
  bool isModelCompatible = true,
}) => t.pumpWidget(
  MaterialApp(
    home: Material(
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 400,
          child: ModelSelectorTrigger(
            currentProvider: currentProvider,
            currentModel: currentModel,
            defaultModel: defaultModel,
            resolvedProvider: mockResolvedProvider,
            credentialPanelOf: (p) {
              credentialPanelCalls.add(p);
              return mockUseCredentialPanelState(p);
            },
            disabled: disabled,
            isModelCompatible: isModelCompatible,
          ),
        ),
      ),
    ),
  ),
);

ModelSelectorTrigger getTrigger(WidgetTester t) => t.widget(find.byType(ModelSelectorTrigger));

bool enabled(WidgetTester t) => t
    .widget<Semantics>(find.descendant(of: find.byType(ModelSelectorTrigger), matching: find.byType(Semantics)).first)
    .properties
    .enabled!;

Color? background(WidgetTester t) {
  final c = t.widget<Container>(
    find.descendant(of: find.byType(ModelSelectorTrigger), matching: find.byType(Container)).first,
  );
  return (c.decoration! as BoxDecoration).color;
}

Future<void> hover(WidgetTester t, Finder f) async {
  final gesture = await t.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: Offset.zero);
  addTearDown(gesture.removePointer);
  await gesture.moveTo(t.getCenter(f));
  // DifyTooltip is Base UI's Tooltip: `delay` 300 ms before it opens, then a 150 ms fade. `pumpAndSettle` alone
  // does not advance the delay timer.
  await t.pump(const Duration(milliseconds: 350));
  await t.pumpAndSettle();
}

void main() {
  group('ModelSelectorTrigger', () {
    setUp(() {
      credentialPanelCalls.clear();
      mockUseCredentialPanelState = (_) => state();
    });

    group('Rendering', () {
      testWidgets('should render empty state when no model is selected', (t) async {
        await render(t);

        expect(find.text('Configure model'), findsOneWidget);
        expect(enabled(t), isTrue);
      });

      testWidgets('should render selected model details when model is active', (t) async {
        await render(t, currentProvider: createModel(), currentModel: createModelItem());

        expect(find.text('GPT-4'), findsOneWidget);
        expect(find.text('CHAT'), findsOneWidget);
        expect(enabled(t), isTrue);
      });

      testWidgets('should render deprecated default model and disabled style when selection is missing', (t) async {
        await render(t, defaultModel: (provider: 'openai', model: 'legacy-model'));

        expect(find.text('legacy-model'), findsOneWidget);
        expect(find.text('Incompatible'), findsOneWidget);
        expect(background(t), DifyColors.componentsInputBgDisabled);
      });
    });

    group('Props', () {
      testWidgets('should disable the combobox trigger', (t) async {
        await render(t, currentProvider: createModel(), currentModel: createModelItem(), disabled: true);

        expect(enabled(t), isFalse);
      });
    });

    group('Status Handling', () {
      testWidgets('should show status badge when selected model is not active and enabled', (t) async {
        await render(
          t,
          currentProvider: createModel(),
          currentModel: createModelItem(status: ModelStatusEnum.noConfigure),
        );

        expect(find.text('Configure required'), findsOneWidget);
        expect(getTrigger(t).status.value, 'configure-required');
        expect(background(t), DifyColors.componentsInputBgDisabled);
      });

      testWidgets('should show credits exhausted state when model quota is exceeded', (t) async {
        mockUseCredentialPanelState = (_) =>
            state(variant: CardVariant.creditsExhausted, isCreditsExhausted: true, credits: 0);

        await render(t, currentProvider: createModel(), currentModel: createModelItem());

        expect(find.text('Credits exhausted'), findsOneWidget);
        expect(find.text('CHAT'), findsNothing);
      });

      testWidgets('should hide model meta when api key is unavailable', (t) async {
        mockUseCredentialPanelState = (_) => state(
          variant: CardVariant.apiUnavailable,
          priority: UsagePriority.apiKey,
          hasCredentials: true,
          credentialName: 'Primary Key',
          credits: 0,
        );

        await render(t, currentProvider: createModel(), currentModel: createModelItem());

        expect(find.text('API Key unavailable'), findsOneWidget);
        expect(find.text('CHAT'), findsNothing);
        expect(background(t), DifyColors.componentsInputBgDisabled);
      });

      testWidgets('should show disabled badge when selected model is disabled', (t) async {
        await render(
          t,
          currentProvider: createModel(),
          currentModel: createModelItem(status: ModelStatusEnum.disabled),
        );

        expect(find.text('Disabled'), findsOneWidget);
        expect(find.text('CHAT'), findsNothing);
      });

      testWidgets('should not show status badge when selected model is disabled', (t) async {
        await render(
          t,
          currentProvider: createModel(),
          currentModel: createModelItem(status: ModelStatusEnum.noConfigure),
          disabled: true,
        );

        expect(find.text('Configure required'), findsNothing);
      });

      testWidgets('should show incompatible tooltip when hovering no-permission status badge', (t) async {
        await render(
          t,
          currentProvider: createModel(),
          currentModel: createModelItem(status: ModelStatusEnum.noPermission),
        );

        expect(find.text('CHAT'), findsNothing);
        expect(background(t), DifyColors.componentsInputBgDisabled);
        final gesture = await t.createGesture(kind: PointerDeviceKind.mouse);
        await gesture.addPointer(location: Offset.zero);
        addTearDown(gesture.removePointer);
        await gesture.moveTo(t.getCenter(find.text('Incompatible')));
        // The delay itself (nothing before 300 ms) is asserted in the variable-label tooltip test; Base UI's delay
        // group makes the next tooltip open at once, so the exact wait is not this test's subject.
        await t.pump(const Duration(milliseconds: 400));
        await t.pumpAndSettle();
        expect(find.text(DerivedModelStatus.incompatibleTip), findsOneWidget);
        // Away from both the trigger and the popup (placement top puts it over the top-left corner).
        await gesture.moveTo(t.getBottomRight(find.byType(MaterialApp)) + const Offset(-4, -4));
        await t.pump(const Duration(milliseconds: 600));
        await t.pumpAndSettle();
        expect(find.text(DerivedModelStatus.incompatibleTip), findsNothing, reason: 'closed when the pointer leaves');
      });

      testWidgets('should show incompatible badge when selected model fails the compatibility predicate', (t) async {
        await render(t, currentProvider: createModel(), currentModel: createModelItem(), isModelCompatible: false);

        expect(find.text('Incompatible'), findsOneWidget);
        expect(find.text('CHAT'), findsNothing);
      });
    });

    group('Edge Cases', () {
      testWidgets('should show incompatible badge for deprecated selection', (t) async {
        await render(t, defaultModel: (provider: 'openai', model: 'legacy-model'));

        expect(find.text('Incompatible'), findsOneWidget);
        await hover(t, find.text('Incompatible'));

        expect(find.text(DerivedModelStatus.incompatibleTip), findsOneWidget);
      });

      // dart format off
      testWidgets('should show credits exhausted badge for deprecated selection when ai credits are exhausted without api key', (t) async {
      // dart format on
          mockUseCredentialPanelState = (provider) => state(
            variant: provider != null ? CardVariant.noUsage : CardVariant.creditsActive,
            priority: provider != null ? UsagePriority.apiKey : UsagePriority.credits,
            supportsCredits: provider != null,
            isCreditsExhausted: provider != null,
            credits: provider != null ? 0 : 100,
          );

          await render(t, defaultModel: (provider: 'openai', model: 'legacy-model'));

          expect(credentialPanelCalls.any((p) => p?.provider == 'openai'), isTrue);
          expect(find.text('Credits exhausted'), findsOneWidget);
          await hover(t, find.text('Credits exhausted'));

          expect(find.text(DerivedModelStatus.creditsExhausted.tooltip!), findsOneWidget);
        },
      );
    });
  });
}
