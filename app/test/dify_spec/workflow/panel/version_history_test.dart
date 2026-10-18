// dify-spec: web/app/components/workflow/panel/version-history-panel/__tests__/index.spec.tsx
// dify-spec: web/app/components/workflow/panel/version-history-panel/__tests__/version-history-item.spec.tsx
// dify-spec: web/app/components/workflow/panel/version-history-panel/__tests__/restore-confirm-modal.spec.tsx
// dify-spec: web/app/components/workflow/panel/version-history-panel/__tests__/delete-confirm-modal.spec.tsx
// dify-spec: web/app/components/workflow/panel/version-history-panel/action-menu/__tests__/action-menu-item.spec.tsx
// dify-spec: web/app/components/workflow/panel/version-history-panel/action-menu/__tests__/index.spec.tsx
// dify-spec: web/app/components/workflow/panel/version-history-panel/action-menu/__tests__/use-action-menu.spec.tsx
// dify-spec: web/app/components/workflow/panel/version-history-panel/filter/__tests__/filter-item.spec.tsx
// dify-spec: web/app/components/workflow/panel/version-history-panel/filter/__tests__/filter-switch.spec.tsx
// dify-spec: web/app/components/workflow/panel/version-history-panel/filter/__tests__/index.spec.tsx
// dify-spec: web/app/components/workflow/panel/version-history-panel/filter/__tests__/use-filter.spec.tsx
//
// The version history panel. Dify's mocked services (the version list query, restore / update requests, the
// useWorkflowRun hooks) are the panel's VersionHistoryPanelData callbacks; the store is the real one.
import 'dart:ui' show Tristate;

import 'package:flutter/gestures.dart' show PointerDeviceKind;

import 'package:dify_sf_app/src/design/dify_icon.dart';
import 'package:dify_sf_app/src/design/dify_tokens.g.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/controls.dart' show DifySwitch;
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:dify_sf_app/src/workflow_editor/version_history/version_history_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../dify_test_i18n.dart';
import '../header/harness.dart';

DifyJson _version({
  String id = 'version-1',
  String version = '2024-01-01T00:00:00Z',
  String markedName = 'Release 1',
  String markedComment = 'Initial release',
  int? versionNumber,
  List<DifyJson>? environments,
}) => {
  'id': id,
  'version': version,
  'marked_name': markedName,
  'marked_comment': markedComment,
  'version_number': ?versionNumber,
  'created_at': 1710000000,
  'created_by': {'id': 'user-1', 'name': 'Alice', 'email': 'alice@example.com'},
  'environments': ?environments,
};

/// The recorded calls of the panel's host.
class _Host {
  final loadBackupDraft = <int>[];
  final restoreFromPublished = <DifyJson>[];
  final restored = <String>[];
  final updated = <(String, String, String)>[];
  final exported = <String>[];
  final toasts = <(DifyToastType, String)>[];
  var refreshDraft = 0, invalidateApp = 0, fetches = 0;
  bool failRestore = false;
  bool hasMore = false;
  List<DifyJson>? environments;

  VersionHistoryPanelData data() => VersionHistoryPanelData(
    latestVersionId: 'published-version-id',
    currentUserId: 'user-1',
    fetchVersions: ({required page, required limit, required userId, required namedOnly}) async {
      fetches++;
      return (
        items: page == 1
            ? [
                _version(id: 'draft-version-id', version: 'draft', markedName: '', markedComment: ''),
                _version(
                  id: 'published-version-id',
                  markedName: 'v1.0',
                  markedComment: 'First release',
                  environments: environments,
                ),
              ]
            : [_version(id: 'older-version-id', markedName: 'v0.9')],
        hasMore: hasMore && page == 1,
      );
    },
    handleLoadBackupDraft: () => loadBackupDraft.add(1),
    handleRestoreFromPublishedWorkflow: restoreFromPublished.add,
    handleRefreshWorkflowDraft: () => refreshDraft++,
    restoreVersion: (id) async {
      if (failRestore) throw StateError('restore failed');
      restored.add(id);
    },
    updateVersion: (id, {required title, required releaseNotes}) async => updated.add((id, title, releaseNotes)),
    exportDsl: exported.add,
    invalidateAppWorkflow: () => invalidateApp++,
    toast: (type, m) => toasts.add((type, m)),
  );
}

Future<WorkflowStore> _renderPanel(WidgetTester t, _Host host, {void Function(WorkflowStore s)? init}) async {
  final store = await renderWorkflowComponent(
    t,
    SizedBox(height: 600, child: VersionHistoryPanel(data: host.data())),
    initialStoreState: init,
  );
  await t.pump();
  await t.pump();
  return store;
}

Finder _named(String label) => find.bySemanticsLabel(label);

/// Hovers the version [name]'s row and opens its action menu.
Future<void> _openMenu(WidgetTester t, String name) async {
  final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: Offset.zero);
  addTearDown(mouse.removePointer);
  await mouse.moveTo(t.getCenter(_named(name).first));
  await t.pump();
  await t.tap(_named('common.operation.more').last);
  await settle(t);
}

Future<void> _menuAction(WidgetTester t, String version, String action) async {
  await _openMenu(t, version);
  await t.tap(find.text(action).last);
  await settle(t);
}

Widget _item(
  DifyJson item, {
  DifyJson? currentVersion,
  String latestVersionId = 'latest-version',
  ValueChanged<DifyJson>? onClick,
  ValueChanged<VersionHistoryAction>? onAction,
  bool canImportExportDsl = true,
  bool isLast = false,
}) => SizedBox(
  width: 268,
  child: VersionHistoryItem(
    item: item,
    currentVersion: currentVersion,
    latestVersionId: latestVersionId,
    onClick: onClick ?? (_) {},
    handleClickActionMenuItem: onAction ?? (_) {},
    canImportExportDsl: canImportExportDsl,
    isLast: isLast,
  ),
);

const BackupDraft _backup = (
  nodes: [],
  edges: [],
  viewport: (x: 0.0, y: 0.0, zoom: 1.0),
  features: null,
  environmentVariables: [],
);

void main() {
  group('VersionHistoryPanel', () {
    testWidgets('should expose close and pagination actions as accessible buttons', (t) async {
      final host = _Host()..hasMore = true;
      final store = await _renderPanel(
        t,
        host,
        init: (s) => s
          ..isRestoring.value = true
          ..setShowWorkflowVersionHistoryPanel(true),
      );
      expect(host.fetches, 1);
      await t.tap(_named('workflow.common.loadMore'));
      await t.pump();
      await t.pump();
      expect(host.fetches, 2);
      expect(find.text('v0.9'), findsOneWidget);
      expect(host.loadBackupDraft, isNotEmpty);
      host.loadBackupDraft.clear();
      await t.tap(_named('common.operation.close'));
      await t.pump();
      expect(host.loadBackupDraft, hasLength(1));
      expect(store.isRestoring.value, isFalse);
      expect(store.showWorkflowVersionHistoryPanel.value, isFalse);
    });

    group('Version Click Behavior', () {
      testWidgets('should call handleLoadBackupDraft when draft version is selected on mount', (t) async {
        final host = _Host();
        await _renderPanel(t, host);
        expect(host.loadBackupDraft, isNotEmpty);
        expect(host.restoreFromPublished, isEmpty);
      });

      testWidgets('should call handleRestoreFromPublishedWorkflow when clicking published version', (t) async {
        final host = _Host();
        await _renderPanel(t, host);
        host.loadBackupDraft.clear();
        await t.tap(_named('v1.0').first);
        await t.pump();
        expect(host.restoreFromPublished.single['id'], 'published-version-id');
        expect(host.loadBackupDraft, isEmpty);
      });
    });

    testWidgets('should set current version before confirming restore from context menu', (t) async {
      final host = _Host();
      final store = await _renderPanel(
        t,
        host,
        init: (s) => s
          ..isRestoring.value = true
          ..backupDraft.value = _backup
          ..setShowWorkflowVersionHistoryPanel(true),
      );
      await _menuAction(t, 'v1.0', 'workflow.common.restore');
      expect(find.text('workflow.common.restore v1.0'), findsOneWidget);
      await t.tap(find.widgetWithText(DifyButton, 'workflow.common.restore'));
      await settle(t);
      expect(store.currentVersion.value?['id'], 'published-version-id');
      expect(host.restored, ['published-version-id']);
      expect(store.isRestoring.value, isFalse);
      expect(store.backupDraft.value, isNull);
      expect(host.refreshDraft, 1);
    });

    testWidgets('should block deleting a version deployed to an environment', (t) async {
      final host = _Host()
        ..environments = [
          {'id': 'environment-id', 'name': 'Production'},
        ];
      await _renderPanel(t, host);
      // The latest version has no Delete; the item's menu callback is what Dify's mock clicks.
      t
          .widget<VersionHistoryItem>(find.byKey(const ValueKey('published-version-id')))
          .handleClickActionMenuItem(
            VersionHistoryAction.delete,
          );
      await settle(t);
      expect(host.toasts.single, (DifyToastType.error, 'workflow.versionHistory.action.deleteDeployedVersionError'));
      expect(find.text('workflow.versionHistory.deletionTip'), findsNothing);
    });

    testWidgets('should allow deleting a version that is not deployed', (t) async {
      final host = _Host();
      await _renderPanel(t, host);
      t
          .widget<VersionHistoryItem>(find.byKey(const ValueKey('published-version-id')))
          .handleClickActionMenuItem(
            VersionHistoryAction.delete,
          );
      await settle(t);
      expect(find.text('workflow.versionHistory.deletionTip'), findsOneWidget);
      expect(host.toasts, isEmpty);
    });

    testWidgets('should keep restore mode backup state when restore request fails', (t) async {
      final host = _Host()..failRestore = true;
      const backup = _backup;
      final draft = _version(id: 'draft-version-id', version: 'draft', markedName: '', markedComment: '');
      final store = await _renderPanel(
        t,
        host,
        init: (s) => s
          ..setCurrentVersion(draft)
          ..isRestoring.value = true
          ..backupDraft.value = backup,
      );
      await _menuAction(t, 'v1.0', 'workflow.common.restore');
      await t.tap(find.widgetWithText(DifyButton, 'workflow.common.restore'));
      await settle(t);
      expect(store.isRestoring.value, isTrue);
      expect(store.backupDraft.value, same(backup));
      expect(store.currentVersion.value?['id'], 'draft-version-id');
      expect(host.refreshDraft, 0);
      expect(host.toasts.last, (DifyToastType.error, 'workflow.versionHistory.action.restoreFailure'));
    });

    testWidgets('should refresh the published workflow after editing the latest app version', (t) async {
      final host = _Host();
      await _renderPanel(t, host);
      await _menuAction(t, 'v1.0', 'workflow.versionHistory.editVersionInfo');
      await t.enterText(find.byType(EditableText).first, 'Updated release');
      await t.tap(find.widgetWithText(DifyButton, 'common.operation.save').last);
      await settle(t);
      expect(host.updated.single.$1, 'published-version-id');
      expect(host.updated.single.$2, 'Updated release');
      expect(host.invalidateApp, 1);
      expect(host.toasts.last, (DifyToastType.success, 'workflow.versionHistory.action.updateSuccess'));
    });
  });

  group('VersionHistoryItem', () {
    group('Draft Behavior', () {
      testWidgets('should auto-select the draft version on mount', (t) async {
        final clicks = <DifyJson>[];
        await renderWorkflowComponent(
          t,
          _item(
            _version(id: 'draft-version', version: 'draft', markedName: '', markedComment: ''),
            onClick: clicks.add,
          ),
        );
        await t.pump();
        expect(find.text('workflow.versionHistory.currentDraft'), findsOneWidget);
        expect(clicks.single['version'], 'draft');
        expect(find.text('Initial release'), findsNothing);
      });
    });

    group('Published Items', () {
      testWidgets('should show the version number when the published version has no marked name', (t) async {
        await renderWorkflowComponent(
          t,
          _item(_version(markedName: '', versionNumber: 5), latestVersionId: 'other-version'),
        );
        expect(find.text('# 5'), findsOneWidget);
        expect(find.text('2024-01-01T00:00:00Z'), findsNothing);
      });

      testWidgets('should show the environments deployed from the published version', (t) async {
        await renderWorkflowComponent(
          t,
          _item(
            _version(
              environments: [
                {'id': 'environment-staging', 'name': 'Staging'},
                {'id': 'environment-production', 'name': 'Production'},
              ],
            ),
            latestVersionId: 'version-1',
          ),
        );
        expect(find.text('Staging'), findsOneWidget);
        expect(find.text('Production'), findsOneWidget);
      });

      testWidgets('should open the context menu for a latest named version and forward restore', (t) async {
        final actions = <VersionHistoryAction>[];
        final clicks = <DifyJson>[];
        await renderWorkflowComponent(
          t,
          _item(_version(), latestVersionId: 'version-1', onAction: actions.add, onClick: clicks.add),
        );
        await _openMenu(t, 'Release 1');
        expect(find.text('WORKFLOW.VERSIONHISTORY.LATEST'), findsOneWidget);
        expect(find.text('Initial release'), findsOneWidget);
        expect(find.textContaining(RegExp(r'Alice$')), findsOneWidget);
        expect(find.text('workflow.common.restore'), findsOneWidget);
        expect(find.text('workflow.versionHistory.editVersionInfo'), findsOneWidget);
        expect(find.text('app.export'), findsOneWidget);
        expect(find.text('workflow.versionHistory.copyId'), findsOneWidget);
        expect(find.text('version-1'), findsOneWidget);
        expect(find.text('common.operation.delete'), findsNothing);
        await t.tap(find.text('workflow.common.restore'));
        await settle(t);
        expect(actions, [VersionHistoryAction.restore]);
        expect(clicks, isEmpty);
      });

      testWidgets('should hide export from the context menu when import/export DSL permission is missing', (t) async {
        await renderWorkflowComponent(
          t,
          _item(_version(), latestVersionId: 'version-1', canImportExportDsl: false),
        );
        await _openMenu(t, 'Release 1');
        expect(find.text('app.export'), findsNothing);
        expect(find.text('workflow.versionHistory.copyId'), findsOneWidget);
      });

      testWidgets('should ignore clicks when the item is already selected', (t) async {
        final clicks = <DifyJson>[];
        final item = _version();
        await renderWorkflowComponent(
          t,
          _item(item, currentVersion: item, latestVersionId: 'other-version', onClick: clicks.add, isLast: true),
        );
        final sem = t.getSemantics(_named('Release 1').first).getSemanticsData();
        expect(sem.flagsCollection.isSelected, isNot(Tristate.isFalse));
        await t.tap(_named('Release 1').first);
        await t.pump();
        expect(clicks, isEmpty);
      });

      testWidgets('should expose the version and action menu in keyboard order', (t) async {
        await renderWorkflowComponent(t, _item(_version(), latestVersionId: 'version-1', isLast: true));
        await t.sendKeyEvent(LogicalKeyboardKey.tab);
        await t.pump();
        final primary = FocusManager.instance.primaryFocus!;
        expect(
          find.ancestor(
            of: find.byElementPredicate((e) => e == primary.context),
            matching: find.byKey(const ValueKey('version-version-1')),
          ),
          findsOneWidget,
        );
        await t.sendKeyEvent(LogicalKeyboardKey.tab);
        await t.pump();
        expect(
          find.ancestor(
            of: find.byElementPredicate((e) => e == FocusManager.instance.primaryFocus!.context),
            matching: find.byWidgetPredicate((w) => w is DifyIconButton && w.label == 'common.operation.more'),
          ),
          findsOneWidget,
        );
      });
    });
  });

  group('RestoreConfirmModal', () {
    testWidgets('renders the version name and triggers restore and close actions', (t) async {
      var closes = 0;
      final restores = <DifyJson>[];
      final info = _version(version: '1', markedComment: '');
      await renderWorkflowComponent(
        t,
        RestoreConfirmModal(versionInfo: info, onClose: () => closes++, onRestore: restores.add),
      );
      expect(find.text('workflow.common.restore Release 1'), findsOneWidget);
      await t.tap(find.text('common.operation.cancel'));
      await t.tap(find.text('workflow.common.restore'));
      expect(closes, 1);
      expect(restores, [info]);
    });

    testWidgets('renders the version number when the marked name is empty', (t) async {
      await renderWorkflowComponent(
        t,
        RestoreConfirmModal(
          versionInfo: _version(markedName: '', versionNumber: 5),
          onClose: () {},
          onRestore: (_) {},
        ),
      );
      expect(find.text('workflow.common.restore # 5'), findsOneWidget);
    });
  });

  group('DeleteConfirmModal', () {
    testWidgets('renders the version name and triggers delete and close actions', (t) async {
      var closes = 0;
      final deletes = <String>[];
      await renderWorkflowComponent(
        t,
        DeleteConfirmModal(versionInfo: _version(), onClose: () => closes++, onDelete: deletes.add),
      );
      expect(find.text('common.operation.delete Release 1'), findsOneWidget);
      await t.tap(find.text('common.operation.cancel'));
      await t.tap(find.text('common.operation.delete'));
      expect(closes, 1);
      expect(deletes, ['version-1']);
    });

    testWidgets('renders the default name for a legacy version without a version number', (t) async {
      await renderWorkflowComponent(
        t,
        DeleteConfirmModal(
          versionInfo: _version(markedName: ''),
          onClose: () {},
          onDelete: (_) {},
        ),
      );
      expect(find.text('common.operation.delete workflow.versionHistory.defaultName'), findsOneWidget);
    });
  });

  group('ActionMenuItem', () {
    testWidgets('forwards the selected operation and supports destructive styling', (t) async {
      final clicks = <VersionHistoryAction>[];
      await renderWorkflowComponent(
        t,
        DifyDropdownMenu(
          open: true,
          builder: (context, c) => const SizedBox(width: 10, height: 10),
          children: [
            VersionHistoryActionMenuItem(
              item: (key: VersionHistoryAction.delete, name: 'Delete', description: null, disabled: false),
              isDestructive: true,
              onClick: clicks.add,
            ),
          ],
        ),
      );
      await settle(t);
      expect(
        t.widget<DifyMenuItem>(find.byType(DifyMenuItem)).variant,
        DifyMenuItemVariant.destructive,
      );
      await t.tap(find.text('Delete'));
      expect(clicks, [VersionHistoryAction.delete]);
    });
  });

  group('ActionMenu', () {
    testWidgets('toggles the trigger and forwards menu clicks', (t) async {
      final opens = <bool>[];
      final actions = <VersionHistoryAction>[];
      await renderWorkflowComponent(
        t,
        StatefulBuilder(
          builder: (context, setState) => VersionHistoryActionMenu(
            workflowId: 'version-1',
            isNamedVersion: true,
            isShowDelete: true,
            canImportExportDsl: true,
            open: opens.isEmpty || opens.last,
            setOpen: (v) => setState(() => opens.add(v)),
            handleClickActionMenuItem: actions.add,
          ),
        ),
      );
      await settle(t);
      await t.tap(_named('common.operation.more'));
      await settle(t);
      expect(opens, isNotEmpty);
      await t.tap(_named('common.operation.more'));
      await settle(t);
      await t.tap(find.text('workflow.common.restore'));
      await settle(t);
      await t.tap(_named('common.operation.more'));
      await settle(t);
      await t.tap(find.text('common.operation.delete'));
      await settle(t);
      expect(actions, [VersionHistoryAction.restore, VersionHistoryAction.delete]);
    });
  });

  group('useActionMenu', () {
    test('returns restore, edit, export, copy and delete operations for app workflows', () {
      final r = versionHistoryActionMenu(workflowId: 'version-1', isNamedVersion: true, canImportExportDsl: true);
      expect(r.deleteOperation.key, VersionHistoryAction.delete);
      expect(r.deleteOperation.name, 'common.operation.delete');
      expect(
        [for (final o in r.options) o.key],
        [
          VersionHistoryAction.restore,
          VersionHistoryAction.edit,
          VersionHistoryAction.exportDsl,
          VersionHistoryAction.copyId,
        ],
      );
    });

    test('omits export for pipelines and renames the edit action for unnamed versions', () {
      final r = versionHistoryActionMenu(
        workflowId: 'version-1',
        isNamedVersion: false,
        canImportExportDsl: true,
        isPipeline: true,
      );
      expect(r.options, [
        (key: VersionHistoryAction.restore, name: 'workflow.common.restore', description: null, disabled: false),
        (
          key: VersionHistoryAction.edit,
          name: 'workflow.versionHistory.nameThisVersion',
          description: null,
          disabled: false,
        ),
        (
          key: VersionHistoryAction.copyId,
          name: 'workflow.versionHistory.copyId',
          description: 'version-1',
          disabled: false,
        ),
      ]);
    });

    test('omits export when import/export DSL permission is missing', () {
      final r = versionHistoryActionMenu(workflowId: 'version-1', isNamedVersion: true, canImportExportDsl: false);
      expect(
        [for (final o in r.options) o.key],
        [
          VersionHistoryAction.restore,
          VersionHistoryAction.edit,
          VersionHistoryAction.copyId,
        ],
      );
    });
  });

  group('FilterItem', () {
    testWidgets('renders the label, fires selection, and shows the check mark when selected', (t) async {
      final clicks = <WorkflowVersionFilter>[];
      await renderWorkflowComponent(
        t,
        SizedBox(
          width: 248,
          child: VersionHistoryFilterItem(
            item: (key: WorkflowVersionFilter.onlyYours, name: 'Only yours'),
            isSelected: true,
            onClick: clicks.add,
          ),
        ),
      );
      final sem = t.getSemantics(_named('Only yours')).getSemanticsData();
      expect(sem.flagsCollection.isSelected, isNot(Tristate.isFalse));
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.sendKeyEvent(LogicalKeyboardKey.space);
      await t.pump();
      expect(clicks, [WorkflowVersionFilter.onlyYours]);
    });
  });

  group('FilterSwitch', () {
    testWidgets('renders the switch label and toggles through the change handler', (t) async {
      final changes = <bool>[];
      await renderWorkflowComponent(
        t,
        SizedBox(width: 248, child: VersionHistoryFilterSwitch(enabled: false, handleSwitch: changes.add)),
      );
      expect(find.text('workflow.versionHistory.filter.onlyShowNamedVersions'), findsOneWidget);
      await t.tap(find.byType(DifySwitch));
      expect(changes, [true]);
    });
  });

  group('VersionHistory Filter Components', () {
    group('FilterSwitch', () {
      testWidgets('should render the switch label and emit toggled value', (t) async {
        final changes = <bool>[];
        await renderWorkflowComponent(
          t,
          SizedBox(width: 248, child: VersionHistoryFilterSwitch(enabled: false, handleSwitch: changes.add)),
        );
        expect(find.text('workflow.versionHistory.filter.onlyShowNamedVersions'), findsOneWidget);
        expect(t.widget<DifySwitch>(find.byType(DifySwitch)).checked, isFalse);
        await t.tap(find.byType(DifySwitch));
        expect(changes, [true]);
      });
    });

    group('Filter', () {
      testWidgets('should open the menu and forward option and switch actions', (t) async {
        final filters = <WorkflowVersionFilter>[];
        final switches = <bool>[];
        await renderWorkflowComponent(
          t,
          VersionHistoryFilter(
            filterValue: WorkflowVersionFilter.all,
            isOnlyShowNamedVersions: false,
            onClickFilterItem: filters.add,
            handleSwitch: switches.add,
          ),
        );
        await t.tap(find.byKey(const Key('version-history-filter')));
        await settle(t);
        expect(find.text('workflow.versionHistory.filter.all'), findsOneWidget);
        expect(find.text('workflow.versionHistory.filter.onlyYours'), findsOneWidget);
        await t.tap(find.text('workflow.versionHistory.filter.onlyYours'));
        await t.pump();
        expect(filters, [WorkflowVersionFilter.onlyYours]);
        await t.tap(find.byType(DifySwitch));
        expect(switches, [true]);
      });

      testWidgets('should mark the trigger as active when a filter is applied', (t) async {
        await renderWorkflowComponent(
          t,
          VersionHistoryFilter(
            filterValue: WorkflowVersionFilter.onlyYours,
            isOnlyShowNamedVersions: false,
            onClickFilterItem: (_) {},
            handleSwitch: (_) {},
          ),
        );
        final box = t.widget<Container>(
          find.descendant(of: find.byKey(const Key('version-history-filter')), matching: find.byType(Container)).first,
        );
        expect((box.decoration! as BoxDecoration).color, DifyColors.stateAccentActiveAlt);
        expect(
          t.widget<RemixIcon>(find.byWidgetPredicate((w) => w is RemixIcon && w.name == 'filter-3-line')).color,
          DifyColors.textAccent,
        );
      });
    });
  });

  group('useFilterOptions', () {
    test('returns the translated version filter options', () {
      useDifyTestTranslator();
      expect(versionHistoryFilterOptions(), [
        (key: WorkflowVersionFilter.all, name: 'workflow.versionHistory.filter.all'),
        (key: WorkflowVersionFilter.onlyYours, name: 'workflow.versionHistory.filter.onlyYours'),
      ]);
    });
  });
}
