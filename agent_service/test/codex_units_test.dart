// Several expectations are ported from OpenAI Codex rust-v0.163.0 tests
// (codex-rs/utils/string/src/truncate/tests.rs,
// codex-rs/utils/output-truncation/src/truncate_tests.rs,
// codex-rs/core/src/tools/context_tests.rs,
// codex-rs/prompts/src/update_plan_instructions_tests.rs), Copyright 2025
// OpenAI, Apache License 2.0.

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:agent_service/agent_service.dart';
import 'package:agent_service/src/harness/codex/exec_output.dart';
import 'package:agent_service/src/harness/codex/prompts.dart';
import 'package:agent_service/src/harness/codex/retry.dart';
import 'package:agent_service/src/harness/codex/tools.dart';
import 'package:agent_service/src/harness/codex/transport.dart';
import 'package:agent_service/src/harness/codex/truncation.dart';
import 'package:agent_service/src/harness/codex/unified_exec.dart';
import 'package:agent_service/src/harness/codex/vendored.g.dart';
import 'package:test/test.dart';

import '../tool/gen_codex_vendor.dart';
import 'support.dart';

void main() {
  group('truncation (truncate tests)', () {
    test('token budget', () {
      expect(truncateMiddleWithTokenBudget('short output', 100), (
        'short output',
        null,
      ));
      expect(truncateMiddleWithTokenBudget('abcdef', 0), (
        '…2 tokens truncated…',
        2,
      ));
      expect(
        truncateMiddleWithTokenBudget(
          '😀😀😀😀😀😀😀😀😀😀\nsecond line with text\n',
          8,
        ),
        ('😀😀😀😀…8 tokens truncated… line with text\n', 16),
      );
      for (final (input, expected) in [
        ('a😀b😀c', 'a…2 tokens truncated…c'),
        ('é中😀é', 'é…2 tokens truncated…é'),
        ('😀😀😀', '…2 tokens truncated…'),
      ]) {
        expect(truncateMiddleWithTokenBudget(input, 1), (expected, 3));
      }
    });

    test('byte budget', () {
      expect(
        truncateMiddleChars(
          '😀😀😀😀😀😀😀😀😀😀\nsecond line with text\n',
          20,
        ),
        '😀😀…21 chars truncated…with text\n',
      );
    });

    test('formatted', () {
      const content = 'example output';
      expect(
        formattedTruncateText(content, const TruncationPolicy.bytes(1)),
        'Warning: truncated output (original token count: 4)\nTotal output '
        'lines: 1\n\n…13 chars truncated…t',
      );
      expect(
        formattedTruncateText(content, const TruncationPolicy.tokens(1)),
        'Warning: truncated output (original token count: 4)\nTotal output '
        'lines: 1\n\nex…3 tokens truncated…ut',
      );
      expect(
        formattedTruncateText(content, const TruncationPolicy.tokens(10)),
        content,
      );
      expect(
        formattedTruncateText(content, const TruncationPolicy.bytes(20)),
        content,
      );
      const long =
          'this is an example of a long output that should be truncated';
      expect(
        formattedTruncateText(long, const TruncationPolicy.tokens(5)),
        'Warning: truncated output (original token count: 15)\nTotal output '
        'lines: 1\n\nthis is an…10 tokens truncated… truncated',
      );
      expect(
        formattedTruncateText(long, const TruncationPolicy.bytes(30)),
        'Warning: truncated output (original token count: 15)\nTotal output '
        'lines: 1\n\nthis is an exam…30 chars truncated…ld be truncated',
      );
      const two = '$long\nalso some other line';
      expect(
        formattedTruncateText(two, const TruncationPolicy.bytes(30)),
        'Warning: truncated output (original token count: 21)\nTotal output '
        'lines: 2\n\nthis is an exam…51 chars truncated…some other line',
      );
      expect(
        formattedTruncateText(two, const TruncationPolicy.tokens(10)),
        'Warning: truncated output (original token count: 21)\nTotal output '
        'lines: 2\n\nthis is an example o…11 tokens truncated…also some other '
        'line',
      );
    });

    test('policies: catalog, fallback, serialization allowance', () {
      expect(catalogTruncationPolicy.byteBudget, 40000);
      expect(fallbackTruncationPolicy.byteBudget, 10000);
      expect(
        withSerializationAllowance(catalogTruncationPolicy),
        const TruncationPolicy.tokens(12000),
      );
    });

    test('the dify style keeps its 8 KiB cap (unchanged constants)', () {
      expect(shellOutputPromptEdgeBytes, 4 * 1024);
      expect(shellOutputMarkerLimitBytes, 8 * 1024);
    });
  });

  group('exec output (context_tests)', () {
    test('header and token truncation', () {
      final out = ExecCommandOutput(
        chunkId: 'abc123',
        wallTime: const Duration(milliseconds: 1250),
        rawOutput: utf8.encode(
          'token one token two token three token four token five',
        ),
        truncationPolicy: const TruncationPolicy.tokens(10000),
        maxOutputTokens: 4,
        exitCode: 0,
        originalTokenCount: 10,
      );
      expect(
        out.header,
        'Chunk ID: abc123\nWall time: 1.2500 seconds\nProcess exited with '
        'code 0\nOriginal token count: 10\nOutput:',
      );
      expect(
        out.responseText(),
        matches(
          RegExp(
            r'^Chunk ID: abc123\nWall time: \d+\.\d{4} seconds\nProcess exited '
            r'with code 0\nOriginal token count: 10\nOutput:\n.*tokens '
            r'truncated.*$',
            dotAll: true,
          ),
        ),
      );
    });

    test('reserves the metadata budget, keeps policy units', () {
      final raw = utf8.encode([for (var i = 1; i <= 150; i++) '$i\n'].join());
      for (final (policy, marker) in [
        (const TruncationPolicy.bytes(200), 'chars truncated'),
        (const TruncationPolicy.tokens(50), 'tokens truncated'),
      ]) {
        final text = ExecCommandOutput(
          chunkId: 'abc123',
          wallTime: const Duration(milliseconds: 1250),
          rawOutput: raw,
          truncationPolicy: policy,
          exitCode: 0,
          originalTokenCount: 123,
        ).responseText();
        expect(
          utf8.encode(text).length,
          lessThanOrEqualTo((policy * 1.2).byteBudget),
        );
        expect(marker.allMatches(text).length, 1);
        expect(text, contains('Original token count: 123'));
        expect(text, contains('Total output lines: 150'));
        expect(text, contains('\n1\n2\n3\n'));
        expect(text, endsWith('149\n150\n'));
      }
    });

    test('omission marker kept once', () {
      final marker = outputOmissionMarker(123456);
      final text = ExecCommandOutput(
        chunkId: 'abc123',
        wallTime: const Duration(milliseconds: 1250),
        rawOutput: utf8.encode('HEAD-${'a' * 100}\n$marker\nTAIL-${'z' * 100}'),
        truncationPolicy: const TruncationPolicy.tokens(10000),
        maxOutputTokens: 4,
        exitCode: 0,
        originalTokenCount: 42000,
        outputOmittedBytes: 123456,
      ).responseText();
      expect(text, contains('Original token count: 42000'));
      expect(
        text,
        contains('Warning: truncated output (original token count: 42000)'),
      );
      expect(marker.allMatches(text).length, 1);
    });

    test('a running process reports its session ID', () {
      final out = ExecCommandOutput(
        chunkId: 'c0ffee',
        wallTime: const Duration(milliseconds: 500),
        rawOutput: utf8.encode('waiting'),
        truncationPolicy: catalogTruncationPolicy,
        processId: 4711,
        originalTokenCount: 2,
      );
      expect(
        out.responseText(),
        'Chunk ID: c0ffee\nWall time: 0.5000 seconds\nProcess running with '
        'session ID 4711\nOriginal token count: 2\nOutput:\nwaiting',
      );
    });

    test('Codex sees ~40 KB where the dify style shows 8 KiB', () {
      final raw = utf8.encode('x' * 30000);
      final text = ExecCommandOutput(
        chunkId: '',
        wallTime: Duration.zero,
        rawOutput: raw,
        truncationPolicy: catalogTruncationPolicy,
        exitCode: 0,
      ).responseText();
      expect(text, isNot(contains('truncated')));
    });

    test('head/tail buffer', () {
      final b = HeadTailBuffer(maxBytes: 10);
      b.push(utf8.encode('0123456789abcdef'));
      expect(
        utf8.decode(b.toBytesWithOmissionMarker()),
        '01234\n... 6 bytes omitted ...\nbcdef',
      );
      expect(b.totalBytes, 16);
    });

    test('format_exec_output_for_model (apply_patch)', () {
      expect(
        formatExecOutputForModel(
          exitCode: 0,
          duration: const Duration(milliseconds: 40),
          output: 'Success. Updated the following files:\nM a.txt\n',
          policy: catalogTruncationPolicy,
        ),
        'Exit code: 0\nWall time: 0 seconds\nOutput:\nSuccess. Updated the '
        'following files:\nM a.txt\n',
      );
      expect(
        formatExecOutputForModel(
          exitCode: 1,
          duration: const Duration(milliseconds: 1260),
          output: 'boom\n',
          policy: catalogTruncationPolicy,
        ),
        'Exit code: 1\nWall time: 1.3 seconds\nOutput:\nboom\n',
      );
    });

    test('yield clamps', () {
      expect(clampYieldTime(10), 250);
      expect(clampYieldTime(99999), 30000);
      expect(writeStdinYieldTime(250, empty: true), 5000);
      expect(writeStdinYieldTime(999999, empty: true), 300000);
      expect(writeStdinYieldTime(100, empty: false), 250);
      expect(writeStdinYieldTime(99999, empty: false), 30000);
    });
  });

  group('prompts', () {
    test('vendored texts are the third_party files', () {
      expect(
        File('lib/src/harness/codex/vendored.g.dart').readAsStringSync(),
        generateVendored(),
        reason: 'regenerate with: dart run tool/gen_codex_vendor.dart',
      );
    });

    test('the license copies of the image are third_party/codex', () {
      for (final f in ['LICENSE', 'NOTICE']) {
        expect(
          File('third_party_licenses/codex/$f').readAsStringSync(),
          File('../third_party/codex/$f').readAsStringSync(),
        );
      }
      expect(codexNotice, startsWith('OpenAI Codex\n'));
    });

    test('routing: gpt-6 family, namespaced, fallback', () {
      expect(codexModelProfile('gpt-6.1-terra').family, 'gpt-6');
      expect(codexModelProfile('codex/gpt-6.1-terra').family, 'gpt-6');
      expect(codexModelProfile('gpt-6-astra').family, 'gpt-6');
      expect(codexModelProfile('a/b/gpt-6.1-terra').family, 'fallback');
      expect(codexModelProfile('deepseek-v4').family, 'fallback');
      expect(
        codexModelProfile('deepseek-v4').truncationPolicy,
        const TruncationPolicy.bytes(10000),
      );
      expect(
        codexModelProfile('gpt-6.1-terra').truncationPolicy,
        const TruncationPolicy.tokens(10000),
      );
    });

    test('gpt-6 base instructions: astra up to "# Using skills", Direct '
        'bullet', () {
      final text = baseInstructions(
        codexModelProfile('gpt-6.1-terra'),
        updatePlan: false,
      );
      expect(text, startsWith('You are Codex, an agent based on GPT-6.'));
      expect(text, isNot(contains('# Using skills')));
      expect(text, isNot(contains('# Apps (Connectors)')));
      expect(text, isNot(contains('functions.exec')));
      expect(text, contains(gpt6DirectToolsBullet));
      // Everything else is the upstream text byte for byte.
      final upstream = codexGpt6AstraTemplate.substring(
        0,
        codexGpt6AstraTemplate.indexOf('\n# Using skills\n'),
      );
      expect(
        text.replaceFirst(gpt6DirectToolsBullet, gpt6CodeModeBullets),
        upstream,
      );
    });

    test('fallback: prompt.md without the update_plan sections unless on', () {
      final p = codexModelProfile('deepseek-v4');
      final off = baseInstructions(p, updatePlan: false);
      final on = baseInstructions(p, updatePlan: true);
      expect(on, codexFallbackPrompt);
      expect(off, isNot(contains('## `update_plan`')));
      expect(off, isNot(contains('You have access to an `update_plan` tool')));
      expect(off, contains('# AGENTS.md spec'));
    });

    test('without_update_plan_instructions (upstream tests)', () {
      expect(
        withoutUpdatePlanInstructions(
          'Before.\n\n## Planning\nYou have access to an `update_plan` tool '
          'which tracks steps.\n\n### Examples\nKeep steps current.\n\n## '
          'Work\nImplement.\n\n## `update_plan`\nUpdate the checklist.\n\n# '
          'Next\n## Planning\nDiscuss architecture and inspect update_plan '
          'before editing.\n',
        ),
        'Before.\n\n## Work\nImplement.\n\n# Next\n## Planning\nDiscuss '
        'architecture and inspect update_plan before editing.\n',
      );
      expect(
        withoutUpdatePlanInstructions(
          '# Plan Mode\nKeep planning.\n\n## Plan Mode vs update_plan tool\n'
          'The tools are separate.\n\n## Execution\nDo not edit.\n\n## Plan '
          'tool\nWhen using the planning tool:\n- Update steps.\n',
        ),
        '# Plan Mode\nKeep planning.\n\n## Execution\nDo not edit.\n\n',
      );
      expect(
        withoutUpdatePlanInstructions(
          'Keep working.\n- Use the plan tool to explain the work\n    - Skip '
          'simple tasks.\n    - Keep steps current.\n- Explain discoveries.\n'
          '- If you create a checklist or task list, update its statuses.\n\n'
          'Progress visibility:\nIf update_plan is available, use it for '
          'complex work.\n\nCompletion:\nVerify the result.\n',
        ),
        'Keep working.\n- Explain discoveries.\n\nCompletion:\nVerify the '
        'result.\n',
      );
    });

    test('permissions: the text of a real 0.163.0 rollout', () {
      expect(
        permissionsInstructions(networkEnabled: true),
        '<permissions instructions>\nFilesystem sandboxing defines which '
        'files can be read or written. `sandbox_mode` is `danger-full-access`: '
        'No filesystem sandboxing - all commands are permitted. Network '
        'access is enabled.\nApproval policy is currently never. Do not '
        'provide the `sandbox_permissions` for any reason, commands will be '
        'rejected.\n</permissions instructions>',
      );
      expect(
        permissionsInstructions(networkEnabled: false),
        contains('Network access is restricted.'),
      );
    });

    test('AGENTS.md block and environment context', () {
      expect(
        agentsMdInstructions('Be brief.'),
        '# AGENTS.md instructions for /workspace\n\n<INSTRUCTIONS>\nBe '
        'brief.\n</INSTRUCTIONS>',
      );
      expect(
        environmentContext(now: DateTime.utc(2026, 10, 27, 23)),
        '<environment_context>\n  <cwd>/workspace</cwd>\n  <shell>bash</shell>'
        '\n  <current_date>2026-10-27</current_date>\n  <timezone>UTC'
        '</timezone>\n  <filesystem><workspace_roots><root>/workspace</root>'
        '</workspace_roots><permission_profile type="disabled"><file_system '
        'type="unrestricted" /></permission_profile></filesystem>\n'
        '</environment_context>',
      );
    });
  });

  group('tool definitions', () {
    test('exec_command and write_stdin: Codex schemas less the dropped '
        'parameters', () {
      expect(execCommandTool.toResponsesJson(), {
        'type': 'function',
        'name': 'exec_command',
        'description':
            'Runs a command in a PTY, returning output or a session ID for '
            'ongoing interaction.',
        'strict': false,
        'parameters': {
          'type': 'object',
          'properties': {
            'cmd': {
              'type': 'string',
              'description': 'Shell command to execute.',
            },
            'login': {
              'type': 'boolean',
              'description':
                  'True runs the shell with -l/-i semantics; false disables '
                  'them. Defaults to true.',
            },
            'max_output_tokens': {
              'type': 'number',
              'description':
                  'Output token budget. Defaults to 10000 tokens; larger '
                  'requests may be capped by policy.',
            },
            'tty': {
              'type': 'boolean',
              'description':
                  'True allocates a PTY for the command; false or omitted uses '
                  'plain pipes.',
            },
            'workdir': {
              'type': 'string',
              'description': 'Working directory for the command. Defaults to the turn cwd.',
            },
            'yield_time_ms': {
              'type': 'number',
              'description':
                  'Wait before yielding output. Defaults to 10000 ms; effective '
                  'range is 250-30000 ms.',
            },
          },
          'required': ['cmd'],
          'additionalProperties': false,
        },
      });
      expect((writeStdinTool.parameters!['properties'] as Map).keys, [
        'chars',
        'max_output_tokens',
        'session_id',
        'yield_time_ms',
      ]);
    });

    test('apply_patch: freeform with the Lark grammar; a function on the '
        'plugin wire', () {
      expect(applyPatchFreeformTool.toResponsesJson(), {
        'type': 'custom',
        'name': 'apply_patch',
        'description':
            'The `apply_patch` tool can be used to edit files. This is a '
            'FREEFORM tool, so do not wrap the patch in JSON.',
        'format': {
          'type': 'grammar',
          'syntax': 'lark',
          'definition': codexApplyPatchLark,
        },
      });
      expect(applyPatchFunctionTool.description, contains(codexApplyPatchLark));
      expect(applyPatchFunctionTool.parameters!['required'], ['input']);
    });

    test('view_image detail only with original-detail models; update_plan', () {
      expect(
        (viewImageTool(originalDetail: true).parameters!['properties'] as Map)
            .keys,
        ['detail', 'path'],
      );
      expect(
        (viewImageTool(originalDetail: false).parameters!['properties'] as Map)
            .keys,
        ['path'],
      );
      final plan =
          (updatePlanTool.parameters!['properties'] as Map)['plan'] as Map;
      expect((plan['items'] as Map)['required'], ['step', 'status']);
    });

    test('the tool set', () {
      List<String> names({bool updatePlan = false}) => [
        for (final t in codexTools(
          shell: true,
          viewImage: true,
          updatePlan: updatePlan,
          askHuman: true,
          reportProgress: true,
          freeform: false,
          originalImageDetail: true,
        ))
          t.name,
      ];
      expect(names(), [
        'exec_command',
        'write_stdin',
        'apply_patch',
        'view_image',
        'ask_human',
        'report_progress',
      ]);
      expect(names(updatePlan: true), contains('update_plan'));
    });
  });

  group('retry rules', () {
    final random = Random(1);
    test('backoff: 200 ms doubling, ±10%', () {
      for (var attempt = 1; attempt <= 5; attempt++) {
        final base = 200 * (1 << (attempt - 1));
        final s = streamBackoff(attempt, random).inMilliseconds;
        final r = requestBackoff(attempt, random).inMilliseconds;
        for (final v in [s, r]) {
          expect(v, inInclusiveRange(base * 0.9 - 1, base * 1.1));
        }
      }
      expect(requestBackoff(0, random), retryBaseDelay);
      expect(requestMaxRetries, 4);
      expect(streamMaxRetries, 5);
    });

    test('classification', () {
      expect(classifyHttpStatus(500), ModelFailureKind.serverError);
      expect(classifyHttpStatus(502), ModelFailureKind.serverError);
      expect(
        classifyHttpStatus(503, errorCode: 'server_is_overloaded'),
        ModelFailureKind.overloaded,
      );
      for (final s in [400, 401, 403, 404, 409, 410, 413, 422]) {
        expect(classifyHttpStatus(s), ModelFailureKind.invalidRequest);
      }
      expect(classifyHttpStatus(429), ModelFailureKind.quota);
      expect(
        classifyEnvelope(-429, 'InvokeRateLimitError'),
        ModelFailureKind.rateLimited,
      );
      expect(classifyEnvelope(-429, null), ModelFailureKind.quota);
      expect(
        classifyEnvelope(-500, 'InvokeServerUnavailableError'),
        ModelFailureKind.stream,
      );
      expect(
        classifyEnvelope(-500, 'InvokeBadRequestError'),
        ModelFailureKind.invalidRequest,
      );
    });

    test('which layer retries what', () {
      final r = Random(2);
      ModelCallFailure f(
        ModelFailureKind k, {
        Duration? after,
        bool pre = true,
      }) => ModelCallFailure(k, 'x', retryAfter: after, beforeStream: pre);
      expect(f(ModelFailureKind.serverError).requestRetryable, isTrue);
      expect(f(ModelFailureKind.connection).requestRetryable, isTrue);
      expect(f(ModelFailureKind.rateLimited).requestRetryable, isFalse);
      expect(f(ModelFailureKind.stream, pre: false).requestRetryable, isFalse);
      expect(f(ModelFailureKind.quota).streamRetryDelay(1, r), isNull);
      expect(f(ModelFailureKind.invalidRequest).streamRetryDelay(1, r), isNull);
      expect(f(ModelFailureKind.overloaded).streamRetryDelay(1, r), isNull);
      expect(
        f(
          ModelFailureKind.overloaded,
          after: const Duration(seconds: 3),
        ).streamRetryDelay(1, r),
        const Duration(seconds: 3),
      );
      expect(f(ModelFailureKind.stream).streamRetryDelay(1, r), isNotNull);
      expect(parseRetryAfter('1.5'), const Duration(milliseconds: 1500));
      expect(parseRetryAfter('soon'), isNull);
      expect(invocationIdFor('R', 3, 0), 'R:3');
      expect(invocationIdFor('R', 3, 2), 'R:3:2');
    });
  });

  group('unified exec over a fake backend', () {
    late _Backend backend;
    late UnifiedExec exec;
    final tracked = <String>[];
    setUp(() {
      backend = _Backend();
      tracked.clear();
      exec = UnifiedExec(
        backend,
        env: {'HOME': '/home/dify/agent'},
        truncationPolicy: catalogTruncationPolicy,
        track: (id, _, _) => tracked.add(id),
        random: Random(7),
      );
    });

    test('a finished command; Codex env; login shell; workdir', () async {
      final t = await exec.execCommand({'cmd': 'echo hi', 'workdir': 'sub'});
      expect(t.error, isFalse);
      expect(t.text, contains('Process exited with code 0'));
      expect(t.text, endsWith('Output:\nran: exec bash -lc \'echo hi\''));
      final run = backend.runs.single;
      expect(run['cwd'], '/workspace/sub');
      expect(run['mode'], 'stdio');
      expect((run['env'] as Map)['TERM'], 'dumb');
      expect((run['env'] as Map)['HOME'], '/home/dify/agent');
      expect(run['timeout'], 10.0);
      expect(tracked, ['j1']);
    });

    test('a running command gets a session; write_stdin polls; stdin '
        'closed without a tty', () async {
      backend.running = true;
      final t = await exec.execCommand({
        'cmd': 'sleep 100',
        'yield_time_ms': 1,
      });
      expect(t.text, contains('Process running with session ID '));
      expect(backend.runs.single['timeout'], 0.25);
      final id = exec.sessionIds.single;
      final w = await exec.writeStdin({'session_id': id, 'chars': 'x'});
      expect(w.error, isTrue);
      expect(
        w.text,
        'write_stdin failed: stdin is closed for this session; rerun '
        'exec_command with tty=true to keep stdin open',
      );
      backend.running = false;
      final poll = await exec.writeStdin({'session_id': id});
      expect(poll.text, contains('Process exited with code 0'));
      expect(backend.waits.last, 5.0);
      expect(exec.sessionIds, isEmpty);
      final gone = await exec.writeStdin({'session_id': id});
      expect(gone.text, 'write_stdin failed: Unknown process id $id');
    });

    test('a tty session takes input', () async {
      backend.running = true;
      await exec.execCommand({'cmd': 'cat', 'tty': true});
      expect(backend.runs.single['mode'], 'pty');
      final id = exec.sessionIds.single;
      final w = await exec.writeStdin({'session_id': id, 'chars': 'abc\n'});
      expect(w.error, isFalse);
      expect(w.text, contains('got: abc'));
      expect(backend.inputs.single, 0.25);
    });
  });

  group('effort and harness_style validation (OperationRequest.parse)', () {
    Map<String, Object?> op({
      String? style,
      Object? effort,
      bool plan = false,
    }) {
      final o = operation();
      if (style != null) o['harness_style'] = style;
      if (effort != null) {
        (o['model'] as Map)['parameters'] = {'reasoning_effort': effort};
      }
      if (plan) (o['tools'] as Map)['update_plan'] = true;
      return o;
    }

    int? status(Map<String, Object?> o) {
      try {
        OperationRequest.parse(o);
        return null;
      } on ApiError catch (e) {
        return e.status;
      }
    }

    test('styles', () {
      expect(OperationRequest.parse(op()).harnessStyle, HarnessStyle.dify);
      expect(
        OperationRequest.parse(op(style: 'codex')).harnessStyle,
        HarnessStyle.codex,
      );
      expect(status(op(style: 'claude_code')), 422);
      expect(status(op()..['harness_style'] = 3), 400);
      expect(status(op(plan: true)), 400);
      expect(status(op(style: 'codex', plan: true)), isNull);
    });

    test('efforts in the codex style', () {
      for (final e in codexReasoningEfforts) {
        expect(
          status(op(style: 'codex', effort: e)),
          isNull,
          reason: e,
        );
      }
      for (final e in ['ultra', 'persistent', 'turbo', 3]) {
        expect(
          status(op(style: 'codex', effort: e)),
          422,
          reason: '$e',
        );
      }
      try {
        OperationRequest.parse(op(style: 'codex', effort: 'ultra'));
      } on ApiError catch (e) {
        expect(e.code, 'unsupported_reasoning_effort');
        expect(e.message, contains('sub-agents'));
      }
      // The dify style forwards whatever the plugin accepts.
      expect(status(op(effort: 'ultra')), isNull);
    });
  });
}

class _Backend implements ExecBackend {
  final runs = <Map<String, Object?>>[];
  final waits = <num>[];
  final inputs = <num>[];
  bool running = false;
  var _n = 0;

  JobResult _r(String id, String out) => JobResult(
    jobId: id,
    status: running ? 'running' : 'exited',
    done: !running,
    exitCode: running ? null : 0,
    output: out,
    offset: out.length,
  );

  @override
  Future<JobResult> run(
    String script, {
    required String cwd,
    required Map<String, String> env,
    required num timeout,
    required String mode,
  }) async {
    runs.add({'cwd': cwd, 'env': env, 'timeout': timeout, 'mode': mode});
    return _r('j${++_n}', 'ran: $script');
  }

  @override
  Future<JobResult> wait(
    String jobId, {
    required int offset,
    required num timeout,
  }) async {
    waits.add(timeout);
    return _r(jobId, '');
  }

  @override
  Future<JobResult> input(
    String jobId,
    String text, {
    required int offset,
    required num timeout,
  }) async {
    inputs.add(timeout);
    return _r(jobId, 'got: $text');
  }

  @override
  Future<JobResult> terminate(String jobId) async => _r(jobId, '');
}
