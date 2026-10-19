// The Access Point page on the in-memory server (FakeAppsApi + FakeAccessApi + FakeVersionsApi): what each community
// edition role can do, Dify's role quirks (the editor's API switch, token reset and key delete are refused with 403
// and an error toast), the unpublished banner until a workflow is published, keys and site settings.
import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart';
import 'package:dify_sf_app/src/app_detail/access/access_point_card.dart';
import 'package:dify_sf_app/src/app_detail/access/access_point_page.dart';
import 'package:dify_sf_app/src/app_detail/access/access_point_utils.dart' show clearRequestErrors;
import 'package:dify_sf_app/src/app_detail/access/api_key_modal.dart';
import 'package:dify_sf_app/src/app_detail/access/site_settings_modal.dart';
import 'package:dify_sf_app/src/app_detail/access/web_app_card.dart';
import 'package:dify_sf_app/src/design/widgets/emoji_catalog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dify_spec/access_point/harness.dart';

/// A workspace with one app created by the owner, seen by [role].
class _Fixture {
  _Fixture._(this.owner, this.view, this.appId);

  final FakeAppsApi owner, view;
  final String appId;
  late final access = FakeAccessApi(view);
  late final versions = FakeVersionsApi(view);
  late final ValueNotifier<AppInfo> app;
  var refreshes = 0;

  static Future<_Fixture> create({String mode = AppModes.advancedChat, String role = AccountRole.owner}) async {
    final owner = FakeAppsApi(clock: () => DateTime.utc(2026, 10, 19, 8, 30));
    final created = await owner.create(name: 'Support Bot', mode: mode);
    final view = role == AccountRole.owner ? owner : owner.asAccount('member', name: 'Member', role: role);
    final f = _Fixture._(owner, view, created.id);
    f.app = ValueNotifier(await view.get(created.id));
    return f;
  }

  Future<void> refresh() async {
    refreshes++;
    app.value = await view.get(appId);
  }
}

Future<_Fixture> _open(WidgetTester t, {String mode = AppModes.advancedChat, String role = AccountRole.owner}) async {
  final f = await _Fixture.create(mode: mode, role: role);
  await renderMembers(
    t,
    AccessPointPage(app: f.app, access: f.access, versions: f.versions, refreshApp: f.refresh, openUrl: (_) {}),
  );
  await settle(t);
  return f;
}

AccessPointStatus _status(WidgetTester t, int index) =>
    t.widgetList<AccessPointCard>(find.byType(AccessPointCard)).elementAt(index).status;

const _apiKeys = 'appApi.apiKeyModal.apiSecretKey';

void main() {
  setUp(() async {
    clearRequestErrors();
    await EmojiCatalog.load();
  });

  testWidgets('owner, chatflow: cards in service, API switch, keys created, listed and deleted', (t) async {
    final f = await _open(t);
    // A chatflow is not affected by publishing (Dify's shared/utils.ts).
    expect(find.text('deployments.studio.accessPoint.noPublishedTitle'), findsNothing);
    expect(_status(t, 0), AccessPointStatus.inService);
    expect(_status(t, 1), AccessPointStatus.inService);
    expect(find.text('${f.owner.origin}/chat/${f.app.value.site!.accessToken}'), findsOneWidget);
    expect(find.text('${f.owner.origin}/v1'), findsOneWidget);

    // The API switch is stored.
    await tapSwitch(t, 1);
    expect((await f.owner.get(f.appId)).enableApi, isFalse);
    expect(switchChecked(1), isFalse);

    // Keys: none, create one (shown once in full), it is listed, delete it.
    await tapButton(t, '$_apiKeys 0');
    expect(find.byType(ApiKeyModal), findsOneWidget);
    await tapButton(t, 'appApi.apiKeyModal.createNewSecretKey');
    final created = await f.access.listApiKeys(f.appId);
    expect(created.single.token, startsWith('app-'));
    expect(find.byType(CreatedApiKeyDialog), findsOneWidget);
    await tapButton(t, 'appApi.actionMsg.ok');
    expect(find.text(maskApiKeyToken(created.single.token)), findsOneWidget);
    await tapButton(t, 'common.operation.delete ${maskApiKeyToken(created.single.token)}');
    await tapButton(t, 'common.operation.confirm');
    expect(await f.access.listApiKeys(f.appId), isEmpty);
    await tapButton(t, 'common.operation.close');
    expect(button('$_apiKeys 0').evaluate(), hasLength(1));
  });

  testWidgets('owner, workflow: unpublished until published, then the cards are available', (t) async {
    final f = await _open(t, mode: AppModes.workflow);
    expect(find.text('deployments.studio.accessPoint.noPublishedTitle'), findsOneWidget);
    expect(_status(t, 0), AccessPointStatus.unavailable);
    expect(_status(t, 1), AccessPointStatus.unavailable);
    expect(isEnabled('deployments.studio.accessPoint.goToPublish'), isTrue);

    await f.versions.publish(f.appId, markedName: 'v1');
    // Publishing refetches the app (the editor calls the shell's refreshApp); the page asks for the published workflow
    // again.
    await f.refresh();
    await settle(t);
    expect(find.text('deployments.studio.accessPoint.noPublishedTitle'), findsNothing);
    expect(_status(t, 0), AccessPointStatus.inService);
    expect(_status(t, 1), AccessPointStatus.inService);
  });

  testWidgets('owner: site settings are saved and the app refetched', (t) async {
    final f = await _open(t);
    await tapButton(t, 'common.settings.settings');
    expect(find.byType(SiteSettingsModal), findsOneWidget);
    await t.enterText(
      find.descendant(of: find.byKey(const ValueKey('settings-title')), matching: find.byType(EditableText)),
      'Help Desk',
    );
    await t.tap(find.byKey(const ValueKey('settings-save')));
    await settle(t);
    expect(f.app.value.site!.title, 'Help Desk');
    expect(f.refreshes, greaterThan(0));
    expect(toastShown('common.actionMsg.modifiedSuccessfully'), isTrue);
  });

  testWidgets('owner: regenerating the access token changes the Web App URL', (t) async {
    final f = await _open(t);
    final before = f.app.value.site!.accessToken;
    await tapButton(t, 'appOverview.overview.appInfo.regenerate');
    await tapButton(t, 'common.operation.confirm');
    final after = f.app.value.site!.accessToken;
    expect(after, isNot(before));
    expect(find.text('${f.owner.origin}/chat/$after'), findsOneWidget);
  });

  testWidgets('editor: Dify quirk, the API switch looks enabled and is refused', (t) async {
    final f = await _open(t, role: AccountRole.editor);
    // The Web App switch is the editor's.
    await tapSwitch(t, 0);
    expect((await f.owner.get(f.appId)).enableSite, isFalse);

    // The API switch is shown enabled (access_point_manage), the server refuses it: rolled back with Dify's toast.
    expect(switchEnabled(1), isTrue);
    await tapSwitch(t, 1);
    expect((await f.owner.get(f.appId)).enableApi, isTrue);
    expect(switchChecked(1), isTrue);
    // Dify's request layer toasts the server's 403 message, then the mutation's own "modified unsuccessfully".
    expect(toastShown('common.actionMsg.modifiedUnsuccessfully'), isTrue);
    final refused = await f.access.setApiEnabled(f.appId, false).then<Object?>((_) => null, onError: (Object e) => e);
    expect(find.text((refused! as TransportException).message), findsOneWidget);
  });

  testWidgets('editor: regenerate is refused with Dify\'s toast', (t) async {
    final f = await _open(t, role: AccountRole.editor);
    final before = f.app.value.site!.accessToken;
    expect(isEnabled('appOverview.overview.appInfo.regenerate'), isTrue);
    await tapButton(t, 'appOverview.overview.appInfo.regenerate');
    await tapButton(t, 'common.operation.confirm');
    expect(toastShown('common.actionMsg.generatedUnsuccessfully'), isTrue);
    expect((await f.owner.get(f.appId)).site!.accessToken, before);
  });

  for (final role in [AccountRole.normal, AccountRole.datasetOperator]) {
    testWidgets('$role: the Access Point is read-only', (t) async {
      await _open(t, role: role);
      expect(find.text('common.appMenus.accessPoint'), findsOneWidget);
      expect(switchEnabled(0), isFalse);
      expect(switchEnabled(1), isFalse);
      expect(isEnabled('common.settings.settings'), isFalse);
      expect(isEnabled('appOverview.overview.appInfo.regenerate'), isFalse);
      // Keys are not even requested (the server would refuse them).
      expect(isEnabled('$_apiKeys 0'), isFalse);
      expect(t.widget<WebAppAccessPointCard>(find.byType(WebAppAccessPointCard)).canManageAccessPoint, isFalse);
    });
  }

  testWidgets('normal member, workflow: the published workflow is refused, cards unavailable without the banner', (
    t,
  ) async {
    final f = await _open(t, mode: AppModes.workflow, role: AccountRole.normal);
    // Dify: a 403 is not retried; the query errs, so no "Go to publish" banner, and the cards stay unavailable. Its
    // request layer toasts the server's message, once.
    expect(find.text('deployments.studio.accessPoint.noPublishedTitle'), findsNothing);
    expect(_status(t, 0), AccessPointStatus.unavailable);
    final refused = await f.versions.published(f.appId).then<Object?>((_) => null, onError: (Object e) => e);
    expect(refused, isA<TransportException>().having((e) => e.statusCode, 'status', 403));
    expect(find.text((refused! as TransportException).message), findsOneWidget);
  });
}
