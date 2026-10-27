/// A minimal Docker Engine API client over the unix socket (`dart:io`
/// `HttpClient` with a unix-socket connection factory; no docker CLI).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// The Engine API version every request is pinned to.
const dockerApiVersion = 'v1.44';

/// A non-2xx answer of the Engine API.
class DockerException implements Exception {
  DockerException(this.status, this.message);

  /// HTTP status, or 0 when the socket could not be reached.
  final int status;
  final String message;

  @override
  String toString() => 'DockerException($status: $message)';
}

class DockerResponse {
  DockerResponse(this.status, this.body);
  final int status;
  final Object? body;

  Map<String, Object?> get json => (body as Map).cast<String, Object?>();
}

class DockerClient {
  DockerClient(this.socketPath, {this.timeout = const Duration(seconds: 60)})
    : _http = HttpClient() {
    _http.connectionFactory = (uri, proxyHost, proxyPort) =>
        Socket.startConnect(
          InternetAddress(socketPath, type: InternetAddressType.unix),
          0,
        );
    _http.idleTimeout = const Duration(seconds: 5);
  }

  final String socketPath;
  final Duration timeout;
  final HttpClient _http;

  void close() => _http.close(force: true);

  /// Sends one request; `query` values are strings. Answers with the decoded
  /// JSON body (or null). Throws [DockerException] on a transport failure;
  /// HTTP errors are returned for the caller to classify.
  Future<DockerResponse> send(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
  }) async {
    final uri = Uri(
      scheme: 'http',
      host: 'docker',
      path: '/$dockerApiVersion$path',
      queryParameters: query == null || query.isEmpty ? null : query,
    );
    try {
      final request = await _http.openUrl(method, uri).timeout(timeout);
      if (body != null) {
        final bytes = utf8.encode(jsonEncode(body));
        request.headers.contentType = ContentType.json;
        request.contentLength = bytes.length;
        request.add(bytes);
      }
      final response = await request.close().timeout(timeout);
      final text = await utf8.decodeStream(response).timeout(timeout);
      Object? decoded;
      if (text.isNotEmpty) {
        try {
          decoded = jsonDecode(text);
        } on FormatException {
          decoded = text;
        }
      }
      return DockerResponse(response.statusCode, decoded);
    } on TimeoutException {
      throw DockerException(0, 'docker $method $path timed out');
    } on SocketException catch (e) {
      final os = e.osError?.message;
      throw DockerException(
        0,
        'docker socket $socketPath: ${e.message}'
        '${os == null || os.isEmpty ? '' : ' ($os)'}',
      );
    } on HttpException catch (e) {
      throw DockerException(0, 'docker $method $path: ${e.message}');
    }
  }

  static String _message(DockerResponse r) {
    final b = r.body;
    if (b is Map && b['message'] is String) return b['message'] as String;
    return '$b';
  }

  /// Throws unless the status is one of [ok].
  static DockerResponse expect(DockerResponse r, Set<int> ok, String what) {
    if (!ok.contains(r.status)) {
      throw DockerException(r.status, '$what: ${_message(r)}');
    }
    return r;
  }

  Future<void> ping() async {
    final r = await send('GET', '/_ping');
    expect(r, {200}, 'ping');
  }

  /// Containers carrying every label in [labels] (`key=value` or `key`), in
  /// any state unless [runningOnly].
  Future<List<Map<String, Object?>>> listContainers(
    List<String> labels, {
    bool runningOnly = false,
  }) async {
    final r = await send(
      'GET',
      '/containers/json',
      query: {
        'all': runningOnly ? '0' : '1',
        'filters': jsonEncode({'label': labels}),
      },
    );
    expect(r, {200}, 'list containers');
    return [for (final c in r.body as List) (c as Map).cast<String, Object?>()];
  }

  /// The image's inspect document, or null when it is not on this host.
  Future<Map<String, Object?>?> inspectImage(String reference) async {
    final r = await send('GET', '/images/$reference/json');
    if (r.status == 404) return null;
    expect(r, {200}, 'inspect image');
    return r.json;
  }

  /// Creates a container; returns its ID, or null when [name] exists (409).
  Future<String?> createContainer(
    String name,
    Map<String, Object?> payload,
  ) async {
    final r = await send(
      'POST',
      '/containers/create',
      query: {'name': name},
      body: payload,
    );
    if (r.status == 409) return null;
    expect(r, {201}, 'create container');
    return r.json['Id'] as String;
  }

  Future<void> startContainer(String id) async {
    final r = await send('POST', '/containers/$id/start');
    expect(r, {204, 304}, 'start container');
  }

  /// The container's inspect document, or null when it does not exist.
  Future<Map<String, Object?>?> inspectContainer(String idOrName) async {
    final r = await send('GET', '/containers/$idOrName/json');
    if (r.status == 404) return null;
    expect(r, {200}, 'inspect container');
    return r.json;
  }

  /// Force-removes a container and its anonymous volumes; false if absent.
  Future<bool> removeContainer(String id) async {
    final r = await send(
      'DELETE',
      '/containers/$id',
      query: {'force': '1', 'v': '1'},
    );
    if (r.status == 404) return false;
    expect(r, {204}, 'remove container');
    return true;
  }

  // ---- networks -----------------------------------------------------------

  /// Creates a network; returns its ID. Docker's refusals (a name conflict,
  /// an overlapping subnet) are thrown as [DockerException] with the status.
  Future<String> createNetwork(Map<String, Object?> payload) async {
    final r = await send('POST', '/networks/create', body: payload);
    expect(r, {201}, 'create network');
    return r.json['Id'] as String;
  }

  /// The network's inspect document, or null when it does not exist.
  Future<Map<String, Object?>?> inspectNetwork(String idOrName) async {
    final r = await send('GET', '/networks/$idOrName');
    if (r.status == 404) return null;
    expect(r, {200}, 'inspect network');
    return r.json;
  }

  Future<bool> removeNetwork(String id) async {
    final r = await send('DELETE', '/networks/$id');
    if (r.status == 404) return false;
    expect(r, {204}, 'remove network');
    return true;
  }

  /// Networks carrying every label in [labels]; all networks when empty.
  Future<List<Map<String, Object?>>> listNetworks([
    List<String> labels = const [],
  ]) async {
    final r = await send(
      'GET',
      '/networks',
      query: {
        if (labels.isNotEmpty) 'filters': jsonEncode({'label': labels}),
      },
    );
    expect(r, {200}, 'list networks');
    return [for (final n in r.body as List) (n as Map).cast<String, Object?>()];
  }

  /// Connects [container] to [network], with a fixed [ipv4] if given.
  Future<void> connectNetwork(
    String network,
    String container, {
    String? ipv4,
  }) async {
    final r = await send(
      'POST',
      '/networks/$network/connect',
      body: {
        'Container': container,
        'EndpointConfig': {
          if (ipv4 != null) 'IPAMConfig': {'IPv4Address': ipv4},
        },
      },
    );
    expect(r, {200}, 'connect $container to $network');
  }

  /// Disconnects [container] from [network]; false when either is gone.
  Future<bool> disconnectNetwork(String network, String container) async {
    final r = await send(
      'POST',
      '/networks/$network/disconnect',
      body: {'Container': container, 'Force': true},
    );
    if (r.status == 404) return false;
    expect(r, {200}, 'disconnect $container from $network');
    return true;
  }

  // ---- used by tests only -------------------------------------------------

  /// Runs [cmd] in a running container (test tooling); returns the exit
  /// code and the combined output (multiplexed stream headers stripped).
  Future<(int, String)> exec(String id, List<String> cmd) async {
    final created = expect(
      await send(
        'POST',
        '/containers/$id/exec',
        body: {'Cmd': cmd, 'AttachStdout': true, 'AttachStderr': true},
      ),
      {201},
      'create exec',
    );
    final execId = created.json['Id'] as String;
    final uri = Uri(
      scheme: 'http',
      host: 'docker',
      path: '/$dockerApiVersion/exec/$execId/start',
    );
    final request = await _http.openUrl('POST', uri);
    final bytes = utf8.encode(jsonEncode({'Detach': false, 'Tty': false}));
    request.headers.contentType = ContentType.json;
    request.contentLength = bytes.length;
    request.add(bytes);
    final response = await request.close().timeout(timeout);
    final raw = <int>[];
    await for (final chunk in response.timeout(timeout)) {
      raw.addAll(chunk);
    }
    final out = StringBuffer();
    var i = 0;
    while (i + 8 <= raw.length) {
      final size =
          (raw[i + 4] << 24) |
          (raw[i + 5] << 16) |
          (raw[i + 6] << 8) |
          raw[i + 7];
      final end = (i + 8 + size).clamp(0, raw.length);
      out.write(utf8.decode(raw.sublist(i + 8, end), allowMalformed: true));
      i = end;
    }
    final inspected = expect(await send('GET', '/exec/$execId/json'), {
      200,
    }, 'inspect exec');
    return (inspected.json['ExitCode'] as int? ?? -1, out.toString());
  }
}
