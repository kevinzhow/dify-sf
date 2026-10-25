/// The shell tools `shell_run`, `shell_wait`, `shell_input` and
/// `shell_interrupt`, mirroring Dify 1.17.1's shell layer
/// (`dify_agent/layers/shell/layer.py` and `output_text.py`): the same
/// arguments, defaults, prompt, error texts and output shaping.
library;

import 'dart:convert';

import 'shellctl.dart';

const shellRunToolName = 'shell_run';
const shellWaitToolName = 'shell_wait';
const shellInputToolName = 'shell_input';
const shellInterruptToolName = 'shell_interrupt';

const shellToolNames = [
  shellRunToolName,
  shellWaitToolName,
  shellInputToolName,
  shellInterruptToolName,
];

/// Dify's defaults.
const defaultShellTimeoutSeconds = 30.0;
const defaultTerminateGraceSeconds = 10.0;

/// shellctl's hard bound on a shell tool wait.
const shellToolHardTimeoutSeconds = 300.0;

/// Head and tail of the output shown to the model.
const shellOutputPromptEdgeBytes = 4 * 1024;

/// The size named in the truncation marker (`2 * edge`, as in Dify).
const shellOutputMarkerLimitBytes = 2 * shellOutputPromptEdgeBytes;

/// Tool definitions (pydantic-ai schemas of Dify's tool functions).
final Map<String, ({String description, Map<String, Object?> parameters})>
shellToolDefinitions = {
  shellRunToolName: (
    description: 'Start a shell job in the current workspace and return its output and status.',
    parameters: _object(
      {
        'script': {'type': 'string'},
        'timeout': {'default': defaultShellTimeoutSeconds, 'type': 'number'},
      },
      ['script'],
    ),
  ),
  shellWaitToolName: (
    description:
        'Wait for more output or completion from an existing shell job.',
    parameters: _object(
      {
        'job_id': {'type': 'string'},
        'timeout': {'default': defaultShellTimeoutSeconds, 'type': 'number'},
      },
      ['job_id'],
    ),
  ),
  shellInputToolName: (
    description:
        'Send text to a running shell job and wait for its next output.',
    parameters: _object(
      {
        'job_id': {'type': 'string'},
        'text': {'type': 'string'},
        'timeout': {'default': defaultShellTimeoutSeconds, 'type': 'number'},
      },
      ['job_id', 'text'],
    ),
  ),
  shellInterruptToolName: (
    description: 'Interrupt a running shell job and return its final status.',
    parameters: _object(
      {
        'job_id': {'type': 'string'},
        'grace_seconds': {
          'default': defaultTerminateGraceSeconds,
          'type': 'number',
        },
      },
      ['job_id'],
    ),
  ),
};

Map<String, Object?> _object(
  Map<String, Object?> properties,
  List<String> required,
) => {
  'additionalProperties': false,
  'properties': properties,
  'required': required,
  'type': 'object',
};

/// Dify's shell prompt (prefix and the default working-location text), less
/// the paragraph about the `dify-agent` CLI, which dify-sf does not install.
const shellPrefixPrompt =
    '''You can run commands in an isolated shell workspace.

Available shell tools:

1. shell_run
   Starts a new shell job in the current workspace.
   Use it to run commands or scripts.

2. shell_wait
   Waits for more output or completion from an existing shell job.
   Use it when shell_run returns done=false.

3. shell_input
   Sends stdin text to a running shell job, then waits for new output.
   Use it only when an interactive command is waiting for input.

4. shell_interrupt
   Interrupts a running shell job.
   Use it to stop a long-running, stuck, or no-longer-needed command.

Common arguments:

- script:
  Command or script to execute. Used by shell_run.

- job_id:
  Shell job id returned by shell_run.
  Use it with shell_wait, shell_input, and shell_interrupt.
  Never invent a job_id.

- timeout:
  Maximum time in seconds to wait for output or completion for this tool call.
  A timeout does not necessarily mean the job has stopped; if done=false, use shell_wait again.

- text:
  Text to send to the running process stdin. Used by shell_input.
  Include "\\n" if the process expects Enter.

- grace_seconds:
  Time to wait after interrupting before forceful cleanup. Used by shell_interrupt.

Usage rules:

- Start with shell_run.
- If shell_run returns done=false, call shell_wait with the returned job_id.
- Use shell_input only when the job is running and waiting for stdin.
- Use shell_interrupt when a job is stuck or should be stopped.

Filesystem spaces:

- `\$HOME` is the system space for reusable tools and state.
- The current working directory (`cwd`) is the active Workspace and temporary working space.
- Relative paths and the standard temp environment variables (`TMPDIR`, `TMP`, and `TEMP`) resolve directly to `cwd`.
- Do not use `/tmp`.

shell_run script rules:

- The script argument can be a normal shell script or a shebang script.
- If the first line is a shebang, the shell executes the script directly.

Tips:

- Python 3.12, uv, pip, Node.js, pnpm, and pnx are preinstalled in the local sandbox.
- For one-off Python dependencies, prefer a uv script with a PEP 723 dependency header or:
  `uv run --with <package> python <script-or--c>`.
- For reusable Python CLI tools, use `uv tool install <tool>`; installed commands land in `\$HOME/.local/bin`.
  Run them by full path or add `\$HOME/.local/bin` to PATH in the command that needs them.
- `python3 -m pip install --user <package>` also installs into `\$HOME/.local`; add `\$HOME/.local/bin` to PATH
  when you need console scripts.
- For reusable Node.js CLIs, use user-level global installs:
  `PNPM_HOME=\$HOME/.local/share/pnpm PATH=\$HOME/.local/share/pnpm/bin:\$PATH pnpm add -g <package>`.
  Installed commands land in `\$PNPM_HOME/bin`; run them by full path or with the same PATH prefix.
- For one-off Node.js CLIs, prefer `pnx <command> [args]`.
- Do not install new packages into system or image tool paths such as `/usr/local`, `/usr`, or `/opt/dify-agent-tools`.
- If you need MCP, install the MCP server in the shell environment and start that server when you use it.

Example shell_run script:

[begin script]
#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.12"
# dependencies = [
#   "httpx==0.28.1",
#   "rich>=13.8.0",
# ]
# ///

import httpx
from rich import print

response = httpx.get("https://example.com", timeout=10)
print(f"[green]status:[/green] {response.status_code}")
[end script]

Working location:

- Prefer `cwd` for your work.
- Changes in `\$HOME` or `cwd` do not update the saved Agent state.''';

const shellSuffixPrompt =
    '''Environment variables may contain API keys, tokens, or credentials.
You may refer to environment variable names when needed.''';

// ---- output text (output_text.py) -------------------------------------------

/// The longest UTF-8-safe prefix of [text] within [maxBytes].
String utf8Prefix(String text, int maxBytes) {
  if (maxBytes <= 0) return '';
  final bytes = utf8.encode(text);
  if (bytes.length <= maxBytes) return text;
  var end = maxBytes;
  while (end > 0 && (bytes[end] & 0xC0) == 0x80) {
    end--;
  }
  return utf8.decode(bytes.sublist(0, end));
}

/// The longest UTF-8-safe suffix of [text] within [maxBytes].
String utf8Suffix(String text, int maxBytes) {
  if (maxBytes <= 0) return '';
  final bytes = utf8.encode(text);
  if (bytes.length <= maxBytes) return text;
  var start = bytes.length - maxBytes;
  while (start < bytes.length && (bytes[start] & 0xC0) == 0x80) {
    start++;
  }
  return utf8.decode(bytes.sublist(start));
}

/// Bounded output with an optional truncation marker and log path.
String normalizedOutputText(
  String head, {
  required String? tail,
  required String? outputPath,
  required int maxOutputSizeBytes,
  bool? truncatedInMiddle,
}) {
  final truncated = truncatedInMiddle ?? (tail != null && tail != head);
  if (!truncated) return head;
  return [
    head,
    '... (truncated in middle because the max output size is limited to '
        '$maxOutputSizeBytes bytes) ...',
    ?tail,
    if (outputPath != null && outputPath.isNotEmpty)
      '(check the $outputPath for full output)',
  ].join('\n');
}

/// `render_prompt_observation_from_result`: head and tail of the output; a
/// truncated window fetches the tail from shellctl.
Future<({String text, String? outputPath, int offset})> renderObservation(
  ShellctlClient client,
  JobResult result, {
  int edgeBytes = shellOutputPromptEdgeBytes,
  void Function(String)? log,
}) async {
  final exceeds = utf8.encode(result.output).length > edgeBytes;
  String? tail;
  var outputPath = result.outputPath;
  var offset = result.offset;
  if (result.truncated) {
    try {
      final t = await client.tail(result.jobId);
      tail = utf8Suffix(t.output, edgeBytes);
      outputPath = t.outputPath ?? outputPath;
      offset = t.offset;
    } on ShellctlException catch (e) {
      log?.call('failed to fetch tail for shell job ${result.jobId}: $e');
    }
  } else if (exceeds) {
    tail = utf8Suffix(result.output, edgeBytes);
  }
  final text = normalizedOutputText(
    utf8Prefix(result.output, edgeBytes),
    tail: tail,
    outputPath: result.truncated || exceeds ? outputPath : null,
    maxOutputSizeBytes: shellOutputMarkerLimitBytes,
    truncatedInMiddle: result.truncated || exceeds,
  );
  return (text: text, outputPath: outputPath, offset: offset);
}

/// `<metadata>{compact json}</metadata>` and `<output>…</output>`.
String taggedShellObservation({
  required String jobId,
  required String status,
  required bool done,
  required int? exitCode,
  required String? outputPath,
  required String output,
}) {
  final metadata = jsonEncode({
    'job_id': jobId,
    'status': status,
    'done': done,
    'exit_code': exitCode,
    'output_path': ?outputPath,
  });
  return '<metadata>\n$metadata\n</metadata>\n\n<output>\n$output\n</output>';
}

/// A tool error observation (`{"error", "job_id"?}`).
Map<String, Object?> shellToolError(String message, {String? jobId}) => {
  'error': message,
  'job_id': ?jobId,
};
