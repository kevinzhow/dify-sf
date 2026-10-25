/// Workspace path rules shared by the protocol and the sandbox.
library;

/// `'…'` shell quoting.
String shellQuote(String value) => "'${value.replaceAll("'", r"'\''")}'";

/// Normalizes a workspace-relative path (an absolute path under the
/// workspace is accepted); throws [FormatException] for anything that could
/// leave the workspace.
String normalizeWorkspacePath(String path, {String workspace = '/workspace'}) {
  var p = path.trim();
  if (p.isEmpty) throw const FormatException('the path is empty');
  if (p.contains('\u0000') || p.contains('\n') || p.contains('\r')) {
    throw const FormatException('the path contains control characters');
  }
  if (p == workspace) throw const FormatException('the path is the workspace');
  if (p.startsWith('$workspace/')) p = p.substring(workspace.length + 1);
  if (p.startsWith('/') || p.startsWith('~')) {
    throw FormatException('$path is outside the workspace');
  }
  final parts = <String>[];
  for (final s in p.split('/')) {
    if (s.isEmpty || s == '.') continue;
    if (s == '..') throw FormatException('$path leaves the workspace');
    parts.add(s);
  }
  if (parts.isEmpty) throw FormatException('$path names no file');
  return parts.join('/');
}
