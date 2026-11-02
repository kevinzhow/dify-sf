// Shared set-up for the phone component tests (dify-sf's phone layout: no Dify spec).
import 'package:dify_sf_app/src/design/dify_theme.dart';

import 'control_harness.dart';

export 'control_harness.dart';

/// A phone window [size] dp at a device pixel ratio of 1. [padding] is the system bars' inset as the platform reports
/// it; [viewPadding] the bars' full size (defaults to [padding]; differs only under the keyboard); [viewInsets] the
/// keyboard.
void phoneView(
  WidgetTester t, {
  Size size = const Size(412, 915),
  EdgeInsets padding = EdgeInsets.zero,
  EdgeInsets? viewPadding,
  EdgeInsets viewInsets = EdgeInsets.zero,
}) {
  FakeViewPadding fake(EdgeInsets e) => FakeViewPadding(left: e.left, top: e.top, right: e.right, bottom: e.bottom);
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = size;
  t.view.padding = fake(padding);
  t.view.viewPadding = fake(viewPadding ?? padding);
  t.view.viewInsets = fake(viewInsets);
  addTearDown(t.view.reset);
}

/// Gesture navigation: a 32 dp status bar and a 24 dp gesture handle.
const gestureInsets = EdgeInsets.only(top: 32, bottom: 24);

/// Three-button navigation: a 32 dp status bar and a 48 dp navigation bar.
const threeButtonInsets = EdgeInsets.only(top: 32, bottom: 48);

/// Landscape with three-button navigation on the right and a cutout on the left.
const landscapeInsets = EdgeInsets.only(left: 32, top: 24, right: 48);

/// [home] in the app shell, as the app shows it (a toast host over the navigator when [toasts] is given).
Future<GlobalKey<NavigatorState>> pumpPhoneApp(
  WidgetTester t,
  Widget home, {
  bool edgeToEdge = false,
  DifyToastManager? toasts,
}) async {
  final navigator = GlobalKey<NavigatorState>();
  await t.pumpWidget(
    DifyApplication(
      navigatorKey: navigator,
      theme: difyTheme(),
      edgeToEdge: edgeToEdge,
      home: home,
      builder: toasts == null
          ? null
          : (_, child) => Stack(
              fit: StackFit.expand,
              children: [
                child!,
                DifyToastHost(manager: toasts, timeout: Duration.zero),
              ],
            ),
    ),
  );
  await t.pump();
  return navigator;
}

/// The colour of the nearest DecoratedBox / ColoredBox at [finder] painting a background.
Color? backgroundOf(WidgetTester t, Finder finder) {
  final w = t.widget(finder);
  return switch (w) {
    ColoredBox(:final color) => color,
    DecoratedBox(decoration: BoxDecoration(:final color)) => color,
    _ => null,
  };
}
