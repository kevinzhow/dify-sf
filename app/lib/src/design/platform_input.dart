import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Flutter owns canvas menus and editable-text selection menus in this app.
/// Without this, Web shows the browser menu over the Dify menu and suppresses
/// EditableText's custom selection toolbar. Native platforms keep their behavior.
Future<void> initializeDifyPlatformInput() async {
  if (kIsWeb) await BrowserContextMenu.disableContextMenu();
}
