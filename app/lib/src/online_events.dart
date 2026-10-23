import 'online_events_stub.dart' if (dart.library.js_interop) 'online_events_web.dart' as impl;

/// Calls [onOnline] when the platform reports that connectivity is back (the browser's `online` event); a no-op
/// elsewhere. Returns a function that removes the listener. The client uses it to skip its reconnect backoff.
void Function() listenForOnline(void Function() onOnline) => impl.listenForOnline(onOnline);
