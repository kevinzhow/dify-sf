import 'dart:async';

import 'package:collab_client/testing.dart' show FakeAppsApi;
import 'package:dify_sf_app/src/auth/auth_api.dart';
import 'package:dify_sf_app/src/auth/auth_controller.dart';
import 'package:dify_sf_app/src/auth/server_address_form.dart';
import 'package:dify_sf_app/src/home_page.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/server_connection.dart';
import 'package:dify_sf_app/src/settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/auth_fakes.dart';

Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Finder input(Key key) => find.descendant(of: find.byKey(key), matching: find.byType(EditableText));

Future<void> choose(WidgetTester t, String server) async {
  await t.enterText(input(const ValueKey('server-address-input')), server);
  await t.tap(find.byKey(const ValueKey('server-address-connect')));
  await settle(t);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => await DifyI18n.load('en-US'));
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('first launch asks before making a request; correcting the address removes the error and is remembered', (
    t,
  ) async {
    final settings = AppSettings(serverUrl: '', journaled: true, lastDoc: '');
    final requests = <String>[];
    await t.pumpWidget(
      buildApp(
        settings,
        authApiFor: (uri) {
          requests.add(uri.origin);
          return RecordingAuthApi();
        },
        tokenStore: MemoryTokenStore(),
      ),
    );
    await settle(t);
    expect(requests, isEmpty);
    expect(find.byKey(const ValueKey('server-address-input')), findsOneWidget);
    await choose(t, 'https://server.example/v1');
    expect(find.byKey(const ValueKey('server-address-error')), findsOneWidget);
    expect(requests, isEmpty);
    await choose(t, 'http://ONE.example/');
    expect(requests, ['http://one.example']);
    expect(find.byKey(const ValueKey('server-address-error')), findsNothing);
    expect(find.byKey(const ValueKey('signin-submit')), findsOneWidget);
    expect((await AppSettings.load()).serverUrl, 'http://one.example');
    await t.pumpWidget(const SizedBox());
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  for (final invalid in ['ftp://remote.example', 'https://server.example/v1']) {
    testWidgets('stored Android address $invalid requires correction before requests', (t) async {
      final requests = <String>[];
      await t.pumpWidget(
        buildApp(
          AppSettings(serverUrl: invalid, journaled: true, lastDoc: ''),
          authApiFor: (uri) {
            requests.add(uri.origin);
            return RecordingAuthApi();
          },
          tokenStore: MemoryTokenStore(),
        ),
      );
      await settle(t);
      expect(requests, isEmpty);
      expect(find.byKey(const ValueKey('server-address-input')), findsOneWidget);
      await t.pumpWidget(const SizedBox());
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  }

  testWidgets('switching from an open page closes it, keeps each server sign-in separate and restores the first one', (
    t,
  ) async {
    t.view.physicalSize = const Size(1440, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final one = RecordingAuthApi()
      ..addAccount(email: 'same@example.com', name: 'One account', id: 'one', password: 'FirstPassword9');
    final two = RecordingAuthApi();
    for (var i = 0; i < 5; i++) {
      two.addAccount(email: 'decoy$i@example.com');
    }
    two.addAccount(email: 'same@example.com', name: 'Two account', id: 'two', password: 'SecondPassword9');
    final store = MemoryTokenStore();
    final initial = await one.login(email: 'same@example.com', password: 'FirstPassword9');
    await store.write('https://one.example', initial.tokens);
    final settings = AppSettings(serverUrl: 'https://one.example', journaled: true, lastDoc: 'one-doc');
    await t.pumpWidget(
      buildApp(
        settings,
        authApiFor: (u) => u.host == 'one.example' ? one : two,
        tokenStore: store,
        studioPollInterval: null,
        appsApiFor: (_) => FakeAppsApi(),
        backendFor: (_) => throw StateError('no workflow may be automatically opened on another server'),
      ),
    );
    await settle(t);
    expect(find.text('One account'), findsOneWidget);
    final home = t.element(find.byKey(const ValueKey('studio-page')));
    unawaited(
      Navigator.of(home).push<void>(
        MaterialPageRoute(
          builder: (context) => Scaffold(
            body: Column(
              children: [
                const Text('Old workflow'),
                TextButton(
                  onPressed: () => showServerAddressDialog(context, ServerConnectionScope.maybeOf(context)!),
                  child: const Text('Choose another server'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await settle(t);
    await t.tap(find.text('Choose another server'));
    await settle(t);
    await choose(t, 'https://two.example');
    expect(find.text('Old workflow'), findsNothing);
    expect(find.text('One account'), findsNothing);
    expect(settings.lastDoc, isEmpty);
    expect(two.callNames.where((n) => n == 'login'), isEmpty, reason: 'server One credentials were not sent');
    expect(find.byKey(const ValueKey('signin-submit')), findsOneWidget);
    await t.enterText(input(const ValueKey('signin-email')), 'same@example.com');
    await t.enterText(input(const ValueKey('signin-password')), 'SecondPassword9');
    await t.tap(find.byKey(const ValueKey('signin-submit')));
    await settle(t);
    expect(find.text('Two account'), findsOneWidget);
    expect(await store.read('https://one.example'), initial.tokens);
    expect((await store.read('https://two.example'))!.accessToken, isNot(initial.tokens.accessToken));
    await t.tap(find.byKey(const ValueKey('account-trigger')));
    await settle(t);
    await t.tap(find.byKey(const ValueKey('account-switch-server')));
    await settle(t);
    await choose(t, 'https://one.example');
    expect(find.text('One account'), findsOneWidget);
    expect(find.text('Two account'), findsNothing);
    expect(one.callNames.where((n) => n == 'login'), hasLength(1), reason: 'the saved session was restored');
    expect((await AppSettings.load()).serverUrl, 'https://one.example');
    await t.pumpWidget(const SizedBox());
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('a late startup response from the old server cannot replace the selected server', (t) async {
    final old = RecordingAuthApi();
    final gate = Completer<void>();
    old.hold['setupStatus'] = gate;
    final next = RecordingAuthApi();
    await t.pumpWidget(
      buildApp(
        AppSettings(serverUrl: 'https://old.example', journaled: true, lastDoc: ''),
        authApiFor: (u) => u.host == 'old.example' ? old : next,
        tokenStore: MemoryTokenStore(),
      ),
    );
    await settle(t);
    await t.tap(find.byKey(const ValueKey('server-change')));
    await settle(t);
    await choose(t, 'https://next.example');
    gate.complete();
    await settle(t);
    final context = t.element(find.byKey(const ValueKey('signin-submit')));
    expect(AuthScope.read(context)!.server, 'https://next.example');
    expect(next.callNames, contains('setupStatus'));
    await t.pumpWidget(const SizedBox());
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
