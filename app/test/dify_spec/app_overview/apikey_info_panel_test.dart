// dify-spec: web/app/components/app/overview/apikey-info-panel/__tests__/index.spec.tsx
import 'package:dify_sf_app/src/app_detail/overview/apikey_info_panel.dart';
import 'package:dify_sf_app/src/workflow/workspace_models.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

/// The workspace's LLM providers (`models/model-types/llm`), one `openai` provider when [active].
class _Models extends Fake implements ModelProvidersApi {
  _Models({required this.active});
  final bool active;

  @override
  Future<List<Map<String, Object?>>> modelsOfType(String modelType) async => [
    if (active && modelType == 'llm')
      {
        'provider': 'openai',
        'tenant_id': 'test-workspace',
        'label': {'en_US': 'OpenAI'},
        'status': 'active',
        'models': <Object?>[],
      },
  ];
}

class _Calls {
  final settings = <String>[];
  final urls = <String>[];
}

Future<_Calls> _render(WidgetTester t, {required bool active}) async {
  final calls = _Calls();
  final models = WorkspaceModels(_Models(active: active), fixedLanguage: 'en_US');
  addTearDown(models.dispose);
  await renderOverview(
    t,
    ApikeyInfoPanel(
      models: models,
      openProviderSettings: () => calls.settings.add('provider'),
      openUrl: calls.urls.add,
    ),
  );
  return calls;
}

Finder get _panel => find.byKey(const ValueKey('apikey-info-panel'));

void main() {
  group('APIKeyInfoPanel - Community Edition', () {
    testWidgets('hides the panel when an API key already exists', (t) async {
      await _render(t, active: true);
      expect(_panel, findsNothing);
    });

    testWidgets('opens provider settings from the primary action', (t) async {
      final calls = await _render(t, active: false);
      expect(find.text('appOverview.apiKeyInfo.selfHost.title.row1'), findsOneWidget);
      expect(find.text('appOverview.apiKeyInfo.selfHost.title.row2'), findsOneWidget);
      await tapButton(t, 'appOverview.apiKeyInfo.setAPIBtn');
      expect(calls.settings, ['provider']);
    });

    testWidgets('links self-hosted users to Dify Cloud safely', (t) async {
      final calls = await _render(t, active: false);
      final link = find.semantics.byPredicate(
        (n) => n.getSemanticsData().flagsCollection.isLink && n.label == 'appOverview.apiKeyInfo.tryCloud',
      );
      expect(link, findsOneWidget);
      await t.tap(find.text('appOverview.apiKeyInfo.tryCloud'));
      // `target="_blank" rel="noopener noreferrer"`: opened outside the app.
      expect(calls.urls, [difyCloudAppsUrl]);
    });

    testWidgets('dismisses the panel from the close action', (t) async {
      await _render(t, active: false);
      await t.tap(find.byKey(const ValueKey('apikey-info-panel-close')));
      await t.pump();
      expect(_panel, findsNothing);
    });
  });
}
