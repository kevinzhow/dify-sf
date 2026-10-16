import 'package:flutter/material.dart';

import 'src/home_page.dart';
import 'src/settings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = await AppSettings.load();
  runApp(buildApp(settings));
}
