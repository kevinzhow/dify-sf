import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'src/canvas/workflow_canvas.dart';
import 'src/cards/dify_cards.dart';
import 'src/design/dify_icon.dart';
import 'src/i18n/dify_i18n.dart';
import 'src/home_page.dart';
import 'src/launch_options.dart';
import 'src/settings.dart';

/// Command line (desktop): `--server URL --doc ID [--volatile] [--demo]`. With `--doc` or `--demo` the
/// editor opens directly. Several windows on one document are fine: each claims its own journal slot.
Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = await AppSettings.load();
  // Cards on the canvas are captured right after they first paint: their icons must be ready by then.
  await IconCache.preload(DifyCards.icons);
  final options = (kIsWeb ? LaunchOptions.fromQuery(Uri.base.queryParameters) : LaunchOptions.parse(args))
    ..applyTo(settings);
  // Cards measure and draw text outside the widget tree too: the translations load before anything is built.
  await DifyI18n.load(options.lang ?? difyLanguageFor(WidgetsBinding.instance.platformDispatcher.locale));
  CanvasDefaults.viewport = CanvasDefaults.parseViewport(options.view);
  CanvasDefaults.reportRect = kIsWeb && Uri.base.queryParameters['visual'] == '1';
  if (CanvasDefaults.reportRect) CanvasDefaults.select = Uri.base.queryParameters['select'];
  runApp(buildApp(settings, launch: options));
}
