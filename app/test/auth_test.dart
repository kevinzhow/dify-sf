import 'package:dify_sf_app/src/auth/auth_api.dart';
import 'package:dify_sf_app/src/auth/auth_controller.dart';
import 'package:dify_sf_app/src/home_page.dart';
import 'package:dify_sf_app/src/session_factory.dart' show journalKeyOf;
import 'package:dify_sf_app/src/settings.dart';
import 'package:collab_client/testing.dart' show FakeAccounts, FakeAuthApi;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/auth_fakes.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('startup', () {
    test('the install page until the server has an owner', () async {
      final auth = AuthController.on(server: 's', api: RecordingAuthApi(setupDone: false), store: MemoryTokenStore());
      await auth.start();
      expect(auth.route, isA<InstallRoute>());
    });

    test('the sign-in page without a stored session', () async {
      final auth = AuthController.on(server: 's', api: RecordingAuthApi(), store: MemoryTokenStore());
      await auth.start();
      expect(auth.route, isA<SignInRoute>());
    });

    test('home with a stored session that still works, refreshed once when its access token expired', () async {
      final api = RecordingAuthApi();
      final store = MemoryTokenStore();
      final first = await signedInAuth(api: api);
      await store.write('s', first.tokens!);
      final auth = AuthController.on(server: 's', api: api, store: store);
      await auth.start();
      expect(auth.route, isA<HomeRoute>());
      expect(auth.account?.email, 'kim@example.com');

      // The access token expired: one refresh, the new pair stored, the call retried.
      api.sessions.clear();
      final again = AuthController.on(server: 's', api: api, store: store);
      await again.start();
      expect(again.route, isA<HomeRoute>());
      expect(api.callNames.where((n) => n == 'refresh'), hasLength(1));
      expect((await store.read('s'))!.accessToken, again.tokens!.accessToken);
    });

    test('a stored session the server refuses (refresh fails too) is dropped: sign-in page', () async {
      final api = RecordingAuthApi()..addAccount(email: 'a@b.co');
      final store = MemoryTokenStore();
      await store.write('s', const AuthTokens(accessToken: 'old', refreshToken: 'gone'));
      final auth = AuthController.on(server: 's', api: api, store: store);
      await auth.start();
      expect(auth.route, isA<SignInRoute>());
      expect(await store.read('s'), isNull);
    });

    test('an invitation link opens the activation page', () async {
      final auth = AuthController.on(server: 's', api: RecordingAuthApi(), store: MemoryTokenStore());
      await auth.start(activateToken: 'tok');
      expect(auth.route, isA<ActivateRoute>().having((r) => r.token, 'token', 'tok'));
    });

    test('an unreachable server', () async {
      final auth = AuthController.on(server: 's', api: const OfflineAuthApi(), store: MemoryTokenStore());
      await auth.start();
      expect(auth.route, isA<UnreachableRoute>());
    });
  });

  group('session', () {
    test('concurrent 401s share one refresh; a 401 after it ends the session', () async {
      final api = RecordingAuthApi();
      final auth = await signedInAuth(api: api);
      api.sessions.clear();
      final results = await Future.wait([auth.authorized(api.account), auth.authorized(api.account)]);
      expect(results.map((a) => a.email), ['kim@example.com', 'kim@example.com']);
      expect(api.callNames.where((n) => n == 'refresh'), hasLength(1));

      api.sessions.clear();
      api.refreshTokens.clear();
      await expectLater(auth.authorized(api.account), throwsA(isA<Object>()));
      await Future<void>.delayed(Duration.zero);
      expect(auth.signedIn, isFalse);
      expect(auth.route, isA<SignInRoute>());
    });

    test('sign-out tells the server, forgets the tokens and shows the sign-in page', () async {
      final api = RecordingAuthApi();
      final store = MemoryTokenStore();
      api.addAccount(email: 'kim@example.com');
      final auth = AuthController.on(server: 's', api: api, store: store);
      await auth.signIn(email: 'kim@example.com', password: 'Password123');
      expect(await store.read('s'), isNotNull);
      await auth.signOut();
      expect(api.callNames.last, 'logout');
      expect(await store.read('s'), isNull);
      expect(auth.route, isA<SignInRoute>());
    });

    test('journals (and so client ids) are kept per account: another account on this device gets fresh ones', () {
      expect(journalKeyOf('2398cda1-e182-41b6'), '2398cda1-e182-41b6');
      expect(journalKeyOf('a/b'), 'a_b');
      expect(journalKeyOf(null), 'anonymous');
      expect(journalKeyOf('acc-1'), isNot(journalKeyOf('acc-2')));
    });

    test('roles: owner, admin and editor edit; normal members and dataset operators only look', () {
      for (final r in [AccountRole.owner, AccountRole.admin, AccountRole.editor]) {
        expect(AccountRole.canEdit(r), isTrue, reason: r);
      }
      for (final r in [AccountRole.normal, AccountRole.datasetOperator, null]) {
        expect(AccountRole.canEdit(r), isFalse, reason: r);
      }
    });
  });

  testWidgets('a session that ends while an editor is open closes it and shows the sign-in page', (t) async {
    t.view.physicalSize = const Size(1440, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final auth = await signedInAuth();
    await t.pumpWidget(
      buildApp(
        AppSettings(serverUrl: 'http://test', journaled: true, lastDoc: ''),
        auth: auth,
      ),
    );
    await t.pump();
    final nav = t.state<NavigatorState>(find.byType(Navigator).first);
    nav.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('an editor'))));
    await t.pumpAndSettle();
    expect(find.text('an editor'), findsOneWidget);
    await auth.sessionExpired();
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    expect(find.text('an editor'), findsNothing);
    expect(find.byKey(const ValueKey('signin-submit')), findsOneWidget);
  });

  testWidgets('end to end on the fake accounts server: sign in, home with the account menu, sign out', (t) async {
    t.view.physicalSize = const Size(1440, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final accounts = FakeAccounts()..addMember(email: 'kim@example.com', name: 'Kim');
    final store = MemoryTokenStore();
    await t.pumpWidget(
      buildApp(
        AppSettings(serverUrl: 'http://fake', journaled: true, lastDoc: ''),
        authApiFor: (_) => FakeAuthApi(accounts),
        tokenStore: store,
      ),
    );
    for (var i = 0; i < 5; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    await t.enterText(find.byType(EditableText).at(0), 'kim@example.com');
    await t.enterText(find.byType(EditableText).at(1), 'password-1');
    await t.tap(find.byKey(const ValueKey('signin-submit')));
    for (var i = 0; i < 5; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(find.byKey(const Key('doc-field')), findsOneWidget, reason: 'the home page');
    expect(find.text('Kim'), findsOneWidget, reason: 'the account section');
    expect(await store.read('http://fake'), isNotNull);

    await t.tap(find.byKey(const ValueKey('account-trigger')));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('kim@example.com'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('account-logout')));
    for (var i = 0; i < 5; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(find.byKey(const ValueKey('signin-submit')), findsOneWidget);
    expect(await store.read('http://fake'), isNull);
  });
}
