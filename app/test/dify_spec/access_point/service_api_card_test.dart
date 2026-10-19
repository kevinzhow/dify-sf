// dify-spec: web/app/components/app/access-point/__tests__/service-api-card.spec.tsx
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/app_detail/access/access_point_card.dart';
import 'package:dify_sf_app/src/app_detail/access/access_point_utils.dart';
import 'package:dify_sf_app/src/app_detail/access/service_api_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

/// The card on the app store's app (Dify's `StoreConnectedServiceApiCard`): a stored change replaces the app.
class _Rig {
  _Rig(this.app);
  AppInfo app;
  final api = RecordingAccessApi();
  final opened = <String>[];
}

Future<_Rig> _render(
  WidgetTester t,
  String mode, {
  AccessPointAvailability availability = AccessPointAvailability.available,
  bool canManage = true,
  bool enableApi = true,
}) async {
  final rig = _Rig(accessAppInfo(mode: mode, enableApi: enableApi));
  await renderMembers(
    t,
    StatefulBuilder(
      builder: (context, setState) => SingleChildScrollView(
        child: ServiceApiAccessPointCard(
          app: rig.app,
          api: rig.api,
          availability: availability,
          canManage: canManage,
          onAppChanged: (a) => setState(() => rig.app = a),
          onOpen: rig.opened.add,
        ),
      ),
    ),
  );
  return rig;
}

const _keysLabel = 'appApi.apiKeyModal.apiSecretKey 0';

bool _noSuccessToast() => find.textContaining('actionMsg.modifiedSuccessfully').evaluate().isEmpty;

void main() {
  group('ServiceApiAccessPointCard', () {
    testWidgets('links %s apps to the matching external API reference', (t) async {
      for (final (mode, path) in [
        (AppModes.advancedChat, '/api-reference/guides/chatflow'),
        (AppModes.workflow, '/api-reference/guides/workflow'),
        ('chat', '/api-reference/guides/chat'),
        ('agent-chat', '/api-reference/guides/chat'),
        ('completion', '/api-reference/guides/completion'),
      ]) {
        final rig = await _render(t, mode);
        // useDocLink in English (the test translator has no language).
        final url = 'https://docs.dify.ai/en$path';
        final link = linkNode('appOverview.overview.apiInfo.doc')!;
        expect(link.getSemanticsData().linkUrl, Uri.parse(url));
        await tapButton(t, 'appOverview.overview.apiInfo.doc');
        // `target="_blank" rel="noopener noreferrer"`: the external opener.
        expect(rig.opened, [url]);
        await t.pumpWidget(const SizedBox());
      }
    });

    testWidgets('updates API status through the generated contract', (t) async {
      final rig = await _render(t, AppModes.workflow);
      await tapSwitch(t);
      expect(rig.api.callsOf('setApiEnabled'), [
        ['app-1', false],
      ]);
    });

    testWidgets('shows loading without reporting an environment failure', (t) async {
      await _render(t, AppModes.workflow, availability: AccessPointAvailability.loading);
      expect(t.widget<AccessPointCard>(find.byType(AccessPointCard)).busy, isTrue);
      expect(find.bySemanticsLabel(RegExp('serviceApi.title')), findsWidgets);
      expect(label('common.loading'), findsOneWidget);
      expect(label('deployments.health.ENVIRONMENT_STATUS_FAILED'), findsNothing);
    });

    testWidgets('keeps API keys and external documentation available when the API is stopped', (t) async {
      await _render(t, AppModes.workflow, enableApi: false);
      expect(isEnabled(_keysLabel), isTrue);
      expect(
        linkNode('appOverview.overview.apiInfo.doc')!.getSemanticsData().linkUrl,
        Uri.parse(difyDocLink('/api-reference/guides/workflow')),
      );
    });

    testWidgets('disables API management without Access Point management permission', (t) async {
      final rig = await _render(t, AppModes.workflow, canManage: false);
      expect(isEnabled(_keysLabel), isFalse);
      // The keys are not even requested.
      expect(rig.api.callsOf('listApiKeys'), isEmpty);
      expect(switchEnabled(), isFalse);
    });

    testWidgets('disables API keys and external documentation when the access point is unavailable', (t) async {
      await _render(t, AppModes.workflow, availability: AccessPointAvailability.unavailable);
      expect(isEnabled(_keysLabel), isFalse);
      expect(linkNode('appOverview.overview.apiInfo.doc'), isNull);
      expect(isEnabled('appOverview.overview.apiInfo.doc'), isFalse);
    });

    testWidgets('rolls back a failed status change and shows only an error toast', (t) async {
      final rig = await _render(t, AppModes.workflow);
      final toggle = rig.api.hold('setApiEnabled').single;
      await tapSwitch(t);
      expect(switchChecked(), isFalse);

      toggle.completeError(const TransportException('request failed'));
      await settle(t);
      expect(switchChecked(), isTrue);
      expect(toastShown('common.actionMsg.modifiedUnsuccessfully'), isTrue);
      expect(_noSuccessToast(), isTrue);
    });

    testWidgets('keeps successful status changes silent', (t) async {
      final rig = await _render(t, AppModes.workflow);
      await tapSwitch(t);
      expect(rig.app.enableApi, isFalse);
      expect(switchChecked(), isFalse);
      expect(_noSuccessToast(), isTrue);
    });
  });
}
