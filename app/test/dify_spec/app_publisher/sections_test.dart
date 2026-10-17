// dify-spec: web/app/components/app/app-publisher/__tests__/sections.spec.tsx
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/workflow_editor/header/publisher/actions_section.dart';
import 'package:dify_sf_app/src/workflow_editor/header/publisher/summary_section.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

final _now = DateTime.now().millisecondsSinceEpoch;

/// The test font draws every glyph a full em wide, and the keys are long: a wide viewport keeps rows from overflowing.
Future<void> _show(WidgetTester t, Widget section) async {
  t.view.physicalSize = const Size(1600, 1200);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await render(t, SizedBox(width: 1200, child: section));
}

PublishedWorkflowInfo _version({int? versionNumber, String markedName = '', String markedComment = ''}) =>
    PublishedWorkflowInfo(
      id: 'workflow-version-1',
      createdAt: 1710000000,
      createdByName: 'Alice',
      versionNumber: versionNumber,
      markedName: markedName,
      markedComment: markedComment,
    );

PublisherSummarySection _summary({
  int? draftUpdatedAt,
  String time = '3 minutes ago',
  VoidCallback? onPublish,
  VoidCallback? onRestore,
  bool isChatApp = false,
  bool isWorkflowApp = false,
  VoidCallback? onEditVersion,
  bool published = false,
  int? publishedAt,
  bool startNodeLimitExceeded = false,
  PublishedWorkflowInfo? versionInfo,
}) => PublisherSummarySection(
  draftUpdatedAt: draftUpdatedAt ?? _now,
  formatTimeFromNow: (_) => time,
  onPublish: onPublish ?? () {},
  onRestore: onRestore ?? () {},
  isChatApp: isChatApp,
  isWorkflowApp: isWorkflowApp,
  onEditVersion: onEditVersion,
  published: published,
  publishedAt: publishedAt,
  startNodeLimitExceeded: startNodeLimitExceeded,
  versionInfo: versionInfo,
);

PublisherActionsSection _actions({
  String? appId = 'workflow-app',
  String appMode = 'workflow',
  bool canViewAccessPoint = true,
  bool disabledFunctionButton = false,
  String? disabledFunctionTooltip,
  ValueChanged<String>? onOpenRunConfig,
  bool hasTriggerNode = false,
  int? publishedAt,
  bool showDeployAction = false,
  bool showMarketplaceAction = false,
  bool showRunConfig = false,
  bool toolPublished = false,
  bool workflowToolAvailable = true,
  bool workflowToolIsLoading = false,
  String? workflowToolMessage,
  bool workflowToolOutdated = false,
  VoidCallback? onConfigureWorkflowTool,
  VoidCallback? onPublishToMarketplace,
}) => PublisherActionsSection(
  appId: appId,
  appMode: appMode,
  appUrl: 'https://example.com/app',
  canViewAccessPoint: canViewAccessPoint,
  disabledFunctionButton: disabledFunctionButton,
  disabledFunctionTooltip: disabledFunctionTooltip,
  onOpenRunConfig: onOpenRunConfig,
  hasTriggerNode: hasTriggerNode,
  publishedAt: publishedAt,
  showDeployAction: showDeployAction,
  showMarketplaceAction: showMarketplaceAction,
  showRunConfig: showRunConfig,
  toolPublished: toolPublished,
  workflowToolAvailable: workflowToolAvailable,
  workflowToolIsLoading: workflowToolIsLoading,
  workflowToolMessage: workflowToolMessage,
  workflowToolOutdated: workflowToolOutdated,
  onConfigureWorkflowTool: onConfigureWorkflowTool ?? () {},
  onPublishToMarketplace: onPublishToMarketplace,
);

String _status() => statuses().single.label;

bool _isBelow(WidgetTester t, Finder lower, Finder upper) => t.getTopLeft(lower).dy > t.getTopLeft(upper).dy;

void main() {
  setUp(useDifyTestTranslator);

  group('app-publisher sections', () {
    testWidgets('should render restore controls for published chat apps', (t) async {
      final semantics = t.ensureSemantics();
      var restores = 0;
      await _show(t, _summary(isChatApp: true, publishedAt: _now, onRestore: () => restores++));
      await t.tap(find.text('workflow.common.restore'));
      expect(restores, 1);
      expect(_status(), contains('workflow.common.currentDraft'));
      semantics.dispose();
    });

    testWidgets('should disable publish and restore after publishing in the current open session', (t) async {
      final semantics = t.ensureSemantics();
      var restores = 0;
      await _show(t, _summary(isChatApp: true, published: true, publishedAt: _now, onRestore: () => restores++));
      final restore = named('workflow.common.restore');
      expect(isDisabled(restore), isTrue);
      expect(isDisabled(named('workflow.common.published')), isTrue);
      expect(_status(), contains('workflow.common.upToDate'));
      await t.tap(find.text('workflow.common.restore'));
      expect(restores, 0);
      semantics.dispose();
    });

    testWidgets('should render the initial publish action when the draft has not been published yet', (t) async {
      final semantics = t.ensureSemantics();
      await _show(t, _summary(time: '1 minute ago'));
      expect(find.text('workflow.common.notPublishedYet'), findsOneWidget);
      expect(find.text('workflow.common.publish'), findsOneWidget);
      expect(find.text('P'), findsOneWidget);
      expect(_status(), contains('workflow.common.currentDraft'));
      semantics.dispose();
    });

    testWidgets('should expose naming and keep publishing available for an unnamed published workflow', (t) async {
      final semantics = t.ensureSemantics();
      var edits = 0;
      await _show(
        t,
        _summary(
          draftUpdatedAt: 1710000000000,
          time: '17 days ago',
          isWorkflowApp: true,
          onEditVersion: () => edits++,
          publishedAt: 1710000100000,
          versionInfo: _version(versionNumber: 5),
        ),
      );
      expect(find.text('# 5'), findsOneWidget);
      expect(find.text('2024-03-09T16:00:00Z'), findsNothing);
      expect(isButton(named('workflow.versionHistory.nameIt')), isTrue);
      await t.tap(find.text('workflow.versionHistory.nameIt'));
      expect(edits, 1);
      final publish = named('workflow.common.publishUpdate');
      expect(isButton(publish) && !isDisabled(publish), isTrue);
      expect(
        find.descendant(of: find.widgetWithText(DifyButton, 'workflow.common.publishUpdate'), matching: find.text('P')),
        findsOneWidget,
      );
      expect(find.textContaining('workflow.common.autoSaved'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('should show named workflow metadata and keep publish update available', (t) async {
      final semantics = t.ensureSemantics();
      var edits = 0;
      await _show(
        t,
        _summary(
          draftUpdatedAt: 1710000200000,
          time: '2 minutes ago',
          isWorkflowApp: true,
          onEditVersion: () => edits++,
          publishedAt: 1710000100000,
          versionInfo: _version(
            markedName: 'Sprint-42',
            markedComment: 'Fixed data synchronization and page loading.',
          ),
        ),
      );
      expect(find.text('Sprint-42'), findsOneWidget);
      expect(find.text('Fixed data synchronization and page loading.'), findsOneWidget);
      await activate(t, 'workflow.versionHistory.editVersionInfo');
      expect(edits, 1);
      expect(isDisabled(named('workflow.common.publishUpdate')), isFalse);
      expect(find.textContaining('workflow.common.autoSaved'), findsOneWidget);
      expect(find.textContaining('2 minutes ago'), findsWidgets);
      semantics.dispose();
    });

    testWidgets('should keep non-workflow apps free of workflow version details and saved time', (t) async {
      final semantics = t.ensureSemantics();
      await _show(
        t,
        _summary(
          draftUpdatedAt: 1710000200000,
          time: '2 minutes ago',
          isChatApp: true,
          publishedAt: 1710000100000,
        ),
      );
      expect(find.text('workflow.common.latestPublished'), findsOneWidget);
      expect(find.text('#5'), findsNothing);
      expect(find.text('workflow.versionHistory.nameIt'), findsNothing);
      expect(isDisabled(named('workflow.common.publishUpdate')), isFalse);
      expect(_status(), contains('workflow.common.currentDraft'));
      semantics.dispose();
    });

    testWidgets('should render the upgrade hint when the start node limit is exceeded', (t) async {
      await _show(t, _summary(time: '1 minute ago', startNodeLimitExceeded: true));
      expect(find.text('workflow.publishLimit.startNodeDesc'), findsOneWidget);
    });

    testWidgets('should render the published workflow actions with Workflow as Tool after Marketplace', (t) async {
      final semantics = t.ensureSemantics();
      final runConfigs = <String>[];
      var configures = 0, marketplace = 0;
      await _show(
        t,
        _actions(
          disabledFunctionTooltip: 'disabled',
          onOpenRunConfig: runConfigs.add,
          publishedAt: _now,
          showDeployAction: true,
          showMarketplaceAction: true,
          showRunConfig: true,
          onPublishToMarketplace: () => marketplace++,
          onConfigureWorkflowTool: () => configures++,
        ),
      );
      expect(data(named('workflow.common.openWebApp')).linkUrl, Uri.parse('https://example.com/app'));
      await t.tap(find.bySemanticsLabel('common.operation.config'));
      expect(runConfigs, ['https://example.com/app']);
      expect(data(named('common.appMenus.accessPoint')).linkUrl, Uri.parse('/app/workflow-app/access-point'));
      expect(data(named('common.appMenus.deploy')).linkUrl, Uri.parse('/app/workflow-app/deploy'));

      final market = find.text('workflow.common.publishToMarketplace');
      final tool = find.text('workflow.common.workflowAsTool');
      expect(isButton(named('workflow.common.publishToMarketplace')), isTrue);
      expect(isButton(named('workflow.common.workflowAsTool')), isTrue);
      expect(_isBelow(t, tool, market), isTrue);
      expect(isStatus(named('workflow.common.configureRequired')), isTrue);

      await t.tap(market);
      expect(marketplace, 1);
      await t.tap(tool);
      expect(configures, 1);
      semantics.dispose();
    });

    testWidgets('should expose Configure and Manage in Tools actions for a ready workflow tool', (t) async {
      final semantics = t.ensureSemantics();
      var configures = 0;
      await _show(
        t,
        _actions(
          publishedAt: _now,
          showDeployAction: true,
          toolPublished: true,
          onConfigureWorkflowTool: () => configures++,
        ),
      );
      expect(isStatus(named('workflow.common.workflowAsToolReady')), isTrue);
      final manage = named('workflow.common.manageInTools');
      expect(isLink(manage), isTrue);
      expect(data(manage).linkUrl, Uri.parse('/integrations/tools/workflow'));
      await t.tap(find.text('workflow.common.configure'));
      expect(configures, 1);
      semantics.dispose();
    });

    testWidgets('should show the disabled reason below setup and configured workflow tool actions', (t) async {
      final semantics = t.ensureSemantics();
      Widget section({required bool toolPublished}) => _actions(
        publishedAt: _now,
        workflowToolAvailable: false,
        workflowToolMessage: 'Workflow tool unavailable',
        toolPublished: toolPublished,
      );
      await _show(t, section(toolPublished: false));
      final reason = find.text('Workflow tool unavailable');
      expect(isDisabled(named('workflow.common.workflowAsTool')), isTrue);
      expect(reason, findsOneWidget);
      expect(_isBelow(t, reason, find.text('workflow.common.workflowAsTool')), isTrue);

      await _show(t, section(toolPublished: true));
      final manage = named('workflow.common.manageInTools');
      expect(isDisabled(named('workflow.common.configure')), isTrue);
      expect(isButton(manage) && isDisabled(manage), isTrue);
      expect(reason, findsOneWidget);
      expect(_isBelow(t, reason, find.text('workflow.common.manageInTools')), isTrue);
      semantics.dispose();
    });

    testWidgets('should surface update-needed and loading states for a configured workflow tool', (t) async {
      final semantics = t.ensureSemantics();
      var configures = 0;
      Widget section({required bool loading, required bool outdated}) => _actions(
        publishedAt: _now,
        toolPublished: true,
        workflowToolIsLoading: loading,
        workflowToolOutdated: outdated,
        onConfigureWorkflowTool: () => configures++,
      );
      await _show(t, section(loading: false, outdated: true));
      expect(isStatus(named('workflow.common.workflowAsToolUpdateNeeded')), isTrue);
      expect(find.text('workflow.common.workflowAsToolTip'), findsOneWidget);
      await t.tap(find.text('workflow.common.workflowAsToolReconfigure'));
      expect(configures, 1);

      await _show(t, section(loading: true, outdated: false));
      expect(isDisabled(named('workflow.common.workflowAsTool')), isTrue);
      expect(isStatus(named('common.loading')), isTrue);
      expect(find.text('workflow.common.workflowAsToolTip'), findsNothing);
      semantics.dispose();
    });

    testWidgets('should keep Access Point and Deploy available for trigger workflows', (t) async {
      final semantics = t.ensureSemantics();
      await _show(
        t,
        _actions(appId: 'trigger-app', hasTriggerNode: true, publishedAt: _now, showDeployAction: true),
      );
      expect(find.text('workflow.common.openWebApp'), findsNothing);
      expect(find.text('workflow.common.workflowAsTool'), findsNothing);
      expect(data(named('common.appMenus.accessPoint')).linkUrl, Uri.parse('/app/trigger-app/access-point'));
      expect(data(named('common.appMenus.deploy')).linkUrl, Uri.parse('/app/trigger-app/deploy'));
      semantics.dispose();
    });

    testWidgets('should hide the Access Point publisher entry without view permission', (t) async {
      final semantics = t.ensureSemantics();
      await _show(t, _actions(canViewAccessPoint: false, publishedAt: _now, showDeployAction: true));
      expect(allNamed('common.appMenus.accessPoint'), isEmpty);
      expect(data(named('common.appMenus.deploy')).linkUrl, Uri.parse('/app/workflow-app/deploy'));
      semantics.dispose();
    });

    testWidgets('should expose unavailable quick links as disabled buttons before the first publish', (t) async {
      final semantics = t.ensureSemantics();
      await _show(t, _actions(disabledFunctionButton: true, showDeployAction: true));
      for (final label in [
        'workflow.common.openWebApp',
        'common.appMenus.accessPoint',
        'common.appMenus.deploy',
        'workflow.common.workflowAsTool',
      ]) {
        final n = named(label);
        expect(isButton(n) && isDisabled(n), isTrue, reason: label);
      }
      semantics.dispose();
    });

    testWidgets('should show the disabled reason when hovering an unavailable action', (t) async {
      await _show(
        t,
        _actions(disabledFunctionButton: true, disabledFunctionTooltip: 'Open web app unavailable'),
      );
      final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(t.getCenter(find.text('workflow.common.openWebApp')));
      await t.pump(const Duration(milliseconds: 300));
      await t.pump(const Duration(milliseconds: 200));
      expect(
        find.descendant(of: find.byType(DifyTooltipSurface), matching: find.text('Open web app unavailable')),
        findsOneWidget,
      );
    });

    testWidgets('should keep an unavailable action with a tooltip keyboard focusable', (t) async {
      final semantics = t.ensureSemantics();
      await _show(
        t,
        _actions(disabledFunctionButton: true, disabledFunctionTooltip: 'Open web app unavailable'),
      );
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pump();
      await t.pump(const Duration(milliseconds: 200));
      final action = named('workflow.common.openWebApp');
      expect(isFocused(action), isTrue);
      expect(isDisabled(action), isTrue, reason: 'aria-disabled');
      expect(data(action).hint, 'Open web app unavailable');
      expect(
        find.descendant(of: find.byType(DifyTooltipSurface), matching: find.text('Open web app unavailable')),
        findsOneWidget,
      );
      semantics.dispose();
    });
  });
}
