import 'dart:io';

String? localTimezone() {
  try {
    final tz = Platform.environment['TZ'];
    if (tz != null && tz.contains('/')) return tz.startsWith(':') ? tz.substring(1) : tz;
    if (Platform.isLinux) {
      final f = File('/etc/timezone');
      if (f.existsSync()) {
        final name = f.readAsStringSync().trim();
        if (name.isNotEmpty) return name;
      }
    }
    if (Platform.isLinux || Platform.isMacOS) {
      final target = Link('/etc/localtime').targetSync();
      final i = target.indexOf('zoneinfo/');
      if (i >= 0) return target.substring(i + 'zoneinfo/'.length);
    }
  } on Object {
    // Unknown.
  }
  return null;
}
