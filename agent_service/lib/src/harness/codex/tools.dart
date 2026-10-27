// Portions derived from OpenAI Codex (https://github.com/openai/codex,
// rust-v0.163.0, codex-rs/core/src/tools/handlers/{shell,apply_patch,
// view_image,plan}_spec.rs), Copyright 2025 OpenAI, licensed under the
// Apache License 2.0. Modified for dify-sf: `exec_command` without `shell`,
// `environment_id` and the approval parameters (danger-full-access with
// approval `never`); `apply_patch` also as a function tool for the plugin
// wire. See third_party/codex/PATCHES.md.

/// The tool definitions of the `codex` style.
library;

import '../../ask_human.dart';
import '../../report_progress.dart';
import 'vendored.g.dart';

const execCommandToolName = 'exec_command';
const writeStdinToolName = 'write_stdin';
const applyPatchToolName = 'apply_patch';
const codexViewImageToolName = 'view_image';
const updatePlanToolName = 'update_plan';

/// Tools that may run concurrently with each other (Codex's
/// `supports_parallel_tool_calls` handlers); every other tool runs alone.
const parallelSafeTools = {
  execCommandToolName,
  writeStdinToolName,
  codexViewImageToolName,
};

/// One tool: a function (JSON Schema parameters) or a freeform tool (Lark
/// grammar), as in Codex's `ToolSpec`.
class CodexToolSpec {
  const CodexToolSpec.function(this.name, this.description, this.parameters)
    : grammar = null;
  const CodexToolSpec.freeform(this.name, this.description, this.grammar)
    : parameters = null;

  final String name;
  final String description;
  final Map<String, Object?>? parameters;

  /// The Lark grammar of a freeform tool.
  final String? grammar;

  bool get isFreeform => grammar != null;

  /// The Responses API tool (`ToolSpec` serialization).
  Map<String, Object?> toResponsesJson() => isFreeform
      ? {
          'type': 'custom',
          'name': name,
          'description': description,
          'format': {
            'type': 'grammar',
            'syntax': 'lark',
            'definition': grammar,
          },
        }
      : {
          'type': 'function',
          'name': name,
          'description': description,
          'strict': false,
          'parameters': parameters,
        };
}

Map<String, Object?> _string(String description) => {
  'type': 'string',
  'description': description,
};

Map<String, Object?> _number(String description) => {
  'type': 'number',
  'description': description,
};

Map<String, Object?> _boolean(String description) => {
  'type': 'boolean',
  'description': description,
};

Map<String, Object?> _object(
  Map<String, Map<String, Object?>> properties,
  List<String> required,
) => {
  'type': 'object',
  'properties': {
    for (final k in properties.keys.toList()..sort()) k: properties[k],
  },
  'required': required,
  'additionalProperties': false,
};

final execCommandTool = CodexToolSpec.function(
  execCommandToolName,
  'Runs a command in a PTY, returning output or a session ID for ongoing '
  'interaction.',
  _object(
    {
      'cmd': _string('Shell command to execute.'),
      'workdir': _string(
        'Working directory for the command. Defaults to the turn cwd.',
      ),
      'tty': _boolean(
        'True allocates a PTY for the command; false or omitted uses plain '
        'pipes.',
      ),
      'yield_time_ms': _number(
        'Wait before yielding output. Defaults to 10000 ms; effective range is '
        '250-30000 ms.',
      ),
      'max_output_tokens': _number(
        'Output token budget. Defaults to 10000 tokens; larger requests may be '
        'capped by policy.',
      ),
      'login': _boolean(
        'True runs the shell with -l/-i semantics; false disables them. '
        'Defaults to true.',
      ),
    },
    ['cmd'],
  ),
);

final writeStdinTool = CodexToolSpec.function(
  writeStdinToolName,
  'Writes characters to an existing unified exec session and returns recent '
  'output.',
  _object(
    {
      'session_id': _number('Identifier of the running unified exec session.'),
      'chars': _string(
        'Bytes to write to stdin. Defaults to empty, which polls without '
        'writing.',
      ),
      'yield_time_ms': _number(
        'Wait before yielding output. Non-empty writes default to 250 ms and cap '
        'at 30000 ms; empty polls wait 5000-300000 ms by default.',
      ),
      'max_output_tokens': _number(
        'Output token budget. Defaults to 10000 tokens; larger requests may be '
        'capped by policy.',
      ),
    },
    ['session_id'],
  ),
);

const applyPatchFreeformDescription =
    'The `apply_patch` tool can be used to edit files. This is a FREEFORM '
    'tool, so do not wrap the patch in JSON.';

/// `create_apply_patch_freeform_tool` (the Responses wire).
const applyPatchFreeformTool = CodexToolSpec.freeform(
  applyPatchToolName,
  applyPatchFreeformDescription,
  codexApplyPatchLark,
);

/// The plugin wire has function tools only (Dify's `PromptMessageTool`):
/// the patch is the `input` string and the grammar is in the description.
final applyPatchFunctionTool = CodexToolSpec.function(
  applyPatchToolName,
  'The `apply_patch` tool can be used to edit files. Pass the whole patch as '
  'the `input` string. The patch follows this Lark grammar:\n\n'
  '$codexApplyPatchLark',
  _object(
    {'input': _string('The entire contents of the apply_patch command')},
    ['input'],
  ),
);

/// `create_view_image_tool`: `detail` only for models that may request
/// original detail.
CodexToolSpec viewImageTool({required bool originalDetail}) =>
    CodexToolSpec.function(
      codexViewImageToolName,
      'View a local image file from the filesystem when visual inspection is '
      'needed. Use this for images already available on disk.',
      _object(
        {
          'path': _string('Local filesystem path to an image file.'),
          if (originalDetail)
            'detail': {
              'type': 'string',
              'description':
                  'Image detail level. Defaults to `high`; use `original` to '
                  'preserve exact resolution.',
              'enum': ['high', 'original'],
            },
        },
        ['path'],
      ),
    );

final updatePlanTool = CodexToolSpec.function(
  updatePlanToolName,
  'Updates the task plan.\nProvide an optional explanation and a list of plan '
  'items, each with a step and status.\nAt most one step can be '
  'in_progress at a time.\n',
  _object(
    {
      'explanation': _string('Optional explanation for this plan update.'),
      'plan': {
        'type': 'array',
        'description': 'The list of steps',
        'items': _object(
          {
            'step': _string('Task step text.'),
            'status': {
              'type': 'string',
              'description': 'Step status.',
              'enum': ['pending', 'in_progress', 'completed'],
            },
          },
          ['step', 'status'],
        ),
      },
    },
    ['plan'],
  ),
);

/// dify-sf's own tools keep their dify definitions.
final askHumanCodexTool = CodexToolSpec.function(
  askHumanToolName,
  askHumanDescription,
  askHumanInputSchema,
);

const reportProgressCodexTool = CodexToolSpec.function(
  reportProgressToolName,
  reportProgressDescription,
  reportProgressInputSchema,
);

/// The tools of a `codex` run, in Codex's order (shell tools first).
List<CodexToolSpec> codexTools({
  required bool shell,
  required bool viewImage,
  required bool updatePlan,
  required bool askHuman,
  required bool reportProgress,
  required bool freeform,
  required bool originalImageDetail,
}) => [
  if (shell) ...[execCommandTool, writeStdinTool],
  if (updatePlan) updatePlanTool,
  if (shell) freeform ? applyPatchFreeformTool : applyPatchFunctionTool,
  if (viewImage) viewImageTool(originalDetail: originalImageDetail),
  if (askHuman) askHumanCodexTool,
  if (reportProgress) reportProgressCodexTool,
];
