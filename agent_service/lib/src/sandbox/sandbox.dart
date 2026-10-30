/// Per-execution sandboxes: acquired through the sandbox supervisor on first
/// shell use, probed before the first command, holding the execution's
/// workspace until `DELETE /v1/executions/{id}` or lease expiry releases them.
library;

import 'dart:async';
import 'dart:convert';

import 'package:genkit/genkit.dart' show CancellationToken;
import 'package:http/http.dart' as http;

import '../executor_profiles.dart';
import '../gateway.dart';
import '../protocol.dart';
import '../run_store.dart';
import 'paths.dart';
import 'shell_tools.dart';

export 'paths.dart';
import 'shellctl.dart';

/// Ends a run with [errorType] (`sandbox_unavailable`, `sandbox_error` or
/// `file_error`).
class SandboxFailure implements Exception {
  SandboxFailure(
    this.errorType,
    this.message, {
    this.supervisorCode,
    this.httpStatus,
  });
  final String errorType;
  final String message;
  final String? supervisorCode;
  final int? httpStatus;
  @override
  String toString() => 'SandboxFailure($errorType: $message)';
}

/// What the supervisor granted.
class SandboxGrant {
  SandboxGrant(
    this.sandboxId,
    this.url,
    this.token, {
    required this.created,
    this.gateway,
    this.profile,
    this.codexGatewayUrl,
    this.workspaceKeptFrom = const [],
    this.retained,
  });
  final String sandboxId;
  final Uri url;
  final String token;
  final bool created;

  /// The executor profile the supervisor created the sandbox with (null
  /// from a supervisor without profiles).
  final String? profile;

  /// The supervisor's dedicated, path-restricted Responses reverse proxy.
  /// Never inferred from arbitrary operation input or the host gateway.
  final Uri? codexGatewayUrl;

  /// The sandbox network's reserved gateway address (no host owns it when
  /// the network is set up as required); probed for host reachability.
  final String? gateway;

  /// Earlier sandboxes of the execution whose disk workspace this one keeps
  /// (the supervisor replaced a stopped container; the files are there).
  final List<String> workspaceKeptFrom;

  /// The retained workspace (`workspace: {"retained", "reused", "id"}`),
  /// when the acquire named a `workspace_key`.
  final RetainedWorkspaceGrant? retained;
}

/// A node's disk workspace kept across the rounds of a workflow run, as the
/// supervisor answered it.
class RetainedWorkspaceGrant {
  const RetainedWorkspaceGrant({required this.id, required this.reused});

  /// The supervisor's workspace ID (`DELETE /v1/workspaces/{id}`).
  final String id;

  /// Whether the workspace existed before this acquire (an earlier round's,
  /// re-bound), as opposed to a new, empty one.
  final bool reused;

  /// The `workspace` object of an acquire answer; null when it is not a
  /// retained workspace's.
  static RetainedWorkspaceGrant? parse(Object? raw) {
    if (raw is! Map || raw['retained'] != true) return null;
    final id = raw['id'];
    final reused = raw['reused'];
    if (id is! String || id.isEmpty || reused is! bool) return null;
    return RetainedWorkspaceGrant(id: id, reused: reused);
  }
}

/// Client of the sandbox supervisor.
class SupervisorClient {
  SupervisorClient(
    this.baseUrl,
    this.key, {
    http.Client? client,
    this.diskSlotWaitTimeout = const Duration(seconds: 60),
    this.diskSlotRetryInterval = const Duration(milliseconds: 500),
  }) : _client = client ?? http.Client();

  final Uri baseUrl;
  final String key;
  final http.Client _client;

  /// A finished execution may still be releasing its disk workspace when
  /// the next node starts. Only a structured 503 `disk_pool_busy` is retried.
  /// Waiting takes place here, outside the supervisor's disk-manager lock,
  /// so the earlier execution's release can make progress.
  final Duration diskSlotWaitTimeout;
  final Duration diskSlotRetryInterval;

  Uri _url(String path) =>
      Uri.parse('${baseUrl.toString().replaceFirst(RegExp(r'/+$'), '')}$path');

  Map<String, String> get _headers => {
    'Authorization': 'Bearer $key',
    'Content-Type': 'application/json',
  };

  Future<Map<String, Object?>> _call(
    String method,
    String path, [
    Object? body,
  ]) async {
    final request = http.Request(method, _url(path))..headers.addAll(_headers);
    if (body != null) request.body = jsonEncode(body);
    final http.Response r;
    try {
      r = await http.Response.fromStream(await _client.send(request))
          .timeout(const Duration(seconds: 120));
    } on TimeoutException {
      throw SandboxFailure('sandbox_unavailable', 'the supervisor timed out');
    } catch (e) {
      throw SandboxFailure('sandbox_unavailable', 'the supervisor failed: $e');
    }
    Object? decoded;
    try {
      decoded = jsonDecode(r.body);
    } on FormatException {
      decoded = null;
    }
    if (r.statusCode >= 300 || decoded is! Map) {
      final message = decoded is Map ? decoded['message'] : r.body;
      throw SandboxFailure(
        'sandbox_unavailable',
        'the supervisor answered HTTP ${r.statusCode}: $message',
        supervisorCode: decoded is Map && decoded['error'] is String
            ? decoded['error'] as String
            : null,
        httpStatus: r.statusCode,
      );
    }
    return decoded.cast<String, Object?>();
  }

  /// `POST /v1/sandboxes`. [workspaceKey] keys the disk workspace by a
  /// node's workflow run instead of the execution (docs/agent-v2.md, "Codex
  /// session retained across rounds"). `409 workspace_in_use` is retried
  /// like `503 disk_pool_busy` (same budget, interval and cancellation)
  /// while [workspaceInUseRetryable] says the holder is only still being
  /// released (asked at each refusal); else, and when the budget is spent,
  /// it is a `sandbox_unavailable` failure naming that code.
  Future<SandboxGrant> acquire(
    String executionKey, {
    String profile = defaultProfileName,
    String? workspaceKey,
    bool Function()? workspaceInUseRetryable,
    CancellationToken? cancel,
  }) async {
    final clock = Stopwatch()..start();
    late Map<String, Object?> j;
    while (true) {
      cancel?.throwIfCancelled();
      try {
        j = await _call('POST', '/v1/sandboxes', {
          'execution_key': executionKey,
          'profile': profile,
          'workspace_key': ?workspaceKey,
        });
        break;
      } on SandboxFailure catch (e) {
        cancel?.throwIfCancelled();
        final inUse =
            e.httpStatus == 409 && e.supervisorCode == 'workspace_in_use';
        if (inUse && !(workspaceInUseRetryable?.call() ?? false)) {
          throw SandboxFailure(
            'sandbox_unavailable',
            'the retained workspace of this node is in use by another sandbox '
                '(supervisor: 409 workspace_in_use): ${e.message}',
            supervisorCode: e.supervisorCode,
            httpStatus: e.httpStatus,
          );
        }
        if (e.httpStatus == 409 && e.supervisorCode == 'workspace_conflict') {
          throw SandboxFailure(
            'sandbox_unavailable',
            'the execution\'s sandbox was created with another workspace '
                'scope (supervisor: 409 workspace_conflict): ${e.message}',
            supervisorCode: e.supervisorCode,
            httpStatus: e.httpStatus,
          );
        }
        if (!inUse &&
            (e.httpStatus != 503 || e.supervisorCode != 'disk_pool_busy')) {
          rethrow;
        }
        SandboxFailure waitedTooLong() => SandboxFailure(
          'sandbox_unavailable',
          inUse
              ? 'the retained workspace of this node was still in use by the '
                    'previous round\'s sandbox after '
                    '${diskSlotWaitTimeout.inMilliseconds} ms (supervisor: '
                    '409 workspace_in_use): ${e.message}'
              : 'no sandbox disk slot became available within '
                    '${diskSlotWaitTimeout.inMilliseconds} ms (supervisor: '
                    '503 disk_pool_busy): ${e.message}',
          supervisorCode: e.supervisorCode,
          httpStatus: e.httpStatus,
        );
        final remaining = diskSlotWaitTimeout - clock.elapsed;
        if (remaining <= Duration.zero) throw waitedTooLong();
        final ready = Completer<void>();
        final timer = Timer(
          remaining < diskSlotRetryInterval ? remaining : diskSlotRetryInterval,
          () => ready.complete(),
        );
        try {
          await Future.any<void>([
            ready.future,
            if (cancel != null) cancel.whenCancelled.then((_) {}),
          ]);
          cancel?.throwIfCancelled();
        } finally {
          timer.cancel();
        }
        // Do not send a last request after the waiting budget has expired.
        if (clock.elapsed >= diskSlotWaitTimeout) throw waitedTooLong();
      }
    }
    return SandboxGrant(
      j['sandbox_id'] as String,
      Uri.parse(j['url'] as String),
      j['token'] as String,
      created: j['created'] == true,
      gateway: j['gateway'] as String?,
      profile: j['profile'] as String?,
      codexGatewayUrl: j['codex_gateway_url'] is String
          ? Uri.parse(j['codex_gateway_url'] as String)
          : null,
      workspaceKeptFrom: [
        for (final id in (j['workspace_kept_from'] as List?) ?? const [])
          if (id is String) id,
      ],
      retained: RetainedWorkspaceGrant.parse(j['workspace']),
    );
  }

  /// `GET /v1/profiles`: per profile `{"status", "digest"}`.
  Future<Map<String, Map<String, Object?>>> profiles() async {
    final j = await _call('GET', '/v1/profiles');
    final p = j['profiles'];
    if (p is! Map) {
      throw SandboxFailure('sandbox_unavailable', 'malformed profile list');
    }
    return {
      for (final e in p.entries)
        if (e.key is String && e.value is Map)
          e.key as String: (e.value as Map).cast<String, Object?>(),
    };
  }

  Future<void> release(String sandboxId) =>
      _call('DELETE', '/v1/sandboxes/${Uri.encodeComponent(sandboxId)}');

  /// `DELETE /v1/workspaces/{id}`: deletes a retained workspace once its
  /// workflow run has ended. A workspace the supervisor does not know (404)
  /// is already gone; `409` (a container still uses it) and every other
  /// failure throw [SandboxFailure].
  Future<void> deleteWorkspace(String workspaceId) async {
    try {
      await _call(
        'DELETE',
        '/v1/workspaces/${Uri.encodeComponent(workspaceId)}',
      );
    } on SandboxFailure catch (e) {
      if (e.httpStatus == 404) return;
      rethrow;
    }
  }

  Future<List<Map<String, Object?>>> list() async {
    final j = await _call('GET', '/v1/sandboxes');
    return [
      for (final s in (j['sandboxes'] as List?) ?? const [])
        (s as Map).cast<String, Object?>(),
    ];
  }

  void close() => _client.close();
}

/// Paths inside every sandbox. The job home is a subdirectory of the image
/// user's home so that shellctl's own state (`/home/dify/.local/share/
/// shellctl`) stays outside the paths Landlock grants to jobs.
class SandboxLayout {
  const SandboxLayout({
    this.homeDir = '/home/dify/agent',
    this.workspaceDir = '/workspace',
    this.daemonStateDir = '/home/dify/.local/share/shellctl',
  });
  final String homeDir;
  final String workspaceDir;
  final String daemonStateDir;
}

/// TCP ports tried on every host address by the host-reachability probe.
const defaultHostProbePorts = [
  22, 53, 80, 443, 2375, 2376, 3000, 5000, 5432, 6379, 8000, 8080, 8443, //
  11434,
];

/// Host addresses tried besides the sandbox network's gateway: Docker's
/// default bridge gateway (no route exists from a sandbox network).
const defaultHostProbeAddresses = ['172.17.0.1'];

/// Names Docker maps to the host (`host-gateway`); tried when they resolve.
const hostGatewayNames = ['host.docker.internal', 'gateway.docker.internal'];

/// The result of a bounded control command.
typedef ControlResult = ({String status, int? exitCode, String output});

/// One execution's sandbox as seen by this process.
class ExecutionSandbox {
  ExecutionSandbox({
    required this.executionId,
    required this.grant,
    this.layout = const SandboxLayout(),
    this.hostProbePorts = defaultHostProbePorts,
    this.httpClient,
    this.log,
  });

  final String executionId;
  final SandboxGrant grant;
  final SandboxLayout layout;
  final List<int> hostProbePorts;

  /// Makes the HTTP client of each shellctl connection (default: a plain
  /// one); the integration test routes through a relay with it.
  final http.Client Function()? httpClient;
  final void Function(String)? log;

  /// Set once the probes passed in this process.
  bool probed = false;

  /// The supervisor's answer to the latest acquire that returned this
  /// sandbox ([grant] is the first one's).
  late SandboxGrant acquired = grant;

  /// With a retained workspace: whether the latest acquire found the
  /// workspace already there (an earlier round's, or this execution's
  /// running sandbox), as opposed to a new, empty one.
  bool get workspaceReused =>
      (acquired.retained?.reused ?? false) || !acquired.created;

  String get sandboxId => grant.sandboxId;

  ShellctlClient client({int outputLimit = shellctlOutputLimitBytes}) =>
      ShellctlClient(
        grant.url,
        grant.token,
        outputLimit: outputLimit,
        client: httpClient?.call(),
      );

  /// The environment of every job: the profile's `env`, the user's `env`
  /// (which may not override the profile's) and `HOME`. Reserved names are
  /// refused here too, whatever the protocol layer let through.
  Map<String, String> jobEnv(
    Map<String, String> userEnv, {
    Map<String, String> profileEnv = const {},
  }) {
    final overriding = userEnv.keys
        .where(
          (k) => profileEnv.keys.any((p) => p.toUpperCase() == k.toUpperCase()),
        )
        .toList();
    if (overriding.isNotEmpty) {
      throw SandboxFailure(
        'sandbox_error',
        'environment variables set by the executor profile: '
            '${overriding.join(', ')}',
      );
    }
    final reserved = [
      ...userEnv.keys,
      ...profileEnv.keys,
    ].where(isReservedEnvName).toList();
    if (reserved.isNotEmpty) {
      throw SandboxFailure(
        'sandbox_error',
        'reserved environment variable names: ${reserved.join(', ')}',
      );
    }
    final invalid = userEnv.entries
        .where(
          (e) =>
              e.key.isEmpty ||
              e.key.contains('=') ||
              e.key.contains('\u0000') ||
              e.value.contains('\u0000'),
        )
        .map((e) => e.key)
        .toList();
    if (invalid.isNotEmpty) {
      throw SandboxFailure(
        'sandbox_error',
        'invalid environment variable names: ${invalid.join(', ')}',
      );
    }
    return {...profileEnv, ...userEnv, 'HOME': layout.homeDir};
  }

  /// Runs a bounded non-interactive command (`stdio`; stderr merged into the
  /// output unless [mergeStderr] is false) and deletes its job.
  Future<ControlResult> control(
    String script, {
    bool mergeStderr = true,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final c = client(outputLimit: 512 * 1024);
    String? jobId;
    try {
      final deadline = DateTime.now().add(timeout);
      var r = await c.run(
        mergeStderr ? '{\n$script\n} 2>&1' : script,
        cwd: layout.workspaceDir,
        env: {'HOME': layout.homeDir},
        timeout: 10,
        mode: 'stdio',
      );
      jobId = r.jobId;
      final out = StringBuffer(r.output);
      while (r.truncated || !r.done) {
        if (DateTime.now().isAfter(deadline)) {
          throw ShellctlException('timeout', 'control command timed out');
        }
        r = await c.wait(r.jobId, offset: r.offset, timeout: 10);
        out.write(r.output);
      }
      return (status: r.status, exitCode: r.exitCode, output: out.toString());
    } finally {
      if (jobId != null) {
        try {
          await c.delete(jobId, force: true, grace: 0);
        } catch (e) {
          log?.call('could not delete control job $jobId: $e');
        }
      }
      c.close();
    }
  }

  /// Waits until shellctl answers `/healthz`.
  Future<void> waitReady({
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final deadline = DateTime.now().add(timeout);
    final c = client();
    try {
      while (true) {
        try {
          await c.health();
          return;
        } on ShellctlException {
          if (DateTime.now().isAfter(deadline)) rethrow;
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
      }
    } finally {
      c.close();
    }
  }

  /// The probe script; each line is `<probe>=blocked|reachable`.
  String probeScript() {
    final s = layout.daemonStateDir;
    final daemonHome = layout.homeDir.substring(
      0,
      layout.homeDir.lastIndexOf('/'),
    );
    return '''
r=blocked
for p in ${shellQuote('$daemonHome/.dify-sf-probe')} /tmp/.dify-sf-probe /var/tmp/.dify-sf-probe /dev/shm/.dify-sf-probe /.dify-sf-probe; do
  if ( : > "\$p" ) 2>/dev/null; then r=reachable; rm -f "\$p" 2>/dev/null; fi
done
echo "write_outside_workspace=\$r"
r=blocked
for p in ${shellQuote(s)} ${shellQuote('$s/jobs')}; do
  if ls "\$p" >/dev/null 2>&1; then r=reachable; fi
done
if head -c 1 ${shellQuote('$s/shellctl.db')} >/dev/null 2>&1; then r=reachable; fi
for d in /proc/[0-9]*; do
  [ "\$(cat "\$d/comm" 2>/dev/null)" = shellctl ] || continue
  if head -c 1 "\$d/environ" >/dev/null 2>&1; then r=reachable; fi
done
echo "daemon_records=\$r"
r=blocked
for a in 1.1.1.1 8.8.8.8; do
  if timeout 3 bash -c "exec 3<>/dev/tcp/\$a/443" 2>/dev/null; then r=reachable; fi
done
echo "direct_internet=\$r"
${hostProbeScript(gateway: grant.gateway, ports: hostProbePorts)}''';
  }

  /// The host-reachability probes: `host_reachable` tries TCP to the
  /// sandbox network's gateway [gateway], [defaultHostProbeAddresses] and the
  /// host-gateway names (when they resolve) on [ports], all in parallel with
  /// a 3-second budget; any connection makes it `reachable` (followed by the
  /// address:port pairs). `host_ipv6` is `reachable` when any interface but
  /// `lo` has an IPv6 address (a link-local route to the host's bridge).
  static String hostProbeScript({
    required String? gateway,
    required List<int> ports,
  }) {
    final addresses = [?gateway, ...defaultHostProbeAddresses];
    return '''
targets=${shellQuote(addresses.join(' '))}
for n in ${hostGatewayNames.join(' ')}; do
  a=\$(getent ahostsv4 "\$n" 2>/dev/null | awk 'NR==1{print \$1}')
  [ -n "\$a" ] && targets="\$targets \$a"
done
hits=\$(for a in \$targets; do
  for p in ${ports.join(' ')}; do
    ( timeout 3 bash -c "exec 3<>/dev/tcp/\$a/\$p" 2>/dev/null && echo "\$a:\$p" ) &
  done
  wait
done)
if [ -n "\$hits" ]; then echo "host_reachable=reachable" \$hits; else echo "host_reachable=blocked"; fi
if grep -qv ' lo\$' /proc/net/if_inet6 2>/dev/null; then echo "host_ipv6=reachable"; else echo "host_ipv6=blocked"; fi''';
  }

  /// Probe names that must report `blocked`.
  static const probeNames = [
    'write_outside_workspace',
    'daemon_records',
    'direct_internet',
    'host_reachable',
    'host_ipv6',
  ];

  /// Parses `name=value` probe lines.
  static Map<String, String> parseProbes(String output) {
    final seen = <String, String>{};
    for (final line in const LineSplitter().convert(output)) {
      final eq = line.indexOf('=');
      if (eq > 0) seen[line.substring(0, eq).trim()] = line.substring(eq + 1);
    }
    return seen;
  }

  /// Runs the probes; returns the names of failed probes (empty = isolated).
  Future<List<String>> probe() async {
    final r = await control(
      probeScript(),
      timeout: const Duration(seconds: 30),
    );
    final seen = parseProbes(r.output);
    final failed = [
      for (final name in probeNames)
        if (seen[name]?.trim() != 'blocked') name,
    ];
    if (failed.isNotEmpty) {
      log?.call(
        'probes of $sandboxId: ${[for (final n in failed) '$n=${seen[n]}'].join('; ')}',
      );
    }
    return failed;
  }

  /// Kills every process except PID 1, the shellctl daemon (the oldest
  /// child of PID 1) with its helpers, and this command's own ancestors.
  static const reapScript = r'''
victims() {
  cat /proc/[0-9]*/stat 2>/dev/null | awk -v self="$$" '
    {
      pid = $1; line = $0; sub(/^.*\) /, "", line); split(line, f, " ")
      ppid[pid] = f[2] + 0
    }
    END {
      daemon = 0
      for (p in ppid) if (ppid[p] == 1 && (daemon == 0 || p + 0 < daemon)) daemon = p + 0
      keep[1] = 1; keep[daemon] = 1
      for (p = self; (p in ppid) && p + 0 > 0; p = ppid[p] "") keep[p] = 1
      mine[self] = 1
      for (i = 0; i < 4; i++) for (p in ppid) if ((ppid[p] "") in mine) mine[p] = 1
      for (p in ppid) if (!(p in keep) && !(p in mine) && ppid[p] != daemon) printf "%s ", p
      printf "#"
    }'
}
list() {
  out=$(victims)
  case "$out" in *"#") ;; *) echo "reap=failed"; exit 1;; esac
  v=${out%#}
}
n=0
for round in 1 2 3 4 5 6 7 8 9 10; do
  list
  [ -z "$v" ] && break
  n=$((n + 1))
  kill -STOP $v 2>/dev/null
  kill -KILL $v 2>/dev/null
  sleep 0.1
done
list
if [ -n "$v" ]; then echo "reap=incomplete $v"; exit 1; fi
echo "reap=ok rounds=$n"''';

  /// Kills every process left by the execution's jobs. False when the reaper
  /// could not run or finish (e.g. the PID limit is exhausted).
  Future<bool> reap() async {
    try {
      final r = await control(reapScript, timeout: const Duration(seconds: 20));
      final ok = r.exitCode == 0 && r.output.contains('reap=ok');
      if (!ok) log?.call('reap of $sandboxId failed: ${r.status} ${r.output}');
      return ok;
    } catch (e) {
      log?.call('reap of $sandboxId failed: $e');
      return false;
    }
  }

  // ---- files --------------------------------------------------------------

  static const _writeChunk = 192 * 1024;
  static const _readChunk = 256 * 1024;

  /// Writes [bytes] to the workspace-relative [path] (parents created).
  Future<void> writeFile(String path, List<int> bytes) async {
    final rel = normalizeWorkspacePath(path, workspace: layout.workspaceDir);
    final target = '${layout.workspaceDir}/$rel';
    final part = '$target.dify-sf-part';
    final dir = target.substring(0, target.lastIndexOf('/'));
    Future<void> step(String script) async {
      final r = await control('set -eu\n$script');
      if (r.exitCode != 0) {
        throw SandboxFailure(
          'file_error',
          'writing $rel into the workspace failed: ${r.status} ${r.output.trim()}',
        );
      }
    }

    await step('mkdir -p -- ${shellQuote(dir)}\n: > ${shellQuote(part)}');
    for (var i = 0; i < bytes.length; i += _writeChunk) {
      final chunk = bytes.sublist(i, (i + _writeChunk).clamp(0, bytes.length));
      final b64 = base64.encode(chunk);
      final lines = [
        for (var j = 0; j < b64.length; j += 76)
          b64.substring(j, (j + 76).clamp(0, b64.length)),
      ];
      await step(
        "base64 -d >> ${shellQuote(part)} <<'DIFYSF_EOF'\n${lines.join('\n')}\nDIFYSF_EOF",
      );
    }
    await step('mv -f -- ${shellQuote(part)} ${shellQuote(target)}');
  }

  /// Resolves a workspace file: its real path must stay inside the
  /// workspace. Returns null with a reason when it is not a usable file.
  Future<({String? realPath, int size, String mimeType, String? error})>
  statFile(String path) async {
    final String rel;
    try {
      rel = normalizeWorkspacePath(path, workspace: layout.workspaceDir);
    } on FormatException catch (e) {
      return (realPath: null, size: 0, mimeType: '', error: e.message);
    }
    final ws = layout.workspaceDir;
    final r = await control('''
p=${shellQuote('$ws/$rel')}
r=\$(realpath -e -- "\$p" 2>/dev/null) || { echo "missing"; exit 0; }
case "\$r" in ${shellQuote(ws)}/*) ;; *) echo "escape"; exit 0;; esac
[ -f "\$r" ] || { echo "notfile"; exit 0; }
echo "ok \$(stat -c %s -- "\$r") \$(file -b --mime-type -- "\$r" 2>/dev/null || echo application/octet-stream)"
printf '%s\\n' "\$r"''');
    final lines = const LineSplitter().convert(r.output);
    final first = lines.isEmpty ? '' : lines.first.trim();
    switch (first.split(' ').first) {
      case 'missing':
        return (
          realPath: null,
          size: 0,
          mimeType: '',
          error: '$rel does not exist in the workspace',
        );
      case 'escape':
        return (
          realPath: null,
          size: 0,
          mimeType: '',
          error: '$rel resolves outside the workspace',
        );
      case 'notfile':
        return (
          realPath: null,
          size: 0,
          mimeType: '',
          error: '$rel is not a regular file',
        );
      case 'ok' when lines.length >= 2:
        final f = first.split(' ');
        return (
          realPath: lines[1],
          size: int.tryParse(f.length > 1 ? f[1] : '') ?? 0,
          mimeType: f.length > 2 && f[2].contains('/')
              ? f[2]
              : 'application/octet-stream',
          error: null,
        );
      default:
        throw SandboxFailure(
          'file_error',
          'reading $rel failed: ${r.status} ${r.output.trim()}',
        );
    }
  }

  /// Reads a file resolved by [statFile].
  Future<List<int>> readFile(String realPath, int size) async {
    final out = <int>[];
    for (var i = 0; i * _readChunk < size; i++) {
      final r = await control(
        'dd if=${shellQuote(realPath)} bs=$_readChunk skip=$i count=1 status=none | base64 -w0',
        mergeStderr: false,
      );
      if (r.exitCode != 0) {
        throw SandboxFailure('file_error', 'reading $realPath failed');
      }
      out.addAll(base64.decode(r.output.trim()));
    }
    if (out.length != size) {
      throw SandboxFailure(
        'file_error',
        '$realPath changed while it was read (${out.length} of $size bytes)',
      );
    }
    return out;
  }
}

/// Owns the sandboxes of this process's executions.
class SandboxManager {
  SandboxManager({
    required this.supervisor,
    required this.store,
    ExecutorProfiles? profiles,
    this.profileStatusTtl = const Duration(seconds: 15),
    this.layout = const SandboxLayout(),
    this.maxInputFileBytes = 64 * 1024 * 1024,
    this.hostProbePorts = defaultHostProbePorts,
    this.shellctlHttpClient,
    this.log,
  }) : profiles = profiles ?? ExecutorProfiles.implicit();

  /// Null when no supervisor is configured (`sandbox: disabled`).
  final SupervisorClient? supervisor;
  final RunStore store;

  /// This service's copy of the executor profiles.
  final ExecutorProfiles profiles;

  /// How long a profile status read from the supervisor is reused.
  final Duration profileStatusTtl;
  final SandboxLayout layout;
  final int maxInputFileBytes;
  final List<int> hostProbePorts;

  /// See [ExecutionSandbox.httpClient].
  final http.Client Function()? shellctlHttpClient;
  final void Function(String)? log;

  final Map<String, ExecutionSandbox> _live = {};
  final Map<String, Future<void>> _locks = {};
  bool _unavailable = false;
  ({bool reached, Map<String, String> statuses, DateTime at})? _profileStatus;
  Future<({bool reached, Map<String, String> statuses})>? _profileRefresh;

  /// The status of every profile: `ok`, `image_missing`, `device_missing`
  /// (as the supervisor reports it) or `unavailable` (no supervisor, the
  /// supervisor could not be asked, or its copy of the profile differs from
  /// this service's). `reached` is false when the supervisor was not asked
  /// successfully. Cached for [profileStatusTtl].
  Future<({bool reached, Map<String, String> statuses})>
  profileStatuses() async {
    final cached = _profileStatus;
    if (cached != null &&
        DateTime.now().difference(cached.at) < profileStatusTtl) {
      return (reached: cached.reached, statuses: cached.statuses);
    }
    return _profileRefresh ??= _fetchProfileStatuses().whenComplete(
      () => _profileRefresh = null,
    );
  }

  Future<({bool reached, Map<String, String> statuses})>
  _fetchProfileStatuses() async {
    Map<String, Map<String, Object?>>? remote;
    final s = supervisor;
    if (s != null) {
      try {
        remote = await s.profiles().timeout(const Duration(seconds: 5));
      } catch (e) {
        log?.call('profile status from the supervisor failed: $e');
      }
    }
    final statuses = <String, String>{};
    for (final p in profiles.profiles.values) {
      final r = remote?[p.name];
      if (remote == null) {
        statuses[p.name] = 'unavailable';
      } else if (r == null || r['digest'] != p.digest) {
        log?.call(
          'executor profile ${p.name}: the supervisor\'s copy '
          '${r == null ? 'does not define it' : 'differs'}; reported unavailable',
        );
        statuses[p.name] = 'unavailable';
      } else {
        final status = r['status'];
        statuses[p.name] = status is String ? status : 'unavailable';
      }
    }
    final result = (
      reached: remote != null,
      statuses: Map<String, String>.unmodifiable(statuses),
    );
    _profileStatus = (
      reached: result.reached,
      statuses: result.statuses,
      at: DateTime.now(),
    );
    return result;
  }

  bool get enabled => supervisor != null;

  /// `GET /v1/health`'s `sandbox`: the latest probe or supervisor outcome.
  String get health => !enabled
      ? 'disabled'
      : _unavailable
      ? 'unavailable'
      : 'isolated';

  /// The sandbox ID recorded for [executionId], if any.
  String? sandboxIdOf(String executionId) =>
      store.execution(executionId)?.sandboxId;

  Future<T> _locked<T>(String executionId, Future<T> Function() body) async {
    final previous = _locks[executionId] ?? Future<void>.value();
    final done = Completer<void>();
    _locks[executionId] = done.future;
    try {
      await previous;
      return await body();
    } finally {
      done.complete();
      if (identical(_locks[executionId], done.future)) {
        _locks.remove(executionId);
      }
    }
  }

  /// The execution's sandbox, created on first use: probed before any
  /// command and, when new, with `files[]` materialized into the workspace.
  /// [expectedRef] is the snapshot's `workspace_ref`: a different sandbox
  /// means the workspace was lost (`sandbox_error`), unless the new one
  /// keeps its disk workspace (`workspace_kept_from`).
  Future<ExecutionSandbox> open(
    OperationRequest request,
    InnerClient inner, {
    String? expectedRef,
    CancellationToken? cancel,
  }) {
    final executionId = request.execution.executionId;
    final workspaceKey = request.workspaceKey;
    return _locked(executionId, () async {
      final s = supervisor;
      if (s == null) {
        throw SandboxFailure(
          'sandbox_unavailable',
          'this agent service has no sandbox supervisor',
        );
      }
      // Indexed before the acquire: the supervisor may create the disk and
      // then fail (parking it); the workflow run's release still finds it.
      if (workspaceKey != null) {
        store.prepareRetainedWorkspace(workspaceKey, request.execution);
      }
      final SandboxGrant grant;
      try {
        grant = await s.acquire(
          executionId,
          profile: request.executorProfile,
          workspaceKey: workspaceKey,
          // The previous round's result is in, and the Swift server's queue
          // has not yet deleted its sandbox (which parks the workspace).
          workspaceInUseRetryable: workspaceKey == null
              ? null
              : () => store.retainedWorkspaceHolderEnded(
                  workspaceKey,
                  executionId,
                ),
          cancel: cancel,
        );
      } on SandboxFailure {
        _unavailable = true;
        rethrow;
      }
      if (workspaceKey != null) {
        final retained = grant.retained;
        if (retained == null) {
          _unavailable = true;
          if (grant.created) await _releaseUnrecorded(s, grant.sandboxId);
          throw SandboxFailure(
            'sandbox_unavailable',
            'the supervisor did not retain the workspace: its answer has no '
                '"workspace": {"retained": true, "reused", "id"} for the '
                'workspace_key',
          );
        }
        final predicted = retainedWorkspaceId(workspaceKey);
        if (retained.id != predicted) {
          // Never indexed or deleted: one wrong answer must not make the
          // release delete another workflow run's workspace. The sandbox
          // goes with the normal DELETE, which only parks a workspace.
          _unavailable = true;
          log?.call(
            'ANOMALY: the supervisor granted sandbox ${grant.sandboxId} with '
            'retained workspace ${retained.id} for workspace_key '
            '$workspaceKey; expected $predicted. The grant is refused and '
            'the sandbox released; the workspace ${retained.id} is not '
            'deleted by agent_service',
          );
          _live.remove(executionId);
          await _releaseUnrecorded(s, grant.sandboxId);
          if (sandboxIdOf(executionId) == grant.sandboxId) {
            store.setSandbox(executionId, null);
          }
          throw SandboxFailure(
            'sandbox_error',
            'the supervisor granted retained workspace ${retained.id}, not '
                '$predicted (sha256 of "retained:" + workspace_key): the '
                'grant was refused and the sandbox released',
          );
        }
        store.retainedWorkspaceGranted(workspaceKey, executionId);
      }
      if (grant.profile != request.executorProfile) {
        // A supervisor that ignores profiles would give the default image.
        _unavailable = true;
        // Not recorded for the execution yet: release it here.
        if (grant.created) await _releaseUnrecorded(s, grant.sandboxId);
        throw SandboxFailure(
          'sandbox_unavailable',
          'the supervisor created the sandbox with profile '
              '${grant.profile ?? '(none)'}, not ${request.executorProfile}',
        );
      }
      // A retained workspace re-used by a new execution (another round of
      // the node) lists the earlier rounds' sandboxes in
      // workspace_kept_from; the new execution still gets its files[].
      final firstOfExecution = sandboxIdOf(executionId) == null;
      store.setSandbox(executionId, grant.sandboxId);
      if (expectedRef != null &&
          expectedRef != grant.sandboxId &&
          !grant.workspaceKeptFrom.contains(expectedRef)) {
        throw SandboxFailure(
          'sandbox_error',
          'the workspace of this execution is gone: sandbox $expectedRef was '
              'replaced by ${grant.sandboxId}',
        );
      }
      final known = _live[executionId];
      final sandbox = known != null && known.sandboxId == grant.sandboxId
          ? known
          : ExecutionSandbox(
              executionId: executionId,
              grant: grant,
              layout: layout,
              hostProbePorts: hostProbePorts,
              httpClient: shellctlHttpClient,
              log: log,
            );
      sandbox.acquired = grant;
      _live[executionId] = sandbox;
      if (!sandbox.probed) {
        final List<String> failed;
        try {
          await sandbox.waitReady();
          failed = await sandbox.probe();
        } on ShellctlException catch (e) {
          _unavailable = true;
          throw SandboxFailure(
            'sandbox_unavailable',
            'the sandbox probes could not run: ${e.toolText}',
          );
        }
        if (failed.isNotEmpty) {
          _unavailable = true;
          log?.call('sandbox ${grant.sandboxId} failed probes: $failed');
          await _discard(executionId, grant.sandboxId);
          throw SandboxFailure(
            'sandbox_unavailable',
            'the sandbox is not isolated (failed probes: ${failed.join(', ')})',
          );
        }
        _unavailable = false;
        sandbox.probed = true;
      }
      if (grant.created &&
          (grant.workspaceKeptFrom.isEmpty ||
              (workspaceKey != null && firstOfExecution))) {
        await _materialize(sandbox, request, inner);
      }
      return sandbox;
    });
  }

  Future<void> _releaseUnrecorded(SupervisorClient s, String sandboxId) async {
    try {
      await s.release(sandboxId);
    } catch (e) {
      log?.call('could not release sandbox $sandboxId: $e');
    }
  }

  Future<void> _materialize(
    ExecutionSandbox sandbox,
    OperationRequest request,
    InnerClient inner,
  ) async {
    for (final f in request.files) {
      try {
        final info = await inner.downloadRequest(f.fileId);
        final url = info['url'];
        if (url is! String || url.isEmpty) {
          throw GatewayException(
            'file_error',
            'no download URL for ${f.fileId}',
          );
        }
        final bytes = await inner.downloadBytes(url, maxInputFileBytes);
        await sandbox.writeFile(f.path, bytes);
      } on GatewayException catch (e) {
        throw SandboxFailure('file_error', 'file ${f.fileId}: ${e.message}');
      } on ShellctlException catch (e) {
        throw SandboxFailure('file_error', 'file ${f.fileId}: ${e.toolText}');
      }
    }
  }

  /// The sandbox known in this process (no supervisor call).
  ExecutionSandbox? liveSandbox(String executionId) => _live[executionId];

  Future<void> _discard(String executionId, String sandboxId) async {
    _live.remove(executionId);
    try {
      await supervisor?.release(sandboxId);
      if (store.execution(executionId)?.sandboxId == sandboxId) {
        store.setSandbox(executionId, null);
      }
    } catch (e) {
      log?.call('could not release sandbox $sandboxId: $e');
    }
  }

  /// Removes the sandbox when its processes could not be stopped.
  Future<void> discard(String executionId, String sandboxId) =>
      _locked(executionId, () => _discard(executionId, sandboxId));

  /// Releases the execution's sandbox through the supervisor. Throws
  /// [SandboxFailure] when the supervisor fails (the caller retries).
  Future<void> release(String executionId) => _locked(executionId, () async {
    _live.remove(executionId);
    final id = sandboxIdOf(executionId);
    if (id == null) return;
    await supervisor?.release(id);
    store.setSandbox(executionId, null);
  });

  void close() => supervisor?.close();
}

/// The shell of one run: Dify's four tools over the execution's sandbox,
/// with the jobs started in this run tracked by ID and offset.
class ShellSession {
  ShellSession(
    this.sandbox,
    Map<String, String> userEnv, {
    Map<String, String> profileEnv = const {},
    this.log,
  }) : env = sandbox.jobEnv(userEnv, profileEnv: profileEnv) {
    _client = sandbox.client();
  }

  final ExecutionSandbox sandbox;
  final Map<String, String> env;
  final void Function(String)? log;
  late ShellctlClient _client;
  final List<String> jobIds = [];
  final Map<String, int> _offsets = {};
  final Set<String> _done = {};
  bool _closed = false;

  /// Aborts the tool calls in flight (their HTTP requests).
  void abort() => _client.close();

  /// Records a job started by another client of this sandbox (the `codex`
  /// style's exec tools), so [close] terminates and deletes it too.
  void trackJob(String jobId, int offset, {required bool done}) =>
      _remember(jobId, offset, done);

  void _remember(String jobId, int offset, bool done) {
    if (!jobIds.contains(jobId)) jobIds.add(jobId);
    _offsets[jobId] = offset;
    if (done) _done.add(jobId);
  }

  int _tracked(String jobId) {
    if (!jobIds.contains(jobId)) {
      throw FormatException('Unknown shell job id for this session: $jobId.');
    }
    return _offsets[jobId] ?? 0;
  }

  static num _number(Object? v, num fallback) => v is num ? v : fallback;

  static void _checkTimeout(num t, {required bool allowZero}) {
    if (t.isNaN ||
        t < 0 ||
        (!allowZero && t == 0) ||
        t > shellToolHardTimeoutSeconds) {
      throw FormatException(
        'timeout must be ${allowZero ? '>= 0' : '> 0'} and <= '
        '${shellToolHardTimeoutSeconds.toInt()} seconds',
      );
    }
  }

  Future<Object> _observe(JobResult result) async {
    final o = await renderObservation(_client, result, log: log);
    _remember(result.jobId, o.offset, result.done);
    return taggedShellObservation(
      jobId: result.jobId,
      status: result.status,
      done: result.done,
      exitCode: result.exitCode,
      outputPath: o.outputPath,
      output: o.text,
    );
  }

  /// Runs one shell tool; failures become `{"error", "job_id"?}`.
  Future<Object> call(String tool, Map<String, Object?> input) async {
    final jobId = input['job_id'] is String ? input['job_id'] as String : null;
    try {
      switch (tool) {
        case shellRunToolName:
          final script = input['script'];
          if (script is! String) {
            throw const FormatException('script is required');
          }
          final timeout = _number(input['timeout'], defaultShellTimeoutSeconds);
          _checkTimeout(timeout, allowZero: false);
          return await _observe(
            await _client.run(
              script,
              cwd: sandbox.layout.workspaceDir,
              env: env,
              timeout: timeout,
            ),
          );
        case shellWaitToolName:
          if (jobId == null) throw const FormatException('job_id is required');
          final offset = _tracked(jobId);
          final timeout = _number(input['timeout'], defaultShellTimeoutSeconds);
          _checkTimeout(timeout, allowZero: true);
          return await _observe(
            await _client.wait(jobId, offset: offset, timeout: timeout),
          );
        case shellInputToolName:
          if (jobId == null) throw const FormatException('job_id is required');
          final text = input['text'];
          if (text is! String) throw const FormatException('text is required');
          final offset = _tracked(jobId);
          final timeout = _number(input['timeout'], defaultShellTimeoutSeconds);
          _checkTimeout(timeout, allowZero: false);
          return await _observe(
            await _client.input(jobId, text, offset: offset, timeout: timeout),
          );
        case shellInterruptToolName:
          if (jobId == null) throw const FormatException('job_id is required');
          _tracked(jobId);
          final grace = _number(
            input['grace_seconds'],
            defaultTerminateGraceSeconds,
          );
          final r = await _client.terminate(jobId, graceSeconds: grace);
          _remember(r.jobId, r.offset, true);
          String? outputPath;
          try {
            outputPath = (await _client.tail(jobId)).outputPath;
          } on ShellctlException catch (e) {
            log?.call('no output path for interrupted job $jobId: $e');
          }
          return taggedShellObservation(
            jobId: r.jobId,
            status: r.status,
            done: r.done,
            exitCode: r.exitCode,
            outputPath: outputPath,
            output: 'Job was interrupted.',
          );
        default:
          throw FormatException('unknown shell tool $tool');
      }
    } on ShellctlException catch (e) {
      return shellToolError(e.toolText, jobId: jobId);
    } on FormatException catch (e) {
      return shellToolError(e.message, jobId: jobId);
    }
  }

  /// Ends the session: terminates the jobs of this run, deletes them and
  /// kills every process they left (including `setsid`/`nohup` descendants).
  /// Returns false when the processes could not be stopped, in which case the
  /// caller removes the sandbox.
  Future<bool> close() async {
    if (_closed) return true;
    _closed = true;
    _client.close();
    final control = sandbox.client();
    try {
      for (final id in jobIds) {
        if (!_done.contains(id)) {
          try {
            await control.terminate(id, graceSeconds: 0);
          } catch (e) {
            log?.call('terminate of job $id failed: $e');
          }
        }
        try {
          await control.delete(id, force: true, grace: 0);
        } catch (e) {
          log?.call('delete of job $id failed: $e');
        }
      }
    } finally {
      control.close();
    }
    return sandbox.reap();
  }
}
