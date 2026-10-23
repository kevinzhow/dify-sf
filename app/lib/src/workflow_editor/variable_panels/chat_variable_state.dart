/// The conversation variable modal's logic (chat-variable-panel: type.ts, utils.ts,
/// components/variable-modal.helpers.ts, components/use-variable-modal-state.ts), with JavaScript's `undefined` as
/// null.
library;

import 'dart:convert';

import '../../i18n/dify_i18n.dart';
import '../panel_fields/var_picker_model.dart' show checkKeys;
import '../prompt_editor/config_prompt.dart' show uuid4;
import 'app_variables.dart';

/// `ChatVarType`.
abstract final class ChatVarType {
  static const number = 'number';
  static const string = 'string';
  static const boolean = 'boolean';
  static const object = 'object';
  static const arrayString = 'array[string]';
  static const arrayNumber = 'array[number]';
  static const arrayBoolean = 'array[boolean]';
  static const arrayObject = 'array[object]';
}

/// A row of the object form: its key, type (string or number) and value.
typedef ObjectValueItem = ({String key, String type, Object? value});

/// `DEFAULT_OBJECT_VALUE` (object-value-item.tsx).
const ObjectValueItem defaultObjectValue = (key: '', type: ChatVarType.string, value: null);

/// `MAX_DESCRIPTION_LENGTH`.
const maxDescriptionLength = 255;

/// `typeList`.
const chatVarTypeList = [
  ChatVarType.string,
  ChatVarType.number,
  ChatVarType.boolean,
  ChatVarType.object,
  ChatVarType.arrayString,
  ChatVarType.arrayNumber,
  ChatVarType.arrayBoolean,
  ChatVarType.arrayObject,
];

const objectPlaceholder = '#  example\n#  {\n#     "name": "ray",\n#     "age": 20\n#  }';
const arrayStringPlaceholder = '#  example\n#  [\n#     "value1",\n#     "value2"\n#  ]';
const arrayNumberPlaceholder = '#  example\n#  [\n#     100,\n#     200\n#  ]';
const arrayObjectPlaceholder =
    '#  example\n#  [\n#     {\n#       "name": "ray",\n#       "age": 20\n#     },\n#     {\n#       "name": "lily",\n'
    '#       "age": 18\n#     }\n#  ]';
const arrayBoolPlaceholder = '#  example\n#  [\n#     "True",\n#     "False"\n#  ]';

/// `getEditorMinHeight`, in logical pixels.
double getEditorMinHeight(String type) => type == ChatVarType.arrayObject ? 240 : 120;

/// `getPlaceholderByType`.
String getPlaceholderByType(String type) => switch (type) {
  ChatVarType.arrayString => arrayStringPlaceholder,
  ChatVarType.arrayNumber => arrayNumberPlaceholder,
  ChatVarType.arrayObject => arrayObjectPlaceholder,
  ChatVarType.arrayBoolean => arrayBoolPlaceholder,
  _ => objectPlaceholder,
};

List<ObjectValueItem> _itemsOf(Map<Object?, Object?> record) => [
  for (final e in record.entries)
    (key: '${e.key}', type: e.value is String ? ChatVarType.string : ChatVarType.number, value: e.value),
];

/// `buildObjectValueItems`.
List<ObjectValueItem> buildObjectValueItems([DifyVariable? chatVar]) {
  final value = chatVar?['value'];
  if (value is! Map || value.isEmpty) return const [defaultObjectValue];
  return _itemsOf(value);
}

/// `formatObjectValueFromList`: rows with a key, an empty value as null.
Map<String, Object?> formatObjectValueFromList(List<ObjectValueItem> list) => {
  for (final i in list)
    if (i.key.isNotEmpty) i.key: i.value == '' ? null : i.value,
};

bool _jsTruthy(Object? v) => !(v == null || v == false || v == '' || v == 0);

/// `formatChatVariableValue`: the value saved for [type].
Object? formatChatVariableValue({
  required bool editInJSON,
  required List<ObjectValueItem> objectValue,
  required String type,
  required Object? value,
}) {
  List<Object?> compact(List<Object?> items) => [
    for (final i in items)
      if (i != null && i != '') i,
  ];
  return switch (type) {
    ChatVarType.string => _jsTruthy(value) ? value : '',
    ChatVarType.number => _jsTruthy(value) ? value : 0,
    ChatVarType.boolean => value ?? true,
    ChatVarType.object => editInJSON ? value : formatObjectValueFromList(objectValue),
    ChatVarType.arrayString ||
    ChatVarType.arrayNumber ||
    ChatVarType.arrayObject => value is List ? compact(value.cast<Object?>()) : const <Object?>[],
    ChatVarType.arrayBoolean => _jsTruthy(value) ? value : const <Object?>[],
    _ => value,
  };
}

/// `validateVariableName`: false (after [notify]ing the error) when [name] is not a valid variable name.
bool validateVariableName(String name, void Function(String message) notify) {
  final bad = checkKeys([name]);
  if (bad == null) return true;
  notify(DifyI18n.tr('app-debug', 'varKeyError.${bad.error}', {'key': DifyI18n.tr('workflow', 'env.modal.name')}));
  return false;
}

/// `getTypeChangeState`.
({bool editInJSON, String? editorContent, List<ObjectValueItem>? objectValue, Object? value}) getTypeChangeState(
  String next,
) => (
  editInJSON: next == ChatVarType.arrayObject,
  editorContent: null,
  objectValue: next == ChatVarType.object ? const [defaultObjectValue] : null,
  value: next == ChatVarType.boolean
      ? false
      : next == ChatVarType.arrayBoolean
      ? const [false]
      : null,
);

/// `parseEditorContent`: the JSON [content] (array[boolean] takes `True` / `true` / `False` / `false` and drops
/// the rest; anything but an array throws).
Object? parseEditorContent(String content, String type) {
  final parsed = jsonDecode(content);
  if (type != ChatVarType.arrayBoolean) return parsed;
  if (parsed is! List) throw const FormatException('ArrayBoolean editor content must be a JSON array');
  return [
    for (final item in parsed)
      if (item == 'True' || item == 'true' || item == true)
        true
      else if (item == 'False' || item == 'false' || item == false)
        false,
  ];
}

/// `getEditorToggleLabelKey`.
String getEditorToggleLabelKey(String type, bool editInJSON) {
  if (type == ChatVarType.object) {
    return editInJSON ? 'chatVariable.modal.editInForm' : 'chatVariable.modal.editInJSON';
  }
  return editInJSON ? 'chatVariable.modal.oneByOne' : 'chatVariable.modal.editInJSON';
}

/// `JSON.stringify` of plain JSON (undefined -> null).
String? _stringify(Object? v) => v == null ? null : jsonEncode(v);

/// `useVariableModalState`: the modal's state ([chatVar]'s, or a new string variable's) and its handlers; the
/// widget calls them inside `setState`. [save] validates (errors go to [notify]), then hands the variable to
/// [onSave] and calls [onClose].
class ChatVariableModalState {
  ChatVariableModalState({
    this.chatVar,
    required this.conversationVariables,
    required this.notify,
    required this.onClose,
    required this.onSave,
  }) : description = '${chatVar?['description'] ?? ''}',
       editInJSON = chatVar?['value_type'] == ChatVarType.arrayObject,
       editorContent = chatVar?['value_type'] == ChatVarType.arrayObject ? jsonEncode(chatVar?['value']) : null,
       name = '${chatVar?['name'] ?? ''}',
       objectValue = buildObjectValueItems(chatVar),
       type = '${chatVar?['value_type'] ?? ChatVarType.string}',
       value = chatVar?['value'];

  final DifyVariable? chatVar;
  final List<DifyVariable> Function() conversationVariables;
  final void Function(String message) notify;
  final void Function() onClose;
  final void Function(DifyVariable chatVar) onSave;

  String description;
  bool editInJSON;
  String? editorContent;
  String name;
  List<ObjectValueItem> objectValue;
  String type;
  Object? value;

  double get editorMinHeight => getEditorMinHeight(type);
  String get placeholder => getPlaceholderByType(type);

  void handleVarNameChange(String v) => name = v;

  void handleTypeChange(String next) {
    final s = getTypeChangeState(next);
    editInJSON = s.editInJSON;
    editorContent = s.editorContent;
    objectValue = s.objectValue ?? objectValue;
    type = next;
    value = s.value;
  }

  void handleStringOrNumberChange(List<Object?> next) => value = next.isEmpty ? null : next.first;

  void handleEditorChange(bool nextEditInJSON) {
    final prevType = type, prevValue = value;
    editInJSON = nextEditInJSON;
    if (prevType == ChatVarType.object) {
      if (nextEditInJSON) {
        final next = objectValue.any((i) => i.key.isNotEmpty) ? formatObjectValueFromList(objectValue) : null;
        value = next;
        editorContent = _stringify(next);
        return;
      }
      if (editorContent == null || editorContent!.isEmpty) {
        value = null;
        objectValue = const [defaultObjectValue];
        return;
      }
      try {
        final next = jsonDecode(editorContent!);
        if (next is Map) {
          value = next;
          objectValue = _itemsOf(next);
        }
      } on FormatException {
        // ignore JSON.parse errors
      }
      return;
    }
    if (prevType == ChatVarType.arrayString || prevType == ChatVarType.arrayNumber) {
      if (nextEditInJSON) {
        final compact = prevValue is List
            ? [
                for (final i in prevValue)
                  if (i != null && i != '') i,
              ]
            : const [];
        final next = compact.isEmpty ? null : compact;
        value = next;
        if (editorContent == null || editorContent!.isEmpty) editorContent = _stringify(next);
        return;
      }
      value = prevValue is List && prevValue.isNotEmpty ? prevValue : const [null];
      return;
    }
    if (prevType == ChatVarType.arrayBoolean && prevValue is List && nextEditInJSON) {
      editorContent = jsonEncode([for (final i in prevValue) _jsTruthy(i) ? 'True' : 'False']);
    }
  }

  void handleEditorValueChange(String content) {
    editorContent = content;
    if (content.isEmpty) {
      value = null;
      return;
    }
    try {
      value = parseEditorContent(content, type);
    } on FormatException {
      // ignore JSON.parse errors
    }
  }

  void save() {
    if (!validateVariableName(name, notify)) return;
    if (chatVar == null && conversationVariables().any((v) => v['name'] == name)) {
      return notify(
        DifyI18n.tr('app-debug', 'varKeyError.keyAlreadyExists', {
          'key': DifyI18n.tr('workflow', 'chatVariable.modal.name'),
        }),
      );
    }
    if (type == ChatVarType.object && objectValue.any((i) => i.key.isEmpty && i.value != null && i.value != '')) {
      return notify(DifyI18n.tr('workflow', 'chatVariable.modal.objectKeyRequired'));
    }
    if (description.length > maxDescriptionLength) {
      return notify(
        DifyI18n.tr('workflow', 'chatVariable.modal.descriptionTooLong', {'maxLength': maxDescriptionLength}),
      );
    }
    onSave({
      'description': description,
      'id': chatVar == null ? uuid4() : chatVar!['id'],
      'name': name,
      'value': formatChatVariableValue(editInJSON: editInJSON, objectValue: objectValue, type: type, value: value),
      'value_type': type,
    });
    onClose();
  }
}
