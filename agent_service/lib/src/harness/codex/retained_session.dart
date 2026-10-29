/// The sandbox side of a Codex session retained across rounds
/// (docs/agent-v2.md, "Codex session retained across rounds"): the root
/// thread's rollout is copied into the kept workspace after a `succeeded`
/// round and back into the next round's fresh CODEX_HOME. Both copies are
/// shell commands in the sandbox; agent_service only reads the sizes and
/// SHA-256 sums they print (and the rollout's first line on a resume).
library;

import 'dart:convert';

import '../../sandbox/paths.dart' show shellQuote;

/// The largest rollout kept for the next round (128 MiB).
const codexSessionMaxBytes = 128 * 1024 * 1024;

/// Where the rollout copy lives, relative to the workspace.
const retainedRolloutDir = '.dify-sf/codex';

/// The most of the rollout's first line (`session_meta`) read on a resume.
const sessionMetaMaxBytes = 4 * 1024 * 1024;

/// Codex's thread IDs (UUIDs); nothing else is put into a path or pattern.
final codexThreadIdPattern = RegExp(r'^[0-9A-Za-z][0-9A-Za-z_-]{0,127}$');

/// A rollout path relative to CODEX_HOME as Codex writes it
/// (`sessions/YYYY/MM/DD/rollout-<time>-<thread_id>.jsonl`).
bool isRolloutPath(String path, String threadId) =>
    path.startsWith('sessions/') &&
    path.endsWith('-$threadId.jsonl') &&
    !path.split('/').any((s) => s.isEmpty || s == '.' || s == '..') &&
    !path.contains('\n');

/// The workspace path of [threadId]'s rollout copy.
String retainedRolloutFile(String workspaceDir, String threadId) =>
    '$workspaceDir/$retainedRolloutDir/$threadId.jsonl';

/// After a `succeeded` round: finds the root thread's rollout under [home]
/// (CODEX_HOME), refuses one over [maxBytes] and copies it to
/// `<workspace>/.dify-sf/codex/<thread_id>.jsonl` (through a part file),
/// then prints `rollout=`, `size=` and `sha256=` of the copy. Problems are
/// one `error=` line (exit status 0).
String rolloutSaveScript({
  required String home,
  required String workspaceDir,
  required String threadId,
  int maxBytes = codexSessionMaxBytes,
}) {
  final dir = '$workspaceDir/$retainedRolloutDir';
  final dst = retainedRolloutFile(workspaceDir, threadId);
  return '''
set -u
found=\$(find ${shellQuote('$home/sessions')} -type f -name ${shellQuote('rollout-*-$threadId.jsonl')} -printf '%P\\n' 2>/dev/null)
n=\$(printf '%s' "\$found" | grep -c '^' || true)
[ "\$n" = 1 ] || { echo "error=\$n rollouts of the thread under CODEX_HOME/sessions"; exit 0; }
src=${shellQuote('$home/sessions')}/"\$found"
size=\$(stat -c %s -- "\$src") || { echo "error=cannot stat the rollout"; exit 0; }
[ "\$size" -le $maxBytes ] || { echo "error=too_large \$size"; exit 0; }
mkdir -p -- ${shellQuote(dir)} || { echo "error=cannot create $retainedRolloutDir"; exit 0; }
real=\$(realpath -e -- ${shellQuote(dir)}) || { echo "error=cannot resolve $retainedRolloutDir"; exit 0; }
case "\$real" in ${shellQuote(workspaceDir)}/*) ;; *) echo "error=$retainedRolloutDir resolves outside the workspace (\$real)"; exit 0;; esac
cp -- "\$src" ${shellQuote('$dst.dify-sf-part')} || { echo "error=cp failed"; exit 0; }
mv -f -- ${shellQuote('$dst.dify-sf-part')} ${shellQuote(dst)} || { echo "error=mv failed"; exit 0; }
echo "rollout=sessions/\$found"
echo "size=\$(stat -c %s -- ${shellQuote(dst)})"
echo "sha256=\$(sha256sum -- ${shellQuote(dst)} | cut -d' ' -f1)"''';
}

/// Before a resume: copies the workspace's rollout copy of [threadId] into
/// the fresh [home] (CODEX_HOME) at [rolloutPath] and prints `size=`,
/// `sha256=` of what Codex will read and `meta=` (base64 of its first line,
/// at most [sessionMetaMaxBytes]). A missing copy prints `missing`; other
/// problems one `error=` line (exit status 0).
String rolloutRestoreScript({
  required String home,
  required String workspaceDir,
  required String threadId,
  required String rolloutPath,
}) {
  final src = retainedRolloutFile(workspaceDir, threadId);
  final dst = '$home/$rolloutPath';
  final dir = dst.substring(0, dst.lastIndexOf('/'));
  return '''
set -u
[ -e ${shellQuote(src)} ] || { echo missing; exit 0; }
real=\$(realpath -e -- ${shellQuote(src)}) || { echo missing; exit 0; }
case "\$real" in ${shellQuote(workspaceDir)}/*) ;; *) echo "error=the rollout copy resolves outside the workspace (\$real)"; exit 0;; esac
[ -f "\$real" ] || { echo "error=the rollout copy is not a regular file"; exit 0; }
mkdir -p -- ${shellQuote(dir)} || { echo "error=cannot create the rollout directory in CODEX_HOME"; exit 0; }
cp -- "\$real" ${shellQuote(dst)} || { echo "error=cp failed"; exit 0; }
echo "size=\$(stat -c %s -- ${shellQuote(dst)})"
echo "sha256=\$(sha256sum -- ${shellQuote(dst)} | cut -d' ' -f1)"
echo "meta=\$(head -n 1 -- ${shellQuote(dst)} | head -c $sessionMetaMaxBytes | base64 -w0)"''';
}

/// The `key=value` lines of the scripts above.
Map<String, String> scriptValues(String output) {
  final out = <String, String>{};
  for (final line in const LineSplitter().convert(output)) {
    final eq = line.indexOf('=');
    if (eq > 0) {
      out[line.substring(0, eq)] = line.substring(eq + 1);
    } else if (line.trim().isNotEmpty) {
      out[line.trim()] = '';
    }
  }
  return out;
}

/// The dynamic tool names in a rollout's first line (`session_meta`), or
/// null when it is not one.
List<String>? sessionMetaDynamicTools(String line) {
  try {
    final meta = jsonDecode(line);
    if (meta is! Map || meta['type'] != 'session_meta') return null;
    final payload = meta['payload'];
    if (payload is! Map) return null;
    final tools = payload['dynamic_tools'];
    if (tools == null) return const [];
    if (tools is! List) return null;
    return [
      for (final t in tools)
        if (t is Map && t['name'] is String) t['name'] as String,
    ];
  } on FormatException {
    return null;
  }
}
