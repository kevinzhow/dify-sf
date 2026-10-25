/// Generates the `dify-sf-agent/1` contract fixtures in
/// `fixtures/dify-sf-agent-1/` by running the real agent service against the
/// scripted inner gateway (and, for the shell, the fake supervisor and
/// shellctl), recording every request and response on both sides.
///
/// ```sh
/// dart run tool/gen_fixtures.dart [OUT_DIR]
/// ```
///
/// `test/fixtures_test.dart` regenerates them and fails on any drift. The
/// file format and the placeholder rules are described in
/// `fixtures/README.md`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_service/agent_service.dart';
import 'package:agent_service/testing.dart';
import 'package:http/http.dart' as http;

/// Where the fixtures live, relative to the package root.
const fixturesPath = 'fixtures/dify-sf-agent-1';

const fixtureServiceKey = 'fixture-service-key';
const fixtureRunToken = 'fixture-run-token';
const fixtureSupervisorKey = 'fixture-supervisor-key';

/// Every timestamp in a fixture.
const fixtureTimestamp = '2026-01-01T00:00:00.000Z';

/// Base URLs standing for the in-process fakes' `http://127.0.0.1:<port>`.
const innerPlaceholder = 'http://inner-gateway.invalid';
const supervisorPlaceholder = 'http://sandbox-supervisor.invalid';
const sandboxPlaceholder = 'http://sandbox.invalid';

/// Run ID of the [n]th run of a scenario (from 1).
String fixtureRunId(int n) => 'run_${n.toRadixString(16).padLeft(24, '0')}';

Future<void> main(List<String> args) async {
  final out = args.isEmpty ? fixturesPath : args.single;
  final fixtures = await generateFixtures(
    only: Platform.environment['FIXTURES_ONLY'],
    log: stderr.writeln,
  );
  writeFixtures(Directory(out), fixtures);
  stdout.writeln('wrote ${fixtures.length} fixtures to $out');
}

/// Writes [fixtures] (file name → content) into [dir] and removes JSON
/// files that are no longer generated.
void writeFixtures(Directory dir, Map<String, String> fixtures) {
  dir.createSync(recursive: true);
  for (final f in dir.listSync().whereType<File>()) {
    final name = f.uri.pathSegments.last;
    if (name.endsWith('.json') && !fixtures.containsKey(name)) f.deleteSync();
  }
  fixtures.forEach((name, text) {
    File('${dir.path}/$name').writeAsStringSync(text);
  });
}

/// Runs every scenario; returns file name → pretty JSON.
Future<Map<String, String>> generateFixtures({
  String? only,
  void Function(String)? log,
}) async {
  final out = <String, String>{};
  for (final s in scenarios) {
    if (only != null && s.name != only) continue;
    final sw = Stopwatch()..start();
    out['${s.name}.json'] = await s.generate();
    log?.call('${s.name}: ${sw.elapsedMilliseconds} ms');
  }
  return out;
}

// ---------------------------------------------------------------------------
// Request bodies

Map<String, Object?> operation({
  String executionId = 'E1',
  int outputAttempt = 0,
  int resumeSequence = 0,
  int generation = 1,
  String task = 'Plan a weekend in Kyoto.',
  List<Map<String, Object?>>? taskParts,
  Map<String, Object?>? outputSchema,
  bool askHuman = false,
  bool shell = false,
  Map<String, Object?> env = const {},
  List<Map<String, Object?>> files = const [],
  Map<String, Object?>? continuation,
  String configSnapshotId = 'cfg-1',
  String protocol = protocolName,
}) => {
  'protocol': protocol,
  'operation_id': '$executionId:$outputAttempt:$resumeSequence',
  'generation': generation,
  'execution': {
    'tenant_id': 'T1',
    'app_id': 'A1',
    'workflow_run_id': 'W1',
    'node_id': 'N1',
    'execution_id': executionId,
    'agent_config_snapshot_id': configSnapshotId,
    'user_id': 'U1',
    'user_from': 'account',
    'invoke_from': 'debugger',
  },
  'model': {
    'provider': 'langgenius/openai_api_compatible/openai_api_compatible',
    'name': 'test-model',
    'parameters': {'temperature': 0.7},
  },
  'system_prompt': 'You are a travel planner.',
  'task':
      taskParts ??
      [
        {'type': 'text', 'text': task},
      ],
  'output_schema': outputSchema,
  'tools': {'ask_human': askHuman, 'shell': shell},
  'env': env,
  'files': files,
  'limits': {'max_turns': 10, 'timeout_seconds': 600},
  'continuation': continuation,
};

Map<String, Object?> answerContinuation(
  Map<String, Object?> paused,
  Map<String, Object?> values,
) => {
  'kind': 'answer',
  'question_id': paused['question_id'],
  'snapshot': paused['snapshot'],
  'result': {
    'status': 'submitted',
    'action': {'id': 'submit', 'label': 'Submit'},
    'values': values,
    'rendered_content': [for (final e in values.entries) '${e.key}: ${e.value}']
        .join('\n'),
  },
};

const scoreSchema = {
  'type': 'object',
  'properties': {
    'text': {'type': 'string'},
    'score': {'type': 'number'},
  },
  'required': ['text', 'score'],
};

const reportSchema = {
  'type': 'object',
  'properties': {
    'text': {'type': 'string'},
    'report': {
      'type': 'string',
      'x-dify-sf-file': {
        'extensions': ['.csv'],
      },
    },
    'bundle': {
      'type': 'object',
      'properties': {
        'title': {'type': 'string'},
        'pages': {
          'type': 'array',
          'items': {
            'type': 'string',
            'x-dify-sf-file': {
              'mime_types': ['text/*'],
            },
          },
        },
      },
    },
    'extra': {
      'type': 'object',
      'properties': {
        'notes': {'type': 'string', 'x-dify-sf-file': {}},
      },
    },
  },
  'required': ['text', 'report'],
};

Map<String, Object?> usage(int prompt, int completion, {int? reasoning}) =>
    defaultUsage(prompt: prompt, completion: completion, reasoning: reasoning);

Map<String, Object?> toolCallScript(
  String id,
  String name,
  Map<String, Object?> arguments, {
  Map<String, Object?>? callUsage,
}) => {
  'chunks': [
    {
      'tool_calls': [
        toolCallDelta(id: id, name: name, arguments: jsonEncode(arguments)),
      ],
    },
    {'usage': callUsage ?? usage(10, 5), 'finish_reason': 'tool_calls'},
  ],
};

Map<String, Object?> textScript(String text, {Map<String, Object?>? u}) => {
  'chunks': [
    {'text': text},
    {'usage': u ?? usage(10, 5), 'finish_reason': 'stop'},
  ],
};

// ---------------------------------------------------------------------------
// Scenarios

class Scenario {
  const Scenario(
    this.name,
    this.description,
    this.gatewayScript,
    this.body, {
    this.sandbox,
  });

  final String name;
  final String description;

  /// The scripted gateway's script (format of `scripted_gateway.dart`).
  final Map<String, Object?> gatewayScript;

  /// The fake sandbox setup, or null without a supervisor.
  final SandboxSetup? sandbox;
  final Future<void> Function(Session s) body;

  Future<String> generate() async {
    final session = await Session.open(this);
    try {
      await body(session);
      return encodeFixture(await session.build());
    } finally {
      await session.close();
    }
  }
}

/// What the fake sandbox holds: the output of every user job and the files
/// present in the workspace.
class SandboxSetup {
  const SandboxSetup({this.jobOutput = '', this.workspaceFiles = const {}});
  final String jobOutput;
  final Map<String, String> workspaceFiles;

  Map<String, Object?> toJson() => {
    'job_output': jobOutput,
    'workspace_files': workspaceFiles,
  };
}

final scenarios = <Scenario>[
  Scenario(
    'plain_text',
    'A plain text answer streamed in two chunks: events, cursor resume by '
        '`after` and by `Last-Event-ID`, status, ack, `410 cursor_expired` '
        'after the ack, the active list and DELETE.',
    {
      'calls': [
        {
          'chunks': [
            {'text': 'Saturday: temples. '},
            {'text': 'Sunday: markets.'},
            {'usage': usage(12, 8), 'finish_reason': 'stop'},
          ],
        },
      ],
    },
    (s) async {
      await s.request('health', 'GET', '/v1/health');
      final run = await s.start('start', operation());
      await s.waitEnded(run);
      await s.events('events', run);
      await s.events('events_after_2', run, after: 2);
      await s.events('events_last_event_id_3', run, lastEventId: 3);
      await s.status('status', run);
      await s.ack('ack', run);
      await s.events('events_after_ack', run);
      await s.status('status_after_ack', run);
      await s.request(
        'active_runs',
        'GET',
        '/v1/runs',
        query: {'state': 'active'},
      );
      await s.request(
        'delete',
        'DELETE',
        '/v1/executions/E1',
        body: {'protocol': protocolName, 'generation': 1},
      );
    },
  ),
  Scenario(
    'operation_responses',
    'Answers of `POST /v1/operations` and the routes around it: 401, '
        '`400 unsupported_protocol`, `400 invalid_request` (no run token), '
        '`400 reserved_env`, 202, the idempotent resend (200), '
        '`409 operation_conflict`, `409 stale_generation` after a newer '
        'lease, `422 snapshot_incompatible` (unknown envelope; an answer to a '
        'snapshot without a pending question), `404 run_not_found`, '
        '`400 invalid_cursor`, and `410 execution_deleted` after DELETE.',
    {
      'calls': [textScript('Saturday: temples. Sunday: markets.')],
    },
    (s) async {
      final body = operation();
      await s.request(
        'unauthorized',
        'POST',
        '/v1/operations',
        body: body,
        key: 'wrong-key',
        runToken: true,
      );
      await s.request(
        'unsupported_protocol',
        'POST',
        '/v1/operations',
        body: operation(protocol: 'dify-sf-agent/2'),
        runToken: true,
      );
      await s.request(
        'missing_run_token',
        'POST',
        '/v1/operations',
        body: body,
      );
      await s.request(
        'reserved_env',
        'POST',
        '/v1/operations',
        body: operation(env: {'HTTPS_PROXY': 'http://proxy', 'Path': '/x'}),
        runToken: true,
      );
      final run = await s.start('start', body);
      await s.waitEnded(run);
      await s.events('events', run);
      final (_, resent) = await s.request(
        'resend',
        'POST',
        '/v1/operations',
        body: body,
        runToken: true,
      );
      await s.request(
        'conflict',
        'POST',
        '/v1/operations',
        body: operation(task: 'Plan a weekend in Osaka.'),
        runToken: true,
      );
      await s.request(
        'lease_generation_2',
        'POST',
        '/v1/executions/E1/lease',
        body: {'protocol': protocolName, 'generation': 2, 'ttl_seconds': 120},
      );
      await s.request(
        'stale_generation',
        'POST',
        '/v1/operations',
        body: body,
        runToken: true,
      );
      final result = (resent['result'] as Map).cast<String, Object?>();
      final snapshot = (result['snapshot'] as Map).cast<String, Object?>();
      await s.request(
        'snapshot_unknown_envelope',
        'POST',
        '/v1/operations',
        body: operation(
          generation: 2,
          outputAttempt: 1,
          continuation: {
            'kind': 'output_retry',
            'snapshot': {...snapshot, 'envelope': 'dify-sf-agent-session/0'},
            'feedback': [
              {'field': '', 'error': 'retry'},
            ],
          },
        ),
        runToken: true,
      );
      await s.request(
        'snapshot_without_pending_question',
        'POST',
        '/v1/operations',
        body: operation(
          generation: 2,
          resumeSequence: 1,
          continuation: {
            'kind': 'answer',
            'question_id': 'E1:q1',
            'snapshot': snapshot,
            'result': {'status': 'timeout'},
          },
        ),
        runToken: true,
      );
      await s.request('unknown_run', 'GET', '/v1/runs/${fixtureRunId(99)}');
      await s.events('cursor_out_of_range', run, after: 99);
      await s.request(
        'ack',
        'POST',
        '/v1/runs/$run/ack',
        body: {
          'protocol': protocolName,
          'generation': 2,
          'result_event_id': resent['last_event_id'],
        },
      );
      await s.request(
        'delete',
        'DELETE',
        '/v1/executions/E1',
        body: {'protocol': protocolName, 'generation': 2},
      );
      await s.request(
        'operation_after_delete',
        'POST',
        '/v1/operations',
        body: operation(generation: 2),
        runToken: true,
      );
      await s.request(
        'lease_after_delete',
        'POST',
        '/v1/executions/E1/lease',
        body: {'protocol': protocolName, 'generation': 2, 'ttl_seconds': 120},
      );
    },
  ),
  Scenario(
    'declared_output_valid',
    'Declared outputs: the model calls `final_output` with valid arguments; '
        'they are the candidate, `candidate_errors` is empty.',
    {
      'calls': [
        toolCallScript('fo_1', 'final_output', {
          'text': 'A relaxed weekend.',
          'score': 4,
        }),
      ],
    },
    (s) async {
      final run = await s.start('start', operation(outputSchema: scoreSchema));
      await s.finishRun(run);
    },
  ),
  Scenario(
    'declared_output_retry',
    'Declared outputs: an invalid `final_output` (score is a string) ends '
        '`succeeded` with `candidate_errors`; the Swift server retries with '
        '`output_retry` (`E1:1:0`) and the feedback; the second candidate is '
        'valid. The retry request carries the full history.',
    {
      'calls': [
        toolCallScript('fo_1', 'final_output', {
          'text': 'A relaxed weekend.',
          'score': 'high',
        }),
        toolCallScript('fo_2', 'final_output', {
          'text': 'A relaxed weekend.',
          'score': 0.9,
        }),
      ],
    },
    (s) async {
      final run1 = await s.start('start', operation(outputSchema: scoreSchema));
      final first = await s.finishRun(run1);
      final run2 = await s.start(
        'start_output_retry',
        operation(
          outputAttempt: 1,
          outputSchema: scoreSchema,
          continuation: {
            'kind': 'output_retry',
            'snapshot': first['snapshot'],
            'feedback': [
              {'field': 'score', 'error': 'expected number, got string'},
            ],
          },
        ),
      );
      await s.finishRun(run2, prefix: 'retry_');
    },
  ),
  Scenario(
    'ask_human_two_questions',
    'ask_human: the run pauses (`E1:q1`); the answer (`E1:0:1`) resumes the '
        'original tool call; the model asks again with the same provider id '
        '`ask_human:0` (as kimi does) and pauses (`E1:q2`); the second answer '
        '(`E1:0:2`) ends `succeeded`. Both tool results are in the third '
        'model request.',
    {
      'calls': [
        toolCallScript('ask_human:0', 'ask_human', {
          'question': 'Which city?',
          'fields': [
            {'type': 'paragraph', 'name': 'city', 'label': 'City'},
          ],
        }),
        toolCallScript('ask_human:0', 'ask_human', {
          'question': 'Which month?',
        }),
        textScript('Kyoto in April.'),
      ],
    },
    (s) async {
      final run1 = await s.start('start', operation(askHuman: true));
      final p1 = await s.finishRun(run1);
      final run2 = await s.start(
        'start_answer_1',
        operation(
          askHuman: true,
          resumeSequence: 1,
          continuation: answerContinuation(p1, {'city': 'Kyoto'}),
        ),
      );
      final p2 = await s.finishRun(run2, prefix: 'answer_1_');
      final run3 = await s.start(
        'start_answer_2',
        operation(
          askHuman: true,
          resumeSequence: 2,
          continuation: answerContinuation(p2, {'month': 'April'}),
        ),
      );
      await s.finishRun(run3, prefix: 'answer_2_');
    },
  ),
  Scenario(
    'reasoning_think_tag',
    'Reasoning as `<think>` in the content, split across chunks: `thought` '
        'events, kept out of the answer. The first turn calls ask_human with '
        'invalid arguments (a tool error goes back to the model), so the '
        'second request carries the history: the reasoning is sent back as '
        '`<think>\\n…\\n</think>` before the assistant content. The second '
        'call reports `reasoning_tokens`.',
    {
      'calls': [
        {
          'chunks': [
            {'text': '<thi'},
            {'text': 'nk>\nThe user wants a plan.'},
            {'text': '\n</th'},
            {
              'text': 'ink>',
              'tool_calls': [
                toolCallDelta(id: 'c1', name: 'ask_human', arguments: '{}'),
              ],
            },
            {'usage': usage(10, 5), 'finish_reason': 'tool_calls'},
          ],
        },
        {
          'chunks': [
            {'text': '<think>No question then.</think>Saturday: temples. '},
            {'text': 'Sunday: markets.'},
            {'usage': usage(20, 7, reasoning: 3), 'finish_reason': 'stop'},
          ],
        },
      ],
    },
    (s) async {
      final run = await s.start('start', operation(askHuman: true));
      await s.finishRun(run);
    },
  ),
  Scenario(
    'reasoning_content',
    'Reasoning as `delta.message.reasoning_content` streamed in pieces, '
        'then an ask_human call: the run pauses; the snapshot keeps the '
        'reasoning, and the answer\'s model request sends it back as the '
        'assistant message\'s `reasoning_content`.',
    {
      'calls': [
        {
          'chunks': [
            {'reasoning': 'The user did not say '},
            {'reasoning': 'which month.'},
            {
              'tool_calls': [
                toolCallDelta(
                  id: 'ask_human:0',
                  name: 'ask_human',
                  arguments: '{"question":"Which month?"}',
                ),
              ],
            },
            {
              'usage': usage(10, 5, reasoning: 4),
              'finish_reason': 'tool_calls',
            },
          ],
        },
        {
          'chunks': [
            {'reasoning': 'April it is.'},
            {'text': 'Kyoto in April: cherry blossoms.'},
            {'usage': usage(30, 9, reasoning: 3), 'finish_reason': 'stop'},
          ],
        },
      ],
    },
    (s) async {
      final run1 = await s.start('start', operation(askHuman: true));
      final paused = await s.finishRun(run1);
      final run2 = await s.start(
        'start_answer',
        operation(
          askHuman: true,
          resumeSequence: 1,
          continuation: answerContinuation(paused, {'month': 'April'}),
        ),
      );
      await s.finishRun(run2, prefix: 'answer_');
    },
  ),
  Scenario(
    'interleaved_tool_deltas',
    'Two tool calls streamed interleaved by `index`; later deltas carry only '
        'the index. They merge into `ask_human` `{"question":"Sure?"}` and '
        '`final_output` `{"text":"done","score":5}`. `final_output` ends the '
        'run (end_strategy early): ask_human is not executed and is answered '
        'with pydantic-ai\'s text in the snapshot.',
    {
      'calls': [
        {
          'chunks': [
            {
              'tool_calls': [
                toolCallDelta(
                  index: 0,
                  id: 'call_a',
                  name: 'ask_human',
                  arguments: '{"quest',
                ),
                toolCallDelta(
                  index: 1,
                  id: 'call_b',
                  name: 'final_output',
                  arguments: '{"text":',
                ),
              ],
            },
            {
              'tool_calls': [
                toolCallDelta(index: 1, arguments: '"done","score":'),
                toolCallDelta(index: 0, arguments: 'ion":"Sure?"}'),
              ],
            },
            {
              'tool_calls': [toolCallDelta(index: 1, arguments: '5}')],
            },
            {'usage': usage(10, 12), 'finish_reason': 'tool_calls'},
          ],
        },
      ],
    },
    (s) async {
      final run = await s.start(
        'start',
        operation(askHuman: true, outputSchema: scoreSchema),
      );
      await s.finishRun(run);
    },
  ),
  Scenario(
    'non_streamed_complete_chunk',
    'A call the gateway completed without streaming: one chunk with '
        'reasoning, two complete tool calls without `index` (kept apart by '
        'id), usage and finish reason. The first `final_output` wins.',
    {
      'calls': [
        {
          'chunks': [
            {
              'reasoning': 'Score it.',
              'tool_calls': [
                toolCallDelta(
                  id: 'fo_1',
                  name: 'final_output',
                  arguments: '{"text":"ok","score":3}',
                ),
                toolCallDelta(
                  id: 'fo_2',
                  name: 'final_output',
                  arguments: '{"text":"second","score":1}',
                ),
              ],
              'usage': usage(10, 9),
              'finish_reason': 'tool_calls',
            },
          ],
        },
      ],
    },
    (s) async {
      final run = await s.start('start', operation(outputSchema: scoreSchema));
      await s.finishRun(run);
    },
  ),
  Scenario(
    'image_input',
    'An image task part: the model request carries Dify image content with '
        '`url: dify-sf-file:F1` and empty `base64_data`; no download request '
        'is made; the snapshot lists the file id only.',
    {
      'calls': [textScript('A cat on a windowsill.')],
      'files': {
        'F1': {'mime_type': 'image/png', 'size': 3},
      },
    },
    (s) async {
      final run = await s.start(
        'start',
        operation(
          taskParts: [
            {'type': 'text', 'text': 'What is in this picture?'},
            {'type': 'file', 'file_id': 'F1', 'mime_type': 'image/png'},
          ],
        ),
      );
      await s.finishRun(run);
    },
  ),
  Scenario(
    'cancel_mid_stream',
    'A model call streams three reasoning chunks and stays open. While it '
        'runs: the resend answers 200 `running`, status, the active list, ack '
        'answers `409 run_active`. Cancel answers 202; the run ends '
        '`cancelled` and the gateway connection is closed by the agent '
        'service. A second cancel answers `409 run_ended` with the result; an '
        'ack of another event id answers `409 result_mismatch`.',
    {
      'calls': [
        {
          'chunks': [
            {'reasoning': 'Step 1. '},
            {'reasoning': 'Step 2. '},
            {'reasoning': 'Step 3. '},
          ],
          'hang': true,
        },
      ],
    },
    (s) async {
      final body = operation();
      final run = await s.start('start', body);
      await s.waitForEvents(run, 4);
      await s.request(
        'resend_while_running',
        'POST',
        '/v1/operations',
        body: body,
        runToken: true,
      );
      await s.status('status_running', run);
      await s.request(
        'active_runs',
        'GET',
        '/v1/runs',
        query: {'state': 'active'},
      );
      await s.request(
        'ack_running',
        'POST',
        '/v1/runs/$run/ack',
        body: {'protocol': protocolName, 'generation': 1, 'result_event_id': 4},
      );
      await s.request(
        'cancel',
        'POST',
        '/v1/runs/$run/cancel',
        body: {'protocol': protocolName, 'generation': 1},
      );
      await s.waitEnded(run);
      await s.events('events', run);
      await s.status('status', run);
      await s.request(
        'cancel_again',
        'POST',
        '/v1/runs/$run/cancel',
        body: {'protocol': protocolName, 'generation': 1},
      );
      await s.request(
        'ack_wrong_event',
        'POST',
        '/v1/runs/$run/ack',
        body: {'protocol': protocolName, 'generation': 1, 'result_event_id': 4},
      );
      await s.ack('ack', run);
    },
  ),
  Scenario(
    'lease_expiry_cancel_lost',
    'A running operation whose lease (1 second) is not renewed: the run '
        'ends `failed` with `cancel_lost` and the gateway connection is '
        'closed.',
    {
      'calls': [
        {
          'chunks': [
            {'reasoning': 'Thinking.'},
          ],
          'hang': true,
        },
      ],
    },
    (s) async {
      final run = await s.start('start', operation());
      await s.waitForEvents(run, 2);
      await s.request(
        'lease',
        'POST',
        '/v1/executions/E1/lease',
        body: {'protocol': protocolName, 'generation': 1, 'ttl_seconds': 1},
      );
      await s.finishRun(run);
    },
  ),
  Scenario(
    'gateway_error_quota',
    'The gateway ends the stream with a `-429` error envelope: the run '
        'fails `model_quota`.',
    {
      'calls': [
        {
          'error': {
            'code': -429,
            'error_type': 'AgentLLMQuotaExceededError',
            'message': 'Insufficient quota',
          },
        },
      ],
    },
    (s) async {
      final run = await s.start('start', operation());
      await s.finishRun(run);
    },
  ),
  Scenario(
    'gateway_error_model',
    'The gateway streams a chunk, then a `-500` error envelope: the run '
        'fails `model_error`; the partial text is not an answer.',
    {
      'calls': [
        {
          'chunks': [
            {'text': 'Saturday: tem'},
          ],
          'error': {
            'code': -500,
            'error_type': 'InvokeServerUnavailableError',
            'message': 'upstream answered 502',
          },
        },
      ],
    },
    (s) async {
      final run = await s.start('start', operation());
      await s.finishRun(run);
    },
  ),
  Scenario(
    'gateway_http_413',
    'The gateway answers HTTP 413 (the request\'s files exceed its byte '
        'budget) before any stream: the run fails `file_error`.',
    {
      'calls': [
        {
          'http_status': 413,
          'http_body': {
            'error': 'payload_too_large',
            'message': 'the files of this request exceed the byte budget',
          },
        },
      ],
      'files': {
        'F1': {'mime_type': 'image/png', 'size': 3},
      },
    },
    (s) async {
      final run = await s.start(
        'start',
        operation(
          taskParts: [
            {'type': 'text', 'text': 'Describe it.'},
            {'type': 'file', 'file_id': 'F1', 'mime_type': 'image/png'},
          ],
        ),
      );
      await s.finishRun(run);
    },
  ),
  Scenario(
    'gateway_http_422_file_error',
    'A task file that is not a file of the execution: the gateway answers '
        '`422 {"error": "file_error"}` before the stream starts; the run '
        'fails `file_error`.',
    {'calls': <Object?>[], 'files': <String, Object?>{}},
    (s) async {
      final run = await s.start(
        'start',
        operation(
          taskParts: [
            {'type': 'text', 'text': 'Describe it.'},
            {'type': 'file', 'file_id': 'F404', 'mime_type': 'image/png'},
          ],
        ),
      );
      await s.finishRun(run);
    },
  ),
  Scenario(
    'shell_file_output',
    'The shell (fake supervisor and shellctl): `files[]` is materialized '
        'through `files/download-request` and the signed URL, `shell_run` '
        'runs, and the declared file outputs are uploaded through '
        '`files/upload-request` and a PUT each: the top-level `report` and '
        'the array `bundle.pages` nested in an object; each is replaced in '
        'place by its upload. `extra.notes` names a missing file: a '
        '`candidate_errors` entry for `extra`, which keeps the model\'s value. '
        'The snapshot\'s `workspace_ref` is the sandbox.',
    {
      'calls': [
        toolCallScript('c1', 'shell_run', {
          'script': 'python3 make_report.py inputs/cities.txt > out/report.csv',
        }),
        toolCallScript('fo_1', 'final_output', {
          'text': 'The report is ready.',
          'report': 'out/report.csv',
          'bundle': {
            'title': 'Kyoto',
            'pages': ['out/day1.txt', 'out/day2.txt'],
          },
          'extra': {'notes': 'out/missing.txt'},
        }),
      ],
      'files': {
        'f1': {'mime_type': 'text/plain', 'size': 6, 'content': 'Kyoto\n'},
      },
    },
    (s) async {
      final run = await s.start(
        'start',
        operation(
          shell: true,
          outputSchema: reportSchema,
          env: {'REGION': 'kansai'},
          files: [
            {'file_id': 'f1', 'path': 'inputs/cities.txt'},
          ],
        ),
      );
      await s.finishRun(run);
    },
    sandbox: const SandboxSetup(
      jobOutput: 'wrote out/report.csv\r\n',
      workspaceFiles: {
        '/workspace/out/report.csv': 'city,month\nKyoto,April\n',
        '/workspace/out/day1.txt': 'Temples.\n',
        '/workspace/out/day2.txt': 'Markets.\n',
      },
    ),
  ),
  Scenario(
    'delete_cleanup_failed',
    'DELETE of an execution whose sandbox the supervisor fails to remove: '
        '`503 cleanup_failed` (records stay); the retry answers 200; a third '
        'DELETE is idempotent; later leases and operations answer '
        '`410 execution_deleted`.',
    {
      'calls': [
        toolCallScript('c1', 'shell_run', {'script': 'ls'}),
        textScript('Nothing to do.'),
      ],
    },
    (s) async {
      final run = await s.start('start', operation(shell: true));
      await s.finishRun(run);
      final delete = {'protocol': protocolName, 'generation': 1};
      s.supervisor!.failDelete = 503;
      await s.request(
        'delete_supervisor_fails',
        'DELETE',
        '/v1/executions/E1',
        body: delete,
      );
      await s.status('status_after_failed_delete', run);
      s.supervisor!.failDelete = null;
      await s.request(
        'delete_retry',
        'DELETE',
        '/v1/executions/E1',
        body: delete,
      );
      await s.request(
        'delete_again',
        'DELETE',
        '/v1/executions/E1',
        body: delete,
      );
      await s.request(
        'lease_after_delete',
        'POST',
        '/v1/executions/E1/lease',
        body: {'protocol': protocolName, 'generation': 1, 'ttl_seconds': 120},
      );
      await s.request(
        'operation_after_delete',
        'POST',
        '/v1/operations',
        body: operation(shell: true),
        runToken: true,
      );
    },
    sandbox: const SandboxSetup(jobOutput: 'inputs\r\n'),
  ),
];

// ---------------------------------------------------------------------------
// Recording session

class Session {
  Session._(this.scenario, this.gateway, this.supervisor, this.dataDir);

  final Scenario scenario;
  final ScriptedGateway gateway;
  final FakeSupervisor? supervisor;
  final Directory dataDir;
  late final AgentService service;
  final http.Client client = http.Client();

  final List<Map<String, Object?>> _steps = [];

  /// `gateway.exchanges.length` when each step started.
  final List<int> _marks = [];
  final List<String> _runIds = [];

  Uri get _base => Uri.parse('http://127.0.0.1:${service.port}');

  static Future<Session> open(Scenario scenario) async {
    final gateway = ScriptedGateway.fromJson(
      scenario.gatewayScript,
      serviceKey: fixtureServiceKey,
    );
    await gateway.start();
    FakeSupervisor? supervisor;
    final setup = scenario.sandbox;
    if (setup != null) {
      supervisor = FakeSupervisor(
        key: fixtureSupervisorKey,
        configure: (shellctl) {
          shellctl.onJob = (_) => FakeJobSpec(output: setup.jobOutput);
          setup.workspaceFiles.forEach((path, content) {
            shellctl.files[path] = utf8.encode(content);
          });
        },
      );
      await supervisor.start();
    }
    final root = Directory(
      '${Directory.current.path}/.dart_tool/agent_service_fixtures',
    )..createSync(recursive: true);
    final s = Session._(
      scenario,
      gateway,
      supervisor,
      root.createTempSync('${scenario.name}-'),
    );
    s.service = AgentService(
      serviceKey: fixtureServiceKey,
      dataDir: s.dataDir.path,
      innerUrl: gateway.url,
      logLevel: LogLevel.error,
      supervisor: supervisor == null
          ? null
          : SupervisorClient(supervisor.url, fixtureSupervisorKey),
    );
    await s.service.start(address: '127.0.0.1', port: 0);
    return s;
  }

  Future<void> close() async {
    await service.stop();
    client.close();
    await gateway.close();
    await supervisor?.close();
    if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
  }

  Map<String, String> _headers({
    String? key = fixtureServiceKey,
    bool runToken = false,
    bool json = false,
  }) => {
    'Authorization': 'Bearer ${key ?? ''}',
    if (json) 'Content-Type': 'application/json',
    if (runToken) 'X-Agent-Run-Token': fixtureRunToken,
  };

  /// Sends one request to the agent service and records it as [step].
  Future<(int, Map<String, Object?>)> request(
    String step,
    String method,
    String path, {
    Map<String, Object?>? body,
    Map<String, String>? query,
    String key = fixtureServiceKey,
    bool runToken = false,
  }) async {
    _marks.add(gateway.exchanges.length);
    final headers = _headers(key: key, runToken: runToken, json: body != null);
    final req = http.Request(
      method,
      _base.replace(path: path, queryParameters: query),
    )..headers.addAll(headers);
    if (body != null) req.body = jsonEncode(body);
    final res = await http.Response.fromStream(await client.send(req));
    final decoded = res.body.isEmpty
        ? <String, Object?>{}
        : (jsonDecode(res.body) as Map).cast<String, Object?>();
    _steps.add({
      'step': step,
      'request': {
        'method': method,
        'path': path,
        'query': ?query,
        'headers': headers,
        'body': ?body,
      },
      'response': {
        'status': res.statusCode,
        'content_type': res.headers['content-type'],
        'body': decoded,
      },
    });
    return (res.statusCode, decoded);
  }

  /// `POST /v1/operations` expecting 202; returns the run ID.
  Future<String> start(String step, Map<String, Object?> body) async {
    final (status, json) = await request(
      step,
      'POST',
      '/v1/operations',
      body: body,
      runToken: true,
    );
    if (status != 202) {
      throw StateError('$step: expected 202, got $status ${jsonEncode(json)}');
    }
    final runId = json['run_id'] as String;
    _runIds.add(runId);
    return runId;
  }

  Future<Map<String, Object?>> status(String step, String runId) async =>
      (await request(step, 'GET', '/v1/runs/$runId')).$2;

  Future<Map<String, Object?>> ack(String step, String runId) async {
    final run = service.store.run(runId)!;
    return (await request(
      step,
      'POST',
      '/v1/runs/$runId/ack',
      body: {
        'protocol': protocolName,
        'generation': run.generation,
        'result_event_id': run.result!.id,
      },
    )).$2;
  }

  /// Waits for the end, reads all events, the status and acks; returns the
  /// terminal event's data.
  Future<Map<String, Object?>> finishRun(
    String runId, {
    String prefix = '',
  }) async {
    await waitEnded(runId);
    await events('${prefix}events', runId);
    final s = await status('${prefix}status', runId);
    await ack('${prefix}ack', runId);
    return (s['result'] as Map).cast<String, Object?>();
  }

  /// Reads the event stream of [runId] until it ends and records it.
  Future<List<Map<String, Object?>>> events(
    String step,
    String runId, {
    int? after,
    int? lastEventId,
  }) async {
    _marks.add(gateway.exchanges.length);
    final query = after == null ? null : {'after': '$after'};
    final headers = {
      ..._headers(),
      if (lastEventId != null) 'Last-Event-ID': '$lastEventId',
    };
    final path = '/v1/runs/$runId/events';
    final req = http.Request(
      'GET',
      _base.replace(path: path, queryParameters: query),
    )..headers.addAll(headers);
    final res = await client.send(req);
    final response = <String, Object?>{
      'status': res.statusCode,
      'content_type': res.headers['content-type'],
    };
    final events = <Map<String, Object?>>[];
    if (res.statusCode == 200) {
      events.addAll(await parseEventStream(res.stream));
      response['events'] = events;
    } else {
      final text = await res.stream.bytesToString();
      response['body'] = jsonDecode(text);
    }
    _steps.add({
      'step': step,
      'request': {
        'method': 'GET',
        'path': path,
        'query': ?query,
        'headers': headers,
      },
      'response': response,
    });
    return events;
  }

  Future<void> _until(bool Function() condition, String what) async {
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('${scenario.name}: $what');
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  Future<void> waitEnded(String runId) => _until(
    () =>
        (service.store.run(runId)?.isEnded ?? false) &&
        !service.liveRuns.containsKey(runId),
    'run $runId did not end',
  );

  /// Waits until [runId] has stored [count] events.
  Future<void> waitForEvents(String runId, int count) => _until(
    () => service.store.run(runId)!.lastEventId >= count,
    'run $runId has no $count events',
  );

  Future<Map<String, Object?>> build() async {
    // Model calls cut short are seen closed by the gateway asynchronously.
    await _until(
      () => gateway.observations.every(
        (o) => o.completed || o.closedByClient.isCompleted,
      ),
      'gateway connections did not settle',
    );
    final inner = <Map<String, Object?>>[];
    for (var i = 0; i < gateway.exchanges.length; i++) {
      var step = 0;
      while (step + 1 < _marks.length && _marks[step + 1] <= i) {
        step++;
      }
      inner.add(_exchangeJson(gateway.exchanges[i], _steps[step]['step']));
    }
    final fixture = <String, Object?>{
      'fixture': scenario.name,
      'protocol': protocolName,
      'description': scenario.description,
      'gateway_script': scenario.gatewayScript,
      'sandbox': scenario.sandbox?.toJson(),
      'steps': _steps,
      'inner': inner,
    };
    return normalize(fixture);
  }

  static const _innerHeaders = {
    'authorization',
    'x-agent-run-token',
    'content-type',
    'accept',
  };

  Map<String, Object?> _exchangeJson(RecordedExchange e, Object? step) => {
    'step': step,
    'request': {
      'method': e.method,
      'path': e.path,
      if (e.query.isNotEmpty) 'query': e.query,
      'headers': {
        for (final h in e.headers.entries)
          if (_innerHeaders.contains(h.key)) h.key: h.value,
      },
      'body': ?e.body,
    },
    'response': {
      'status': e.status,
      if (e.events != null) 'events': e.events else 'body': ?e.responseBody,
      if (e.events != null) 'closed_by_client': e.closedByClient,
    },
  };

  /// Replaces volatile values (see `fixtures/README.md`) and refuses
  /// anything local that would leak into a public fixture.
  Map<String, Object?> normalize(Map<String, Object?> fixture) {
    final replacements = <String, String>{
      for (var i = 0; i < _runIds.length; i++) _runIds[i]: fixtureRunId(i + 1),
      gateway.url.toString(): innerPlaceholder,
      if (supervisor != null) supervisor!.url.toString(): supervisorPlaceholder,
      for (final s in supervisor?.sandboxes.values ?? const <FakeShellctl>[])
        s.url.toString(): sandboxPlaceholder,
    };
    final callIds = <String, String>{};
    final timestamp = RegExp(
      r'\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?(Z|[+-]\d\d:\d\d)',
    );
    final generatedCallId = RegExp(r'\bcall_[0-9a-f]{12}\b');
    String fix(String s) {
      var out = s;
      replacements.forEach((from, to) => out = out.replaceAll(from, to));
      out = out.replaceAll(timestamp, fixtureTimestamp);
      return out.replaceAllMapped(
        generatedCallId,
        (m) => callIds.putIfAbsent(
          m[0]!,
          () => 'call_${(callIds.length + 1).toString().padLeft(12, '0')}',
        ),
      );
    }

    Object? walk(Object? v) => switch (v) {
      final String s => fix(s),
      final Map<Object?, Object?> m => {
        for (final e in m.entries) fix(e.key as String): walk(e.value),
      },
      final List<Object?> l => [for (final x in l) walk(x)],
      _ => v,
    };
    final out = (walk(fixture) as Map).cast<String, Object?>();
    final text = jsonEncode(out);
    final forbidden = <String>[
      '127.0.0.1',
      'localhost',
      Directory.current.path,
      dataDir.path,
      ?Platform.environment['HOME'],
      ?Platform.environment['USER'],
    ].where((f) => f.length > 3);
    for (final f in forbidden) {
      if (text.contains(f)) {
        throw StateError('${scenario.name}: fixture contains "$f"');
      }
    }
    if (RegExp(r'run_[0-9a-f]{24}').allMatches(text).any((m) {
      final id = m[0]!;
      return !List.generate(
        _runIds.length + 99,
        (i) => fixtureRunId(i + 1),
      ).contains(id);
    })) {
      throw StateError('${scenario.name}: an unknown run id is left');
    }
    return out;
  }
}

/// Parses `id:`/`event:`/`data:` blocks of the agent service's event stream.
Future<List<Map<String, Object?>>> parseEventStream(Stream<List<int>> bytes) =>
    eventBlocks(bytes).toList();

/// The event blocks of an event stream as they arrive.
Stream<Map<String, Object?>> eventBlocks(Stream<List<int>> bytes) async* {
  int? id;
  String? event;
  final data = <String>[];
  await for (final line
      in bytes.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.isEmpty) {
      if (event != null) {
        yield {'id': id, 'event': event, 'data': jsonDecode(data.join('\n'))};
      }
      id = null;
      event = null;
      data.clear();
    } else if (line.startsWith('id: ')) {
      id = int.parse(line.substring(4));
    } else if (line.startsWith('event: ')) {
      event = line.substring(7);
    } else if (line.startsWith('data: ')) {
      data.add(line.substring(6));
    }
  }
}

/// Pretty JSON with object keys sorted at every level, and a final newline.
String encodeFixture(Object? value) {
  Object? sort(Object? v) => switch (v) {
    final Map<Object?, Object?> m => {
      for (final k in m.keys.map((k) => k as String).toList()..sort())
        k: sort(m[k]),
    },
    final List<Object?> l => [for (final x in l) sort(x)],
    _ => v,
  };
  return '${const JsonEncoder.withIndent('  ').convert(sort(value))}\n';
}
