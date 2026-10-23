import '../open_url.dart';

/// Only HTTP(S) file previews can leave the editor; an arbitrary result string is not an executable URL.
String? runtimeFileLink(Object? value) {
  if (value is! String || value.isEmpty) return null;
  final uri = Uri.tryParse(value);
  if (uri == null || !const {'http', 'https'}.contains(uri.scheme) || uri.host.isEmpty || uri.userInfo.isNotEmpty) return null;
  return value;
}

Future<void> openRuntimeFile(String url) async {
  final safe = runtimeFileLink(url);
  if (safe != null) await openExternalUrl(safe);
}
