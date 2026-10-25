/// The `ask_human` tool: Dify's argument schema and default guardrails
/// (`dify_agent/layers/ask_human`), returning a Genkit interrupt.
library;

const askHumanToolName = 'ask_human';

const askHumanDescription =
    'Ask a human for missing information or a decision that is required to '
    'continue. Use this only when the answer cannot be inferred from the '
    'conversation, available tools, or current context. Provide concise '
    'instructions, structured fields, and clear actions for the human.';

/// Dify's default `DifyAskHumanLayerConfig`.
class AskHumanLimits {
  const AskHumanLimits();

  final int maxFields = 8;
  final int maxActions = 4;
  final List<String> allowedFieldTypes = const ['paragraph', 'select'];
  final bool allowFileFields = false;
  final int maxMarkdownChars = 8000;
  final int maxQuestionChars = 1000;
  final int maxFieldLabelChars = 120;
  final int maxActionLabelChars = 80;
}

const askHumanLimits = AskHumanLimits();

/// Dify's `build_prompt_hint` for the default limits.
String askHumanPromptHint([AskHumanLimits l = askHumanLimits]) {
  final types = l.allowedFieldTypes.isEmpty
      ? 'none'
      : l.allowedFieldTypes.join(', ');
  final fieldCount = l.maxFields == 0
      ? 'Do not add any fields.'
      : 'Use at most ${l.maxFields} field(s).';
  return "You may call the external tool '$askHumanToolName' only when human "
      'input is required to continue. Do not ask a human for information that '
      'can be inferred from the conversation, current context, or other '
      'tools.\n\n'
      'Ask-human guardrails:\n'
      '- Allowed field types: $types.\n'
      '- File upload fields are ${l.allowFileFields ? 'enabled' : 'disabled'}.\n'
      '- $fieldCount\n'
      '- Use at most ${l.maxActions} action(s).\n'
      "- Keep 'question' under ${l.maxQuestionChars} characters.\n"
      "- Keep 'markdown' under ${l.maxMarkdownChars} characters.\n"
      '- Keep each field label under ${l.maxFieldLabelChars} characters.\n'
      '- Keep each action label under ${l.maxActionLabelChars} characters.\n'
      '- If you omit actions, the system will add one primary action: Submit.\n'
      'Prefer concise, structured requests that stay comfortably within these '
      'limits.';
}

Map<String, Object?> _nullableString() => {
  'anyOf': [
    {'type': 'string'},
    {'type': 'null'},
  ],
  'default': null,
};

Map<String, Object?> _fieldBase(String type, Map<String, Object?> extra) => {
  'type': 'object',
  'additionalProperties': false,
  'properties': {
    'name': {'type': 'string', 'minLength': 1},
    'label': {'type': 'string', 'minLength': 1},
    'required': {'type': 'boolean', 'default': false},
    'type': {'const': type, 'type': 'string', 'default': type},
    ...extra,
  },
  'required': ['name', 'label'],
};

/// `AskHumanToolArgs.model_json_schema()`, inlined (no `$defs`).
final Map<String, Object?> askHumanInputSchema = {
  'type': 'object',
  'additionalProperties': false,
  'properties': {
    'title': _nullableString(),
    'question': {'type': 'string', 'minLength': 1},
    'markdown': _nullableString(),
    'fields': {
      'type': 'array',
      'default': <Object?>[],
      'items': {
        'oneOf': [
          _fieldBase('paragraph', {
            'placeholder': _nullableString(),
            'default': _nullableString(),
          }),
          _fieldBase('select', {
            'options': {
              'type': 'array',
              'items': {
                'type': 'object',
                'additionalProperties': false,
                'properties': {
                  'value': {'type': 'string', 'minLength': 1},
                  'label': {'type': 'string', 'minLength': 1},
                },
                'required': ['value', 'label'],
              },
            },
            'default': _nullableString(),
          }),
          _fieldBase('file', {}),
          _fieldBase('file-list', {
            'max_files': {
              'anyOf': [
                {'type': 'integer', 'minimum': 1},
                {'type': 'null'},
              ],
              'default': null,
            },
          }),
        ],
      },
    },
    'actions': {
      'type': 'array',
      'default': <Object?>[],
      'items': {
        'type': 'object',
        'additionalProperties': false,
        'properties': {
          'id': {'type': 'string', 'minLength': 1},
          'label': {'type': 'string', 'minLength': 1},
          'style': {
            'enum': ['default', 'primary', 'destructive'],
            'type': 'string',
            'default': 'default',
          },
        },
        'required': ['id', 'label'],
      },
    },
    'urgency': {
      'enum': ['normal', 'high'],
      'type': 'string',
      'default': 'normal',
    },
  },
  'required': ['question'],
};

final _identifier = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

/// Validates and normalizes ask_human arguments as Dify does (schema rules,
/// then the layer's limits; a missing action list becomes one primary
/// Submit action). Throws [FormatException] with Dify-style messages.
Map<String, Object?> normalizeAskHumanArgs(
  Object? raw, [
  AskHumanLimits l = askHumanLimits,
]) {
  if (raw is! Map) {
    throw const FormatException('ask_human arguments must be a JSON object');
  }
  final args = raw.cast<String, Object?>();
  const allowedKeys = {
    'title',
    'question',
    'markdown',
    'fields',
    'actions',
    'urgency',
  };
  _noExtra(args, allowedKeys, 'arguments');

  String? optString(Map<String, Object?> o, String key, String label) {
    final v = o[key];
    if (v == null) return null;
    if (v is! String) throw FormatException('$label must be a string');
    return v;
  }

  String reqString(Map<String, Object?> o, String key, String label) {
    final v = o[key];
    if (v is! String || v.isEmpty) {
      throw FormatException('$label must be a non-empty string');
    }
    if (v.trim().isEmpty) throw FormatException('$label must not be blank');
    return v;
  }

  final title = optString(args, 'title', 'title');
  if (title != null && title.trim().isEmpty) {
    throw const FormatException('title must not be blank');
  }
  final question = reqString(args, 'question', 'question');
  final markdown = optString(args, 'markdown', 'markdown');
  final urgency = args['urgency'] ?? 'normal';
  if (urgency != 'normal' && urgency != 'high') {
    throw const FormatException("urgency must be 'normal' or 'high'");
  }

  final fields = <Map<String, Object?>>[];
  final rawFields = args['fields'] ?? const <Object?>[];
  if (rawFields is! List) throw const FormatException('fields must be a list');
  final fieldNames = <String>{};
  for (final rf in rawFields) {
    if (rf is! Map) throw const FormatException('each field must be an object');
    final f = rf.cast<String, Object?>();
    final type = f['type'] ?? 'paragraph';
    final name = reqString(f, 'name', 'field name');
    if (!_identifier.hasMatch(name)) {
      throw const FormatException('field name must be a valid identifier');
    }
    final label = reqString(f, 'label', 'field label');
    final required = f['required'] ?? false;
    if (required is! bool) {
      throw const FormatException('field required must be a boolean');
    }
    final field = <String, Object?>{
      'name': name,
      'label': label,
      'required': required,
      'type': type,
    };
    switch (type) {
      case 'paragraph':
        _noExtra(f, {
          'name',
          'label',
          'required',
          'type',
          'placeholder',
          'default',
        }, 'paragraph field');
        field['placeholder'] = optString(f, 'placeholder', 'placeholder');
        field['default'] = optString(f, 'default', 'default');
      case 'select':
        _noExtra(f, {
          'name',
          'label',
          'required',
          'type',
          'options',
          'default',
        }, 'select field');
        final rawOptions = f['options'] ?? const <Object?>[];
        if (rawOptions is! List || rawOptions.isEmpty) {
          throw const FormatException(
            'select fields must define at least one option',
          );
        }
        final values = <String>{};
        final options = <Map<String, Object?>>[];
        for (final ro in rawOptions) {
          if (ro is! Map) {
            throw const FormatException('select options must be objects');
          }
          final o = ro.cast<String, Object?>();
          _noExtra(o, {'value', 'label'}, 'select option');
          final value = reqString(o, 'value', 'select option value');
          final optionLabel = reqString(o, 'label', 'select option label');
          if (!values.add(value)) {
            throw FormatException(
              "select field '$name' contains duplicate option value '$value'",
            );
          }
          options.add({'value': value, 'label': optionLabel});
        }
        final def = optString(f, 'default', 'default');
        if (def != null && !values.contains(def)) {
          throw FormatException(
            "select field '$name' default must match one of its option values",
          );
        }
        field['options'] = options;
        field['default'] = def;
      case 'file':
        _noExtra(f, {'name', 'label', 'required', 'type'}, 'file field');
      case 'file-list':
        _noExtra(f, {
          'name',
          'label',
          'required',
          'type',
          'max_files',
        }, 'file-list field');
        final maxFiles = f['max_files'];
        if (maxFiles != null && (maxFiles is! int || maxFiles < 1)) {
          throw const FormatException('max_files must be an integer >= 1');
        }
        field['max_files'] = maxFiles;
      default:
        throw FormatException('unknown field type $type');
    }
    if (!fieldNames.add(name)) {
      throw FormatException("field name '$name' must be unique");
    }
    fields.add(field);
  }

  var actions = <Map<String, Object?>>[];
  final rawActions = args['actions'] ?? const <Object?>[];
  if (rawActions is! List) {
    throw const FormatException('actions must be a list');
  }
  final actionIds = <String>{};
  for (final ra in rawActions) {
    if (ra is! Map) {
      throw const FormatException('each action must be an object');
    }
    final a = ra.cast<String, Object?>();
    _noExtra(a, {'id', 'label', 'style'}, 'action');
    final id = reqString(a, 'id', 'action id');
    if (!_identifier.hasMatch(id)) {
      throw const FormatException('action id must be a valid identifier');
    }
    final label = reqString(a, 'label', 'action label');
    final style = a['style'] ?? 'default';
    if (!const {'default', 'primary', 'destructive'}.contains(style)) {
      throw const FormatException(
        "action style must be 'default', 'primary' or 'destructive'",
      );
    }
    if (!actionIds.add(id)) {
      throw FormatException("action id '$id' must be unique");
    }
    actions.add({'id': id, 'label': label, 'style': style});
  }

  // The layer's guardrails (DifyAskHumanLayer._validate_and_normalize_tool_args).
  if (fields.length > l.maxFields) {
    throw FormatException(
      'ask_human fields must contain at most ${l.maxFields} item(s)',
    );
  }
  if (actions.isEmpty) {
    actions = [
      {'id': 'submit', 'label': 'Submit', 'style': 'primary'},
    ];
  }
  if (actions.length > l.maxActions) {
    throw FormatException(
      'ask_human actions must contain at most ${l.maxActions} item(s)',
    );
  }
  if (question.length > l.maxQuestionChars) {
    throw FormatException(
      'ask_human question must be <= ${l.maxQuestionChars} characters',
    );
  }
  if (markdown != null && markdown.length > l.maxMarkdownChars) {
    throw FormatException(
      'ask_human markdown must be <= ${l.maxMarkdownChars} characters',
    );
  }
  for (final f in fields) {
    if (!l.allowedFieldTypes.contains(f['type'])) {
      throw FormatException(
        "ask_human field type '${f['type']}' is not allowed by this layer config",
      );
    }
    if ((f['label'] as String).length > l.maxFieldLabelChars) {
      throw FormatException(
        "ask_human field label '${f['label']}' must be <= ${l.maxFieldLabelChars} characters",
      );
    }
    if (!l.allowFileFields &&
        (f['type'] == 'file' || f['type'] == 'file-list')) {
      throw const FormatException(
        'ask_human file fields are disabled by this layer config',
      );
    }
  }
  for (final a in actions) {
    if ((a['label'] as String).length > l.maxActionLabelChars) {
      throw FormatException(
        "ask_human action label '${a['label']}' must be <= ${l.maxActionLabelChars} characters",
      );
    }
  }

  return {
    'title': title,
    'question': question,
    'markdown': markdown,
    'fields': fields,
    'actions': actions,
    'urgency': urgency,
  };
}

void _noExtra(Map<String, Object?> o, Set<String> allowed, String where) {
  final extra = o.keys.where((k) => !allowed.contains(k)).toList();
  if (extra.isNotEmpty) {
    throw FormatException('$where: unexpected keys ${extra.join(', ')}');
  }
}
