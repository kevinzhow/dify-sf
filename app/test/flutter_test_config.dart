// Every test under test/ starts as a pointer (mouse) test: `flutter test` reports Android as the platform, which
// DifyInteraction would read as touch, turning every wide window into the touch desktop. Compact windows are phones
// whatever the input, so the phone suites are not affected. A touch test on a wide window (a tablet, a landscape
// phone) sets `DifyInteraction.debugDefault = DifyInteractionMode.touch` or wraps its widget in a DifyInteractionScope.
import 'dart:async';

import 'package:dify_sf_app/src/design/widgets/responsive.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  setUp(() => DifyInteraction.debugDefault = DifyInteractionMode.pointer);
  await testMain();
}
