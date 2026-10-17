import 'package:dify_sf_app/src/cards/card_kit.dart';
import 'package:flutter/services.dart';

bool _loaded = false;

/// Real text metrics for whole-app tests: loads the bundled Noto Sans and lays the app out as on Linux (where it uses
/// Noto Sans, like Dify there: the app keeps a font family set before it starts), instead of the test font whose glyphs are all one em wide.
Future<void> useAppFonts() async {
  if (!_loaded) {
    final loader = FontLoader('Noto Sans')
      ..addFont(rootBundle.load('assets/fonts/NotoSans-Regular.ttf'))
      ..addFont(rootBundle.load('assets/fonts/NotoSans-Bold.ttf'));
    await loader.load();
    _loaded = true;
  }
  cardFontFamily = 'Noto Sans';
}
