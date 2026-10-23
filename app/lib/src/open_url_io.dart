import 'dart:io';

Future<void> openExternalUrl(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null || !(uri.isScheme('https') || uri.isScheme('http'))) return;
  final (cmd, args) = Platform.isMacOS
      ? ('open', [url])
      : Platform.isWindows
      ? ('rundll32', ['url.dll,FileProtocolHandler', url])
      : ('xdg-open', [url]);
  try {
    await Process.start(cmd, args, mode: ProcessStartMode.detached);
  } on Object {
    // No handler: nothing to do.
  }
}
