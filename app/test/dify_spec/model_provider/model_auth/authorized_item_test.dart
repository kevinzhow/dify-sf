// dify-spec: web/app/components/header/account-setting/model-provider-page/model-auth/authorized/__tests__/authorized-item.spec.tsx
import 'package:dify_sf_app/src/cards/model_chip.dart' show ModelIcon;
import 'package:dify_sf_app/src/settings/model_provider/model_auth.dart';
import 'package:dify_sf_app/src/workflow/model_catalog.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/model_fakes.dart';
import '../_settings_harness.dart';

const mockProvider = <String, Object?>{'provider': 'openai'};
const mockCredentials = [
  Credential(credentialId: 'cred-1', credentialName: 'API Key 1'),
  Credential(credentialId: 'cred-2', credentialName: 'API Key 2'),
];
const mockModel = (model: 'gpt-4', modelType: ModelTypeEnum.textGeneration);

Future<void> render(WidgetTester t, Widget item) => renderSettings(
  t,
  Align(
    alignment: Alignment.topLeft,
    child: SizedBox(width: 360, child: item),
  ),
  env: envOf(RecordingModelsApi()),
);

void main() {
  group('AuthorizedItem', () {
    group('Rendering', () {
      testWidgets('should render credentials list', (t) async {
        await render(t, const AuthorizedItem(provider: mockProvider, credentials: mockCredentials));
        expect(find.byKey(const ValueKey('credential-item-cred-1')), findsOneWidget);
        expect(find.byKey(const ValueKey('credential-item-cred-2')), findsOneWidget);
        expect(find.text('API Key 1'), findsOneWidget);
        expect(find.text('API Key 2'), findsOneWidget);
      });

      testWidgets('should render model title when showModelTitle is true', (t) async {
        await render(
          t,
          const AuthorizedItem(
            provider: mockProvider,
            credentials: mockCredentials,
            model: mockModel,
            showModelTitle: true,
          ),
        );
        expect(find.byType(ModelIcon), findsOneWidget);
        expect(t.widget<ModelIcon>(find.byType(ModelIcon)).modelName, 'gpt-4');
        expect(find.text('gpt-4'), findsOneWidget);
      });

      testWidgets('should not render model title when showModelTitle is false', (t) async {
        await render(t, const AuthorizedItem(provider: mockProvider, credentials: mockCredentials, model: mockModel));
        expect(find.byType(ModelIcon), findsNothing);
      });

      testWidgets('should render custom title instead of model name', (t) async {
        await render(
          t,
          const AuthorizedItem(
            provider: mockProvider,
            credentials: mockCredentials,
            model: mockModel,
            title: 'Custom Title',
            showModelTitle: true,
          ),
        );
        expect(find.text('Custom Title'), findsOneWidget);
      });

      testWidgets('should handle empty credentials array', (t) async {
        await render(t, const AuthorizedItem(provider: mockProvider, credentials: []));
        expect(find.byType(CredentialItem), findsNothing);
      });
    });

    group('Callback Propagation', () {
      testWidgets('should pass onEdit callback to credential items', (t) async {
        final edits = <(Credential?, Object?)>[];
        await render(
          t,
          AuthorizedItem(
            provider: mockProvider,
            credentials: mockCredentials,
            model: mockModel,
            onEdit: (c, m) => edits.add((c, m)),
          ),
        );
        t.widget<CredentialItem>(find.byType(CredentialItem).first).onEdit!(mockCredentials[0]);
        expect(edits, [(mockCredentials[0], mockModel)]);
      });

      testWidgets('should pass onDelete callback to credential items', (t) async {
        final deletes = <(Credential?, Object?)>[];
        await render(
          t,
          AuthorizedItem(
            provider: mockProvider,
            credentials: mockCredentials,
            model: mockModel,
            onDelete: (c, m) => deletes.add((c, m)),
          ),
        );
        t.widget<CredentialItem>(find.byType(CredentialItem).first).onDelete!(mockCredentials[0]);
        expect(deletes, [(mockCredentials[0], mockModel)]);
      });

      testWidgets('should pass onItemClick callback to credential items', (t) async {
        final clicks = <(Credential, Object?)>[];
        await render(
          t,
          AuthorizedItem(
            provider: mockProvider,
            credentials: mockCredentials,
            model: mockModel,
            onItemClick: (c, m) => clicks.add((c, m)),
          ),
        );
        await t.tap(find.text('API Key 1'));
        expect(clicks, [(mockCredentials[0], mockModel)]);
      });
    });
  });
}
