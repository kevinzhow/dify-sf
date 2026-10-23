// dify-spec: web/app/components/app/access-point/__tests__/web-app-card.spec.tsx
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/app_detail/access/access_point_card.dart';
import 'package:dify_sf_app/src/app_detail/access/access_point_utils.dart';
import 'package:dify_sf_app/src/app_detail/access/embedded_modal.dart';
import 'package:dify_sf_app/src/app_detail/access/web_app_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

class _Rig {
  _Rig(this.app);
  AppInfo app;
  final api = RecordingAccessApi();
  final opened = <String>[];
  var refreshed = 0;
}

/// A published workflow whose Start node has the hidden `secret` input.
const Map<String, Object?> workflowWithHiddenInput = {
  'id': 'workflow-id',
  'graph': {
    'nodes': [
      {
        'id': 'start',
        'data': {
          'title': 'Start',
          'type': 'start',
          'variables': [
            {
              'variable': 'secret',
              'label': 'Secret',
              'type': 'text-input',
              'hide': true,
              'required': true,
              'default': '',
            },
          ],
        },
      },
    ],
    'edges': [],
  },
  'version': '1',
};

Future<_Rig> _render(
  WidgetTester t,
  String mode, {
  AccessPointAvailability availability = AccessPointAvailability.available,
  PublishedWorkflow workflow,
  bool canManageAccessPoint = true,
}) async {
  final rig = _Rig(accessAppInfo(mode: mode));
  await renderMembers(
    t,
    StatefulBuilder(
      builder: (context, setState) => SingleChildScrollView(
        child: WebAppAccessPointCard(
          app: rig.app,
          api: rig.api,
          availability: availability,
          canDeploy: true,
          canManageAccess: true,
          canManageAccessPoint: canManageAccessPoint,
          showAccessControl: true,
          workflow: workflow,
          onRefreshApp: () async => rig.refreshed++,
          onSaveSiteConfig: (_) async {},
          onAppChanged: (a) => setState(() => rig.app = a),
          openUrl: rig.opened.add,
        ),
      ),
    ),
  );
  return rig;
}

const _embed = 'deployments.studio.accessPoint.embedIntoSite';
const _customize = 'appOverview.overview.appInfo.customize.entry';
const _settings = 'common.settings.settings';
const _regenerate = 'appOverview.overview.appInfo.regenerate';
const _open = 'deployments.studio.accessPoint.open';

void main() {
  group('WebAppAccessPointCard', () {
    testWidgets('does not offer Embed into site for %s apps', (t) async {
      for (final mode in [AppModes.workflow, 'completion']) {
        await _render(t, mode);
        expect(button(_embed).evaluate(), isEmpty);
        expect(button(_customize).evaluate(), hasLength(1));
        expect(button(_settings).evaluate(), hasLength(1));
        await t.pumpWidget(const SizedBox());
      }
    });

    testWidgets('keeps Embed into site for non-workflow Web apps', (t) async {
      await _render(t, 'chat');
      await tapButton(t, _embed);
      expect(find.byType(EmbeddedModal), findsOneWidget);
    });

    testWidgets('updates site status through the generated contract', (t) async {
      final rig = await _render(t, 'chat');
      await tapSwitch(t);
      expect(rig.api.callsOf('setSiteEnabled'), [
        ['app-1', false],
      ]);
    });

    testWidgets('keeps site status changes behind Access Point management permission', (t) async {
      final rig = await _render(t, 'chat', canManageAccessPoint: false);
      await tapSwitch(t);
      await t.tap(find.byKey(const ValueKey('access-point-switch')), warnIfMissed: false);
      await settle(t);
      expect(rig.api.callsOf('setSiteEnabled'), isEmpty);
    });

    testWidgets('resets the site access token through the generated contract', (t) async {
      final rig = await _render(t, 'chat');
      await tapButton(t, _regenerate);
      await tapButton(t, 'common.operation.confirm');
      expect(rig.api.callsOf('resetAccessToken'), [
        ['app-1'],
      ]);
      expect(rig.refreshed, 1);
    });

    testWidgets('keeps generated mutation failures inside the card owner', (t) async {
      final rig = await _render(t, 'chat');
      rig.api.fail['setSiteEnabled'] = const TransportException('request failed');
      await tapSwitch(t);
      expect(toastShown('common.actionMsg.modifiedUnsuccessfully'), isTrue);
    });

    testWidgets('passes hidden Chatflow inputs to the embed dialog', (t) async {
      await _render(t, AppModes.advancedChat, workflow: workflowWithHiddenInput);
      await tapButton(t, _embed);
      final modal = t.widget<EmbeddedModal>(find.byType(EmbeddedModal));
      expect([for (final v in modal.hiddenInputs) v['variable']], ['secret']);
    });

    testWidgets('configures hidden workflow inputs before opening the Web App', (t) async {
      final rig = await _render(t, AppModes.workflow, workflow: workflowWithHiddenInput);
      await tapButton(t, 'common.operation.config');
      await t.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('workflow-launch-hidden-input-secret')),
          matching: find.byType(EditableText),
        ),
        'top-secret',
      );
      await t.pump();
      await tapButton(t, RegExp(r'overview\.appInfo\.launch'));
      expect(rig.opened, ['https://site.example.test/workflow/site-code?secret=top-secret']);
    });

    testWidgets('shows loading without reporting an environment failure', (t) async {
      await _render(t, AppModes.workflow, availability: AccessPointAvailability.loading);
      expect(t.widget<AccessPointCard>(find.byType(AccessPointCard)).busy, isTrue);
      expect(find.bySemanticsLabel(RegExp(r'webApp\.title')), findsWidgets);
      expect(label('common.loading'), findsOneWidget);
      expect(label('deployments.health.ENVIRONMENT_STATUS_FAILED'), findsNothing);
    });

    testWidgets('does not announce an unavailable access control entry as loading', (t) async {
      await _render(t, AppModes.workflow, availability: AccessPointAvailability.unavailable);
      expect(t.widget<AccessPointCard>(find.byType(AccessPointCard)).busy, isFalse);
      expect(label('common.loading'), findsNothing);
    });

    testWidgets('optimistically serializes status changes without a success toast', (t) async {
      final rig = await _render(t, 'chat');
      final toggles = rig.api.hold('setSiteEnabled', 2);

      await tapSwitch(t);
      expect(switchChecked(), isFalse);
      expect(rig.api.callsOf('setSiteEnabled'), hasLength(1));

      await tapSwitch(t);
      expect(switchChecked(), isTrue);
      expect(rig.api.callsOf('setSiteEnabled'), hasLength(1));
      expect(linkNode(_open), isNull);

      toggles[0].complete(accessAppInfo(mode: 'chat', enableSite: false));
      await settle(t);
      expect(rig.api.callsOf('setSiteEnabled'), hasLength(2));
      expect(rig.api.callsOf('setSiteEnabled')[1], ['app-1', true]);

      toggles[1].complete(accessAppInfo(mode: 'chat'));
      await settle(t);
      expect(linkNode(_open), isNotNull);
      expect(switchChecked(), isTrue);
      expect(find.textContaining('actionMsg.modifiedSuccessfully'), findsNothing);
    });

    testWidgets('disables Web App management actions without Access Point management', (t) async {
      await _render(t, 'chat', canManageAccessPoint: false);
      expect(switchEnabled(), isFalse);
      expect(isEnabled(_embed), isFalse);
      expect(isEnabled(_customize), isFalse);
      expect(isEnabled(_settings), isFalse);
      expect(isEnabled(_regenerate), isFalse);
      expect(linkNode(_open), isNotNull);
      expect(isEnabled(_open), isTrue);
      // Dify's access mode entry is enterprise-only (`webapp_auth`): dify-sf has none.
    });
  });
}
