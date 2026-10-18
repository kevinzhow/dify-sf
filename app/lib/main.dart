import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'src/canvas/workflow_canvas.dart';
import 'src/cards/dify_cards.dart';
import 'src/design/dify_icon.dart';
import 'src/i18n/dify_i18n.dart';
import 'src/home_page.dart';
import 'src/auth/auth_api.dart' show TokenStore;
import 'src/i18n/app_locale.dart';
import 'src/launch_options.dart';
import 'src/settings.dart';

/// Command line (desktop): `--server URL --doc ID [--volatile] [--demo] [--invite LINK]`. The app starts at the server's
/// install, sign-in or invitation page (protocol 1.8 accounts) unless a stored session still works; with `--doc` the
/// editor opens once signed in, `--demo` opens the in-memory demo without a server. Several windows on one document
/// are fine: each claims its own journal slot.
Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = await AppSettings.load();
  // Cards on the canvas are captured right after they first paint: their icons must be ready by then.
  await IconCache.preload(DifyCards.icons);
  final options =
      (kIsWeb
            ? LaunchOptions.fromQuery(Uri.base.queryParameters, path: Uri.base.path, fragment: Uri.base.fragment)
            : LaunchOptions.parse(args))
        ..applyTo(settings);
  // Cards measure and draw text outside the widget tree too: the translations load before anything is built. The
  // language: the command line's, the one chosen last time (the sign-in page's locale menu), the system's.
  final lang =
      options.lang ??
      await AppLocale.remembered() ??
      difyLanguageFor(WidgetsBinding.instance.platformDispatcher.locale);
  await DifyI18n.load(lang);
  CanvasDefaults.viewport = CanvasDefaults.parseViewport(options.view);
  CanvasDefaults.reportRect = kIsWeb && Uri.base.queryParameters['visual'] == '1';
  if (CanvasDefaults.reportRect) CanvasDefaults.select = Uri.base.queryParameters['select'];
  // The signed-in sessions (protocol 1.8): files (0600) under the app support directory, localStorage on the web.
  final tokens = TokenStore.platform(
    directory: kIsWeb ? null : '${(await getApplicationSupportDirectory()).path}/auth',
  );
  runApp(buildApp(settings, launch: options, locale: AppLocale(lang), tokenStore: tokens));
}
