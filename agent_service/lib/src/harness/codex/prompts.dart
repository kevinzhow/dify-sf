// Portions derived from OpenAI Codex (https://github.com/openai/codex,
// rust-v0.163.0, codex-rs/models-manager/src/{manager,model_info}.rs,
// codex-rs/prompts/src/{update_plan_instructions,permissions_instructions}.rs,
// codex-rs/core/src/context/{user_instructions,environment_context}.rs,
// codex-rs/core/src/context/world_state/environment.rs), Copyright 2025
// OpenAI, licensed under the Apache License 2.0. Modified for dify-sf: a
// routing table of our own (gpt-6* to the bundled gpt-6-astra template) and
// the edits listed in third_party/codex/PATCHES.md.

/// The `codex` style's prompt: Codex's base instructions per model family,
/// the permissions fragment, the node's instructions as an AGENTS.md block
/// and the environment context, in Codex's message layout.
library;

import 'dart:convert';

import 'truncation.dart';
import 'vendored.g.dart';

/// What the `codex` style takes from a model's Codex metadata.
class CodexModelProfile {
  const CodexModelProfile({
    required this.family,
    required this.template,
    required this.truncationPolicy,
    required this.supportsImageDetailOriginal,
    required this.usedFallback,
  });

  /// `gpt-6` or `fallback`.
  final String family;

  /// The base instructions before the edits of [baseInstructions].
  final String template;
  final TruncationPolicy truncationPolicy;

  /// Whether `view_image` offers `detail: original`.
  final bool supportsImageDetailOriginal;

  /// Codex's `used_fallback_model_metadata`.
  final bool usedFallback;
}

/// The `gpt-6` family: the bundled `gpt-6-astra` template, whose first 151
/// lines are byte-identical to the remote `gpt-6.1-terra` template (the
/// harness port plan, section 1.1), with the catalog metadata every gpt-6
/// entry shares.
const _gpt6 = CodexModelProfile(
  family: 'gpt-6',
  template: codexGpt6AstraTemplate,
  truncationPolicy: catalogTruncationPolicy,
  supportsImageDetailOriginal: true,
  usedFallback: false,
);

/// `model_info_from_slug`: `prompt.md`, `bytes 10000`.
const _fallback = CodexModelProfile(
  family: 'fallback',
  template: codexFallbackPrompt,
  truncationPolicy: fallbackTruncationPolicy,
  supportsImageDetailOriginal: false,
  usedFallback: true,
);

/// Slug prefixes of the routing table (a dify-sf table; Codex matches its
/// catalog the same way).
const _candidates = {'gpt-6': _gpt6};

String? _longestPrefix(String model) {
  String? best;
  for (final slug in _candidates.keys) {
    if (model.startsWith(slug) && (best == null || slug.length > best.length)) {
      best = slug;
    }
  }
  return best;
}

final _namespacePattern = RegExp(r'^[A-Za-z0-9_-]+$');

/// `construct_model_info_from_candidates`: the longest slug prefix, else
/// the same after one simple `namespace/` segment, else the fallback.
CodexModelProfile codexModelProfile(String model) {
  var slug = _longestPrefix(model);
  if (slug == null) {
    final i = model.indexOf('/');
    if (i > 0) {
      final ns = model.substring(0, i);
      final suffix = model.substring(i + 1);
      if (!suffix.contains('/') && _namespacePattern.hasMatch(ns)) {
        slug = _longestPrefix(suffix);
      }
    }
  }
  return slug == null ? _fallback : _candidates[slug]!;
}

/// The two `functions.exec` bullets of the gpt-6 template (code mode).
const gpt6CodeModeBullets =
    '- Batch independent searches and reads in one functions.exec using await '
    'Promise.allSettled([...]); inspect every result. Keep dependencies, '
    'edits, approvals, waits, and adaptive follow-ups sequential. Avoid '
    'unnecessary output.\n'
    '- When calling `functions.exec`, parallelize independent tool calls by '
    'awaiting Promises. Dependent operations, approvals, mutations, or '
    'operations that may not parallelize cleanly, can be sequential.\n';

/// Their Direct-tools replacement (the plan, section 3.3).
const gpt6DirectToolsBullet =
    '- Run independent read-only commands as parallel tool calls.\n';

/// `without_update_plan_instructions`: drops the checklist-tool guidance
/// from Codex-owned prompt text.
String withoutUpdatePlanInstructions(String instructions) {
  final lines = _splitInclusive(instructions);
  final out = StringBuffer();
  var index = 0;
  while (index < lines.length) {
    final line = _trimEnd(lines[index]);
    if (const {
      '## Planning',
      '## `update_plan`',
      '## Plan tool',
      '## Plan Mode vs update_plan tool',
    }.contains(line)) {
      var end = lines.length;
      for (var next = index + 1; next < lines.length; next++) {
        if (lines[next].startsWith('# ') || lines[next].startsWith('## ')) {
          end = next;
          break;
        }
      }
      final isChecklist =
          line != '## Planning' ||
          lines
              .sublist(index, end)
              .any(
                (l) =>
                    l.startsWith('You have access to an `update_plan` tool') ||
                    l.startsWith(
                      'When `update_plan` is available, follow this section',
                    ),
              );
      if (isChecklist) {
        index = end;
        continue;
      }
    }
    if (line == 'Progress visibility:' &&
        index + 1 < lines.length &&
        lines[index + 1].startsWith('If update_plan is available')) {
      index += 2;
      if (index < lines.length && lines[index].trim().isEmpty) index++;
      continue;
    }
    if (line.startsWith('- Use the plan tool ') ||
        line.startsWith('- If you create a checklist or task list,')) {
      index++;
      while (index < lines.length &&
          (lines[index].startsWith(' ') || lines[index].startsWith('\t'))) {
        index++;
      }
      continue;
    }
    out.write(lines[index]);
    index++;
  }
  return out.toString();
}

List<String> _splitInclusive(String s) {
  final out = <String>[];
  var start = 0;
  while (start < s.length) {
    final nl = s.indexOf('\n', start);
    if (nl < 0) {
      out.add(s.substring(start));
      break;
    }
    out.add(s.substring(start, nl + 1));
    start = nl + 1;
  }
  return out;
}

String _trimEnd(String s) {
  var end = s.length;
  while (end > 0 && ' \t\r\n'.contains(s[end - 1])) {
    end--;
  }
  return s.substring(0, end);
}

/// The base instructions (the first `developer` message) for [profile]:
/// the gpt-6 template up to "# Using skills" (no skills, apps or plugins
/// here) with the code-mode bullets replaced; the fallback prompt as is.
/// The `update_plan` guidance is removed unless the tool is on, as Codex
/// does.
String baseInstructions(CodexModelProfile profile, {required bool updatePlan}) {
  var text = profile.template;
  if (profile.family == 'gpt-6') {
    final cut = text.indexOf('\n# Using skills\n');
    if (cut < 0) throw StateError('gpt-6 template: no "# Using skills"');
    text = text.substring(0, cut);
    if (!text.contains(gpt6CodeModeBullets)) {
      throw StateError('gpt-6 template: the functions.exec bullets changed');
    }
    text = text.replaceFirst(gpt6CodeModeBullets, gpt6DirectToolsBullet);
  }
  return updatePlan ? text : withoutUpdatePlanInstructions(text);
}

/// The `<permissions instructions>` fragment for danger-full-access and
/// approval `never` (the sandbox container is the boundary; Codex runs no
/// sandbox of its own there). [networkEnabled]: the executor profile has
/// egress through the proxy.
String permissionsInstructions({required bool networkEnabled}) {
  final sandbox = _trimEnd(codexDangerFullAccessTemplate).replaceAll(
    '{{ network_access }}',
    networkEnabled ? 'enabled' : 'restricted',
  );
  final approval = _trimEnd(codexApprovalNeverTemplate);
  return '<permissions instructions>\n$sandbox\n$approval\n'
      '</permissions instructions>';
}

/// `UserInstructions`: the node's instructions as the AGENTS.md of [cwd].
String agentsMdInstructions(String text, {String cwd = '/workspace'}) =>
    '# AGENTS.md instructions for $cwd\n\n<INSTRUCTIONS>\n$text\n</INSTRUCTIONS>';

String _xml(String s) =>
    s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

/// The `<environment_context>` of one environment, as Codex renders it for
/// danger-full-access (the filesystem element with a disabled permission
/// profile, as in a real 0.163.0 rollout).
///
/// Without the shell ([withShell] false) there is no environment to
/// describe: only the date and time zone remain.
String environmentContext({
  required DateTime now,
  bool withShell = true,
  String cwd = '/workspace',
  String shell = 'bash',
  String timezone = 'UTC',
}) {
  final d = now.toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  final date =
      '${d.year.toString().padLeft(4, '0')}-${two(d.month)}-${two(d.day)}';
  return '<environment_context>\n'
      '${withShell ? '  <cwd>${_xml(cwd)}</cwd>\n  <shell>${_xml(shell)}</shell>\n' : ''}'
      '  <current_date>$date</current_date>\n'
      '  <timezone>${_xml(timezone)}</timezone>\n'
      '${withShell ? '  <filesystem><workspace_roots><root>${_xml(cwd)}</root></workspace_roots>'
                '<permission_profile type="disabled"><file_system type="unrestricted" />'
                '</permission_profile></filesystem>\n' : ''}'
      '</environment_context>';
}

/// The dify-sf section that tells the model the declared output format. On
/// the plugin wire there is no `text.format` (Codex's `--output-schema`),
/// so the schema has to be in the prompt. The run ends at the first answer
/// without tool calls, as in Codex; nothing invites an earlier submit.
String outputFormatInstructions(Map<String, Object?> schema) =>
    '# Final answer format\n\n'
    'When the task is complete, end with a final message without tool calls '
    'that is only a JSON object conforming to this JSON Schema (no code '
    'fence, no other text):\n\n'
    '${const JsonEncoder.withIndent('  ').convert(schema)}\n\n'
    'The first message without tool calls ends the run and its JSON object '
    'is the result, so send it only when the work is done.';
