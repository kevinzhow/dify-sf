/// Checkpoint hand-in (docs/agent-v2.md, "Checkpoint hand-in"): an agent can
/// keep its last complete work as the arguments of `final_output` in a file of
/// the workspace; when the run fails after real work, the service hands that
/// in instead of losing the round. Official Codex runtime only.
library;

/// The directory an operation without a continuation clears before anything
/// runs, relative to the workspace: a kept workspace's checkpoint belongs to
/// the round that wrote it.
const checkpointDir = '.dify-sf/checkpoint';

/// The checkpoint: a JSON object like the arguments of `final_output`. The
/// writer replaces it atomically, after the files it names are in place.
const checkpointFile = '$checkpointDir/final_output.json';

/// The largest checkpoint file read.
const checkpointMaxBytes = 4 * 1024 * 1024;

/// The top-level string output the service fills on a hand-in. A schema that
/// declares it (optional) lets the workflow see that the result is incomplete;
/// the model never sees it and cannot set it.
const partialHandinOutput = 'partial_handin';

/// Failures a checkpoint may replace. A cancel, a lost lease, a shutdown and
/// a failed session restore or file upload stay what they are.
const checkpointErrorTypes = {
  'model_error',
  'model_quota',
  'max_turns',
  'timeout',
  'sandbox_error',
  'internal',
};

/// Seconds before `timeout_seconds` at which a run with a checkpoint stops and
/// hands it in: the gateway refuses uploads once the operation's time is over.
int checkpointReserveSeconds(int timeoutSeconds) =>
    checkpointReserveForTests ?? (timeoutSeconds ~/ 10).clamp(1, 120);

/// Replaces the reserve in tests.
int? checkpointReserveForTests;

/// The value of [partialHandinOutput]: public text, never Codex's or the
/// gateway's raw message.
String partialHandinNote(String errorType, int calls) {
  final what = switch (errorType) {
    'model_error' => 'the model connection failed',
    'model_quota' => 'a model quota or billing limit was reached',
    'max_turns' => 'the model call limit was reached',
    'timeout' => 'the time limit was reached',
    _ => 'the agent runtime ended mid-round',
  };
  return '$errorType: $what at about model call $calls; this is the last '
      'checkpoint, not a finished hand-in';
}
