/// Declared outputs as the `final_output` tool, as Dify's agent backend does
/// (`dify_agent/layers/output/output_layer.py`: a pydantic-ai `ToolOutput`).
library;

const finalOutputToolName = 'final_output';

/// pydantic-ai's description of an output tool whose schema has none.
const defaultFinalOutputDescription =
    'The final response which ends this conversation';

/// pydantic-ai's tool-return texts for the calls of the turn that ended the
/// run (`end_strategy='early'`).
const finalResultProcessed = 'Final result processed.';
const outputToolNotUsed =
    'Output tool not used - a final result was already processed.';
const toolNotExecuted =
    'Tool not executed - a final result was already processed.';

const _defsPrefix = '#/\$defs/';
const _valueKeywords = {'const', 'default', 'enum', 'example', 'examples'};

/// Checks a declared-output schema as Dify does: an object schema whose
/// `$ref`s are local `#/$defs/...` references. Throws [FormatException].
void checkOutputSchema(Map<String, Object?> schema) {
  if (schema['type'] != 'object') {
    throw const FormatException('output_schema must declare an object output');
  }
  void walk(Object? node) {
    if (node is Map) {
      node.forEach((k, v) {
        if (k == r'$ref' && v is String) {
          if (!v.startsWith(_defsPrefix)) {
            throw FormatException(
              "only local refs under '#/\$defs/' are supported; got '$v'",
            );
          }
        } else if (!_valueKeywords.contains(k)) {
          walk(v);
        }
      });
    } else if (node is List) {
      node.forEach(walk);
    }
  }

  walk(schema);
  inlineLocalDefs(schema);
}

/// [schema] with local `#/$defs/...` references inlined (recursive references
/// are rejected), as `_inline_local_defs_refs` does.
Map<String, Object?> inlineLocalDefs(Map<String, Object?> schema) {
  final defs = schema[r'$defs'];
  Object? resolve(Object? node, List<String> stack) {
    if (node is Map) {
      final ref = node[r'$ref'];
      final out = <String, Object?>{};
      if (ref is String && defs is Map) {
        final name = ref.substring(_defsPrefix.length);
        if (stack.contains(name)) {
          throw const FormatException(
            'recursive \$defs refs are not supported for structured output',
          );
        }
        final target = defs[name];
        if (target is! Map) {
          throw FormatException("local \$ref '$ref' could not be resolved");
        }
        out.addAll(
          (resolve(target, [...stack, name]) as Map).cast<String, Object?>(),
        );
      }
      node.forEach((k, v) {
        if (k == r'$ref' || k == r'$defs') return;
        out[k as String] = _valueKeywords.contains(k) ? v : resolve(v, stack);
      });
      return out;
    }
    if (node is List) return [for (final v in node) resolve(v, stack)];
    return node;
  }

  return (resolve(schema, const []) as Map).cast<String, Object?>();
}

/// The `final_output` tool definition: the inlined schema titled
/// `final_output`; its `description` becomes the tool description.
({String description, Map<String, Object?> parameters}) finalOutputTool(
  Map<String, Object?> schema,
) {
  final parameters = inlineLocalDefs(schema);
  final description = parameters.remove('description');
  parameters['title'] = finalOutputToolName;
  return (
    description: description is String && description.trim().isNotEmpty
        ? description
        : defaultFinalOutputDescription,
    parameters: parameters,
  );
}
