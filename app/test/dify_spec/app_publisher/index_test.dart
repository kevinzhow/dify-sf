// dify-spec: web/app/components/app/app-publisher/__tests__/index.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/header/publisher/app_publisher.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

final _now = DateTime.now().millisecondsSinceEpoch;

// The spec's mockAppDetail: a chat app with a site.
const _chatApp = PublisherAppInfo(
  id: 'app-1',
  name: 'Demo App',
  mode: 'chat',
  appBaseUrl: 'https://example.com',
  accessToken: 'token-1',
  accessMode: 'private',
);
const _workflowApp = PublisherAppInfo(
  id: 'app-1',
  name: 'Demo App',
  mode: 'workflow',
  appBaseUrl: 'https://example.com',
  accessToken: 'token-1',
  accessMode: 'private',
);

Future<void> _mount(WidgetTester t, AppPublisher publisher) async {
  t.view.physicalSize = const Size(1600, 1400);
  t.view.devicePixelRatio = 1;
  // The test font draws every glyph a full em wide and the labels are keys: half-size text keeps rows from overflowing.
  t.platformDispatcher.textScaleFactorTestValue = 0.5;
  addTearDown(t.view.reset);
  addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
  await renderWithSafeViewport(t, Align(alignment: Alignment.topRight, child: publisher));
}

/// The header's Publish trigger (the summary may show another "Publish").
final _trigger = find.text('workflow.common.publish').first;

Future<void> _toggle(WidgetTester t) async {
  await t.tap(_trigger);
  await _settle(t);
}

/// Lets an open or close transition finish.
Future<void> _settle(WidgetTester t) async {
  // The controlled popover starts its transition a frame after the state change, its ticker on the frame after.
  await t.pump();
  await t.pump(const Duration(milliseconds: 16));
  await t.pump(const Duration(milliseconds: 200));
  await t.pump();
}

Future<void> _pressHotkey(WidgetTester t) async {
  await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await t.sendKeyEvent(LogicalKeyboardKey.keyP);
  await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await t.pump();
}

void main() {
  setUp(useDifyTestTranslator);

  group('AppPublisher', () {
    testWidgets('should publish once per open session and reset the lock after reopening', (t) async {
      final semantics = t.ensureSemantics();
      var publishes = 0;
      final toggles = <bool>[];
      await _mount(
        t,
        AppPublisher(
          app: _chatApp,
          publishedAt: _now,
          onPublish: () async => publishes++,
          onToggle: toggles.add,
        ),
      );
      await _toggle(t);
      expect(toggles, [true]);
      await t.tap(find.text('workflow.common.publishUpdate'));
      await _settle(t);
      expect(publishes, 1);
      expect(isDisabled(named('workflow.common.published')), isTrue);

      await _toggle(t);
      expect(find.text('workflow.common.published'), findsNothing);

      await _toggle(t);
      expect(isDisabled(named('workflow.common.publishUpdate')), isFalse);
      semantics.dispose();
    });

    testWidgets('should edit the current workflow version from the publish summary', (t) async {
      final semantics = t.ensureSemantics();
      final updates = <VersionInfoUpdate>[];
      final toasts = <(PublisherToastType, String)>[];
      await _mount(
        t,
        AppPublisher(
          app: _workflowApp,
          publishedAt: _now,
          publishedWorkflow: PublishedWorkflowInfo(
            id: 'workflow-version-5',
            createdAt: _now ~/ 1000,
            markedName: 'Release 5',
            markedComment: 'Initial notes',
          ),
          onUpdateVersionInfo: (u) async => updates.add(u),
          onToast: (type, m) => toasts.add((type, m)),
        ),
      );
      await _toggle(t);
      expect(find.text('Release 5'), findsOneWidget, reason: 'the summary shows the published workflow');
      await activate(t, 'workflow.versionHistory.editVersionInfo');
      await t.pumpAndSettle();

      expect(find.text('Initial notes'), findsOneWidget, reason: 'the modal, prefilled');
      expect(find.text('workflow.common.publishUpdate'), findsNothing, reason: 'the publisher closed');
      final fields = find.byType(EditableText);
      await t.enterText(fields.at(0), 'Release 6');
      await t.enterText(fields.at(1), 'Updated notes');
      await t.tap(find.text('common.operation.save'));
      await t.pumpAndSettle();

      expect(updates, [(id: 'workflow-version-5', title: 'Release 6', releaseNotes: 'Updated notes')]);
      expect(toasts, [(PublisherToastType.success, 'workflow.versionHistory.action.updateSuccess')]);
      semantics.dispose();
    });

    testWidgets('should collect hidden inputs before opening the web app from its config action', (t) async {
      final semantics = t.ensureSemantics();
      final opened = <String>[];
      await _mount(
        t,
        AppPublisher(
          app: _chatApp,
          publishedAt: _now,
          capabilities: const PublisherCapabilities(hasHiddenVariables: true),
          onOpenRunConfig: opened.add,
        ),
      );
      await _toggle(t);
      // WorkflowLaunchDialog (the hidden inputs form) is the host's: it gets the web app's URL.
      await t.tap(find.bySemanticsLabel('common.operation.config'));
      expect(opened, ['https://example.com/chat/token-1']);
      semantics.dispose();
    });

    testWidgets('should keep workflow tool drawer mounted after closing the publish popover', (t) async {
      final semantics = t.ensureSemantics();
      var configures = 0;
      await _mount(
        t,
        AppPublisher(
          app: _workflowApp,
          publishedAt: _now,
          toolPublished: true,
          onConfigureWorkflowTool: () => configures++,
        ),
      );
      await _toggle(t);
      expect(allNamed('workflow.common.workflowAsToolReady'), hasLength(1), reason: 'published, not outdated');
      await t.tap(find.text('workflow.common.configure'));
      await _settle(t);
      expect(find.text('workflow.common.configure'), findsNothing);
      expect(configures, 1, reason: 'the host opens the WorkflowToolDrawer');
      semantics.dispose();
    });

    testWidgets('should not open workflow tool drawer without tool.manage', (t) async {
      final semantics = t.ensureSemantics();
      var configures = 0;
      await _mount(
        t,
        AppPublisher(
          app: _workflowApp,
          publishedAt: _now,
          capabilities: const PublisherCapabilities(canManageTools: false),
          onConfigureWorkflowTool: () => configures++,
        ),
      );
      await _toggle(t);
      await t.tap(find.text('workflow.common.workflowAsTool'));
      await _settle(t);
      expect(configures, 0);
      expect(isDisabled(named('workflow.common.workflowAsTool')), isTrue, reason: 'workflowToolAvailable false');
      semantics.dispose();
    });

    testWidgets('should ignore the trigger when the publish button is disabled', (t) async {
      final toggles = <bool>[];
      await _mount(t, AppPublisher(app: _chatApp, disabled: true, publishedAt: _now, onToggle: toggles.add));
      await _toggle(t);
      expect(find.text('workflow.common.publishUpdate'), findsNothing);
      expect(toggles, isEmpty);
    });

    testWidgets('should keep the popover open when restore and publish fail', (t) async {
      var publishes = 0, restores = 0;
      await _mount(
        t,
        AppPublisher(
          app: _chatApp,
          publishedAt: _now,
          onPublish: () async {
            publishes++;
            throw Exception('publish failed');
          },
          onRestore: () async {
            restores++;
            throw Exception('restore failed');
          },
        ),
      );
      await _pressHotkey(t);
      expect(publishes, 1);

      await _toggle(t);
      await t.tap(find.text('workflow.common.restore'));
      await _settle(t);
      expect(restores, 1);
      expect(find.text('workflow.common.publishUpdate'), findsOneWidget);
    });

    testWidgets('should show marketplace button and open redirect URL on success', (t) async {
      final semantics = t.ensureSemantics();
      var publishes = 0;
      await _mount(
        t,
        AppPublisher(
          app: _chatApp,
          publishedAt: _now,
          capabilities: const PublisherCapabilities(showMarketplaceAction: true),
          onPublishToMarketplace: () async => publishes++,
        ),
      );
      await _toggle(t);
      expect(isDisabled(named('workflow.common.publishToMarketplace')), isFalse);
      await t.tap(find.text('workflow.common.publishToMarketplace'));
      await _settle(t);
      expect(publishes, 1, reason: 'the callback publishes and opens the redirect URL');
      semantics.dispose();
    });

    testWidgets('should show toast error when publish to marketplace fails', (t) async {
      final toasts = <(PublisherToastType, String)>[];
      await _mount(
        t,
        AppPublisher(
          app: _chatApp,
          publishedAt: _now,
          capabilities: const PublisherCapabilities(showMarketplaceAction: true),
          onPublishToMarketplace: () async => throw Exception('network error'),
          onToast: (type, m) => toasts.add((type, m)),
        ),
      );
      await _toggle(t);
      await t.tap(find.text('workflow.common.publishToMarketplace'));
      await _settle(t);
      expect(toasts, [(PublisherToastType.error, 'workflow.common.publishToMarketplaceFailed')]);
    });

    testWidgets('should disable marketplace button when not yet published', (t) async {
      final semantics = t.ensureSemantics();
      var publishes = 0;
      await _mount(
        t,
        AppPublisher(
          app: _chatApp,
          capabilities: const PublisherCapabilities(showMarketplaceAction: true),
          onPublishToMarketplace: () async => publishes++,
        ),
      );
      await _toggle(t);
      expect(isDisabled(named('workflow.common.publishToMarketplace')), isTrue);
      await t.tap(find.text('workflow.common.publishToMarketplace'));
      await _settle(t);
      expect(publishes, 0);
      semantics.dispose();
    });

    testWidgets('should hide marketplace button when enable_creators_platform is false', (t) async {
      await _mount(t, AppPublisher(app: _chatApp, publishedAt: _now, onPublishToMarketplace: () async {}));
      await _toggle(t);
      expect(find.text('workflow.common.publishToMarketplace'), findsNothing);
    });

    testWidgets('should not infer an app mode when app detail is unavailable', (t) async {
      await _mount(t, AppPublisher(publishedAt: _now));
      await _toggle(t);
      // Neither a chat app (no Restore) nor a workflow app (no version name, no auto-saved time).
      expect(find.text('workflow.common.latestPublished'), findsOneWidget);
      expect(find.text('workflow.common.restore'), findsNothing);
      expect(find.text('workflow.versionHistory.defaultName'), findsNothing);
      expect(find.text('workflow.common.currentDraft'), findsOneWidget);
    });

    testWidgets('should keep workflow publishing available for an existing published version', (t) async {
      final semantics = t.ensureSemantics();
      var publishes = 0;
      await _mount(
        t,
        AppPublisher(
          app: _workflowApp,
          draftUpdatedAt: 1710000200000,
          publishedAt: 1710000100000,
          publishedWorkflow: const PublishedWorkflowInfo(id: 'v1', createdAt: 1710000100),
          onPublish: () async => publishes++,
        ),
      );
      await _toggle(t);
      expect(isDisabled(named('workflow.common.publishUpdate')), isFalse, reason: 'published: false');
      await t.tap(find.text('workflow.common.publishUpdate'));
      await _settle(t);
      expect(publishes, 1);
      semantics.dispose();
    });
  });
}
