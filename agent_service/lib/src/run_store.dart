/// Durable file-based run store under `AGENT_DATA_DIR`.
///
/// Layout (every name is derived by the service, never taken from a request):
///
/// ```
/// runs/<run_id>/meta.json      run record (temp file + rename)
/// runs/<run_id>/events.jsonl   append-only events {"id","event","data"}
/// runs/<run_id>/result.json    terminal event, written before it is streamed
/// executions/<sha256(execution_id)>.json
///                              max generation, operation_id -> (run_id, digest)
/// ```
///
/// All writes are synchronous so that no other request interleaves between a
/// lookup and the write that follows it.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'protocol.dart';

typedef Clock = DateTime Function();

DateTime systemClock() => DateTime.now().toUtc();

class RunEvent {
  RunEvent(this.id, this.event, this.data);

  final int id;
  final String event;
  final Map<String, Object?> data;

  bool get isTerminal => terminalEvents.contains(event);

  Map<String, Object?> toJson() => {'id': id, 'event': event, 'data': data};

  static RunEvent fromJson(Map<String, Object?> j) => RunEvent(
    j['id'] as int,
    j['event'] as String,
    (j['data'] as Map).cast<String, Object?>(),
  );
}

class RunRecord {
  RunRecord({
    required this.runId,
    required this.operationId,
    required this.executionId,
    required this.generation,
    required this.digest,
    required this.createdAt,
    this.status = 'running',
    this.endedAt,
    this.acknowledged = false,
    this.lastEventId = 0,
  });

  final String runId;
  final String operationId;
  final String executionId;
  int generation;
  final String digest;
  final DateTime createdAt;
  String status;
  DateTime? endedAt;
  bool acknowledged;
  int lastEventId;
  RunEvent? result;

  /// Events in memory; null until loaded from disk.
  List<RunEvent>? events;
  bool eventsPurged = false;

  bool get isEnded => status != 'running';

  Map<String, Object?> toMetaJson() => {
    'run_id': runId,
    'operation_id': operationId,
    'execution_id': executionId,
    'generation': generation,
    'digest': digest,
    'created_at': createdAt.toIso8601String(),
    'status': status,
    'ended_at': endedAt?.toIso8601String(),
    'acknowledged': acknowledged,
    'last_event_id': lastEventId,
    'events_purged': eventsPurged,
  };

  static RunRecord fromMetaJson(Map<String, Object?> j) => RunRecord(
    runId: j['run_id'] as String,
    operationId: j['operation_id'] as String,
    executionId: j['execution_id'] as String,
    generation: j['generation'] as int,
    digest: j['digest'] as String,
    createdAt: DateTime.parse(j['created_at'] as String),
    status: j['status'] as String,
    endedAt: j['ended_at'] == null
        ? null
        : DateTime.parse(j['ended_at'] as String),
    acknowledged: j['acknowledged'] as bool? ?? false,
    lastEventId: j['last_event_id'] as int? ?? 0,
  )..eventsPurged = j['events_purged'] as bool? ?? false;

  /// The body of `GET /v1/runs/{run_id}`.
  Map<String, Object?> statusJson() => {
    'protocol': protocolName,
    'run_id': runId,
    'operation_id': operationId,
    'status': status,
    'last_event_id': lastEventId,
    'result': result?.data,
    'acknowledged': acknowledged,
  };
}

class ExecutionIndex {
  ExecutionIndex(this.executionId);

  final String executionId;
  int maxGeneration = 0;
  final Map<String, ({String runId, String digest})> operations = {};
  DateTime? deletedAt;

  /// The supervisor's ID of the execution's sandbox (its `workspace_ref`).
  String? sandboxId;

  Map<String, Object?> toJson() => {
    'execution_id': executionId,
    'max_generation': maxGeneration,
    'operations': {
      for (final e in operations.entries)
        e.key: {'run_id': e.value.runId, 'digest': e.value.digest},
    },
    'deleted_at': deletedAt?.toIso8601String(),
    'sandbox_id': sandboxId,
  };

  static ExecutionIndex fromJson(Map<String, Object?> j) {
    final x = ExecutionIndex(j['execution_id'] as String)
      ..maxGeneration = j['max_generation'] as int? ?? 0
      ..deletedAt = j['deleted_at'] == null
          ? null
          : DateTime.parse(j['deleted_at'] as String)
      ..sandboxId = j['sandbox_id'] as String?;
    final ops = (j['operations'] as Map?)?.cast<String, Object?>() ?? {};
    ops.forEach((k, v) {
      final m = (v as Map).cast<String, Object?>();
      x.operations[k] = (
        runId: m['run_id'] as String,
        digest: m['digest'] as String,
      );
    });
    return x;
  }
}

class RunStore {
  RunStore(
    this.root, {
    Clock? clock,
    this.eventRetention = const Duration(hours: 24),
    this.recordRetention = const Duration(days: 7),
  }) : clock = clock ?? systemClock;

  final String root;
  final Clock clock;

  /// How long events of an ended, unacknowledged run are kept.
  final Duration eventRetention;

  /// How long records of ended runs and execution tombstones are kept when
  /// the Swift server never deletes the execution.
  final Duration recordRetention;

  final Map<String, RunRecord> _runs = {};
  final Map<String, ExecutionIndex> _executions = {};
  final Random _random = Random.secure();

  Directory get _runsDir => Directory('$root/runs');
  Directory get _executionsDir => Directory('$root/executions');

  String _runDir(String runId) => '${_runsDir.path}/$runId';
  String _executionPath(String executionId) =>
      '${_executionsDir.path}/${sha256Hex(executionId)}.json';

  /// Loads every record. A run that was still running when the previous
  /// process died is lost: it ends `failed` (`internal`) and nothing is
  /// replayed.
  void load() {
    _runsDir.createSync(recursive: true);
    _executionsDir.createSync(recursive: true);
    for (final f in _executionsDir.listSync().whereType<File>()) {
      if (!f.path.endsWith('.json')) continue;
      final x = ExecutionIndex.fromJson(_readJson(f.path));
      _executions[x.executionId] = x;
    }
    for (final d in _runsDir.listSync().whereType<Directory>()) {
      final meta = File('${d.path}/meta.json');
      if (!meta.existsSync()) {
        d.deleteSync(recursive: true);
        continue;
      }
      final run = RunRecord.fromMetaJson(_readJson(meta.path));
      _runs[run.runId] = run;
      final result = File('${d.path}/result.json');
      if (result.existsSync()) {
        run.result = RunEvent.fromJson(_readJson(result.path));
        final events = _loadEvents(run);
        if (!run.eventsPurged &&
            (events.isEmpty || events.last.id < run.result!.id)) {
          _appendLine(run, run.result!);
          events.add(run.result!);
        }
        run
          ..status = run.result!.event
          ..lastEventId = run.result!.id
          ..endedAt ??= clock();
        _writeMeta(run);
      } else {
        _loadEvents(run);
        finish(run, 'failed', {
          'error_type': 'internal',
          'message': 'the agent service restarted during the run; nothing was replayed',
          'usage': Usage().toJson(),
        });
      }
    }
  }

  // ---- executions ---------------------------------------------------------

  ExecutionIndex? execution(String executionId) => _executions[executionId];

  ExecutionIndex _executionOrCreate(String executionId) =>
      _executions.putIfAbsent(executionId, () => ExecutionIndex(executionId));

  int maxGeneration(String executionId) =>
      _executions[executionId]?.maxGeneration ?? 0;

  /// Rejects [generation] when an execution has seen a newer one.
  void checkGeneration(String executionId, int generation) {
    final max = maxGeneration(executionId);
    if (generation < max) {
      throw ApiError(
        409,
        'stale_generation',
        'generation $generation is older than $max for this execution',
        extra: {'generation': max},
      );
    }
  }

  /// Records [generation] as seen for the execution.
  void observeGeneration(String executionId, int generation) {
    final x = _executionOrCreate(executionId);
    if (generation > x.maxGeneration) {
      x.maxGeneration = generation;
      _writeExecution(x);
    }
  }

  /// Records (or clears) the execution's sandbox.
  void setSandbox(String executionId, String? sandboxId) {
    final x = _executionOrCreate(executionId);
    if (x.sandboxId == sandboxId) return;
    x.sandboxId = sandboxId;
    _writeExecution(x);
  }

  // ---- runs ---------------------------------------------------------------

  RunRecord? run(String runId) => _runs[runId];

  Iterable<RunRecord> get runs => _runs.values;

  Iterable<RunRecord> runsOf(String executionId) =>
      _runs.values.where((r) => r.executionId == executionId);

  String _newRunId() {
    final bytes = List<int>.generate(12, (_) => _random.nextInt(256));
    return 'run_${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
  }

  /// Creates a run for [request]; the execution index is written before the
  /// caller answers `202`.
  RunRecord createRun(OperationRequest request, String digest) {
    final x = _executionOrCreate(request.execution.executionId);
    final run = RunRecord(
      runId: _newRunId(),
      operationId: request.operationId,
      executionId: request.execution.executionId,
      generation: request.generation,
      digest: digest,
      createdAt: clock(),
    )..events = [];
    Directory(_runDir(run.runId)).createSync(recursive: true);
    _writeMeta(run);
    if (request.generation > x.maxGeneration) {
      x.maxGeneration = request.generation;
    }
    x.operations[request.operationId] = (runId: run.runId, digest: digest);
    _writeExecution(x);
    _runs[run.runId] = run;
    return run;
  }

  /// Appends a non-terminal event.
  RunEvent append(RunRecord run, String event, Map<String, Object?> data) {
    if (run.isEnded) {
      throw StateError('run ${run.runId} already ended');
    }
    final e = RunEvent(run.lastEventId + 1, event, data);
    _appendLine(run, e);
    run.lastEventId = e.id;
    (run.events ??= []).add(e);
    return e;
  }

  /// Ends [run]: the result is written (temp file + rename) before the event
  /// is appended and handed to subscribers.
  RunEvent finish(RunRecord run, String event, Map<String, Object?> data) {
    if (run.isEnded) return run.result!;
    assert(terminalEvents.contains(event));
    final e = RunEvent(run.lastEventId + 1, event, data);
    _atomicWrite(
      '${_runDir(run.runId)}/result.json',
      jsonEncode(e.toJson()),
      flush: true,
    );
    run
      ..result = e
      ..status = event
      ..endedAt = clock()
      ..lastEventId = e.id;
    _writeMeta(run);
    _appendLine(run, e, flush: true);
    (run.events ??= []).add(e);
    return e;
  }

  void acknowledge(RunRecord run) {
    if (run.acknowledged) return;
    run.acknowledged = true;
    _writeMeta(run);
  }

  /// Whether the events of [run] are no longer kept.
  bool eventsExpired(RunRecord run) {
    if (run.eventsPurged) return true;
    final ended = run.endedAt;
    if (ended == null) return false;
    return run.acknowledged || !clock().isBefore(ended.add(eventRetention));
  }

  /// Events with an id greater than [after].
  List<RunEvent> eventsAfter(RunRecord run, int after) {
    if (after < 0 || after > run.lastEventId) {
      throw ApiError(
        400,
        'invalid_cursor',
        'cursor $after is outside 0..${run.lastEventId}',
      );
    }
    if (eventsExpired(run) && after < run.lastEventId) {
      throw ApiError(
        410,
        'cursor_expired',
        'events of run ${run.runId} are no longer kept; read the run status',
        extra: {'run_id': run.runId},
      );
    }
    final events = _loadEvents(run);
    return events.where((e) => e.id > after).toList();
  }

  /// Removes every record of the execution and leaves a tombstone so a late
  /// operation for it is refused rather than run again.
  void deleteExecution(String executionId) {
    for (final run in runsOf(executionId).toList()) {
      _runs.remove(run.runId);
      final d = Directory(_runDir(run.runId));
      if (d.existsSync()) d.deleteSync(recursive: true);
    }
    final x = _executionOrCreate(executionId);
    x.operations.clear();
    x.deletedAt ??= clock();
    _writeExecution(x);
  }

  /// Purges expired events and old records. Returns the number of event
  /// files purged.
  int sweep() {
    var purged = 0;
    final now = clock();
    for (final run in _runs.values.toList()) {
      if (!run.isEnded) continue;
      if (!run.eventsPurged && eventsExpired(run)) {
        final f = File('${_runDir(run.runId)}/events.jsonl');
        if (f.existsSync()) f.deleteSync();
        run
          ..eventsPurged = true
          ..events = null;
        _writeMeta(run);
        purged++;
      }
      if (!now.isBefore(run.endedAt!.add(recordRetention))) {
        _runs.remove(run.runId);
        final d = Directory(_runDir(run.runId));
        if (d.existsSync()) d.deleteSync(recursive: true);
        final x = _executions[run.executionId];
        if (x != null && x.operations[run.operationId]?.runId == run.runId) {
          x.operations.remove(run.operationId);
          _writeExecution(x);
        }
      }
    }
    for (final x in _executions.values.toList()) {
      final deleted = x.deletedAt;
      if (deleted != null && !now.isBefore(deleted.add(recordRetention))) {
        _executions.remove(x.executionId);
        final f = File(_executionPath(x.executionId));
        if (f.existsSync()) f.deleteSync();
      }
    }
    return purged;
  }

  // ---- files --------------------------------------------------------------

  List<RunEvent> _loadEvents(RunRecord run) {
    final cached = run.events;
    if (cached != null) return cached;
    final events = <RunEvent>[];
    final f = File('${_runDir(run.runId)}/events.jsonl');
    if (!run.eventsPurged && f.existsSync()) {
      for (final line in f.readAsLinesSync()) {
        if (line.trim().isEmpty) continue;
        try {
          events.add(
            RunEvent.fromJson(
              (jsonDecode(line) as Map).cast<String, Object?>(),
            ),
          );
        } on FormatException {
          // A torn last line from a crash; the event was never acknowledged.
          break;
        }
      }
    }
    run.events = events;
    if (events.isNotEmpty && events.last.id > run.lastEventId) {
      run.lastEventId = events.last.id;
    }
    return events;
  }

  void _appendLine(RunRecord run, RunEvent e, {bool flush = false}) {
    File('${_runDir(run.runId)}/events.jsonl').writeAsStringSync(
      '${jsonEncode(e.toJson())}\n',
      mode: FileMode.append,
      flush: flush,
    );
  }

  void _writeMeta(RunRecord run) => _atomicWrite(
    '${_runDir(run.runId)}/meta.json',
    jsonEncode(run.toMetaJson()),
  );

  void _writeExecution(ExecutionIndex x) => _atomicWrite(
    _executionPath(x.executionId),
    jsonEncode(x.toJson()),
    flush: true,
  );

  static void _atomicWrite(String path, String content, {bool flush = false}) {
    final tmp = File('$path.tmp');
    tmp.writeAsStringSync(content, flush: flush);
    tmp.renameSync(path);
  }

  static Map<String, Object?> _readJson(String path) =>
      (jsonDecode(File(path).readAsStringSync()) as Map)
          .cast<String, Object?>();
}
