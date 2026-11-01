import 'dart:io';

import 'package:cronet_http/cronet_http.dart';
import 'package:http/http.dart' as http;

/// Android uses its native certificate/proxy policy for every package:http client,
/// including clients created by collab_client. Keep initialization and runApp in
/// this zone together; otherwise Flutter's bindings would cross zones.
Future<T> withPlatformHttp<T>(Future<T> Function() action) {
  if (!Platform.isAndroid) return action();
  return http.runWithClient(action, () => CronetClient.defaultCronetEngine());
}
