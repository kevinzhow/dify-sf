// dify-spec: web/app/components/header/account-setting/model-provider-page/provider-added-card/__tests__/model-list-item.spec.tsx
import 'dart:async';

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
  double width = 900,
}) {
  api = RecordingModelsApi();
  changes.clear();
  return renderSettings(
    t,
    Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: width,
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

    testWidgets('custom model removal is visible without hover and cancellation keeps the model', (t) async {
      final model = ModelItem.fromJson(modelJson('custom-model', fetchFrom: 'customizable-model'));
      await render(t, model, isConfigurable: true, width: 300);
      final remove = find.byKey(const ValueKey('model-remove-custom-model'));
      expect(remove, findsOneWidget);
      expect(t.takeException(), isNull);
      await t.tap(remove);
      await settle(t);
      expect(find.textContaining('Saved credentials remain'), findsOneWidget);
      expect(api.callsOf('removeCustomModel'), isEmpty);
      await t.tap(find.byKey(const ValueKey('alert-cancel')));
      await settle(t);
      expect(api.callsOf('removeCustomModel'), isEmpty);
      expect(changes, isEmpty);
      expect(t.widget<DifyIconButton>(remove).disabled, isFalse);
    });

    testWidgets('confirmed removal targets the selected model and type while retaining credentials', (t) async {
      final model = ModelItem.fromJson(
        modelJson('embedding-model', modelType: 'text-embedding', fetchFrom: 'customizable-model'),
      );
      await render(t, model, isConfigurable: true);
      await t.tap(find.byKey(const ValueKey('model-remove-embedding-model')));
      await settle(t);
      expect(find.textContaining('embedding-model'), findsWidgets);
      await t.tap(find.byKey(const ValueKey('alert-confirm')));
      await settle(t);
      expect(api.callsOf('removeCustomModel'), [
        {'provider': 'test-provider', 'model': 'embedding-model', 'modelType': 'text-embedding'},
      ]);
      expect(api.callsOf('deleteModelCredential'), isEmpty);
      expect(api.callsOf('deleteProviderCredential'), isEmpty);
      expect(changes, ['test-provider']);
      expect(api.callsOf('summaries'), isNotEmpty);
    });

    testWidgets('system models and users without model configuration permission have no removal action', (t) async {
      await render(t, mockModel, isConfigurable: true);
      expect(find.byType(DifyIconButton), findsNothing);
      final custom = ModelItem.fromJson(modelJson('custom-model', fetchFrom: 'customizable-model'));
      await render(t, custom, isConfigurable: true, permissionKeys: const ['credential.manage', 'credential.use']);
      expect(find.byKey(const ValueKey('model-remove-custom-model')), findsNothing);
    });

    testWidgets('a failed removal stays open for retry and a pending removal is sent once', (t) async {
      final model = ModelItem.fromJson(modelJson('custom-model', fetchFrom: 'customizable-model'));
      await render(t, model, isConfigurable: true);
      api.fail['removeCustomModel'] = StateError('fixture failure');
      await t.tap(find.byKey(const ValueKey('model-remove-custom-model')));
      await settle(t);
      final confirm = find.byKey(const ValueKey('alert-confirm'));
      await t.tap(confirm);
      await settle(t);
      expect(confirm, findsOneWidget);
      expect(changes, isEmpty);
      api.fail.remove('removeCustomModel');
      final gate = Completer<void>();
      api.hold['removeCustomModel'] = gate;
      await t.tap(confirm);
      await settle(t);
      await t.tap(confirm);
      await settle(t);
      expect(api.callsOf('removeCustomModel'), hasLength(2));
      gate.complete();
      await settle(t);
      expect(find.byKey(const ValueKey('alert-dialog')), findsNothing);
      expect(changes, ['test-provider']);
    });
  });
}
