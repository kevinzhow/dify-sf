// dify-spec: web/app/components/base/qrcode/__tests__/index.spec.tsx
// dify-spec: web/app/components/api-key/__tests__/api-key-modal.spec.tsx
import 'dart:typed_data';

import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/app_detail/access/access_point_card.dart';
import 'package:dify_sf_app/src/app_detail/access/api_key_modal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

const _content = 'https://example.com';

SemanticsFinder get _img => find.semantics.byPredicate((n) => n.getSemanticsData().flagsCollection.isImage);

Future<void> _openQr(WidgetTester t) => tapButton(t, 'appOverview.overview.appInfo.qrcode.title');

/// The modal for app `app-123` on [api], as the button opens it.
Future<AppApiKeysQuery> _renderModal(WidgetTester t, RecordingAccessApi api, {bool canManage = true}) async {
  final query = AppApiKeysQuery(api: api, appId: 'app-123');
  await renderMembers(
    t,
    Builder(
      builder: (context) => Center(
        child: TextButton(
          onPressed: () => showApiKeyModal(context, query: query, canManage: canManage),
          child: const Text('open'),
        ),
      ),
    ),
  );
  await t.tap(find.text('open'));
  await settle(t);
  return query;
}

void main() {
  group('ShareQRCode', () {
    testWidgets('uses caller-provided labels instead of App-specific defaults', (t) async {
      await renderMembers(
        t,
        const Center(
          child: ShareQrCode(
            content: _content,
            triggerLabel: 'Show QR code',
            scanLabel: 'Scan to share',
            downloadLabel: 'Download QR code',
          ),
        ),
      );
      await tapButton(t, 'Show QR code');
      expect(find.text('Scan to share'), findsOneWidget);
      expect(button('Download QR code').evaluate(), hasLength(1));
    });

    group('Rendering', () {
      testWidgets('renders correctly', (t) async {
        await renderMembers(t, const Center(child: ShareQrCode(content: _content)));
        expect(button('appOverview.overview.appInfo.qrcode.title').evaluate(), hasLength(1));
      });
    });

    group('Interaction', () {
      testWidgets('toggles QR code panel when clicking the icon', (t) async {
        await renderMembers(t, const Center(child: ShareQrCode(content: _content)));
        expect(_img, findsNothing);
        await _openQr(t);
        expect(_img, findsOneWidget);
        expect(button('appOverview.overview.appInfo.qrcode.download').evaluate(), hasLength(1));
        expect(find.text('appOverview.overview.appInfo.qrcode.scan'), findsNothing);
        await _openQr(t);
        expect(_img, findsNothing);
      });

      testWidgets('closes panel when clicking outside', (t) async {
        await renderMembers(
          t,
          const Column(
            children: [
              Text('Outside'),
              SizedBox(height: 100),
              ShareQrCode(content: _content),
            ],
          ),
        );
        await _openQr(t);
        expect(_img, findsOneWidget);
        await t.tap(find.text('Outside'));
        await settle(t);
        expect(_img, findsNothing);
      });

      testWidgets('does not close panel when clicking inside the panel', (t) async {
        await renderMembers(t, const Center(child: ShareQrCode(content: _content)));
        await _openQr(t);
        await t.tap(find.byKey(const ValueKey('qrcode-panel')));
        await settle(t);
        expect(_img, findsOneWidget);
      });

      testWidgets('calls downloadUrl when clicking download', (t) async {
        final saved = <(String, Uint8List, String)>[];
        await renderMembers(
          t,
          Center(
            child: ShareQrCode(content: _content, save: (name, bytes, mime) async => saved.add((name, bytes, mime))),
          ),
        );
        await _openQr(t);
        await t.runAsync(() async {
          await tapButton(t, 'appOverview.overview.appInfo.qrcode.download');
          for (var i = 0; i < 20 && saved.isEmpty; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
        });
        expect(saved.single.$1, 'qrcode.png');
        expect(saved.single.$3, 'image/png');
        // A PNG (its signature).
        expect(saved.single.$2.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
      });
    });
  });

  group('ApiKeyModal', () {
    testWidgets('loads and renders app API keys through the generated query input', (t) async {
      final api = RecordingAccessApi(
        keys: const [AppApiKey(id: 'app-key-1', token: 'app-secret-token-123456789', createdAt: 1)],
      );
      await _renderModal(t, api);
      expect(find.text('app...cret-token-123456789'), findsOneWidget);
      expect(api.callsOf('listApiKeys'), [
        ['app-123'],
      ]);
    });

    testWidgets('creates an app API key through the generated mutation input', (t) async {
      final api = RecordingAccessApi();
      await _renderModal(t, api);
      await tapButton(t, 'appApi.apiKeyModal.createNewSecretKey');
      expect(api.callsOf('createApiKey'), [
        ['app-123'],
      ]);
      final input = find.descendant(
        of: find.byKey(const ValueKey('created-api-key')),
        matching: find.byType(EditableText),
      );
      expect(t.widget<EditableText>(input).controller.text, 'new-app-token-123');
      expect(find.bySemanticsLabel('appApi.apiKeyModal.secretKey'), findsWidgets);
    });

    testWidgets('deletes an app API key through the generated mutation input', (t) async {
      final api = RecordingAccessApi(
        keys: const [
          AppApiKey(id: 'app-key-0', token: 'other-app-secret-token-987654321', createdAt: 1),
          AppApiKey(id: 'app-key-1', token: 'app-secret-token-123456789', createdAt: 1),
        ],
      );
      await _renderModal(t, api);
      expect(find.text('app...cret-token-123456789'), findsOneWidget);
      await tapButton(t, 'common.operation.delete app...cret-token-123456789');
      await tapButton(t, 'common.operation.confirm');
      expect(api.callsOf('deleteApiKey'), [
        ['app-123', 'app-key-1'],
      ]);
    });

    testWidgets('disables creation when the caller cannot manage keys', (t) async {
      await _renderModal(t, RecordingAccessApi(), canManage: false);
      expect(isEnabled('appApi.apiKeyModal.createNewSecretKey'), isFalse);
    });

    testWidgets('exposes an accessible close button', (t) async {
      await _renderModal(t, RecordingAccessApi());
      expect(find.byType(ApiKeyModal), findsOneWidget);
      await tapButton(t, 'common.operation.close');
      expect(find.byType(ApiKeyModal), findsNothing);
    });
  });
}
