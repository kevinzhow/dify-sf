// dify-spec: web/app/components/app/access-point/__tests__/index.spec.tsx
// dify-spec: web/app/components/app/access-point/__tests__/api-secret-key-button.spec.tsx
// dify-spec: web/app/components/app/access-point/__tests__/use-access-point-actions.spec.ts
// dify-spec: web/app/components/app/access-point/__tests__/mcp-card.spec.tsx
// dify-spec: web/app/components/app/access-point/__tests__/trigger-card.spec.tsx
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/app_detail/access/access_point_card.dart';
import 'package:dify_sf_app/src/app_detail/access/access_point_page.dart';
import 'package:dify_sf_app/src/app_detail/access/api_key_modal.dart';
import 'package:dify_sf_app/src/app_detail/access/mcp_trigger_cards.dart';
import 'package:dify_sf_app/src/app_detail/access/service_api_card.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

const _keys = [
  AppApiKey(id: 'key-1', token: 'app-a', createdAt: 1, lastUsedAt: 1),
  AppApiKey(id: 'key-2', token: 'app-b', createdAt: 2, lastUsedAt: 2),
];

Future<AccessPointPageState> _renderPage(
  WidgetTester t,
  AppInfo app, {
  AccessApi? access,
  int Function()? refresh,
}) async {
  await renderMembers(
    t,
    AccessPointPage(
      app: ValueNotifier(app),
      access: access ?? RecordingAccessApi(),
      refreshApp: () async => refresh?.call(),
    ),
  );
  return t.state<AccessPointPageState>(find.byType(AccessPointPage));
}

/// Taps the [text] span of the rich text containing it (a link inside a sentence).
void _tapSpan(WidgetTester t, String text) {
  for (final e in find.byType(RichText).evaluate()) {
    final span = (e.widget as RichText).text;
    var done = false;
    span.visitChildren((s) {
      if (!done && s is TextSpan && s.text == text && s.recognizer is TapGestureRecognizer) {
        (s.recognizer! as TapGestureRecognizer).onTap!();
        done = true;
      }
      return !done;
    });
    if (done) return;
  }
  fail('No link "$text"');
}

void main() {
  group('AccessPoint', () {
    testWidgets('hides environment tabs for app types without multi-environment support', (t) async {
      await _renderPage(t, accessAppInfo(mode: 'chat', permissionKeys: const [AppPermissionKeys.accessPointView]));
      expect(find.text('common.appMenus.accessPoint'), findsOneWidget);
      expect(find.text('workflow.nodes.common.memories.builtIn'), findsNothing);
      expect(find.byType(BuiltInAccessPoints), findsOneWidget);
    });

    testWidgets('hides environment tabs without Access Point view permission', (t) async {
      await _renderPage(t, accessAppInfo(mode: AppModes.workflow));
      expect(find.text('workflow.nodes.common.memories.builtIn'), findsNothing);
      expect(find.byType(BuiltInAccessPoints), findsOneWidget);
      // With the view permission the community edition's single tab, Built-in, shows (selected).
      await _renderPage(
        t,
        accessAppInfo(mode: AppModes.workflow, permissionKeys: const [AppPermissionKeys.accessPointView]),
      );
      expect(find.byType(EnvironmentTabs), findsOneWidget);
      expect(find.byType(BuiltInAccessPoints), findsOneWidget);
    });
  });

  group('ApiSecretKeyButton', () {
    testWidgets('shows the current API key count and opens key management', (t) async {
      final api = RecordingAccessApi(keys: _keys);
      await renderMembers(
        t,
        Center(
          child: ApiSecretKeyButton(appId: 'app-1', api: api, canManage: true),
        ),
      );
      const label = 'appApi.apiKeyModal.apiSecretKey 2';
      expect(isEnabled(label), isTrue);
      await tapButton(t, label);
      final modal = t.widget<ApiKeyModal>(find.byType(ApiKeyModal));
      expect((modal.query.appId, modal.canManage), ('app-1', true));
    });

    testWidgets('keeps the current count visible when service access is disabled', (t) async {
      final api = RecordingAccessApi(keys: _keys);
      await renderMembers(
        t,
        Center(
          child: ApiSecretKeyButton(appId: 'app-1', api: api, canManage: true, disabled: true),
        ),
      );
      expect(isEnabled('appApi.apiKeyModal.apiSecretKey 2'), isFalse);
    });

    testWidgets('does not request API keys without management permission', (t) async {
      final api = RecordingAccessApi(keys: _keys);
      await renderMembers(
        t,
        Center(
          child: ApiSecretKeyButton(appId: 'app-1', api: api, canManage: false),
        ),
      );
      expect(isEnabled('appApi.apiKeyModal.apiSecretKey 0'), isFalse);
      expect(api.callsOf('listApiKeys'), isEmpty);
    });
  });

  group('useAccessPointActions', () {
    const siteConfig = <String, Object?>{
      'chat_color_theme': '#000000',
      'chat_color_theme_inverted': false,
      'copyright': '',
      'custom_disclaimer': '',
      'default_language': 'en-US',
      'description': 'Description',
      'icon': '🤖',
      'icon_type': 'emoji',
      'input_placeholder': '',
      'privacy_policy': '',
      'prompt_public': false,
      'show_workflow_steps': false,
      'title': 'App',
      'use_icon_as_answer_icon': false,
    };

    testWidgets('refreshes after a successful access point result', (t) async {
      var refreshed = 0;
      final page = await _renderPage(t, accessAppInfo(), refresh: () => refreshed++);
      page.handleResult(null);
      await settle(t);
      expect(refreshed, 1);
      expect(toastShown('common.actionMsg.modifiedSuccessfully'), isTrue);
    });

    testWidgets('reports a failed result without refreshing stale state', (t) async {
      var refreshed = 0;
      final page = await _renderPage(t, accessAppInfo(), refresh: () => refreshed++);
      page.handleResult(StateError('request failed'));
      await settle(t);
      expect(refreshed, 0);
      expect(toastShown('common.actionMsg.modifiedUnsuccessfully'), isTrue);
    });

    testWidgets('invalidates app detail and lists after saving legacy site configuration', (t) async {
      var refreshed = 0;
      final api = RecordingAccessApi();
      final page = await _renderPage(t, accessAppInfo(), access: api, refresh: () => refreshed++);
      await page.saveSiteConfig(siteConfig, canManageAccessPoint: true);
      await settle(t);
      expect(api.callsOf('updateSite'), [
        ['app-1', siteConfig],
      ]);
      // The app detail is refetched; the Studio's lists refetch when it shows again.
      expect(refreshed, 1);
    });

    testWidgets('keeps site configuration behind Access Point management permission', (t) async {
      final api = RecordingAccessApi();
      final page = await _renderPage(t, accessAppInfo(), access: api);
      await page.saveSiteConfig(siteConfig, canManageAccessPoint: false);
      expect(api.callsOf('updateSite'), isEmpty);
    });
  });

  group('MCPAccessPointCard', () {
    testWidgets('shows loading without reporting an environment failure', (t) async {
      await renderMembers(
        t,
        const SingleChildScrollView(
          child: MCPAccessPointCard(canManageAccessPoint: true, workflowLoading: true, triggerModeDisabled: false),
        ),
      );
      expect(t.widget<AccessPointCard>(find.byType(AccessPointCard)).busy, isTrue);
      expect(find.bySemanticsLabel(RegExp(r'mcp\.server\.title')), findsWidgets);
      expect(label('common.loading'), findsOneWidget);
      expect(label('deployments.health.ENVIRONMENT_STATUS_FAILED'), findsNothing);
    });
  });

  group('TriggerAccessPointCard', () {
    testWidgets('shows loading without reporting an environment failure', (t) async {
      await renderMembers(
        t,
        const SingleChildScrollView(
          child: TriggerAccessPointCard(availability: AccessPointAvailability.loading, canManageAccessPoint: true),
        ),
      );
      expect(t.widget<AccessPointCard>(find.byType(AccessPointCard)).busy, isTrue);
      expect(find.bySemanticsLabel(RegExp(r'settings\.trigger')), findsWidgets);
      expect(label('common.loading'), findsOneWidget);
      expect(label('deployments.health.ENVIRONMENT_STATUS_FAILED'), findsNothing);
    });

    testWidgets('uses the overview empty-state copy and documentation interaction', (t) async {
      final opened = <String>[];
      await renderMembers(
        t,
        SingleChildScrollView(
          child: TriggerAccessPointCard(
            availability: AccessPointAvailability.unavailable,
            canManageAccessPoint: true,
            openUrl: opened.add,
          ),
        ),
      );
      expect(
        find.textContaining('appOverview.overview.triggerInfo.triggerStatusDescription', findRichText: true),
        findsOneWidget,
      );
      _tapSpan(t, 'appOverview.overview.triggerInfo.learnAboutTriggers');
      expect(opened, ['https://docs.dify.ai/en/self-host/use-dify/nodes/trigger/overview']);
      expect(find.textContaining('triggerServiceModeUnavailable', findRichText: true), findsNothing);
      expect(find.textContaining('noTriggerNodes', findRichText: true), findsNothing);
    });
  });
}
