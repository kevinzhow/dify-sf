/// The Human Input node's data logic, ported from Dify 1.17.1 nodes/human-input (types.ts, utils.ts, default.ts,
/// hooks/use-config.ts, hooks/use-form-content.ts, components/user-action.tsx sanitising, components/
/// variable-in-markdown.tsx) and base/chat/chat/answer/human-input-content/utils.ts, on Dify's plain JSON `data`
/// (see `difyDataOf`). checkValid lives in the checklist's node_validators.dart.
library;

import '../../../../../workflow/dify_json.dart';

typedef Json = Map<String, Object?>;

// ---- types.ts ----------------------------------------------------------------------------------------------------

/// `DeliveryMethodType`.
abstract final class DeliveryMethodType {
  static const webapp = 'webapp', email = 'email', slack = 'slack', teams = 'teams', discord = 'discord';
}

/// `UserActionButtonType`.
abstract final class UserActionButtonType {
  static const primary = 'primary', defaultStyle = 'default', accent = 'accent', ghost = 'ghost';
}

/// The form input types (`InputVarType` values).
abstract final class FormInputType {
  static const paragraph = 'paragraph', select = 'select', singleFile = 'file', multiFiles = 'file-list';
}

/// `defaultValue` (default.ts).
const humanInputDefaultValue = <String, Object?>{
  'delivery_methods': <Object?>[],
  'user_actions': <Object?>[],
  'form_content': '',
  'inputs': <Object?>[],
  'timeout': 3,
  'timeout_unit': 'day',
};

String inputTypeOf(Object? input) => jsStr(jsGet(input, 'type')) ?? '';
String inputNameOf(Object? input) => jsStr(jsGet(input, 'output_variable_name')) ?? '';

bool isParagraphFormInput(Object? input) => inputTypeOf(input) == FormInputType.paragraph;
bool isSelectFormInput(Object? input) => inputTypeOf(input) == FormInputType.select;
bool isFileFormInput(Object? input) => inputTypeOf(input) == FormInputType.singleFile;
bool isFileListFormInput(Object? input) => inputTypeOf(input) == FormInputType.multiFiles;

/// `createDefaultParagraphFormInput`.
Json createDefaultParagraphFormInput([String name = '']) => {
  'type': FormInputType.paragraph,
  'output_variable_name': name,
  'default': {'type': 'constant', 'selector': <Object?>[], 'value': ''},
};

/// `createDefaultFormInputByType`.
Json createDefaultFormInputByType(String type, [String name = '']) => switch (type) {
  FormInputType.select => {
    'type': FormInputType.select,
    'output_variable_name': name,
    'option_source': {'type': 'constant', 'selector': <Object?>[], 'value': <Object?>[]},
  },
  FormInputType.singleFile => {
    'type': FormInputType.singleFile,
    'output_variable_name': name,
    'allowed_file_extensions': <Object?>[],
    'allowed_file_types': ['image'],
    'allowed_file_upload_methods': ['local_file', 'remote_url'],
  },
  FormInputType.multiFiles => {
    'type': FormInputType.multiFiles,
    'output_variable_name': name,
    'allowed_file_extensions': <Object?>[],
    'allowed_file_types': ['image'],
    'allowed_file_upload_methods': ['local_file', 'remote_url'],
    'number_limits': 5,
  },
  _ => createDefaultParagraphFormInput(name),
};

// ---- utils.ts / default.ts -----------------------------------------------------------------------------------------

/// `isOutput`: a selector into the form's own inputs (`$output`).
bool isOutputSelector(List<Object?> selector) => selector.isNotEmpty && selector.first == r'$output';

List<String> _strings(Object? x) => [for (final e in jsList(x)) jsKey(e)];

/// `getHumanInputFormDependencySelectors`: the selectors a paragraph's variable default and a select's variable
/// options read.
List<List<String>> humanInputFormDependencySelectors(List<Object?> inputs) => [
  for (final input in inputs)
    if (isParagraphFormInput(input) &&
        jsGet(jsGet(input, 'default'), 'type') == 'variable' &&
        _strings(jsGet(jsGet(input, 'default'), 'selector')).isNotEmpty)
      _strings(jsGet(jsGet(input, 'default'), 'selector'))
    else if (isSelectFormInput(input) &&
        jsGet(jsGet(input, 'option_source'), 'type') == 'variable' &&
        _strings(jsGet(jsGet(input, 'option_source'), 'selector')).isNotEmpty)
      _strings(jsGet(jsGet(input, 'option_source'), 'selector')),
];

/// `getFormInputVarType` / panel.tsx `getOutputVarType`.
String formInputVarType(Object? input) => switch (inputTypeOf(input)) {
  FormInputType.singleFile => 'file',
  FormInputType.multiFiles => 'array[file]',
  _ => 'string',
};

/// `isTriggerWorkflow` (utils/workflow-entry.ts) over the node types of a workflow.
bool isTriggerWorkflow(Iterable<String> nodeTypes) => nodeTypes.any((t) => t.startsWith('trigger-'));

// ---- use-config.ts / panel.tsx -----------------------------------------------------------------------------------

/// panel.tsx `onAddUseAction`: `action_<n>` / `Button Text <n>` for the n-th action, style default.
Json newUserAction(int existing) => {
  'id': 'action_${existing + 1}',
  'title': 'Button Text ${existing + 1}',
  'button_style': UserActionButtonType.defaultStyle,
};

const actionIdMaxLength = 20;
const actionValueMaxLength = 100;

/// What an edit of an action's ID gives (user-action.tsx `handleIDChange`): the new ID (null: the edit is
/// rejected) and the toast to show (`actionIdFormatTip` / `actionIdTooLong`).
({String? id, String? error}) sanitizeActionId(String value) {
  if (value.trim().isEmpty) return (id: '', error: null);
  final withUnderscores = value.replaceAll(' ', '_');
  var sanitized = [
    for (final (i, c) in withUnderscores.split('').indexed)
      if (i == 0 ? RegExp(r'^[a-z_]$', caseSensitive: false).hasMatch(c) : RegExp(r'^\w$').hasMatch(c)) c,
  ].join();
  if (sanitized != withUnderscores) return (id: null, error: 'actionIdFormatTip');
  String? error;
  if (sanitized.length > actionIdMaxLength) {
    sanitized = sanitized.substring(0, actionIdMaxLength);
    error = 'actionIdTooLong';
  }
  return (id: sanitized.isEmpty ? null : sanitized, error: error);
}

/// `handleTextChange`: the title, cut at 100 characters (with whether it was).
({String title, bool tooLong}) sanitizeActionTitle(String value) => value.length > actionValueMaxLength
    ? (title: value.substring(0, actionValueMaxLength), tooLong: true)
    : (title: value, tooLong: false);

// ---- use-form-content.ts ---------------------------------------------------------------------------------------------

/// The token a form input stands as in `form_content`.
String outputToken(String name) => '{{#\$output.$name#}}';

/// `HITL_INPUT_REG` (config): the form inputs referenced in a text.
final hitlInputRegex = RegExp(r'\{\{(#\$output\.(?:[a-z_]\w{0,29}){1,10}#)\}\}', caseSensitive: false);

/// `handleFormInputItemRename`: [data] with the input [oldName] replaced by [payload] (its token renamed in the
/// content; appended when no input had the name), or null when the new name is taken by another input.
Json? renameFormInput(Json data, Json payload, String oldName) {
  final newName = inputNameOf(payload);
  final inputs = jsList(data['inputs']);
  if (oldName != newName && inputs.any((i) => inputNameOf(i) == newName)) return null;
  var next = [for (final i in inputs) inputNameOf(i) == oldName ? payload : i];
  if (!next.any((i) => inputNameOf(i) == newName)) next = [...next, payload];
  return {
    ...data,
    'form_content': (jsStr(data['form_content']) ?? '').replaceAll(outputToken(oldName), outputToken(newName)),
    'inputs': next,
  };
}

/// `handleFormInputItemRemove`: [data] without the input [name] and its tokens.
Json removeFormInput(Json data, String name) => {
  ...data,
  'form_content': (jsStr(data['form_content']) ?? '').replaceAll(outputToken(name), ''),
  'inputs': [
    for (final i in jsList(data['inputs']))
      if (inputNameOf(i) != name) i,
  ],
};

/// input-field.tsx `variableNameError`: `variableNameInvalid` / `variableNameDuplicated`, or null.
String? formInputNameError(String name, Iterable<String> unavailable) {
  final n = name.trim();
  if (n.isEmpty) return null;
  if (n.contains(' ') || !RegExp(r'^[a-z_]\w{0,29}$').hasMatch(n)) return 'variableNameInvalid';
  if (unavailable.map((e) => e.trim()).where((e) => e.isNotEmpty).contains(n)) return 'variableNameDuplicated';
  return null;
}

// ---- human-input-content/utils.ts ------------------------------------------------------------------------------------

/// `splitByOutputVar`: the content in text and `{{#$output.x#}}` pieces (empty pieces dropped).
List<String> splitByOutputVar(String content) {
  final re = RegExp(r'\{\{#\$output\.[^#]+#\}\}');
  final parts = <String>[];
  var last = 0;
  for (final m in re.allMatches(content)) {
    parts
      ..add(content.substring(last, m.start))
      ..add(m[0]!);
    last = m.end;
  }
  parts.add(content.substring(last));
  return [
    for (final p in parts)
      if (p.isNotEmpty) p,
  ];
}

/// `getFormContentInputNames`.
List<String> formContentInputNames(String content) => [
  for (final m in RegExp(r'\{\{#\$output\.([^#]+)#\}\}').allMatches(content)) m[1]!,
];

/// `getRenderedFormInputs`.
List<Object?> renderedFormInputs(List<Object?> inputs, String content) {
  final names = formContentInputNames(content).toSet();
  return [
    for (final i in inputs)
      if (names.contains(inputNameOf(i))) i,
  ];
}

/// `initializeInputs`: paragraph defaults (the resolved value for a variable default), '' for selects, null for a
/// file, [] for a file list.
Map<String, Object?> initializeInputs(List<Object?> inputs, [Map<String, Object?> defaults = const {}]) => {
  for (final item in inputs)
    if (isParagraphFormInput(item))
      inputNameOf(item): jsGet(jsGet(item, 'default'), 'type') == 'variable' && defaults[inputNameOf(item)] is String
          ? defaults[inputNameOf(item)]
          : jsGet(jsGet(item, 'default'), 'value')
    else if (isSelectFormInput(item))
      inputNameOf(item): ''
    else if (isFileFormInput(item))
      inputNameOf(item): null
    else if (isFileListFormInput(item))
      inputNameOf(item): <Object?>[],
};

/// A file the user picked (FileEntity): uploaded once [uploadedId] or [url] is known.
class HumanInputFile {
  const HumanInputFile({
    required this.transferMethod,
    this.supportFileType = 'document',
    this.uploadedId,
    this.url,
    this.progress = 100,
  });
  final String transferMethod, supportFileType;
  final String? uploadedId, url;
  final int progress;

  /// `fileIsUploaded`.
  bool get isUploaded => (uploadedId != null && uploadedId!.isNotEmpty) || transferMethod == 'remote_url';

  /// `getProcessedFiles`.
  Json toJson() => {
    'type': supportFileType,
    'transfer_method': transferMethod,
    'url': url ?? '',
    'upload_file_id': uploadedId ?? '',
  };
}

/// `hasInvalidSelectOrFileInput`: a select without a value, or a file input without uploaded files.
bool hasInvalidSelectOrFileInput(List<Object?> inputs, Map<String, Object?> values) => inputs.any((input) {
  final name = inputNameOf(input);
  if (!values.containsKey(name)) return false;
  final value = values[name];
  if (isSelectFormInput(input)) return value is! String || value.isEmpty;
  bool uploadedList(Object? v) => v is List && v.isNotEmpty && v.every((f) => f is HumanInputFile && f.isUploaded);
  if (isFileFormInput(input)) {
    return value is List ? !uploadedList(value) : !(value is HumanInputFile && value.isUploaded);
  }
  if (isFileListFormInput(input)) return !uploadedList(value);
  return false;
});

/// `getProcessedHumanInputFormInputs`: [values] with files as the server wants them.
Map<String, Object?>? processedHumanInputFormInputs(List<Object?> inputs, Map<String, Object?>? values) {
  if (values == null) return null;
  final out = {...values};
  for (final input in inputs) {
    final name = inputNameOf(input), value = values[name];
    if (isFileListFormInput(input)) {
      out[name] = value is List ? [for (final f in value.whereType<HumanInputFile>()) f.toJson()] : <Object?>[];
    } else if (isFileFormInput(input)) {
      out[name] = switch (value) {
        final List l => l.whereType<HumanInputFile>().firstOrNull?.toJson(),
        final HumanInputFile f => f.toJson(),
        _ => null,
      };
    }
  }
  return out;
}

// ---- variable-in-markdown.tsx --------------------------------------------------------------------------------------

/// A hast node, as the rehype plugins see it.
class MdNode {
  MdNode({this.type, this.value, this.tagName, this.properties, List<MdNode>? children}) : children = children ?? [];
  MdNode.text(String this.value) : type = 'text', children = [];
  MdNode.element(String this.tagName, Map<String, String> this.properties) : type = 'element', children = [];

  String? type, value, tagName;
  Map<String, String>? properties;
  List<MdNode> children;

  Json toJson() => {
    'type': ?type,
    'value': ?value,
    'tagName': ?tagName,
    'properties': ?properties,
    if (type == 'element' || children.isNotEmpty) 'children': [for (final c in children) c.toJson()],
  };
}

final _variableRegex = RegExp(r'\{\{#(.+?)#\}\}');
final _noteRegex = RegExp(r'\{\{#\$(.+?)#\}\}');

List<MdNode> _split(String value, RegExp re, MdNode Function(RegExpMatch m) node) {
  final parts = <MdNode>[];
  var last = 0;
  for (final m in re.allMatches(value)) {
    if (m.start > last) parts.add(MdNode.text(value.substring(last, m.start)));
    parts.add(node(m));
    last = m.end;
  }
  if (parts.isEmpty) return parts;
  if (last < value.length) parts.add(MdNode.text(value.substring(last)));
  return parts;
}

void _visitText(MdNode node, List<MdNode>? Function(String value, MdNode parent) transform) {
  var i = 0;
  while (i < node.children.length) {
    final child = node.children[i];
    if (child.type == 'text' && child.value != null) {
      final next = transform(child.value!, node);
      if (next != null) {
        node.children.replaceRange(i, i + 1, next);
        i += next.length;
        continue;
      }
    }
    _visitText(child, transform);
    i++;
  }
}

/// `rehypeVariable`: `{{#a.b#}}` in text becomes `variable` elements (texts with a note token are left alone).
void rehypeVariable(MdNode tree) => _visitText(tree, (value, _) {
  if (!_variableRegex.hasMatch(value) || _noteRegex.hasMatch(value)) return null;
  return _split(value, _variableRegex, (m) => MdNode.element('variable', {'dataPath': m[0]!.trim()}));
});

/// `rehypeNotes`: `{{#$output.x#}}` becomes `section` elements named `x`; their parent becomes a `div`.
void rehypeNotes(MdNode tree) => _visitText(tree, (value, parent) {
  if (!_noteRegex.hasMatch(value)) return null;
  parent.tagName = 'div';
  return _split(
    value,
    _noteRegex,
    (m) => MdNode.element('section', {'dataName': m[0]!.split('.').last.replaceAll('#}}', '')}),
  );
});

/// `formatVariablePath`: `{{#node.var#}}` shown as `{{node/var}}`.
String formatVariablePath(String path) => path.replaceAll('.', '/').replaceFirst('{{#', '{{').replaceFirst('#}}', '}}');

/// `replaceNodeIdsWithNames`.
String replaceNodeIdsWithNames(String path, String Function(String nodeId) nodeName) =>
    path.replaceAllMapped(RegExp(r'#([^#.]+)([.#])'), (m) => '#${nodeName(m[1]!)}${m[2]}');

/// `sourceToVariablePath`.
String sourceToVariablePath(List<String> selector, String Function(String nodeId) nodeName) =>
    selector.isEmpty ? '' : replaceNodeIdsWithNames('{{#${selector.join('.')}#}}', nodeName);
