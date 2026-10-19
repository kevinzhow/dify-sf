// dify-spec: web/app/components/app/create-app-modal/__tests__/index.spec.tsx
import 'dart:async';

import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/studio/create_app_modal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

Finder _input(String key) => find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(EditableText));

Future<void> _type(WidgetTester t, String key, String text) async {
  await t.enterText(_input(key), text);
  await t.pump();
}

/// The modal alone (`renderModal`): [onCreate] stands in for `POST /apps`.
Future<({List<CreateAppRequest> requests, List<int> closes})> _renderModal(
  WidgetTester t, {
  Future<void> Function(CreateAppRequest r)? onCreate,
}) async {
  final requests = <CreateAppRequest>[];
  final closes = <int>[];
  await renderMembers(
    t,
    CreateAppModal(
      defaultAppMode: AppModes.advancedChat,
      onClose: () => closes.add(1),
      onCreate: (r) async {
        requests.add(r);
        await onCreate?.call(r);
      },
    ),
  );
  return (requests: requests, closes: closes);
}

void main() {
  group('CreateAppModal', () {
    testWidgets('creates an app, notifies success, and fires callbacks', (t) async {
      final f = await StudioFixture.create();
      final calls = await renderStudio(t, f);
      unawaited(studioState(t).openCreateBlank());
      await settle(t);
      await _type(t, 'create-app-name', 'My App');
      await tapButton(t, 'app.newApp.Create');
      await settle(t);

      final page = await f.api.list();
      final app = page.data.single;
      expect(
        (app.name, app.description, app.iconType, app.icon, app.iconBackground, app.mode),
        ('My App', '', 'emoji', '🤖', '#FFEAD5', AppModes.advancedChat),
      );
      expect(find.text('app.newApp.appCreated'), findsOneWidget);
      expect(find.byType(CreateAppModal), findsNothing, reason: 'closed');
      // `getRedirection`: the new app opens in the editor, editable for its creator.
      expect(calls.opened.single.app.id, app.id);
      expect(calls.opened.single.path, endsWith('/workflow'));
    });

    testWidgets('shows error toast when creation fails', (t) async {
      final r = await _renderModal(t, onCreate: (_) async => throw const TransportException('boom'));
      await _type(t, 'create-app-name', 'My App');
      await tapButton(t, 'app.newApp.Create');
      await settle(t);
      expect(r.requests, hasLength(1));
      expect(find.text('boom'), findsOneWidget);
      expect(r.closes, isEmpty);
    });

    testWidgets('shows validation feedback when the keyboard shortcut runs without a name', (t) async {
      final r = await _renderModal(t);
      await t.tap(_input('create-app-name'));
      await t.pump();
      await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await settle(t);
      expect(find.text('app.newApp.nameNotEmpty'), findsOneWidget);
      expect(r.requests, isEmpty);
    });

    testWidgets('should ignore duplicate create clicks while a request is in flight', (t) async {
      final gate = Completer<void>();
      final r = await _renderModal(t, onCreate: (_) => gate.future);
      await _type(t, 'create-app-name', 'Slow App');
      await tapButton(t, 'app.newApp.Create');
      await settle(t);
      expect(r.requests, hasLength(1));
      expect(isEnabled('app.newApp.Create'), isFalse, reason: 'loading');
      await t.tap(find.byKey(const ValueKey('create-app-submit')), warnIfMissed: false);
      await settle(t);
      expect(r.requests, hasLength(1));
      gate.complete();
      await settle(t);
      expect(find.text('app.newApp.appCreated'), findsOneWidget);
    });
  });
}
