// A forward HTTP proxy for the real sandbox integration test, run in a
// container (`dart it_relay.dart PORT ALLOWED_CIDR`). The test process on the
// host cannot reach sandboxes: their networks are internal and the host has no
// address on them (inhibit_ipv4). The supervisor attaches this container to
// every sandbox network as the "agent service" peer, and the test sends its
// shellctl requests through it (127.0.0.1:<published port>).
//
// It listens only on the addresses it has at start (its own network, before
// any sandbox network is attached), so sandboxes cannot use it, and forwards
// only to shellctl's port inside ALLOWED_CIDR.
import 'dart:io';

const shellctlPort = 5004;
const hopByHop = {
  'connection',
  'keep-alive',
  'proxy-connection',
  'proxy-authorization',
  'te',
  'trailer',
  'transfer-encoding',
  'upgrade',
  'host',
};

Future<void> main(List<String> args) async {
  final port = int.parse(args[0]);
  final (base, prefix) = _cidr(args[1]);
  bool allowed(String host) {
    final a = InternetAddress.tryParse(host);
    if (a == null || a.type != InternetAddressType.IPv4) return false;
    final v = a.rawAddress.fold(0, (x, o) => (x << 8) | o);
    final mask = prefix == 0 ? 0 : (0xffffffff << (32 - prefix)) & 0xffffffff;
    return (v & mask) == base;
  }

  final client = HttpClient()..idleTimeout = const Duration(seconds: 5);
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
  );
  for (final address in [for (final i in interfaces) ...i.addresses]) {
    final server = await HttpServer.bind(address, port);
    stderr.writeln('relay listening on ${address.address}:$port');
    server.listen((request) async {
      final response = request.response;
      try {
        final target = request.uri;
        if (!target.hasAuthority) {
          response.statusCode = target.path == '/ready' ? 200 : 400;
          await response.close();
          return;
        }
        if (target.scheme != 'http' ||
            target.port != shellctlPort ||
            !allowed(target.host)) {
          response.statusCode = 403;
          response.write('relay refuses $target');
          await response.close();
          return;
        }
        final out = await client.openUrl(request.method, target);
        request.headers.forEach((name, values) {
          if (hopByHop.contains(name)) return;
          for (final v in values) {
            out.headers.add(name, v, preserveHeaderCase: true);
          }
        });
        await out.addStream(request);
        final upstream = await out.close();
        response.statusCode = upstream.statusCode;
        upstream.headers.forEach((name, values) {
          if (hopByHop.contains(name) || name == 'content-length') return;
          for (final v in values) {
            response.headers.add(name, v);
          }
        });
        await upstream.pipe(response);
      } catch (e) {
        try {
          response.statusCode = 502;
          response.write('relay: $e');
          await response.close();
        } catch (_) {}
      }
    });
  }
}

(int, int) _cidr(String text) {
  final [address, bits] = text.split('/');
  final prefix = int.parse(bits);
  final v = address.split('.').fold(0, (x, o) => (x << 8) | int.parse(o));
  final mask = prefix == 0 ? 0 : (0xffffffff << (32 - prefix)) & 0xffffffff;
  return (v & mask, prefix);
}
