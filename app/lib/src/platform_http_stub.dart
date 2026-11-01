/// Web uses the browser's HTTP implementation and trust settings.
Future<T> withPlatformHttp<T>(Future<T> Function() action) => action();
