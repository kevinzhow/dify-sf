import 'package:flutter/material.dart';

import 'src/home_page.dart';
import 'src/launch_options.dart';
import 'src/settings.dart';

/// Command line (desktop): `--server URL --doc ID --name NAME [--volatile] [--demo]`. With `--doc` or
/// `--demo` the editor opens directly, which makes it easy to start several windows with different names.
Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = await AppSettings.load();
  final options = LaunchOptions.parse(args)..applyTo(settings);
  runApp(buildApp(settings, launch: options));
}
