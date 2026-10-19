import 'dart:ui' show Tristate;

import 'package:dify_sf_app/src/cards/provider_icon_image.dart';
import 'package:dify_sf_app/src/design/widgets/toast.dart';
import 'package:dify_sf_app/src/i18n/app_locale.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/settings/model_provider/model_provider_env.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import '../dify_test_i18n.dart';

/// Dify's `render` for the model provider page: [child] with the env, Dify's test translator (`<ns>.<key>`) and the
/// toast host (toasts stay until closed), on a 1440 x 900 page.
Future<void> renderSettings(
  WidgetTester t,
  Widget child, {
  required ModelProviderEnv env,
  bool settleFrames = true,
  Translator? translator,
}) async {
  useDifyTestTranslator();
  if (translator != null) DifyI18n.current = translator;
  t.view.physicalSize = const Size(1440, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Material(
        child: ModelProviderScope(
          env: env,
          child: ProviderIconScope(source: env.models.icons, child: child),
        ),
      ),
      builder: (context, c) => AppLocaleScope(
        locale: AppLocale('en-US'),
        child: Stack(
          fit: StackFit.expand,
          children: [
            c!,
            const DifyToastHost(timeout: Duration.zero),
          ],
        ),
      ),
    ),
  );
  if (settleFrames) await settle(t);
}

/// Lets the fake's futures, the popups' transitions and the debounces run.
Future<void> settle(WidgetTester t, [int frames = 8]) async {
  for (var i = 0; i < frames; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

/// The widget with the semantics label [label] that is a button.
SemanticsFinder button(String label) => find.semantics.byPredicate(
  (n) => n.getSemanticsData().flagsCollection.isButton && n.label == label,
  describeMatch: (_) => 'button "$label"',
);

/// Taps the semantics node of the button labelled [label].
Future<void> tapButton(WidgetTester t, String label, {int index = 0}) async {
  final node = button(label).evaluate().elementAt(index);
  node.owner!.performAction(node.id, SemanticsAction.tap);
  await settle(t);
}

/// Whether the button labelled [label] is enabled.
bool isEnabled(String label) =>
    button(label).evaluate().first.getSemanticsData().flagsCollection.isEnabled == Tristate.isTrue;

/// Moves a mouse over [finder] (Dify's `group-hover` actions show); one mouse per test.
Future<void> hover(WidgetTester t, Finder finder) async {
  var g = _mice[t];
  if (g == null) {
    g = await t.createGesture(kind: PointerDeviceKind.mouse);
    _mice[t] = g;
    await g.addPointer(location: Offset.zero);
    addTearDown(() async {
      await g!.removePointer();
    });
  }
  await g.moveTo(t.getCenter(finder));
  await t.pump();
}

final _mice = Expando<TestGesture>();
