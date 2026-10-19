// dify-spec: web/app/components/apps/__tests__/app-card.spec.tsx
import 'dart:async';
import 'dart:ui' show Tristate;

import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/studio/app_icons.dart';
import 'package:dify_sf_app/src/studio/app_modals.dart';
import 'package:dify_sf_app/src/workflow_editor/dsl/dsl_export_confirm_modal.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'card_harness.dart';
import 'harness.dart';

import 'package:dify_sf_app/src/design/widgets/widgets.dart';

const _id = 'test-app-id';

/// Moves the mouse over the card (the action bar shows, as `group-hover`).
TestGesture? _mouse;

Future<TestGesture> _hover(WidgetTester t) async {
  final center = t.getCenter(find.byKey(const ValueKey('app-card-$_id')));
  if (_mouse case final g?) {
    await g.moveTo(center);
  } else {
    final g = _mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
    await g.addPointer(location: center);
    addTearDown(() async {
      await g.removePointer();
      _mouse = null;
    });
  }
  await t.pump();
  return _mouse!;
}

Future<void> _openMenu(WidgetTester t) async {
  await _hover(t);
  await openOperations(t);
}

/// A right click at [at].
Future<void> _rightClick(WidgetTester t, Offset at) async {
  final g = await t.createGesture(kind: PointerDeviceKind.mouse, buttons: kSecondaryButton);
  await g.addPointer(location: at);
  await t.pump();
  await g.down(at);
  await g.up();
  await g.removePointer();
  await settle(t);
}

Finder get _deleteInput =>
    find.descendant(of: find.byKey(const ValueKey('delete-app-input')), matching: find.byType(EditableText));

Future<void> _openDelete(WidgetTester t) async {
  await _openMenu(t);
  await tapMenuItem(t, 'common.operation.delete');
}

Future<void> _type(WidgetTester t, Finder field, String text) async {
  await t.enterText(field, text);
  await t.pump();
}

Finder _field(String key) => find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(EditableText));

bool _focusOn(String key) => focusIsIn(find.byKey(ValueKey(key)));

void main() {
  late ScriptedAppsApi api;
  setUp(() => api = ScriptedAppsApi());

  group('AppCard', () {
    group('Rendering', () {
      testWidgets('should render preview-only app card as a dimmed information-only card', (t) async {
        final app = testApp(
          name: 'Preview Only App',
          description: 'Only visible metadata',
          authorName: 'Readonly Author',
          permissionKeys: const [AppPermissionKeys.preview],
        );
        await renderCard(t, app, api: api);
        expect(button('Preview Only App'), findsOneWidget);
        final opacity = t.widget<Opacity>(
          find.ancestor(of: find.text('Preview Only App'), matching: find.byType(Opacity)).first,
        );
        expect(opacity.opacity, 0.6);
        expect(find.text('Only visible metadata'), findsOneWidget);
        expect(find.textContaining('Readonly Author'), findsOneWidget);
        expect(buttonMatching('app.studio.starApp'), findsNothing);
        expect(buttonMatching('common.operation.moreActionsFor'), findsNothing);
        await tapButton(t, 'Preview Only App');
        expect(toastShown('app.noAccessResourcePermission'), isTrue);
      });

      testWidgets('should render preview-only starred app card as a dimmed information-only card', (t) async {
        final app = testApp(
          name: 'Preview Only Starred App',
          authorName: 'Readonly Author',
          permissionKeys: const [AppPermissionKeys.preview],
        );
        await renderCard(t, app, api: api, starred: true);
        final opacity = t.widget<Opacity>(
          find.ancestor(of: find.text('Preview Only Starred App'), matching: find.byType(Opacity)).first,
        );
        expect(opacity.opacity, 0.6);
        expect(find.textContaining('Readonly Author'), findsOneWidget);
        expect(buttonMatching('app.studio.starApp'), findsNothing);
        expect(buttonMatching('common.operation.moreActionsFor'), findsNothing);
        await tapButton(t, 'Preview Only Starred App');
        expect(toastShown('app.noAccessResourcePermission'), isTrue);
      });

      testWidgets('should display app name', (t) async {
        await renderCard(t, testApp(), api: api);
        expect(find.text('Test App'), findsOneWidget);
      });

      testWidgets('should display app description', (t) async {
        await renderCard(t, testApp(), api: api);
        expect(find.text('Test app description'), findsOneWidget);
      });

      testWidgets('should display author name', (t) async {
        await renderCard(t, testApp(), api: api);
        expect(find.textContaining('Test Author'), findsOneWidget);
      });

      testWidgets('should render app icon', (t) async {
        await renderCard(t, testApp(), api: api);
        final icon = find.byType(DifyAppIcon);
        expect(icon, findsOneWidget);
        expect(find.descendant(of: icon, matching: find.text('🤖')), findsOneWidget);
        // Decorative: the tile is not in the accessibility tree.
        expect(find.descendant(of: icon, matching: find.byType(ExcludeSemantics)), findsWidgets);
      });

      testWidgets('should treat a redundant image icon as decorative', (t) async {
        await renderCard(
          t,
          testApp(iconType: 'image', iconUrl: 'https://example.com/app-icon.png'),
          api: api,
        );
        final image = t.widget<Image>(find.descendant(of: find.byType(DifyAppIcon), matching: find.byType(Image)));
        expect(image.excludeFromSemantics, isTrue);
      });

      testWidgets('should render app type icon', (t) async {
        await renderCard(t, testApp(), api: api);
        expect(find.byType(AppTypeIcon), findsOneWidget);
      });

      testWidgets('should display formatted edit time', (t) async {
        await renderCard(t, testApp(), api: api);
        expect(find.textContaining(RegExp('edited', caseSensitive: false)), findsOneWidget);
      });
    });

    group('Props', () {
      testWidgets('should handle different app modes', (t) async {
        await renderCard(t, testApp(mode: AppModes.workflow), api: api);
        expect(button('Test App'), findsOneWidget);
      });
    });

    group('Web app access control entry points', () {
      testWidgets('should not render the access mode icon or tooltip trigger', (t) async {
        await renderCard(t, testApp(), api: api);
        expect(find.text('app.accessItemsDescription.anyone'), findsNothing);
      });
    });

    group('Card Interaction', () {
      testWidgets('should render card navigation as a link', (t) async {
        final calls = await renderCard(t, testApp(), api: api);
        final node = t.getSemantics(find.byKey(const ValueKey('app-card-link-$_id'))).getSemanticsData();
        expect(node.flagsCollection.isButton, isTrue);
        expect(node.label, 'Test App');
        expect(node.hint, 'Test app description');
        await tapButton(t, 'Test App');
        expect(calls.opened.single.app.id, _id);
      });

      testWidgets('should keep card navigation and actions as sibling focus targets', (t) async {
        await renderCard(t, testApp(), api: api);
        await t.sendKeyEvent(LogicalKeyboardKey.tab);
        await t.pump();
        expect(_focusOn('app-card-link-$_id'), isTrue);
        expect(_focusOn('app-card-star-$_id'), isFalse);
        await t.sendKeyEvent(LogicalKeyboardKey.tab);
        await t.pump();
        expect(_focusOn('app-card-star-$_id'), isTrue);
        await t.sendKeyEvent(LogicalKeyboardKey.tab);
        await t.pump();
        expect(_focusOn('app-card-more-$_id'), isTrue);
      });

      testWidgets('should star the app from the card action without navigating', (t) async {
        final calls = await renderCard(t, testApp(), api: api);
        await _hover(t);
        final star = t.getSemantics(find.byKey(const ValueKey('app-card-star-$_id'))).getSemanticsData();
        expect(star.label, 'app.studio.starApp: Test App');
        expect(star.flagsCollection.isToggled, Tristate.isFalse);
        await tapButton(t, 'app.studio.starApp: Test App');
        expect(api.last('star'), {'id': _id});
        expect(calls.opened, isEmpty);
      });

      testWidgets('should unstar the app from the filled star action', (t) async {
        await renderCard(t, testApp(isStarred: true), api: api);
        final g = await _hover(t);
        final star = t.getSemantics(find.byKey(const ValueKey('app-card-star-$_id'))).getSemanticsData();
        expect(star.flagsCollection.isToggled, Tristate.isTrue);
        await g.moveTo(t.getCenter(find.byKey(const ValueKey('app-card-star-$_id'))));
        await settle(t);
        expect(find.text('app.studio.starApp'), findsOneWidget);
        await tapButton(t, 'app.studio.starApp: Test App');
        expect(api.last('unstar'), {'id': _id});
      });
    });

    group('Operations Menu', () {
      testWidgets('should show edit option when dropdown menu is opened', (t) async {
        final calls = await renderCard(t, testApp(), api: api);
        await _openMenu(t);
        expect(find.text('app.editApp'), findsOneWidget);
        expect(calls.opened, isEmpty);
      });

      testWidgets('should expose the same operations from the card context menu', (t) async {
        await renderCard(t, testApp(), api: api);
        await _rightClick(t, t.getTopLeft(find.byKey(const ValueKey('app-card-$_id'))) + const Offset(40, 120));
        expect(find.text('app.editApp'), findsOneWidget);
        expect(find.text('app.duplicate'), findsOneWidget);
        expect(find.text('app.export'), findsOneWidget);
      });

      testWidgets('should keep card actions outside the card context menu trigger', (t) async {
        await renderCard(t, testApp(), api: api);
        await _rightClick(t, t.getCenter(find.byKey(const ValueKey('app-card-star-$_id'))));
        expect(find.text('app.editApp'), findsNothing);
      });

      testWidgets('should show duplicate option when dropdown menu is opened', (t) async {
        await renderCard(t, testApp(), api: api);
        await _openMenu(t);
        expect(find.text('app.duplicate'), findsOneWidget);
      });

      testWidgets('should show duplicate option when user can create apps without app import export permission', (
        t,
      ) async {
        await renderCard(t, testApp(permissionKeys: const [AppPermissionKeys.viewLayout]), api: api);
        await _openMenu(t);
        expect(find.text('app.duplicate'), findsOneWidget);
        expect(find.text('app.export'), findsNothing);
      });

      testWidgets(
        'should show duplicate option on starred cards when user can create apps without app import export permission',
        (t) async {
          await renderCard(t, testApp(permissionKeys: const [AppPermissionKeys.viewLayout]), api: api, starred: true);
          await _openMenu(t);
          expect(find.text('app.duplicate'), findsOneWidget);
          expect(find.text('app.export'), findsNothing);
        },
      );

      testWidgets('should show export option when dropdown menu is opened', (t) async {
        await renderCard(t, testApp(), api: api);
        await _openMenu(t);
        expect(find.text('app.export'), findsOneWidget);
      });

      testWidgets('should show delete option when dropdown menu is opened', (t) async {
        await renderCard(t, testApp(), api: api);
        await _openMenu(t);
        expect(find.text('common.operation.delete'), findsOneWidget);
      });

      testWidgets('should not show switch option for workflow mode apps', (t) async {
        await renderCard(t, testApp(mode: AppModes.workflow), api: api);
        await _openMenu(t);
        expect(find.textContaining(RegExp('switch', caseSensitive: false)), findsNothing);
      });
    });

    group('Modal Interactions', () {
      testWidgets('should open edit modal when edit button is clicked', (t) async {
        await renderCard(t, testApp(), api: api);
        await _openMenu(t);
        await tapMenuItem(t, 'app.editApp');
        expect(find.byType(EditAppModal), findsOneWidget);
      });

      testWidgets('should open duplicate modal when duplicate button is clicked', (t) async {
        await renderCard(t, testApp(), api: api);
        await _openMenu(t);
        await tapMenuItem(t, 'app.duplicate');
        expect(find.byType(DuplicateAppModal), findsOneWidget);
      });

      testWidgets('should open confirm dialog when delete button is clicked', (t) async {
        await renderCard(t, testApp(), api: api);
        await _openDelete(t);
        expect(find.byType(DeleteAppDialog), findsOneWidget);
        expect(find.byType(StudioAlertSurface), findsOneWidget);
      });

      testWidgets('should autofill the app name for delete confirmation', (t) async {
        await renderCard(t, testApp(), api: api);
        await _openDelete(t);
        expect(isEnabled('common.operation.confirm'), isFalse);
        await tapButton(t, 'common.operation.fill');
        expect(t.widget<EditableText>(_deleteInput).controller.text, 'Test App');
        expect(isEnabled('common.operation.confirm'), isTrue);
      });

      testWidgets('should close confirm dialog when cancel is clicked', (t) async {
        await renderCard(t, testApp(), api: api);
        await _openDelete(t);
        expect(find.byType(DeleteAppDialog), findsOneWidget);
        await tapButton(t, 'common.operation.cancel');
        expect(find.byType(DeleteAppDialog), findsNothing);
      });

      testWidgets('should not submit delete when confirmation text does not match', (t) async {
        await renderCard(t, testApp(), api: api);
        await _openDelete(t);
        await t.showKeyboard(_deleteInput);
        await t.testTextInput.receiveAction(TextInputAction.done);
        await settle(t);
        expect(api.count('delete'), 0);
      });

      testWidgets('should close edit modal when onHide is called', (t) async {
        await renderCard(t, testApp(), api: api);
        await _openMenu(t);
        await tapMenuItem(t, 'app.editApp');
        expect(find.byType(EditAppModal), findsOneWidget);
        await t.tap(find.byKey(const ValueKey('app-modal-cancel')));
        await settle(t);
        expect(find.byType(EditAppModal), findsNothing);
      });

      testWidgets('should close duplicate modal when onHide is called', (t) async {
        await renderCard(t, testApp(), api: api);
        await _openMenu(t);
        await tapMenuItem(t, 'app.duplicate');
        expect(find.byType(DuplicateAppModal), findsOneWidget);
        await t.tap(find.byKey(const ValueKey('duplicate-cancel')));
        await settle(t);
        expect(find.byType(DuplicateAppModal), findsNothing);
      });

      testWidgets('should clear delete confirmation input after closing the dialog', (t) async {
        await renderCard(t, testApp(), api: api);
        await _openDelete(t);
        await _type(t, _deleteInput, 'partial name');
        await tapButton(t, 'common.operation.cancel');
        expect(find.byType(DeleteAppDialog), findsNothing);
        await _openDelete(t);
        expect(t.widget<EditableText>(_deleteInput).controller.text, '');
      });
    });

    group('API Callbacks', () {
      testWidgets('should call deleteApp API when confirming delete', (t) async {
        await renderCard(t, testApp(), api: api);
        await _openDelete(t);
        await _type(t, _deleteInput, 'Test App');
        await tapButton(t, 'common.operation.confirm');
        expect(api.last('delete'), {'id': _id});
        expect(toastShown('app.appDeleted'), isTrue);
        expect(find.byType(DeleteAppDialog), findsNothing);
      });

      testWidgets('should handle delete failure', (t) async {
        api.failures['delete'] = const TransportException('Delete failed');
        await renderCard(t, testApp(), api: api);
        await _openDelete(t);
        await _type(t, _deleteInput, 'Test App');
        await tapButton(t, 'common.operation.confirm');
        expect(api.count('delete'), 1);
        expect(toastShown('Delete failed', contains: true), isTrue);
      });

      testWidgets('should handle delete failure without an error message', (t) async {
        api.failures['delete'] = const FormatException();
        await renderCard(t, testApp(), api: api);
        await _openDelete(t);
        await _type(t, _deleteInput, 'Test App');
        await tapButton(t, 'common.operation.confirm');
        expect(api.count('delete'), 1);
        expect(toastShown('app.appDeleteFailed'), isTrue);
      });

      testWidgets('should update the app and close the edit modal', (t) async {
        await renderCard(t, testApp(), api: api);
        await _openMenu(t);
        await tapMenuItem(t, 'app.editApp');
        await _type(t, _field('app-modal-name'), 'Updated App');
        await _type(t, _field('app-modal-description'), 'Updated description');
        await t.tap(find.byKey(const ValueKey('app-modal-submit')));
        await settle(t);
        expect(api.last('update'), {
          'id': _id,
          'name': 'Updated App',
          'icon_type': 'emoji',
          'icon': '🤖',
          'icon_background': '#FFEAD5',
          'description': 'Updated description',
          'use_icon_as_answer_icon': false,
          'max_active_requests': null,
        });
        expect(find.byType(EditAppModal), findsNothing);
      });

      testWidgets('should call copyApp API when duplicating app', (t) async {
        final calls = await renderCard(t, testApp(), api: api);
        await _openMenu(t);
        await tapMenuItem(t, 'app.duplicate');
        await t.tap(find.byKey(const ValueKey('duplicate-submit')));
        await settle(t);
        expect(api.last('copy')['id'], _id);
        expect(toastShown('app.newApp.appCreated'), isTrue);
        expect(calls.opened.single.app.id, 'new-app-id');
      });

      testWidgets('should handle copy failure', (t) async {
        api.failures['copy'] = const TransportException('Copy failed');
        await renderCard(t, testApp(), api: api);
        await _openMenu(t);
        await tapMenuItem(t, 'app.duplicate');
        await t.tap(find.byKey(const ValueKey('duplicate-submit')));
        await settle(t);
        expect(api.count('copy'), 1);
        expect(toastShown('app.newApp.appCreateFailed'), isTrue);
      });

      testWidgets('should export the app DSL when exporting', (t) async {
        final calls = await renderCard(t, testApp(), api: api);
        await _openMenu(t);
        await tapMenuItem(t, 'app.export');
        expect(api.last('exportDsl'), {'id': _id, 'include_secret': false});
        expect(calls.envCalls, isEmpty);
        expect(calls.saved.single.name, 'Test App.yml');
      });

      testWidgets('should prevent duplicate exports while an app DSL export is pending', (t) async {
        final hold = api.hold['exportDsl'] = Completer<void>();
        await renderCard(t, testApp(), api: api);
        await _openMenu(t);
        await tapMenuItem(t, 'app.export');
        expect(isEnabled('common.operation.exporting'), isFalse);
        hold.complete();
        await settle(t);
        expect(buttonMatching('common.operation.moreActionsFor'), findsOneWidget);
      });
    });

    group('Workflow Export with Environment Variables', () {
      testWidgets('should use the workflow export command for workflow apps', (t) async {
        final calls = await renderCard(t, testApp(mode: AppModes.workflow), api: api);
        await _openMenu(t);
        await tapMenuItem(t, 'app.export');
        expect(calls.envCalls, [_id]);
        expect(calls.saved.single.name, 'Test App.yml');
      });

      testWidgets('should show DSL export modal when workflow has secret variables', (t) async {
        final calls = StudioCalls()
          ..env = const [
            {'value_type': 'secret', 'name': 'API_KEY', 'value': 'secret'},
          ];
        await renderCard(
          t,
          testApp(mode: AppModes.workflow),
          api: api,
          calls: calls,
        );
        await _openMenu(t);
        await tapMenuItem(t, 'app.export');
        expect(find.byType(DslExportConfirmContent), findsOneWidget);
        expect(api.count('exportDsl'), 0);
      });

      testWidgets('should not open a modal when the workflow command downloads directly', (t) async {
        final calls = await renderCard(t, testApp(mode: AppModes.workflow), api: api);
        await _openMenu(t);
        await tapMenuItem(t, 'app.export');
        expect(calls.envCalls, [_id]);
        expect(find.byType(DslExportConfirmContent), findsNothing);
      });

      testWidgets('should use the workflow export command for advanced chat apps', (t) async {
        final calls = await renderCard(t, testApp(mode: AppModes.advancedChat), api: api);
        await _openMenu(t);
        await tapMenuItem(t, 'app.export');
        expect(calls.envCalls, [_id]);
        expect(calls.saved.single.name, 'Test App.yml');
      });

      testWidgets('should close DSL export modal when onClose is called', (t) async {
        final calls = StudioCalls()
          ..env = const [
            {'value_type': 'secret', 'name': 'API_KEY', 'value': 'secret'},
          ];
        await renderCard(
          t,
          testApp(mode: AppModes.workflow),
          api: api,
          calls: calls,
        );
        await _openMenu(t);
        await tapMenuItem(t, 'app.export');
        expect(find.byType(DslExportConfirmContent), findsOneWidget);
        await t.tap(find.byKey(const ValueKey('dsl-export-cancel')));
        await settle(t);
        expect(find.byType(DslExportConfirmContent), findsNothing);
      });
    });

    group('Edit mutation', () {
      testWidgets('should handle edit failure', (t) async {
        api.failures['update'] = const TransportException('Edit failed');
        await renderCard(t, testApp(), api: api);
        await _openMenu(t);
        await tapMenuItem(t, 'app.editApp');
        await t.tap(find.byKey(const ValueKey('app-modal-submit')));
        await settle(t);
        expect(api.count('update'), 1);
        expect(toastShown('Edit failed', contains: true), isTrue);
      });

      testWidgets('should fall back to the default edit failure message', (t) async {
        api.failures['update'] = const TransportException('');
        await renderCard(t, testApp(), api: api);
        await _openMenu(t);
        await tapMenuItem(t, 'app.editApp');
        await t.tap(find.byKey(const ValueKey('app-modal-submit')));
        await settle(t);
        expect(api.count('update'), 1);
        expect(toastShown('app.editFailed'), isTrue);
      });
    });

    group('Operations behavior', () {
      testWidgets('should close operations menu after selecting an item', (t) async {
        await renderCard(t, testApp(), api: api);
        await _openMenu(t);
        await tapMenuItem(t, 'app.editApp');
        expect(find.text('app.duplicate'), findsNothing);
        expect(find.byType(EditAppModal), findsOneWidget);
      });
    });

    group('WebApp Auth Enabled', () {
      testWidgets('should omit web app access control when webapp_auth is enabled', (t) async {
        await renderCard(t, testApp(), api: api);
        await _openMenu(t);
        expect(find.text('app.editApp'), findsOneWidget);
        expect(find.text('app.accessControl'), findsNothing);
      });

      testWidgets('should omit web app access control for release-and-version permission', (t) async {
        await renderCard(
          t,
          testApp(permissionKeys: const [AppPermissionKeys.releaseAndVersion, AppPermissionKeys.delete]),
          api: api,
        );
        await _openMenu(t);
        expect(find.text('common.operation.delete'), findsOneWidget);
        expect(find.text('app.accessControl'), findsNothing);
      });

      testWidgets('should hide resource access option when RBAC is disabled', (t) async {
        await renderCard(
          t,
          testApp(permissionKeys: const [AppPermissionKeys.accessConfig, AppPermissionKeys.delete]),
          api: api,
        );
        await _openMenu(t);
        expect(find.text('common.operation.delete'), findsOneWidget);
        expect(find.text('common.settings.resourceAccess'), findsNothing);
      });
    });
  });
}
