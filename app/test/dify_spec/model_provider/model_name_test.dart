// dify-spec: web/app/components/header/account-setting/model-provider-page/model-name/__tests__/index.spec.tsx
import 'package:dify_sf_app/src/cards/model_chip.dart';
import 'package:dify_sf_app/src/workflow/model_catalog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

var mockLocale = 'en-US';

ModelItem createModelItem({
  I18nText label = const {'en_US': 'English Model', 'zh_Hans': 'Chinese Model'},
  String modelType = ModelTypeEnum.textGeneration,
  List<String> features = const [],
  Map<String, Object?> modelProperties = const {},
}) => ModelItem(
  model: 'gpt-4o',
  label: label,
  modelType: modelType,
  features: features,
  modelProperties: modelProperties,
);

Future<void> render(WidgetTester t, Widget w) => t.pumpWidget(
  MaterialApp(
    home: Material(
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(width: 600, child: w),
      ),
    ),
  ),
);

void main() {
  group('ModelName', () {
    setUp(() => mockLocale = 'en-US');

    group('rendering', () {
      testWidgets('should render nothing while the model is unavailable', (t) async {
        await render(t, const ModelName(modelItem: null));

        expect(find.byType(Text), findsNothing);
        expect(t.getSize(find.byType(ModelName)).height, 0);
      });

      testWidgets('should render the localized model label when translation exists', (t) async {
        mockLocale = 'zh-Hans';
        await render(t, ModelName(modelItem: createModelItem(), language: languageOfLocale(mockLocale)));

        expect(find.text('Chinese Model'), findsOneWidget);
      });

      testWidgets('should fall back to en_US label when localized label is missing', (t) async {
        mockLocale = 'fr-FR';
        final modelItem = createModelItem(label: const {'en_US': 'English Only', 'zh_Hans': 'Chinese Model'});
        await render(t, ModelName(modelItem: modelItem, language: languageOfLocale(mockLocale)));

        expect(find.text('English Only'), findsOneWidget);
      });
    });

    group('badges', () {
      testWidgets('should show model type, mode, and context size when enabled', (t) async {
        final modelItem = createModelItem(
          modelType: ModelTypeEnum.textEmbedding,
          modelProperties: const {'mode': 'chat', 'context_size': 2000},
        );
        await render(t, ModelName(modelItem: modelItem, showModelType: true, showMode: true, showContextSize: true));

        expect(find.text('TEXT EMBEDDING'), findsOneWidget);
        expect(find.text('CHAT'), findsOneWidget);
        expect(find.text('2K'), findsOneWidget);
      });

      testWidgets('should render feature labels when showFeaturesLabel is enabled', (t) async {
        final modelItem = createModelItem(features: const [ModelFeatureEnum.vision, ModelFeatureEnum.audio]);
        await render(t, ModelName(modelItem: modelItem, showFeatures: true, showFeaturesLabel: true));

        // ModelBadge is `system-2xs-medium-uppercase`: "Vision" and "Audio" are drawn upper-cased.
        expect(find.text('VISION'), findsOneWidget);
        expect(find.text('AUDIO'), findsOneWidget);
      });
    });
  });
}
