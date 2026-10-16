import 'package:collab_client/collab_client.dart';

/// Names of the output variables a node offers to other nodes' references: the `name` of every item in its
/// keyed `outputs` / `variables` lists, plus the fixed output of some node types.
List<String> outputNames(Node n) {
  final names = <String>[];
  for (final key in const ['variables', 'outputs']) {
    final v = n.config[key];
    if (v is! VItems) continue;
    for (final item in v.items) {
      final value = item.value;
      final name = value is VMap ? value.entries['name'] : value;
      if (name is VString && name.value.isNotEmpty && !names.contains(name.value)) names.add(name.value);
    }
  }
  if (n.type == 'llm' && !names.contains('text')) names.add('text');
  return names;
}

/// The display name for a client id: the part before the random suffix, capitalised
/// (`bo-3fa2c1` -> `Bo`). Ids that do not follow the convention are shown as they are.
String clientDisplayName(String clientId) {
  final m = RegExp(r'^(.+?)[-_.:][0-9a-f]{4,}$').firstMatch(clientId);
  final base = m?.group(1) ?? clientId;
  if (base.isEmpty) return clientId;
  return base[0].toUpperCase() + base.substring(1);
}

/// A label for a register, as the user thinks of it: `title`, `prompt`, `model.name`, `outputs`.
String fieldLabel(FieldKey? key) => switch (key) {
      null => 'this node',
      TitleKey() => 'title',
      ConfigKey(:final path) => path.join('.'),
      ItemKey(:final path) => path.join('.'),
    };

/// Short single-line preview of a value for notices and chips.
String previewValue(Value v, {int max = 60}) {
  final text = switch (v) {
    VString(:final value) => '"$value"',
    VRef(:final ref) => '{{${ref.node}.${ref.output}}}',
    VBroken(:final ref) => '(broken ${ref.node}.${ref.output})',
    _ => '${v.toJson()}',
  }
      .replaceAll('\n', ' ');
  return text.length <= max ? text : '${text.substring(0, max - 1)}…';
}

/// How long ago, for notices.
String ago(DateTime at, [DateTime? now]) {
  final s = (now ?? DateTime.now()).difference(at).inSeconds;
  if (s < 45) return 'just now';
  final m = (s / 60).round();
  return m <= 1 ? '1 min ago' : '$m min ago';
}
