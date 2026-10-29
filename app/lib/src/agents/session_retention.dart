/// Retention is scoped by the server to the workflow run and node, never a user path.
bool validAgentSessionRetention(Object? value) =>
    value == null ||
    (value is Map &&
        value.keys.every((key) => key == 'enabled') &&
        (!value.containsKey('enabled') || value['enabled'] is bool));
