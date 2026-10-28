/// Workflow-owned model overrides. The inline agent still owns the fixed provider and model defaults.
List<String>? agentModelInputSelector(Object? value) {
  if (value is! String || !value.startsWith('{{#') || !value.endsWith('#}}'))
    return null;
  final inner = value.substring(3, value.length - 3);
  if (RegExp(r'[#{}\s]').hasMatch(inner)) return null;
  final parts = inner.split('.');
  return parts.length >= 2 && parts.every((p) => p.isNotEmpty) ? parts : null;
}

bool validAgentModelInputs(Object? value) {
  if (value == null) return true;
  if (value is! Map ||
      value.keys.any((k) => !const {'model', 'reasoning_effort'}.contains(k)))
    return false;
  return value.values.every(
    (v) => v is String && v.length <= 255 && agentModelInputSelector(v) != null,
  );
}

List<List<String>> agentModelInputSelectors(Object? value) => value is Map
    ? [
        for (final v in value.values)
          if (agentModelInputSelector(v) case final selector?) selector,
      ]
    : const [];
