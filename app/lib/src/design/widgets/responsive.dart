/// Window size classes, the input mode and touch metrics for dify-sf's phone and tablet layouts (Dify has no phone
/// breakpoints).
///
/// Three questions, answered here only:
/// * how wide the window is ([DifyWindowClass]) and whether it is short ([DifyWindowClass.shortOf], a landscape
///   phone);
/// * what drives it, a finger or a pointer ([DifyInteraction], from the platform, as raft-flutter's
///   `RaftInteraction`: an unfolded foldable or a tablet is as wide as a desktop window and still touched);
/// * which layout a screen takes from the two ([DifyLayoutMode]): the phone layout in a compact window, the desktop
///   structure with touch sizes ("touch desktop") in a wider one driven by touch, today's desktop otherwise.
library;

import 'package:flutter/material.dart' show Theme;
import 'package:flutter/widgets.dart';

/// Material 3's window size classes by width: [compact] below 600 dp (phones in portrait), [medium] from 600 to
/// 839 dp (tablets in portrait, large unfolded foldables), [expanded] from 840 dp (m3.material.io, "Window size
/// classes"). They describe the window, not a panel ([DifyViewport] is ignored), and are independent of
/// [DifyAdaptive]'s Dify-derived thresholds (720 / 640 / 1280 px), which existing screens keep using.
enum DifyWindowClass {
  compact,
  medium,
  expanded;

  /// The smallest [medium] width.
  static const mediumMinWidth = 600.0;

  /// The smallest [expanded] width.
  static const expandedMinWidth = 840.0;

  /// The class of a window [width] dp wide.
  static DifyWindowClass forWidth(double width) => width < mediumMinWidth
      ? compact
      : width < expandedMinWidth
      ? medium
      : expanded;

  /// The class of the window [context] is shown in (`MediaQuery.size`).
  static DifyWindowClass of(BuildContext context) => forWidth(MediaQuery.sizeOf(context).width);

  /// Below this height a window is short: a phone in landscape (411 or 360 dp tall), where a bottom sheet or a bottom
  /// bar would leave no room for the content. Tablets in landscape (800 dp) are not short.
  static const shortMaxHeight = 480.0;

  /// Whether [context]'s window is shorter than [shortMaxHeight].
  static bool shortOf(BuildContext context) => MediaQuery.sizeOf(context).height < shortMaxHeight;
}

/// How the person reaches the screen.
enum DifyInteractionMode {
  /// Fingers: 44-48 dp targets, row actions instead of hover bars, sheets and long presses, no keyboard shortcuts.
  touch,

  /// A mouse or trackpad: Dify's desktop sizes, hover, tooltips, right-click menus and shortcut hints.
  pointer,
}

/// The one place that says whether a finger or a pointer drives the app (raft-flutter's `RaftInteraction`).
///
/// It comes from the platform, not from the last pointer that moved: Android and iOS (the native apps and their mobile
/// browsers, whose platform the web build reads from the browser) are touch, the desktop platforms (the web on a
/// desktop OS included) are pointer. A layout that flipped every time someone touched the screen after using a mouse
/// would re-parent the editor's panels under their hand. Hover-only widgets still check each event's own
/// `PointerDeviceKind` (Flutter's mouse tracker never gives touch a hover), so a mouse on a tablet keeps its hover
/// there without changing the layout.
abstract final class DifyInteraction {
  /// The answer when no [DifyInteractionScope] is above (null: the platform's). Tests set it (the test suite's
  /// `flutter_test_config.dart` makes every test a pointer test by default, as the host's platform would be, since
  /// `flutter test` reports Android); the app never does.
  @visibleForTesting
  static DifyInteractionMode? debugDefault;

  /// Android, iOS and Fuchsia are touch platforms.
  static bool platformIsTouch(TargetPlatform platform) => switch (platform) {
    TargetPlatform.android || TargetPlatform.iOS || TargetPlatform.fuchsia => true,
    TargetPlatform.macOS || TargetPlatform.windows || TargetPlatform.linux => false,
  };

  /// The input mode of [context]: the nearest [DifyInteractionScope], else [debugDefault], else [Theme]'s platform.
  static DifyInteractionMode of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<DifyInteractionScope>();
    if (scope != null) return scope.mode;
    if (debugDefault case final mode?) return mode;
    return platformIsTouch(Theme.of(context).platform) ? DifyInteractionMode.touch : DifyInteractionMode.pointer;
  }

  /// Whether fingers drive [context].
  static bool touchOf(BuildContext context) => of(context) == DifyInteractionMode.touch;
}

/// Overrides the input mode below it: tests and previews mount a touch surface on a wide window or a pointer surface
/// on a narrow one. The app does not need one (the platform answers).
class DifyInteractionScope extends InheritedWidget {
  const DifyInteractionScope({super.key, required this.mode, required super.child});

  final DifyInteractionMode mode;

  @override
  bool updateShouldNotify(DifyInteractionScope oldWidget) => mode != oldWidget.mode;
}

/// The layout a screen takes, from the window's width class and the input mode.
enum DifyLayoutMode {
  /// A compact window (below 600 dp): the phone layout, whatever drives it.
  phone,

  /// A medium or expanded window driven by touch (a tablet, a landscape phone, an unfolded foldable): the desktop
  /// structure (side by side: the canvas and a docked side panel, the wider grids) with touch sizes, row actions
  /// instead of hover actions and no keyboard shortcuts.
  touch,

  /// A medium or expanded window driven by a pointer: Dify's desktop layout, unchanged.
  desktop;

  static DifyLayoutMode of(BuildContext context) => DifyWindowClass.of(context) == DifyWindowClass.compact
      ? phone
      : DifyInteraction.touchOf(context)
      ? touch
      : desktop;
}

/// Touch metrics.
abstract final class DifyTouch {
  /// The smallest hit area for a touch control: Material's 48 dp (Apple's guideline is 44 pt). Smaller visual
  /// controls get it from [DifyTouchTarget].
  static const minTarget = 48.0;

  /// The visible height of a form control a finger picks from (a select's trigger, a variable picker) in a compact
  /// window: Apple's 44 pt; its hit area still reaches [minTarget] where the row around it has the room.
  static const controlHeight = 44.0;

  /// Whether controls in [context] take their touch form: touch-high fields and buttons, 48 px rows, row actions
  /// ([DifyActionRow]) instead of hover actions, no keycaps. True in the phone layout and in the touch desktop
  /// ([DifyLayoutMode.phone] and [DifyLayoutMode.touch]); false only on today's desktop.
  ///
  /// (The name is from when only a compact window had touch sizes. Whether a picker or a dialog is a sheet is a
  /// question of width, not of input: that is [DifyWindowClass.of].)
  static bool compactOf(BuildContext context) => DifyLayoutMode.of(context) != DifyLayoutMode.desktop;

  /// Whether the primary input is a finger: true on Android and iOS (the native apps and their mobile browsers, whose
  /// platform the web build reads from the browser), false on the desktop platforms, including the web on a desktop
  /// OS. It answers for the platform, not the pointer in use: an Android tablet with a mouse still answers true, a
  /// touch-screen laptop false. Follows [Theme]'s platform, so tests and previews can override it.
  static bool isCoarse(BuildContext context) => switch (Theme.of(context).platform) {
    TargetPlatform.android || TargetPlatform.iOS => true,
    _ => false,
  };
}
