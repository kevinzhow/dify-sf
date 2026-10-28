// The official Codex runtime's pieces that run without a sandbox: the
// operation fields, config.toml, the catalog entry and the output schema.
// The runtime itself is covered end to end by tool/codex_e2e.sh (a real
// sandbox, the real binary and the scripted gateway's Codex entry).
import 'dart:convert';

import 'package:agent_service/agent_service.dart';
import 'package:agent_service/src/harness/codex/official.dart';
import 'package:agent_service/testing.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'support.dart';

void main() {
  test('diagnostic tail redacts before cutting across a credential', () {
    final secret = 'fixture-secret-capability';
    final raw = '${'x' * 100}$secret${'y' * 3990}';
    final safe = codexDiagnosticTail(raw, [null, '', secret]);
    expect(safe.length, lessThanOrEqualTo(4001));
    expect(safe, isNot(contains('capability')));
    expect(codexDiagnosticTail('safe tail', [secret]), 'safe tail');
  });

  Map<String, Object?> codexOp({Object? effort, bool token = true}) {
    final o = operation();
    final model = Map.of(o['model'] as Map<String, Object?>);
    if (token) model['run_token'] = 'secret-run-token';
    if (effort != null) model['parameters'] = {'reasoning_effort': effort};
    return {...o, 'harness_style': 'codex', 'model': model};
  }

  group('operation', () {
    test('model.run_token is kept out of the request JSON and digest', () {
      final r = OperationRequest.parse(codexOp(), officialCodex: true);
      expect(r.officialCodex, isTrue);
      expect(r.codexRunToken, 'secret-run-token');
      expect(jsonEncode(r.json), isNot(contains('secret-run-token')));
      final without = OperationRequest.parse(codexOp(token: false));
      expect(r.digest, without.digest);
    });

    test('the official runtime needs the token and accepts ultra', () {
      expect(
        () =>
            OperationRequest.parse(codexOp(token: false), officialCodex: true),
        throwsA(isA<ApiError>().having((e) => e.status, 'status', 400)),
      );
      final r = OperationRequest.parse(
        codexOp(effort: 'ultra'),
        officialCodex: true,
      );
      expect(r.reasoningEffort, 'ultra');
      expect(
        () => OperationRequest.parse(codexOp(effort: 'ultra')),
        throwsA(isA<ApiError>().having((e) => e.status, 'status', 422)),
      );
      expect(
        () => OperationRequest.parse(
          codexOp(effort: 'persistent'),
          officialCodex: true,
        ),
        throwsA(isA<ApiError>().having((e) => e.status, 'status', 422)),
      );
    });
  });

  test('config.toml', () {
    final toml = codexConfigToml(
      model: 'deepseek-v4.1-flash',
      baseUrl: 'http://gw/inner/agent/codex/v1',
      catalogPath: '/home/dify/agent/.codex-runs/r/models.json',
      workspace: '/workspace',
      effort: 'max',
      shell: true,
      viewImage: false,
      updatePlan: false,
      commandEnv: {'NO_PROXY': 'localhost'},
    );
    for (final line in [
      'model_provider = "difysf"',
      'model_reasoning_effort = "max"',
      'base_url = "http://gw/inner/agent/codex/v1"',
      'env_key = "DIFYSF_RUN_TOKEN"',
      'supports_websockets = false',
      'supports_websockets = false\nrequest_max_retries = 2\n'
          'stream_max_retries = 2\n',
      'exclude = ["DIFYSF_RUN_TOKEN", "SHELLCTL_*"]',
      'NO_PROXY = "localhost"',
      'multi_agent = false',
      'instant_interrupt = false',
      'view_image = false',
    ]) {
      expect(toml, contains(line));
    }
    expect(
      codexConfigToml(
        model: 'm',
        baseUrl: 'u',
        catalogPath: 'c',
        workspace: '/workspace',
        effort: 'ultra',
        shell: true,
        viewImage: true,
        updatePlan: true,
      ),
      contains('multi_agent = true'),
    );
    // Skills: the catalog only with the profile's skills; never bundled
    // skills or the MCP-dependency install prompt.
    expect(toml, contains('[skills]\ninclude_instructions = false\n'));
    expect(toml, contains('[skills.bundled]\nenabled = false\n'));
    expect(toml, contains('skill_mcp_dependency_install = false'));
    final withSkills = codexConfigToml(
      model: 'm',
      baseUrl: 'u',
      catalogPath: 'c',
      workspace: '/workspace',
      shell: true,
      viewImage: true,
      updatePlan: true,
      skills: true,
    );
    expect(withSkills, contains('[skills]\ninclude_instructions = true\n'));
    expect(withSkills, contains('[skills.bundled]\nenabled = false\n'));
    expect(withSkills, contains('skill_mcp_dependency_install = false'));
    // The workspace is an untrusted project (no project config.toml, hooks,
    // exec policies or AGENTS.md from it), declared once, as the last table.
    for (final t in [toml, withSkills]) {
      expect(
        t,
        endsWith('\n[projects."/workspace"]\ntrust_level = "untrusted"\n'),
      );
      expect('[projects.'.allMatches(t), hasLength(1));
    }
  });

  test('skills: the profile directories\' enabled skills by name, every '
      'other skill Codex found to be disabled', () {
    Map<String, Object?> skill(String name, String path, {bool on = true}) => {
      'name': name,
      'path': path,
      'scope': 'user',
      'enabled': on,
    };
    final s = codexSkillSelection(
      {
        'data': [
          {
            'cwd': '/workspace',
            'skills': [
              skill('render', '/opt/kit/tools/skills/render/SKILL.md'),
              skill('board', '/opt/kit/tools/skills/board/SKILL.md'),
              skill('off', '/opt/kit/tools/skills/off/SKILL.md', on: false),
              skill('repo', '/workspace/.agents/skills/repo/SKILL.md'),
              skill('home', '/home/dify/agent/.agents/skills/home/SKILL.md'),
              skill('near', '/opt/kit/tools/skillsx/near/SKILL.md'),
            ],
            'errors': [
              {'path': '/opt/kit/tools/skills/bad/SKILL.md', 'message': 'no'},
            ],
          },
        ],
      },
      ['/opt/kit/tools/skills'],
    );
    expect(s.names, ['board', 'render']);
    expect(s.others, [
      '/workspace/.agents/skills/repo/SKILL.md',
      '/home/dify/agent/.agents/skills/home/SKILL.md',
      '/opt/kit/tools/skillsx/near/SKILL.md',
    ]);
    expect(s.errors, ['/opt/kit/tools/skills/bad/SKILL.md: no']);
    expect(codexSkillSelection({'data': []}, ['/opt/kit']).names, isEmpty);
  });

  group('profile skills before Codex starts', () {
    const image =
        'dify-sf/sandbox@sha256:'
        '1111111111111111111111111111111111111111111111111111111111111111';
    Future<(Harness, String)> start(String resolved) async {
      final profiles = ExecutorProfiles.parse({
        'version': 1,
        'profiles': {
          'default': {
            'image': image,
            'mounts': [
              {'source': '/srv/codex', 'target': '/opt/codex'},
              {'source': '/srv/kit', 'target': '/opt/kit'},
            ],
            'codex': {
              'skills_dirs': ['/opt/kit/tools/skills'],
            },
          },
        },
      });
      final sup =
          FakeSupervisor(
              key: testSupervisorKey,
              configure: (s) => s
                ..onControl = ((script) async => script.contains('--version')
                    ? (
                        0,
                        'version codex-cli $officialCodexVersion\n'
                            'sha256 $officialCodexSha256\n',
                      )
                    : null)
                ..onJob = (script) => FakeJobSpec(
                  output: script.contains('debug models --bundled')
                      ? '{"models": []}'
                      : script.contains('readlink -f')
                      ? resolved
                      : '\n\n',
                ),
            )
            ..profiles = {
              for (final p in profiles.profiles.values)
                p.name: {'status': 'ok', 'digest': p.digest},
            };
      await sup.start();
      final h = await Harness.start(
        supervisorUrl: sup.url,
        profiles: profiles,
        codexRuntime: CodexRuntime.official,
        codexGatewayUrl: 'http://gw/inner/agent/codex/v1',
      );
      addTearDown(() async {
        await h.close();
        await sup.close();
      });
      return (h, await h.startOperation(codexOp()));
    }

    for (final (resolved, message) in [
      ('\n', 'is not a directory in the sandbox'),
      (
        '/home/dify/agent/skills\n',
        'resolves to /home/dify/agent/skills, '
            'outside its mounts',
      ),
    ]) {
      test('a skills directory that ${message.split(',').first} ends the run '
          'sandbox_error; the held run_started comes first', () async {
        final (h, run) = await start(resolved);
        final status = await h.waitEnded(run);
        expect(status['status'], 'failed', reason: jsonEncode(status));
        final result = status['result'] as Map;
        expect(result['error_type'], 'sandbox_error');
        expect(result['message'], contains(message));
        final events = await h.events(run);
        expect(events.map((e) => e.event), ['run_started', 'failed']);
        final runtime = events.first.data['runtime'] as Map;
        expect(runtime['version'], officialCodexVersion);
        expect(runtime.containsKey('skills'), isFalse);
      });
    }
  });

  group('catalog entry', () {
    final bundled = [
      {
        'slug': 'gpt-6-astra',
        'tool_mode': 'code_mode_only',
        'use_responses_lite': true,
        'prefer_websockets': true,
        'apply_patch_tool_type': 'freeform',
        'default_reasoning_level': 'low',
        'supported_reasoning_levels': [
          for (final e in ['low', 'max', 'ultra'])
            {'effort': e, 'description': 'd-$e'},
        ],
        'model_messages': {'instructions_template': 'gpt-6 prompt'},
      },
    ];

    test('where the context window comes from', () {
      expect(codexContextWindowSource('m', bundled, 1000), 'operation');
      expect(
        codexContextWindowSource('gpt-6.1-terra', bundled, null),
        'bundled',
      );
      expect(
        codexContextWindowSource('deepseek-v4.1', bundled, null),
        'fallback',
      );
      expect(
        codexCatalogEntry(
          model: 'deepseek-v4.1',
          bundled: bundled,
          shell: true,
        )['context_window'],
        272000,
      );
    });

    test('gpt-6 models start from gpt-6-astra, in Direct-tools mode', () {
      final e = codexCatalogEntry(
        model: 'gpt-6.1-terra',
        bundled: bundled,
        contextWindow: 400000,
        reasoningEfforts: ['max', 'ultra'],
        shell: true,
      );
      expect(e['slug'], 'gpt-6.1-terra');
      expect(
        (e['model_messages'] as Map)['instructions_template'],
        'gpt-6 prompt',
      );
      expect(e['tool_mode'], isNull);
      expect(e['use_responses_lite'], isFalse);
      expect(e['prefer_websockets'], isFalse);
      expect(e['context_window'], 400000);
      expect(e['supported_reasoning_levels'], [
        {'effort': 'max', 'description': 'd-max'},
        {'effort': 'ultra', 'description': 'd-ultra'},
      ]);
      expect(e['default_reasoning_level'], isNull);
    });

    test(
      'other models get the fallback metadata with freeform apply_patch',
      () {
        final e = codexCatalogEntry(
          model: 'deepseek-v4.1-flash',
          bundled: bundled,
          inputModalities: ['text'],
          shell: true,
        );
        expect(e['shell_type'], 'unified_exec');
        expect(e['apply_patch_tool_type'], 'freeform');
        expect(e['input_modalities'], ['text']);
        expect(
          (e['model_messages'] as Map)['instructions_template'],
          startsWith('You are a coding agent running in the Codex CLI'),
        );
        expect(
          codexCatalogEntry(
            model: 'x',
            bundled: bundled,
            shell: false,
          )['apply_patch_tool_type'],
          isNull,
        );
      },
    );
  });

  test('declared outputs: strict schema and the optional nulls dropped', () {
    final schema = {
      'type': 'object',
      'properties': {
        'text': {'type': 'string'},
        'board': {'type': 'string'},
      },
      'required': ['text'],
    };
    final strict = strictOutputSchema(schema);
    expect(strict['required'], ['text', 'board']);
    expect(strict['additionalProperties'], isFalse);
    expect((strict['properties'] as Map)['board'], {
      'type': ['string', 'null'],
    });
    expect(dropOptionalNulls(schema, {'text': 'a', 'board': null}), {
      'text': 'a',
    });
  });

  test('usageLimitExceeded: the gateway\'s call limit is max_turns, other '
      'limits model_quota', () {
    String type(String message, int attempts) => codexUsageLimitErrorType(
      message: message,
      attempts: attempts,
      maxTurns: 5,
    );
    // Codex 0.163.0's texts: a 429 usage_limit_reached with the gateway's
    // marker, without it, and its quota error.
    const marked =
        'You\u2019ve hit your usage limit. $codexCallLimitMarker, or try '
        'again later.';
    const unmarked = 'You\u2019ve hit your usage limit. Try again later.';
    const quota = 'Quota exceeded. Check your plan and billing details.';
    expect(type(marked, 0), 'max_turns');
    expect(type(unmarked, 5), 'max_turns');
    expect(type(unmarked, 4), 'model_quota');
    expect(type(quota, 5), 'model_quota');
    expect(type(quota, 0), 'model_quota');
  });

  test('the effort Codex sends: ultra resolved from the catalog entry', () {
    Map<String, Object?> entry(List<String> levels, [String? multi]) => {
      'supported_reasoning_levels': [
        for (final l in levels) {'effort': l, 'description': l},
      ],
      'multi_agent_reasoning_effort': multi,
    };
    expect(codexRequestEffort('high', entry([])), 'high');
    expect(codexRequestEffort(null, entry([])), isNull);
    expect(codexRequestEffort('ultra', entry(['low', 'max', 'ultra'])), 'max');
    expect(
      codexRequestEffort('ultra', entry(['low', 'xhigh', 'max'], 'xhigh')),
      'xhigh',
    );
    expect(
      codexRequestEffort('ultra', entry(['low', 'xhigh', 'ultra'])),
      'xhigh',
    );
    expect(codexRequestEffort('ultra', entry([])), 'medium');
  });

  test('scripted gateway: Codex entry token and call limit', () async {
    final gw = ScriptedGateway(
      calls: [ScriptedCall.responses([])],
      codexRunToken: 'tok',
      codexCallLimit: 1,
    );
    final base = await gw.start();
    final url = base.resolve(codexResponsesPath);
    Future<http.Response> post(String token) =>
        http.post(url, headers: {'Authorization': 'Bearer $token'}, body: '{}');
    try {
      expect((await post('wrong')).statusCode, 401);
      final ok = await post('tok');
      expect(ok.statusCode, 200);
      expect(ok.body, contains('"id":"resp_1"'));
      final limited = await post('tok');
      expect(limited.statusCode, 429);
      expect(limited.headers['x-codex-promo-message'], codexCallLimitMarker);
      expect(
        ((jsonDecode(limited.body) as Map)['error'] as Map)['type'],
        'usage_limit_reached',
      );
    } finally {
      await gw.close();
    }
  });
}
