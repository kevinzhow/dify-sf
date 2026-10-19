// dify-spec: web/app/components/app/access-point/__tests__/built-in-access-points.spec.tsx
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/app_detail/access/access_point_card.dart';
import 'package:dify_sf_app/src/app_detail/access/access_point_page.dart';
import 'package:dify_sf_app/src/app_detail/access/access_point_utils.dart';
import 'package:dify_sf_app/src/app_detail/access/mcp_trigger_cards.dart';
import 'package:dify_sf_app/src/app_detail/access/service_api_card.dart';
import 'package:dify_sf_app/src/app_detail/access/web_app_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

Future<void> _render(
  WidgetTester t, {
  PublishedWorkflow workflow,
  bool pending = false,
  bool error = false,
  bool canDeploy = true,
  required bool canManageAccessPoint,
  required bool canReleaseAndVersion,
  String? highlighted,
}) => renderMembers(
  t,
  SingleChildScrollView(
    child: BuiltInAccessPoints(
      app: accessAppInfo(mode: AppModes.workflow, enableSite: false, enableApi: false),
      access: RecordingAccessApi(),
      workflow: workflow,
      workflowPending: pending,
      workflowError: error,
      canDeploy: canDeploy,
      canManageAccessPoint: canManageAccessPoint,
      canReleaseAndVersion: canReleaseAndVersion,
      highlightedAccessPoint: highlighted,
    ),
  ),
);

WebAppAccessPointCard _web(WidgetTester t) => t.widget(find.byType(WebAppAccessPointCard));
ServiceApiAccessPointCard _api(WidgetTester t) => t.widget(find.byType(ServiceApiAccessPointCard));
MCPAccessPointCard _mcp(WidgetTester t) => t.widget(find.byType(MCPAccessPointCard));
TriggerAccessPointCard _trigger(WidgetTester t) => t.widget(find.byType(TriggerAccessPointCard));

const _unpublished = 'deployments.studio.accessPoint.noPublishedTitle';

Map<String, Object?> _published(String startType) => {
  'graph': {
    'nodes': [
      {
        'data': {'type': startType},
      },
    ],
  },
};

void main() {
  group('BuiltInAccessPoints', () {
    testWidgets('renders the unpublished state across all access point cards', (t) async {
      await _render(t, canManageAccessPoint: false, canReleaseAndVersion: false);
      expect(find.text(_unpublished), findsOneWidget);
      expect(_web(t).availability, AccessPointAvailability.unavailable);
      expect(_web(t).canDeploy, isTrue);
      expect(_web(t).canManageAccessPoint, isFalse);
      expect(_api(t).availability, AccessPointAvailability.unavailable);
      expect(_api(t).canManage, isFalse);
      expect(find.byType(MCPAccessPointCard), findsOneWidget);
      expect(_trigger(t).availability, AccessPointAvailability.unavailable);
      expect(_trigger(t).canManageAccessPoint, isFalse);
    });

    testWidgets('keeps Trigger unavailable when no trigger node is published', (t) async {
      final workflow = _published('start');
      await _render(t, workflow: workflow, canManageAccessPoint: false, canReleaseAndVersion: false);
      expect(find.text(_unpublished), findsNothing);
      expect(_web(t).availability, AccessPointAvailability.available);
      expect(_web(t).workflow, workflow);
      expect(_api(t).availability, AccessPointAvailability.available);
      expect(_trigger(t).availability, AccessPointAvailability.unavailable);
    });

    testWidgets('uses Access Point management for every requested built-in operation', (t) async {
      await _render(t, canManageAccessPoint: true, canReleaseAndVersion: false);
      expect(_web(t).canManageAccess, isFalse);
      expect(_web(t).canManageAccessPoint, isTrue);
      expect(_api(t).canManage, isTrue);
      expect(_mcp(t).canManageAccessPoint, isTrue);
      expect(_trigger(t).canManageAccessPoint, isTrue);
    });

    testWidgets('highlights only the targeted built-in access point card', (t) async {
      await _render(t, canManageAccessPoint: true, canReleaseAndVersion: true, highlighted: 'mcp');
      expect(_web(t).highlighted, isFalse);
      expect(_api(t).highlighted, isFalse);
      expect(_mcp(t).highlighted, isTrue);
      expect(_trigger(t).highlighted, isFalse);
    });

    testWidgets('enables Trigger and disables the other access points in trigger mode', (t) async {
      await _render(
        t,
        workflow: _published('trigger-webhook'),
        canManageAccessPoint: true,
        canReleaseAndVersion: true,
      );
      expect(_web(t).availability, AccessPointAvailability.unavailable);
      expect(_api(t).availability, AccessPointAvailability.unavailable);
      expect(_mcp(t).triggerModeDisabled, isTrue);
      expect(_trigger(t).availability, AccessPointAvailability.available);
      expect(
        find.textContaining('deployments.studio.accessPoint.triggerExclusiveNotice', findRichText: true),
        findsOneWidget,
      );
    });

    testWidgets('keeps all cards visible while the published workflow is loading', (t) async {
      await _render(t, pending: true, canManageAccessPoint: true, canReleaseAndVersion: true);
      expect(_web(t).availability, AccessPointAvailability.loading);
      expect(_api(t).availability, AccessPointAvailability.loading);
      expect(_trigger(t).availability, AccessPointAvailability.loading);
    });

    testWidgets('does not show the unpublished card when loading the published workflow fails', (t) async {
      await _render(t, error: true, canManageAccessPoint: true, canReleaseAndVersion: true);
      expect(find.text(_unpublished), findsNothing);
    });

    test('does not retry forbidden published workflow requests', () {
      expect(retryPublishedWorkflow(0, const TransportException('forbidden', statusCode: 403)), isFalse);
      expect(retryPublishedWorkflow(0, const TransportException('server error', statusCode: 500)), isTrue);
      expect(retryPublishedWorkflow(3, const TransportException('server error', statusCode: 500)), isFalse);
    });
  });
}
