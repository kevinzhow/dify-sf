// dify-spec: web/app/components/header/account-setting/model-provider-page/provider-added-card/__tests__/model-list-item.spec.tsx
import 'package:dify_sf_app/src/cards/model_chip.dart' show ModelIcon, ModelName;
import 'package:dify_sf_app/src/design/dify_tokens.g.dart';
import 'package:dify_sf_app/src/settings/model_provider/model_list.dart';
import 'package:dify_sf_app/src/workflow/model_catalog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/model_fakes.dart';
import '../_settings_harness.dart';

import 'package:dify_sf_app/src/design/widgets/widgets.dart';

const mockProvider = <String, Object?>{'provider': 'test-provider'};
final mockModel = ModelItem.fromJson(modelJson('gpt-4', fetchFrom: 'system'));
ModelItem withModel({String? status, bool? deprecated}) => ModelItem.fromJson(
  modelJson('gpt-4', fetchFrom: 'system', status: status ?? 'active', deprecated: deprecated ?? false),
);

late RecordingModelsApi api;
final changes = <String>[];

Future<void> render(
  WidgetTester t,
  ModelItem model, {
  bool isConfigurable = false,
  List<String> permissionKeys = const ['plugin.model_config'],
}) {
  api = RecordingModelsApi();
  changes.clear();
  return renderSettings(
    t,
    Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: 900,
        child: ModelListItem(
          model: model,
          provider: mockProvider,
          isConfigurable: isConfigurable,
          onChange: changes.add,
        ),
      ),
    ),
    env: envOf(api, permissionKeys: permissionKeys),
  );
}

Finder get statusSwitch => find.byType(DifySwitch);

void main() {
  group('ModelListItem', () {
    testWidgets('should render model item with icon and name', (t) async {
      await render(t, mockModel);
      expect(find.byType(ModelIcon), findsOneWidget);
      expect(find.byType(ModelName), findsOneWidget);
    });

    testWidgets('should disable an active model when switch is clicked', (t) async {
      await render(t, mockModel);
      await t.tap(statusSwitch);
      await settle(t);
      expect(api.callsOf('disableModel'), [
        {'provider': 'test-provider', 'model': 'gpt-4', 'modelType': 'llm'},
      ]);
      expect(changes, ['test-provider']);
    });

    testWidgets('should enable a disabled model when switch is clicked', (t) async {
      await render(t, withModel(status: ModelStatusEnum.disabled));
      await t.tap(statusSwitch);
      await settle(t);
      expect(api.callsOf('enableModel'), [
        {'provider': 'test-provider', 'model': 'gpt-4', 'modelType': 'llm'},
      ]);
      expect(changes, ['test-provider']);
    });

    testWidgets('should allow model status and load balancing controls with plugin.model_config', (t) async {
      // The status switch (load balancing is not part of dify-sf).
      await render(t, mockModel, isConfigurable: true);
      expect(statusSwitch, findsOneWidget);
    });

    testWidgets('should hide model status and load balancing controls without plugin.model_config', (t) async {
      await render(t, mockModel, isConfigurable: true, permissionKeys: const []);
      expect(statusSwitch, findsNothing);
    });

    testWidgets('should show deprecated model with opacity and disabled switch', (t) async {
      await render(t, withModel(deprecated: true));
      expect(find.byWidgetPredicate((w) => w is Opacity && w.opacity == 0.6), findsOneWidget);
      expect(t.widget<ModelName>(find.byType(ModelName)).lineThrough, isTrue);
      expect(t.widget<DifySwitch>(statusSwitch).disabled, isTrue);
      expect(t.widget<DifySwitch>(statusSwitch).checked, isFalse);
    });

    testWidgets('should disable switch and hide ConfigModel when status is credentialRemoved', (t) async {
      await render(t, withModel(status: ModelStatusEnum.credentialRemoved));
      expect(t.widget<DifySwitch>(statusSwitch).disabled, isTrue);
      await t.tap(statusSwitch);
      await settle(t);
      expect(t.widget<DifySwitch>(statusSwitch).checked, isFalse);
      expect(api.callsOf('enableModel'), isEmpty);
      expect(api.callsOf('disableModel'), isEmpty);
    });

    testWidgets('should apply hover class when isConfigurable is true', (t) async {
      await render(t, mockModel, isConfigurable: true);
      await hover(t, find.byType(ModelListItem));
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is Container && (w.decoration as BoxDecoration?)?.color == DifyColors.componentsPanelOnPanelItemBgHover,
        ),
        findsOneWidget,
      );
    });
  });
}
