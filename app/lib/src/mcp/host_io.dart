import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:collab_client/collab_client.dart';
import 'package:mcp_dart/mcp_dart.dart';

import '../auth/auth_controller.dart';
import '../agents/inline_checks.dart';
import '../i18n/dify_i18n.dart';
import '../workflow_editor/header/checklist/use_checklist.dart';
import '../workflow/model_catalog.dart' show languageOfLocale;
import 'workflow_reader.dart';

/// Opt-in native endpoint. The local MCP key is distinct from the login session;
/// neither is returned by tools, and browsers are refused even on loopback.
Future<void> startReadonlyMcp({required int port, required String tokenFile, required AuthController auth}) async {
  if (port < 1024 || port > 65535) throw const FormatException('invalid_mcp_port');
  final file = File(tokenFile);
  final stat = await file.stat();
  if (stat.type != FileSystemEntityType.file || stat.mode & 0x3f != 0) {
    throw const FormatException('MCP key must be an owner-only regular file');
  }
  final key = (await file.readAsString()).trim();
  if (key.length < 32 || key.contains(RegExp(r'\s'))) throw const FormatException('invalid_mcp_key');
  final reader = nativeWorkflowReader(auth);
  final host = StreamableMcpServer(
    host: '127.0.0.1',
    port: port,
    path: '/mcp',
    enableJsonResponse: true,
    allowedHosts: const {'127.0.0.1', 'localhost'},
    authenticator: (request) =>
        request.headers.value('origin') == null && _same(request.headers.value('authorization') ?? '', 'Bearer $key'),
    serverFactory: (_) => readonlyMcpServer(reader),
  );
  await host.start();
  for (final signal in [ProcessSignal.sigterm, ProcessSignal.sigint]) {
    signal.watch().listen((_) async {
      try {
        await host.stop();
      } finally {
        auth.dispose();
        exit(0);
      }
    });
  }
  // Contains no token, profile path, server URL, account or document information.
  stderr.writeln('dify-sf readonly MCP ready: http://127.0.0.1:$port/mcp');
}

bool _same(String a, String b) {
  var diff = a.length ^ b.length;
  for (var i = 0; i < b.length; i++) {
    diff |= (i < a.length ? a.codeUnitAt(i) : 0) ^ b.codeUnitAt(i);
  }
  return diff == 0;
}

McpServer readonlyMcpServer(ReadonlyWorkflowReader reader) {
  final server = McpServer(const Implementation(name: 'dify-sf-readonly', version: '0.1.0'));
  for (final name in ['read_workflow', 'check_workflow']) {
    server.registerTool(
      name,
      description: name == 'read_workflow'
          ? 'Read the authenticated workspace draft at an atomic revision.'
          : 'Run the editor checklist. Require complete=true and gate_passed=true before accepting a clean result.',
      inputSchema: JsonSchema.object(
        properties: {
          'workflow_id': JsonSchema.string(),
          'expected_revision': JsonSchema.integer(minimum: 0),
        },
        required: ['workflow_id'],
        additionalProperties: false,
      ),
      annotations: const ToolAnnotations(readOnlyHint: true, destructiveHint: false, idempotentHint: true),
      callback: (args, extra) async {
        try {
          final result = await reader.read(
            args['workflow_id']! as String,
            expectedRevision: args['expected_revision'] as int?,
            check: name == 'check_workflow',
          );
          return CallToolResult(
            structuredContent: result,
            content: [TextContent(text: jsonEncode(result))],
          );
        } on Object {
          // API failures may contain raw URLs or remote text. Do not return those.
          return CallToolResult(
            isError: true,
            content: [
              TextContent(text: 'Unable to read this workflow. Check local sign-in, access and server availability.'),
            ],
          );
        }
      },
    );
  }
  return server;
}

ReadonlyWorkflowReader nativeWorkflowReader(AuthController auth) => ReadonlyWorkflowReader(
  snapshot: (id) async {
    if (!auth.signedIn) throw StateError('sign_in_required');
    final docs = DocsApi(Uri.parse(auth.server), auth: auth.session);
    try {
      // Mode is app metadata; graph + variables + seq are one atomic snapshot.
      final meta = await docs.meta(id);
      final value = await docs.snapshot(id);
      return (seq: value.seq, doc: value.doc, mode: meta.appMode);
    } finally {
      docs.close();
    }
  },
  context: (appId, doc, mode) async {
    final missing = <String>[];
    final nodes = difyGraphOf(doc).nodes;
    List<String>? models;
    if (nodes.any((n) => n.blockType == 'llm' || isInlineAgentData(n.data))) {
      final api = HttpModelProvidersApi(Uri.parse(auth.server), auth: auth.session);
      try {
        models = [
          for (final p in await api.summaries())
            if (p['provider'] is String) p['provider']! as String,
        ];
      } on Object {
        missing.add('model_providers');
      } finally {
        api.close();
      }
    }
    Map<String, List<String>>? agentModelFeatures;
    Map<String, String>? agentModelLabels;
    if (nodes.any((n) => isInlineAgentData(n.data))) {
      final api = HttpModelProvidersApi(Uri.parse(auth.server), auth: auth.session);
      try {
        final catalog = await api.modelsOfType('llm');
        agentModelLabels = {
          for (final provider in catalog)
            for (final model in (provider['models'] as List? ?? const []).whereType<Map>())
              '${provider['provider']}/${model['model']}': (model['label'] as Map?)?['en_US'] as String? ?? '${model['model']}',
        };
        agentModelFeatures = {
          for (final provider in catalog)
            for (final model in (provider['models'] as List? ?? const []).whereType<Map>())
              '${provider['provider']}/${model['model']}': [for (final feature in model['features'] as List? ?? const []) '$feature'],
        };
      } on Object { missing.add('agent_model_features'); }
      finally { api.close(); }
    }
    List<Map<String, Object?>>? builtin, workflows;
    if (nodes.any((n) => n.blockType == 'tool')) {
      final api = ToolsApi(Uri.parse(auth.server), auth: auth.session);
      try {
        if (nodes.any((n) => n.blockType == 'tool' && n.data['provider_type'] == 'builtin')) {
          builtin = await api.providers();
        }
        if (nodes.any((n) => n.blockType == 'tool' && n.data['provider_type'] == 'workflow')) {
          workflows = await api.workflowProviders();
        }
      } on Object {
        missing.add('tool_providers');
      } finally {
        api.close();
      }
      for (final n in nodes.where((n) => n.blockType == 'tool')) {
        if (!const ['builtin', 'workflow'].contains(n.data['provider_type'])) {
          missing.add('tool_catalog:${n.data['provider_type']}');
        }
      }
    }
    var agents = const InlineAgentChecks();
    if (nodes.any((n) => isInlineAgentData(n.data))) {
      final api = HttpAgentComposerApi(Uri.parse(auth.server), auth: auth.session);
      try { agents = await InlineAgentChecks.load(api, appId, doc); missing.addAll(agents.unavailable); }
      finally { api.close(); }
    }
    // These contexts are not yet wired into this read-only bridge. Do not
    // replace unknown data with empty catalogs and accidentally pass the gate.
    for (final n in nodes) {
      if (!isInlineAgentData(n.data) && const ['agent', 'agent-v2', 'knowledge-retrieval', 'trigger-plugin', 'datasource'].contains(n.blockType)) {
        missing.add('unsupported_context:${n.blockType}');
      }
    }
    return (
      env: ChecklistEnv(
        appMode: mode,
        language: languageOfLocale(currentDifyLanguage()),
        environmentVariables: AppRegisters.variables(doc, AppRegisters.environmentVariables),
        conversationVariables: AppRegisters.variables(doc, AppRegisters.conversationVariables),
        modelProviders: models,
        builtInTools: builtin,
        inlineAgentSouls: agents.souls,
        inlineAgentModelFeatures: agentModelFeatures,
        inlineAgentModelLabels: agentModelLabels,
        workflowTools: workflows,
      ),
      unavailable: missing.toSet().toList(),
    );
  },
);

/// Fail without reflecting credential paths, remote payloads or bearer keys.
Never failReadonlyMcpStartup() {
  stderr.writeln('dify-sf MCP startup failed: check local options, key permissions and port availability.');
  exit(78);
}
