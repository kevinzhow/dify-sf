import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'src/canvas/workflow_canvas.dart';
import 'src/home_page.dart';
import 'src/launch_options.dart';
import 'src/settings.dart';

/// Command line (desktop): `--server URL --doc ID [--volatile] [--demo]`. With `--doc` or `--demo` the
/// editor opens directly. Several windows on one document are fine: each claims its own journal slot.
Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = await AppSettings.load();
  final options = (kIsWeb ? LaunchOptions.fromQuery(Uri.base.queryParameters) : LaunchOptions.parse(args))
    ..applyTo(settings);
  CanvasDefaults.viewport = CanvasDefaults.parseViewport(options.view);
  CanvasDefaults.reportRect = kIsWeb && Uri.base.queryParameters['visual'] == '1';
  runApp(buildApp(settings, launch: options));
}
