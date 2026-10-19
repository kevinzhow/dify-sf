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
  await renderMembers(t, _modal(requests, closes, onCreate));
  return (requests: requests, closes: closes);
}

CreateAppModal _modal(
  List<CreateAppRequest> requests,
  List<int> closes,
  Future<void> Function(CreateAppRequest r)? onCreate,
) => CreateAppModal(
  defaultAppMode: AppModes.advancedChat,
  onClose: () => closes.add(1),
  onCreate: (r) async {
    requests.add(r);
    await onCreate?.call(r);
  },
);

void main() {
  group('CreateAppModal', () {
    testWidgets('should give the form half the dialog (floored at 740) and keep the preview box at 666', (t) async {
      // Dify's own boxes, probed with Playwright at the three window sizes: the form column is `flex-1 shrink-0`
      // (content 660 + px-10, so 740 at least) and the preview's `max-w-190` box is its content width everywhere.
      addTearDown(t.view.reset);
      for (final (window, form, box) in [(1440.0, 740.0, 666.0), (1600.0, 783.0, 666.0), (1920.0, 943.0, 666.0)]) {
        // The shell's inset: `p-4` on both sides and the 1 px border, so the modal sees `window - 34`.
        await renderMembers(
          t,
          Center(
            child: SizedBox(
              width: window - 34,
              height: 900 - 34,
              child: _modal(<CreateAppRequest>[], <int>[], null),
            ),
          ),
        );
        // renderMembers fixes the surface at 1440x900; the window itself is what the test varies.
        t.view.devicePixelRatio = 1;
        t.view.physicalSize = Size(window, 900);
        await t.pumpAndSettle();
        expect(t.getSize(find.byKey(const ValueKey('create-app-form'))).width, form, reason: 'form at $window');
        expect(
          t.getSize(find.byKey(const ValueKey('create-app-preview-box'))).width,
          box,
          reason: 'preview box at $window',
        );
        expect(t.takeException(), isNull, reason: 'no overflow at $window');
      }
    });

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
