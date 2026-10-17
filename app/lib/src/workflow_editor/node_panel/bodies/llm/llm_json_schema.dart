/// The LLM's "Structured Output Schema" dialog (nodes/llm/components/json-schema-config-modal/**): the Visual Editor
/// (a tree of the schema's fields, edited in place) and the JSON Schema tab (the code editor), Import from JSON, the
/// generator (when the host offers one), Reset / Cancel / Save with Dify's validations.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../../../cards/card_kit.dart';
import '../../../../design/dify_icon.dart';
import '../../../../design/dify_tokens.g.dart';
import '../../../../design/widgets/widgets.dart';
import '../../../../i18n/dify_i18n.dart';
import '../../../../workflow/dify_json.dart';
import '../../../code_editor/code_editor.dart';
import '../../../panel_fields/panel_fields.dart';
import 'group_host.dart';
import 'llm_config.dart';
import 'llm_dialog.dart';
import 'panel_edit.dart' show jsMap;

String _w(String key) => DifyI18n.tr('workflow', key);
String _c(String key) => DifyI18n.tr('common', key);

/// `DEFAULT_SCHEMA`.
Json defaultSchemaRoot() => {
  'type': 'object',
  'properties': <String, Object?>{},
  'required': <String>[],
  'additionalProperties': false,
};

String _pretty(Object? v) => const JsonEncoder.withIndent('  ').convert(v);

/// Opens the dialog over [defaultSchema]; Save hands the schema to [onSave].
Future<void> showJsonSchemaConfigModal(
  BuildContext context, {
  required Json defaultSchema,
  required ValueChanged<Json> onSave,
}) {
  final services = LlmGroupScope.of(context);
  return showLlmDialog<void>(
    context,
    builder: (ctx) {
      final h = MediaQuery.sizeOf(ctx).height - 32;
      return LlmGroupScope(
        services: services,
        child: LlmDialogSurface(
          label: _w('nodes.llm.jsonSchema.title'),
          width: 960,
          height: h < 800 ? h : 800,
          child: JsonSchemaConfig(
            defaultSchema: defaultSchema,
            onSave: onSave,
            onClose: () => Navigator.of(ctx).pop(),
          ),
        ),
      );
    },
  );
}

/// SchemaView.
enum SchemaView { visualEditor, jsonSchema }

// ---- the visual editor's store and events (visual-editor/store.ts, hooks.ts) ------------------------------------

/// What a field edit card edits (`EditData`).
typedef SchemaEditData = ({String name, String type, bool required, String? description, List<Object?>? enumValues});

/// The visual editor's state (store.ts) and the operations its events run (hooks.ts useSchemaNodeOperations), over
/// the schema the dialog holds ([schema], changed through [onChange]).
class SchemaEditorController extends ChangeNotifier {
  SchemaEditorController({required this.schemaOf, required this.onChange, this.onToast});

  final Json Function() schemaOf;
  final ValueChanged<Json> onChange;
  final void Function(LlmToastType type, String message)? onToast;

  String? hoveringProperty;
  bool isAddingNewField = false;
  bool advancedEditing = false;
  Json? backupSchema;

  /// Bumped when a rename is refused (the card puts the old name back: `restorePropertyName`).
  int restoreNameTick = 0;

  /// Bumped after a successful `fieldChange` (`fieldChangeSuccess`).
  int fieldChangeTick = 0;

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// A card unmounting with the dialog commits after the dialog is gone: nothing to tell then.
  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  void setHoveringProperty(String? p) {
    if (hoveringProperty == p) return;
    hoveringProperty = p;
    notifyListeners();
  }

  void setIsAddingNewField(bool v) {
    isAddingNewField = v;
    notifyListeners();
  }

  void setAdvancedEditing(bool v) {
    advancedEditing = v;
    notifyListeners();
  }

  static Json _at(Json root, List<String> path) {
    Object? cur = root;
    for (final k in path) {
      cur = jsGet(cur, k);
    }
    return cur is Map<String, Object?> ? cur : jsMap(cur);
  }

  void _produce(void Function(Json draft) f) {
    final draft = jsonClone(schemaOf());
    f(draft);
    onChange(draft);
  }

  /// `restoreSchema`.
  void restoreSchema() {
    final b = backupSchema;
    if (b == null) return;
    onChange(b);
    backupSchema = null;
    notifyListeners();
  }

  /// `quitEditing`: back to the backup, out of the editing modes.
  void quitEditing([void Function(Json? backup)? callback]) {
    callback?.call(backupSchema);
    if (backupSchema != null) {
      onChange(backupSchema!);
      backupSchema = null;
    }
    isAddingNewField = false;
    advancedEditing = false;
    hoveringProperty = null;
    notifyListeners();
  }

  /// The object whose `properties` hold the field (an object, or an array of objects' `items`).
  static Json? _container(Json parent) {
    if (parent['type'] == 'object') return parent;
    final items = parent['items'];
    if (parent['type'] == 'array' && items is Map && items['type'] == 'object') return items.cast<String, Object?>();
    return null;
  }

  bool _rename(Json container, String oldName, String newName) {
    final props = jsMap(container['properties']);
    if (props.containsKey(newName)) {
      onToast?.call(LlmToastType.error, _w('nodes.llm.jsonSchema.fieldNameAlreadyExists'));
      return false;
    }
    container['properties'] = {for (final e in props.entries) (e.key == oldName ? newName : e.key): e.value};
    final required = [for (final r in jsList(container['required'])) '$r'];
    final i = required.indexOf(oldName);
    if (i != -1) required[i] = newName;
    container['required'] = required;
    return true;
  }

  /// `propertyNameChange`.
  void propertyNameChange(List<String> parentPath, SchemaEditData oldFields, SchemaEditData fields) {
    if (oldFields.name == fields.name) return onChange(jsonClone(schemaOf()));
    var refused = false;
    _produce((d) {
      final c = _container(_at(d, parentPath));
      if (c != null && !_rename(c, oldFields.name, fields.name)) refused = true;
    });
    if (refused) {
      restoreNameTick++;
      notifyListeners();
    }
  }

  static void _retype(Json schema, String newType) {
    if (schema['type'] == 'object') {
      schema
        ..remove('properties')
        ..remove('required');
    }
    if (schema['type'] == 'array') schema.remove('items');
    switch (newType) {
      case 'object':
        schema
          ..['type'] = 'object'
          ..['properties'] = <String, Object?>{}
          ..['required'] = <String>[]
          ..['additionalProperties'] = false;
      case 'array[string]':
        schema
          ..['type'] = 'array'
          ..['items'] = {'type': 'string'};
      case 'array[number]':
        schema
          ..['type'] = 'array'
          ..['items'] = {'type': 'number'};
      case 'array[object]':
        schema
          ..['type'] = 'array'
          ..['items'] = {
            'type': 'object',
            'properties': <String, Object?>{},
            'required': <String>[],
            'additionalProperties': false,
          };
      default:
        schema['type'] = newType;
    }
  }

  /// `propertyTypeChange`.
  void propertyTypeChange(List<String> path, SchemaEditData oldFields, String newType) {
    if (oldFields.type == newType) return;
    _produce((d) => _retype(_at(d, path), newType));
  }

  static void _toggle(Json container, String name) {
    final required = [for (final r in jsList(container['required'])) '$r'];
    container['required'] = required.contains(name)
        ? [
            for (final r in required)
              if (r != name) r,
          ]
        : [...required, name];
  }

  /// `propertyRequiredToggle`.
  void propertyRequiredToggle(List<String> parentPath, SchemaEditData fields) => _produce((d) {
    final c = _container(_at(d, parentPath));
    if (c != null) _toggle(c, fields.name);
  });

  /// `propertyOptionsChange`.
  void propertyOptionsChange(List<String> path, {String? description, List<Object?>? enumValues}) => _produce((d) {
    final s = _at(d, path);
    _setOptional(s, 'description', description);
    _setOptional(s, 'enum', enumValues);
  });

  static void _setOptional(Json m, String key, Object? v) => v == null ? m.remove(key) : m[key] = v;

  /// `propertyDelete`.
  void propertyDelete(List<String> parentPath, SchemaEditData fields) => _produce((d) {
    final c = _container(_at(d, parentPath));
    if (c == null || c['properties'] is! Map) return;
    (c['properties']! as Map).remove(fields.name);
    if (c['required'] is List) {
      c['required'] = [
        for (final r in jsList(c['required']))
          if (r != fields.name) r,
      ];
    }
  });

  /// `addField`: an unnamed string field under [path], in adding mode with a backup to go back to.
  void addField(List<String> path) {
    if (advancedEditing) advancedEditing = false;
    backupSchema = jsonClone(schemaOf());
    isAddingNewField = true;
    _produce((d) {
      final s = _at(d, path);
      if (s['type'] == 'object') {
        s['properties'] = {
          ...jsMap(s['properties']),
          '': {'type': 'string'},
        };
        hoveringProperty = [...path, 'properties', ''].join('.');
      }
      final items = s['items'];
      if (s['type'] == 'array' && items is Map && items['type'] == 'object') {
        items['properties'] = {
          ...jsMap(items['properties']),
          '': {'type': 'string'},
        };
        hoveringProperty = [...path, 'items', 'properties', ''].join('.');
      }
    });
    notifyListeners();
  }

  /// `fieldChange`: the card's edits as one change (rename, required, type, options); a duplicate name is refused.
  void fieldChange(List<String> parentPath, SchemaEditData oldFields, SchemaEditData fields) {
    var refused = false;
    final draft = jsonClone(schemaOf());
    final c = _container(_at(draft, parentPath));
    if (c != null && c['properties'] is Map) {
      if (oldFields.name != fields.name) {
        final props = jsMap(c['properties']);
        if (props.containsKey(fields.name)) {
          onToast?.call(LlmToastType.error, _w('nodes.llm.jsonSchema.fieldNameAlreadyExists'));
          refused = true;
        }
        c['properties'] = {for (final e in props.entries) (e.key == oldFields.name ? fields.name : e.key): e.value};
        final required = [for (final r in jsList(c['required'])) '$r'];
        final i = required.indexOf(oldFields.name);
        if (i != -1) required[i] = fields.name;
        c['required'] = required;
      }
      if (oldFields.required != fields.required) _toggle(c, fields.name);
      final schema = jsMap(jsMap(c['properties'])[fields.name]);
      if (oldFields.type != fields.type) _retype(schema, fields.type);
      _setOptional(schema, 'description', fields.description);
      _setOptional(schema, 'enum', fields.enumValues);
    }
    if (refused) return;
    onChange(draft);
    // fieldChangeSuccess
    isAddingNewField = false;
    advancedEditing = false;
    fieldChangeTick++;
    notifyListeners();
  }
}

// ---- json-schema-config.tsx --------------------------------------------------------------------------------------

/// JsonSchemaConfig: the dialog's content.
class JsonSchemaConfig extends StatefulWidget {
  const JsonSchemaConfig({super.key, required this.defaultSchema, required this.onSave, required this.onClose});
  final Json defaultSchema;
  final ValueChanged<Json> onSave;
  final VoidCallback onClose;

  @override
  State<JsonSchemaConfig> createState() => _JsonSchemaConfigState();
}

class _JsonSchemaConfigState extends State<JsonSchemaConfig> {
  SchemaView _view = SchemaView.visualEditor;
  late Json _schema = widget.defaultSchema;
  late String _json = _pretty(_schema);
  String? _parseError;
  String _validationError = '';
  late final _editor = SchemaEditorController(
    schemaOf: () => _schema,
    onChange: (s) {
      if (mounted) setState(() => _schema = s);
    },
    onToast: (t, m) => LlmGroupScope.of(context).toast?.call(t, m),
  );

  @override
  void dispose() {
    _editor.dispose();
    super.dispose();
  }

  /// The JSON tab's text as a schema root, or null after showing why it is not one.
  Json? _validated() {
    Object? schema;
    try {
      schema = jsonDecode(_json);
    } on FormatException catch (e) {
      setState(() {
        _validationError = '';
        _parseError = e.message;
      });
      return null;
    }
    setState(() => _parseError = null);
    final pre = preValidateSchema(schema);
    if (pre != null) {
      setState(() => _validationError = pre);
      return null;
    }
    if (checkJsonSchemaDepth(schema) > jsonSchemaMaxDepth) {
      setState(() => _validationError = 'Schema exceeds maximum depth of $jsonSchemaMaxDepth.');
      return null;
    }
    final errors = validateSchemaAgainstDraft7(schema);
    if (errors.isNotEmpty) {
      setState(() => _validationError = getValidationErrorMessage(errors));
      return null;
    }
    return jsMap(schema);
  }

  bool _changeView(SchemaView v) {
    if (_view == v) return true;
    if (_view == SchemaView.jsonSchema) {
      final s = _validated();
      if (s == null) return false;
      setState(() {
        _schema = s;
        _validationError = '';
      });
    } else if (_editor.advancedEditing || _editor.isAddingNewField) {
      _editor.quitEditing((backup) => _json = _pretty(backup ?? _schema));
    } else {
      _json = _pretty(_schema);
    }
    setState(() => _view = v);
    return true;
  }

  void _apply(Json schema) => setState(() {
    if (_view == SchemaView.visualEditor) {
      _schema = schema;
    } else {
      _json = _pretty(schema);
    }
  });

  void _reset() {
    if (_view == SchemaView.visualEditor) {
      _editor
        ..hoveringProperty = null
        ..advancedEditing = false
        ..isAddingNewField = false;
    }
    setState(() {
      _schema = defaultSchemaRoot();
      _json = _pretty(_schema);
    });
  }

  void _save() {
    var schema = _schema;
    if (_view == SchemaView.jsonSchema) {
      final s = _validated();
      if (s == null) return;
      schema = s;
      setState(() {
        _schema = s;
        _validationError = '';
      });
    } else if (_editor.advancedEditing || _editor.isAddingNewField) {
      LlmGroupScope.of(context).toast?.call(LlmToastType.warning, _w('nodes.llm.jsonSchema.warningTips.saveSchema'));
      return;
    }
    widget.onSave(schema);
    widget.onClose();
  }

  @override
  Widget build(BuildContext context) {
    final services = LlmGroupScope.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Stack(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 56, 12),
              child: DifyText(_w('nodes.llm.jsonSchema.title'), DifyType.title2xlSemiBold),
            ),
            Positioned(
              top: 20,
              right: 20,
              child: DifyIconButton(
                label: _c('operation.close'),
                size: DifyIconButtonSize.lg,
                icon: const RemixIcon('close-line', size: 18, color: DifyColors.textTertiary),
                onPressed: widget.onClose,
              ),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
          child: Row(
            children: [
              SchemaViewTabs(value: _view, onChange: _changeView),
              const Spacer(),
              if (services.generateJsonSchema != null) ...[
                JsonSchemaGenerator(onApply: _apply),
                Container(width: 1, height: 12, color: DifyColors.dividerRegular),
              ],
              JsonImporter(
                isEditing: () => _editor.advancedEditing || _editor.isAddingNewField,
                onQuitEditing: _editor.quitEditing,
                onSubmit: (json) => _apply(jsonToSchema(json)),
              ),
            ],
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: switch (_view) {
              SchemaView.visualEditor => VisualEditor(schema: _schema, controller: _editor),
              SchemaView.jsonSchema => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: SchemaJsonEditor(value: _json, onUpdate: (v) => _json = v),
                  ),
                  if (_parseError != null) SchemaErrorMessage(message: _parseError!),
                  if (_validationError.isNotEmpty) SchemaErrorMessage(message: _validationError),
                ],
              ),
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
          child: Wrap(
            alignment: WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              DifyButton(onPressed: _reset, child: Text(_w('nodes.llm.jsonSchema.resetDefaults'))),
              Container(width: 1, height: 16, margin: const EdgeInsets.only(left: 4), color: DifyColors.dividerRegular),
              const SizedBox(width: 4),
              DifyButton(onPressed: widget.onClose, child: Text(_c('operation.cancel'))),
              DifyButton(variant: DifyButtonVariant.primary, onPressed: _save, child: Text(_c('operation.save'))),
            ],
          ),
        ),
      ],
    );
  }
}

/// ErrorMessage: `mt-1 rounded-lg border-[0.5px] bg-toast-error-bg p-2` with the error icon.
class SchemaErrorMessage extends StatelessWidget {
  const SchemaErrorMessage({super.key, required this.message});
  final String message;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(top: 4),
    padding: const EdgeInsets.all(8),
    decoration: BoxDecoration(
      gradient: DifyGradients.toastErrorBg,
      borderRadius: BorderRadius.circular(DifyRadius.lg),
      border: Border.all(color: DifyColors.componentsPanelBorder, width: 0.5),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 4,
      children: [
        const RemixIcon('error-warning-fill', size: 16, color: DifyColors.textDestructive),
        Expanded(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 48),
            child: SingleChildScrollView(
              child: Text(message, style: difyStyle(DifyType.systemXsMedium, DifyColors.textPrimary)),
            ),
          ),
        ),
      ],
    ),
  );
}

/// The JSON tab's editor (code-editor.tsx): "JSON" with Format and Copy over the code editor.
class SchemaJsonEditor extends StatefulWidget {
  const SchemaJsonEditor({super.key, required this.value, required this.onUpdate, this.showFormatButton = true});
  final String value;
  final ValueChanged<String> onUpdate;
  final bool showFormatButton;

  @override
  State<SchemaJsonEditor> createState() => _SchemaJsonEditorState();
}

class _SchemaJsonEditorState extends State<SchemaJsonEditor> {
  late String _value = widget.value;

  @override
  void didUpdateWidget(SchemaJsonEditor old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value) _value = widget.value;
  }

  void _format() {
    try {
      setState(() => _value = _pretty(jsonDecode(_value)));
      widget.onUpdate(_value);
    } on FormatException {
      // Monaco's formatter leaves invalid JSON as it is.
    }
  }

  @override
  Widget build(BuildContext context) => Container(
    clipBehavior: Clip.antiAlias,
    decoration: BoxDecoration(
      color: DifyColors.componentsInputBgNormal,
      borderRadius: BorderRadius.circular(DifyRadius.xl),
    ),
    child: DifyCodeEditor(
      value: _value,
      language: CodeLanguage.json,
      noWrapper: true,
      isExpand: true,
      titleWidget: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: DifyText('JSON', DifyType.systemXsSemiboldUppercase, color: DifyColors.textSecondary),
      ),
      headerRight: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 2,
        children: [
          if (widget.showFormatButton)
            DifyIconButton(
              label: _c('operation.format'),
              icon: const RemixIcon('indent-increase', size: 16, color: DifyColors.textTertiary),
              onPressed: _format,
            ),
          DifyIconButton(
            label: _c('operation.copy'),
            icon: const RemixIcon('clipboard-line', size: 16, color: DifyColors.textTertiary),
            onPressed: () => Clipboard.setData(ClipboardData(text: _value)),
          ),
        ],
      ),
      onChange: (v) {
        _value = v;
        widget.onUpdate(v);
      },
    ),
  );
}

// ---- json-importer.tsx -------------------------------------------------------------------------------------------

/// JsonImporter: "Import from JSON", a popover (bottom-end, `w-100`) with a code editor; Submit parses the sample,
/// refuses a non-object root or one deeper than 10, and hands it on.
class JsonImporter extends StatefulWidget {
  const JsonImporter({super.key, required this.onSubmit, this.isEditing, this.onQuitEditing});
  final ValueChanged<Object?> onSubmit;

  /// Whether the visual editor is editing a field (advanced editing or adding one): opening then quits editing
  /// ([onQuitEditing], Dify's `quitEditing` event).
  final bool Function()? isEditing;
  final VoidCallback? onQuitEditing;

  @override
  State<JsonImporter> createState() => _JsonImporterState();
}

class _JsonImporterState extends State<JsonImporter> {
  final _popup = DifyFloatingController();
  String _json = '';
  String? _error;

  void _submit() {
    Object? parsed;
    try {
      parsed = jsonDecode(_json);
    } on FormatException catch (e) {
      setState(() => _error = e.message);
      return;
    }
    if (parsed is! Map) {
      setState(() => _error = 'Root must be an object, not an array or primitive value.');
      return;
    }
    if (checkJsonDepth(parsed) > jsonSchemaMaxDepth) {
      setState(() => _error = 'Schema exceeds maximum depth of $jsonSchemaMaxDepth.');
      return;
    }
    widget.onSubmit(parsed);
    setState(() => _error = null);
    _popup.close();
  }

  @override
  Widget build(BuildContext context) => DifyFloating(
    controller: _popup,
    placement: DifyPlacement.bottomEnd,
    sideOffset: 4,
    alignOffset: 16,
    builder: (context, c) => DifyPressable(
      semanticLabel: _w('nodes.llm.jsonSchema.import'),
      onPressed: () {
        if (!c.isOpen && (widget.isEditing?.call() ?? false)) widget.onQuitEditing?.call();
        c.toggle();
      },
      builder: (context, hovered, focused) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: hovered || c.isOpen ? DifyColors.componentsButtonGhostBgHover : null,
          borderRadius: BorderRadius.circular(DifyRadius.md),
        ),
        child: DifyText(_w('nodes.llm.jsonSchema.import'), DifyType.systemXsMedium, color: DifyColors.textTertiary),
      ),
    ),
    popupBuilder: (context) => Semantics(
      container: true,
      role: SemanticsRole.dialog,
      label: _w('nodes.llm.jsonSchema.import'),
      explicitChildNodes: true,
      child: Container(
        width: 400,
        decoration: BoxDecoration(
          color: DifyColors.componentsPanelBg,
          borderRadius: BorderRadius.circular(DifyRadius.xxl),
          border: Border.all(color: DifyColors.componentsPanelBorder, width: 0.5),
          boxShadow: DifyShadows.n2xl,
        ),
        child: StatefulBuilder(
          builder: (context, setLocal) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 8, 4),
                child: Row(
                  children: [
                    Expanded(child: DifyText(_w('nodes.llm.jsonSchema.import'), DifyType.systemXlSemibold)),
                    DifyIconButton(
                      label: _c('operation.close'),
                      size: DifyIconButtonSize.lg,
                      icon: const RemixIcon('close-line', size: 16, color: DifyColors.textTertiary),
                      onPressed: _popup.close,
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      height: 340 + 28,
                      child: SchemaJsonEditor(value: _json, showFormatButton: false, onUpdate: (v) => _json = v),
                    ),
                    if (_error != null) SchemaErrorMessage(message: _error!),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    DifyButton(onPressed: _popup.close, child: Text(_c('operation.cancel'))),
                    DifyButton(
                      variant: DifyButtonVariant.primary,
                      onPressed: () {
                        _submit();
                        setLocal(() {});
                      },
                      child: Text(_c('operation.submit')),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

// ---- json-schema-generator (when the host has a generator) -------------------------------------------------------

/// JsonSchemaGenerator: the generator button and its popover: the instruction, Generate, then the result with Back,
/// Regenerate and Apply. The host's generator stands for Dify's model call.
class JsonSchemaGenerator extends StatefulWidget {
  const JsonSchemaGenerator({super.key, required this.onApply});
  final ValueChanged<Json> onApply;

  @override
  State<JsonSchemaGenerator> createState() => _JsonSchemaGeneratorState();
}

class _JsonSchemaGeneratorState extends State<JsonSchemaGenerator> {
  final _popup = DifyFloatingController();
  String _instruction = '';
  bool _generating = false;
  Json? _result;

  Future<void> _generate(StateSetter setLocal) async {
    final gen = LlmGroupScope.of(context).generateJsonSchema;
    if (gen == null || _instruction.trim().isEmpty) return;
    setLocal(() => _generating = true);
    final res = await gen(_instruction);
    if (!mounted) return;
    setLocal(() {
      _generating = false;
      _result = res;
    });
  }

  @override
  Widget build(BuildContext context) => DifyFloating(
    controller: _popup,
    placement: DifyPlacement.bottomEnd,
    sideOffset: 4,
    builder: (context, c) => DifyIconButton(
      label: _w('nodes.llm.jsonSchema.generateJsonSchema'),
      icon: const RemixIcon('sparkling-fill', size: 16, color: DifyColors.textAccent),
      onPressed: c.toggle,
    ),
    popupBuilder: (context) => Container(
      width: 480,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: DifyColors.componentsPanelBg,
        borderRadius: BorderRadius.circular(DifyRadius.xxl),
        border: Border.all(color: DifyColors.componentsPanelBorder, width: 0.5),
        boxShadow: DifyShadows.n2xl,
      ),
      child: StatefulBuilder(
        builder: (context, setLocal) {
          final result = _result;
          if (_generating) {
            return SizedBox(
              height: 200,
              child: Center(
                child: DifyText(
                  _w('nodes.llm.jsonSchema.generating'),
                  DifyType.systemSmRegular,
                  color: DifyColors.textTertiary,
                ),
              ),
            );
          }
          if (result != null) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 8,
              children: [
                DifyText(_w('nodes.llm.jsonSchema.generatedResult'), DifyType.systemXlSemibold),
                DifyText(
                  _w('nodes.llm.jsonSchema.resultTip'),
                  DifyType.systemXsRegular,
                  color: DifyColors.textTertiary,
                  maxLines: null,
                ),
                SizedBox(
                  height: 300,
                  child: SchemaJsonEditor(value: _pretty(result), onUpdate: (_) {}),
                ),
                Row(
                  spacing: 8,
                  children: [
                    DifyButton(
                      variant: DifyButtonVariant.ghost,
                      leading: const RemixIcon('arrow-left-line', size: 16),
                      onPressed: () => setLocal(() => _result = null),
                      child: Text(_w('nodes.llm.jsonSchema.back')),
                    ),
                    const Spacer(),
                    DifyButton(
                      leading: const RemixIcon('sparkling-line', size: 16),
                      onPressed: () => _generate(setLocal),
                      child: Text(_w('nodes.llm.jsonSchema.regenerate')),
                    ),
                    DifyButton(
                      variant: DifyButtonVariant.primary,
                      onPressed: () {
                        widget.onApply(result);
                        _popup.close();
                      },
                      child: Text(_w('nodes.llm.jsonSchema.apply')),
                    ),
                  ],
                ),
              ],
            );
          }
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 8,
            children: [
              DifyText(_w('nodes.llm.jsonSchema.generateJsonSchema'), DifyType.systemXlSemibold),
              DifyText(
                _w('nodes.llm.jsonSchema.generationTip'),
                DifyType.systemXsRegular,
                color: DifyColors.textTertiary,
                maxLines: null,
              ),
              DifyText(
                _w('nodes.llm.jsonSchema.instruction'),
                DifyType.systemSmSemiboldUppercase,
                color: DifyColors.textSecondary,
              ),
              SizedBox(
                height: 200,
                child: DifyInput(
                  value: _instruction,
                  placeholder: _w('nodes.llm.jsonSchema.promptPlaceholder'),
                  onChanged: (v) => _instruction = v,
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                spacing: 8,
                children: [
                  DifyButton(onPressed: _popup.close, child: Text(_c('operation.cancel'))),
                  DifyButton(
                    variant: DifyButtonVariant.primary,
                    leading: const RemixIcon('sparkling-fill', size: 16),
                    onPressed: () => _generate(setLocal),
                    child: Text(_w('nodes.llm.jsonSchema.generate')),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    ),
  );
}

// ---- visual-editor/** --------------------------------------------------------------------------------------------

/// VisualEditor: `h-full overflow-auto rounded-xl bg-background-section-burn p-1 pl-2` around the root node
/// `structured_output`.
class VisualEditor extends StatelessWidget {
  const VisualEditor({super.key, required this.schema, required this.controller, this.rootName, this.readOnly = false});
  final Json schema;
  final SchemaEditorController controller;
  final String? rootName;
  final bool readOnly;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
    decoration: BoxDecoration(
      color: DifyColors.backgroundSectionBurn,
      borderRadius: BorderRadius.circular(DifyRadius.xl),
    ),
    child: SingleChildScrollView(
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) => SchemaNode(
          name: rootName ?? 'structured_output',
          schema: schema,
          required: false,
          path: const [],
          depth: 0,
          readOnly: readOnly,
          controller: controller,
        ),
      ),
    ),
  );
}

/// SchemaNode: a field's card (an EditCard while hovered or tapped, below the root), its children 20 px further in
/// with a guide line, a fold chevron for nested parents, and "Add Field" at the root's end.
class SchemaNode extends StatefulWidget {
  const SchemaNode({
    super.key,
    required this.name,
    required this.schema,
    required this.required,
    required this.path,
    required this.depth,
    required this.controller,
    this.parentPath,
    this.readOnly = false,
  });

  final String name;
  final Json schema;
  final bool required;
  final List<String> path;
  final List<String>? parentPath;
  final int depth;
  final bool readOnly;
  final SchemaEditorController controller;

  @override
  State<SchemaNode> createState() => _SchemaNodeState();
}

class _SchemaNodeState extends State<SchemaNode> {
  bool _expanded = true;
  Timer? _hover;

  @override
  void dispose() {
    _hover?.cancel();
    super.dispose();
  }

  void _setHovering(String? path) {
    final c = widget.controller;
    if (widget.readOnly || c.advancedEditing || c.isAddingNewField) return;
    _hover?.cancel();
    _hover = Timer(const Duration(milliseconds: 50), () => c.setHoveringProperty(path));
  }

  @override
  Widget build(BuildContext context) {
    final w = widget, c = w.controller;
    final schema = w.schema;
    final hasChildren = getHasChildren(schema);
    final type = getFieldType(schema);
    final key = w.path.join('.');
    final hovering = c.hoveringProperty == key;
    final description = jsStr(schema['description']);
    final card = hovering && w.depth > 0
        ? EditCard(
            key: ValueKey('edit-$key'),
            fields: (
              name: w.name,
              type: type,
              required: w.required,
              description: description,
              enumValues: schema['enum'] is List ? jsList(schema['enum']) : null,
            ),
            path: w.path,
            parentPath: w.parentPath ?? const [],
            depth: w.depth,
            controller: c,
          )
        : SchemaCard(name: w.name, type: type, required: w.required, description: description);
    final children = <Widget>[];
    if (_expanded && hasChildren && w.depth < jsonSchemaMaxDepth) {
      final container = schema['type'] == 'object' ? schema : jsMap(schema['items']);
      final required = jsList(container['required']);
      final via = schema['type'] == 'object' ? const ['properties'] : const ['items', 'properties'];
      for (final e in jsMap(container['properties']).entries) {
        children.add(
          SchemaNode(
            key: ValueKey('node-$key.${e.key}'),
            name: e.key,
            schema: jsMap(e.value),
            required: required.contains(e.key),
            path: [...w.path, ...via, e.key],
            parentPath: w.path,
            depth: w.depth + 1,
            readOnly: w.readOnly,
            controller: c,
          ),
        );
      }
    }
    return Stack(
      children: [
        // The guide line below the card (`absolute w-5 justify-center`, `top-7` / `top-12` with a description).
        Positioned(
          left: 20.0 * w.depth,
          top: description != null && description.isNotEmpty ? 48 : 28,
          bottom: 0,
          width: 20,
          child: Center(
            child: Container(width: 1, color: hovering ? DifyColors.dividerDeep : DifyColors.dividerSubtle),
          ),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsets.only(left: 20.0 * w.depth),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  MouseRegion(
                    onEnter: (_) => _setHovering(key),
                    onExit: (_) => _setHovering(null),
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onTap: w.depth > 0 && !hovering ? () => _setHovering(key) : null,
                      child: card,
                    ),
                  ),
                  if (w.depth > 0 && hasChildren)
                    Positioned(
                      left: -20,
                      top: 0,
                      child: Container(
                        width: 20,
                        height: 28,
                        color: DifyColors.backgroundSectionBurn,
                        alignment: Alignment.center,
                        child: DifyPressable(
                          semanticLabel: w.name,
                          onPressed: () => setState(() => _expanded = !_expanded),
                          builder: (context, hovered, focused) => RemixIcon(
                            _expanded ? 'arrow-drop-down-line' : 'arrow-drop-right-line',
                            size: 16,
                            color: hovered ? DifyColors.textAccent : DifyColors.textTertiary,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            ...children,
            if (!w.readOnly && w.depth == 0 && !c.isAddingNewField) AddField(controller: c),
          ],
        ),
      ],
    );
  }
}

/// Card: the read view of a field (name, type, REQUIRED, description).
class SchemaCard extends StatelessWidget {
  const SchemaCard({super.key, required this.name, required this.type, required this.required, this.description});
  final String name, type;
  final bool required;
  final String? description;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 24,
          child: Padding(
            padding: const EdgeInsets.only(left: 4, right: 2),
            child: Row(
              spacing: 4,
              children: [
                Flexible(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                    child: DifyText(name, DifyType.systemSmSemibold),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  child: DifyText(type, DifyType.systemXsMedium, color: DifyColors.textTertiary),
                ),
                if (required)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    child: DifyText(
                      _w('nodes.llm.jsonSchema.required'),
                      DifyType.system2xsMediumUppercase,
                      color: DifyColors.textWarning,
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (description != null && description!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
            child: DifyText(description!, DifyType.systemXsRegular, color: DifyColors.textTertiary),
          ),
      ],
    ),
  );
}

/// AddField: "Add Field" (small secondary-accent, `RiAddCircleFill`) in `py-2 pl-5`.
class AddField extends StatelessWidget {
  const AddField({super.key, required this.controller});
  final SchemaEditorController controller;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 8, 0, 8),
    child: Align(
      alignment: Alignment.centerLeft,
      child: DifyButton(
        size: DifyButtonSize.small,
        variant: DifyButtonVariant.secondaryAccent,
        leading: const RemixIcon('add-circle-fill', size: 14),
        onPressed: () {
          controller.setIsAddingNewField(true);
          Timer(const Duration(milliseconds: 100), () => controller.addField(const []));
        },
        child: Text(_w('nodes.llm.jsonSchema.addField')),
      ),
    ),
  );
}

/// A type option (`TypeItem`).
typedef SchemaTypeItem = ({String value, String text});

/// The type options of the edit card (`TYPE_OPTIONS`; at the maximum depth no object types).
const List<SchemaTypeItem> schemaTypeOptions = [
  (value: 'string', text: 'string'),
  (value: 'number', text: 'number'),
  (value: 'boolean', text: 'boolean'),
  (value: 'object', text: 'object'),
  (value: 'array[string]', text: 'array[string]'),
  (value: 'array[number]', text: 'array[number]'),
  (value: 'array[object]', text: 'array[object]'),
];
const List<SchemaTypeItem> schemaMaxDepthTypeOptions = [
  (value: 'string', text: 'string'),
  (value: 'number', text: 'number'),
  (value: 'boolean', text: 'boolean'),
  (value: 'array[string]', text: 'array[string]'),
  (value: 'array[number]', text: 'array[number]'),
];

/// The enum input as values (`handleAdvancedOptionsChange`): whitespace dropped, split by commas, numbers for a
/// number field (NaN dropped); empty gives none.
List<Object?>? parseSchemaEnum(String text, String type) {
  if (text.isEmpty) return null;
  final parts = text.replaceAll(RegExp(r'\s'), '').split(',');
  if (type == 'number') {
    return [
      for (final p in parts) ?(p.isEmpty ? 0 : num.tryParse(p)),
    ];
  }
  return parts;
}

/// EditCard: the in-place editor of a field (name, type, REQUIRED, the required switch, the actions or, while
/// editing in advanced mode, Cancel / Confirm; the description and the enum).
class EditCard extends StatefulWidget {
  const EditCard({
    super.key,
    required this.fields,
    required this.path,
    required this.parentPath,
    required this.depth,
    required this.controller,
  });

  final SchemaEditData fields;
  final List<String> path, parentPath;
  final int depth;
  final SchemaEditorController controller;

  @override
  State<EditCard> createState() => _EditCardState();
}

class _EditCardState extends State<EditCard> {
  late SchemaEditData _current = widget.fields;
  SchemaEditData? _backup;
  late final _name = TextEditingController(text: _current.name);
  late final _description = TextEditingController(text: _current.description ?? '');
  late final _enum = TextEditingController(text: _enumText(_current));
  final _nameFocus = FocusNode(), _descriptionFocus = FocusNode(), _enumFocus = FocusNode();
  bool _blurWithActions = false;
  late int _restoreTick = widget.controller.restoreNameTick;

  SchemaEditorController get _ctl => widget.controller;
  bool get _isAdvancedEditing => _ctl.advancedEditing || _ctl.isAddingNewField;

  static String _enumText(SchemaEditData f) =>
      f.type == 'string' || f.type == 'number' ? (f.enumValues ?? const []).map(jsKey).join(', ') : '';

  SchemaEditData _with({
    String? name,
    String? type,
    bool? required,
    String? description,
    List<Object?>? enumValues,
    bool clearEnum = false,
  }) => (
    name: name ?? _current.name,
    type: type ?? _current.type,
    required: required ?? _current.required,
    description: description ?? _current.description,
    enumValues: clearEnum ? null : (enumValues ?? _current.enumValues),
  );

  @override
  void initState() {
    super.initState();
    _ctl.addListener(_onController);
    _nameFocus.addListener(() {
      if (!_nameFocus.hasFocus && !_isAdvancedEditing) {
        _ctl.propertyNameChange(widget.parentPath, widget.fields, _current);
      }
    });
    _descriptionFocus.addListener(() {
      if (!_descriptionFocus.hasFocus && !_isAdvancedEditing) {
        _ctl.propertyOptionsChange(widget.path, description: _current.description, enumValues: _current.enumValues);
      }
    });
    _enumFocus.addListener(() {
      if (!_enumFocus.hasFocus) _onEnum(_enum.text);
    });
  }

  void _onController() {
    if (_ctl.restoreNameTick != _restoreTick) {
      _restoreTick = _ctl.restoreNameTick;
      setState(() {
        _current = _with(name: widget.fields.name);
        _name.text = widget.fields.name;
      });
    }
  }

  @override
  void dispose() {
    _ctl.removeListener(_onController);
    // useUnmount: a card left without its actions commits its edits.
    if (!_isAdvancedEditing && !_blurWithActions) {
      final c = _ctl, parent = widget.parentPath, fields = widget.fields, current = _current;
      scheduleMicrotask(() => c.fieldChange(parent, fields, current));
    }
    _name.dispose();
    _description.dispose();
    _enum.dispose();
    _nameFocus.dispose();
    _descriptionFocus.dispose();
    _enumFocus.dispose();
    super.dispose();
  }

  void _onType(String type) {
    setState(() => _current = _with(type: type));
    if (_isAdvancedEditing) return;
    _ctl.propertyTypeChange(widget.path, widget.fields, type);
  }

  void _toggleRequired() {
    setState(() => _current = _with(required: !_current.required));
    if (_isAdvancedEditing) return;
    _ctl.propertyRequiredToggle(widget.parentPath, _current);
  }

  void _onEnum(String text) {
    final values = parseSchemaEnum(text, _current.type);
    setState(() => _current = _with(enumValues: values, clearEnum: values == null));
    if (_isAdvancedEditing) return;
    _ctl.propertyOptionsChange(widget.path, description: _current.description, enumValues: values);
  }

  void _cancel() {
    if (_ctl.isAddingNewField) {
      _blurWithActions = true;
      _ctl.restoreSchema();
      _ctl.setIsAddingNewField(false);
      return;
    }
    final b = _backup;
    if (b != null) {
      setState(() {
        _current = b;
        _name.text = b.name;
        _description.text = b.description ?? '';
        _enum.text = _enumText(b);
        _backup = null;
      });
    }
    _ctl.setAdvancedEditing(false);
  }

  void _confirm() => _ctl.fieldChange(widget.parentPath, widget.fields, _current);

  @override
  Widget build(BuildContext context) {
    final maxDepth = widget.depth == jsonSchemaMaxDepth;
    final disableAdd = maxDepth || (_current.type != 'object' && _current.type != 'array[object]');
    final hasAdvanced = _current.type == 'string' || _current.type == 'number';
    final advanced = _isAdvancedEditing;
    final confirmDisabled = _current.name.isEmpty;
    Widget card = Container(
      padding: const EdgeInsets.symmetric(vertical: 2),
      decoration: BoxDecoration(
        color: DifyColors.componentsPanelBg,
        borderRadius: BorderRadius.circular(DifyRadius.lg),
        boxShadow: DifyShadows.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 24,
            child: Padding(
              padding: const EdgeInsets.only(left: 4, right: 2),
              child: Row(
                children: [
                  Expanded(
                    child: Row(
                      spacing: 4,
                      children: [
                        _AutoWidthInput(
                          controller: _name,
                          focusNode: _nameFocus,
                          placeholder: _w('nodes.llm.jsonSchema.fieldNamePlaceholder'),
                          onChanged: (v) => setState(() => _current = _with(name: v.trim())),
                        ),
                        SchemaTypeSelector(
                          currentValue: _current.type,
                          items: maxDepth ? schemaMaxDepthTypeOptions : schemaTypeOptions,
                          onSelect: (item) => _onType(item.value),
                        ),
                        if (_current.required)
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                            child: DifyText(
                              _w('nodes.llm.jsonSchema.required'),
                              DifyType.system2xsMediumUppercase,
                              color: DifyColors.textWarning,
                            ),
                          ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                    decoration: BoxDecoration(
                      color: DifyColors.backgroundDefaultLighter,
                      borderRadius: BorderRadius.circular(5),
                      border: Border.all(color: DifyColors.dividerSubtle),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      spacing: 4,
                      children: [
                        DifyText(
                          _w('nodes.llm.jsonSchema.required'),
                          DifyType.system2xsMediumUppercase,
                          color: DifyColors.textSecondary,
                        ),
                        DifySwitch(
                          size: DifySwitchSize.xs,
                          checked: _current.required,
                          semanticLabel: _w('nodes.llm.jsonSchema.required'),
                          onCheckedChange: (_) => _toggleRequired(),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    width: 1,
                    height: 12,
                    margin: const EdgeInsets.symmetric(horizontal: 8),
                    color: DifyColors.dividerRegular,
                  ),
                  if (advanced)
                    AdvancedActions(confirmDisabled: confirmDisabled, onCancel: _cancel, onConfirm: _confirm)
                  else
                    Row(
                      spacing: 2,
                      children: [
                        DifyTooltip(
                          content: Text(_w('nodes.llm.jsonSchema.addChildField')),
                          child: DifyIconButton(
                            label: _w('nodes.llm.jsonSchema.addChildField'),
                            disabled: disableAdd,
                            icon: const RemixIcon('add-circle-line', size: 16),
                            onPressed: () {
                              _blurWithActions = true;
                              _ctl.addField(widget.path);
                            },
                          ),
                        ),
                        DifyTooltip(
                          content: Text(_c('operation.edit')),
                          child: DifyIconButton(
                            label: _c('operation.edit'),
                            icon: const RemixIcon('edit-line', size: 16),
                            onPressed: () {
                              _backup = _current;
                              _ctl.setAdvancedEditing(true);
                            },
                          ),
                        ),
                        DifyTooltip(
                          content: Text(_c('operation.remove')),
                          child: DifyIconButton(
                            label: _c('operation.remove'),
                            tone: DifyButtonTone.destructive,
                            icon: const RemixIcon('delete-bin-line', size: 16),
                            onPressed: () {
                              _blurWithActions = true;
                              _ctl.propertyDelete(widget.parentPath, _current);
                            },
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
          if ((widget.fields.description ?? '').isNotEmpty || advanced)
            Padding(
              padding: advanced ? const EdgeInsets.fromLTRB(8, 4, 8, 8) : const EdgeInsets.fromLTRB(8, 0, 8, 4),
              child: SizedBox(
                height: 16,
                child: EditableText(
                  controller: _description,
                  focusNode: _descriptionFocus,
                  style: difyStyle(DifyType.systemXsRegular, DifyColors.textTertiary),
                  cursorColor: const Color(0xFF295EFF),
                  backgroundCursorColor: DifyColors.textTertiary,
                  onChanged: (v) => setState(() => _current = _with(description: v)),
                  onSubmitted: (_) => _descriptionFocus.unfocus(),
                ),
              ),
            ),
          if (advanced && hasAdvanced)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: DifyColors.dividerSubtle)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 4,
                children: [
                  Row(
                    spacing: 8,
                    children: [
                      DifyText(
                        _w('nodes.llm.jsonSchema.stringValidations'),
                        DifyType.system2xsMediumUppercase,
                        color: DifyColors.textTertiary,
                      ),
                      Expanded(child: Container(height: 1, color: DifyColors.dividerRegular)),
                    ],
                  ),
                  SizedBox(
                    height: 24,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: DifyText(
                        _w('nodes.llm.jsonSchema.enum'),
                        DifyType.systemXsMedium,
                        color: DifyColors.textSecondary,
                      ),
                    ),
                  ),
                  DifyInput(
                    value: _enum.text,
                    semanticLabel: _w('nodes.llm.jsonSchema.enum'),
                    placeholder: 'abcd, 1, 1.5, etc.',
                    focusNode: _enumFocus,
                    onChanged: (v) => _enum.text = v,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
    if (advanced && !confirmDisabled) {
      card = CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.enter, control: true): _confirm,
          const SingleActivator(LogicalKeyboardKey.enter, meta: true): _confirm,
        },
        child: card,
      );
    }
    return card;
  }
}

/// AdvancedActions: Cancel and Confirm (Mod+Enter).
class AdvancedActions extends StatelessWidget {
  const AdvancedActions({super.key, required this.confirmDisabled, required this.onCancel, required this.onConfirm});
  final bool confirmDisabled;
  final VoidCallback onCancel, onConfirm;

  @override
  Widget build(BuildContext context) => Row(
    spacing: 4,
    children: [
      DifyButton(size: DifyButtonSize.small, onPressed: onCancel, child: Text(_c('operation.cancel'))),
      DifyButton(
        size: DifyButtonSize.small,
        variant: DifyButtonVariant.primary,
        disabled: confirmDisabled,
        onPressed: onConfirm,
        trailing: const DifyShortcutKbd(hotkey: 'Mod+Enter', color: DifyKbdColor.white),
        child: Text(_c('operation.confirm')),
      ),
    ],
  );
}

/// AutoWidthInput: an `h-5` input as wide as its text (80 to 300 px), `system-sm-semibold`; Enter blurs.
class _AutoWidthInput extends StatelessWidget {
  const _AutoWidthInput({
    required this.controller,
    required this.focusNode,
    required this.placeholder,
    required this.onChanged,
  });
  final TextEditingController controller;
  final FocusNode focusNode;
  final String placeholder;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final style = difyStyle(DifyType.systemSmSemibold, DifyColors.textPrimary);
    return ValueListenableBuilder(
      valueListenable: controller,
      builder: (context, value, _) {
        final text = value.text.isEmpty ? placeholder : value.text;
        final tp = TextPainter(
          text: TextSpan(text: text, style: style),
          textDirection: TextDirection.ltr,
        )..layout();
        final width = (tp.width + 16).clamp(80.0, 300.0);
        return Container(
          width: width,
          height: 20,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          alignment: Alignment.centerLeft,
          decoration: BoxDecoration(
            color: focusNode.hasFocus ? DifyColors.componentsInputBgActive : null,
            borderRadius: BorderRadius.circular(5),
            border: Border.all(
              color: focusNode.hasFocus ? DifyColors.componentsInputBorderActive : const Color(0x00000000),
            ),
          ),
          child: Stack(
            alignment: Alignment.centerLeft,
            children: [
              if (value.text.isEmpty)
                IgnorePointer(
                  child: Text(placeholder, style: style.copyWith(color: DifyColors.textPlaceholder)),
                ),
              EditableText(
                controller: controller,
                focusNode: focusNode,
                style: style,
                cursorColor: const Color(0xFF295EFF),
                backgroundCursorColor: DifyColors.textTertiary,
                onChanged: onChanged,
                onSubmitted: (_) => focusNode.unfocus(),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// TypeSelector (edit-card/type-selector.tsx): the current type's text as `system-xs-medium text-text-tertiary`, a
/// `w-40` list of [items] with a check on the current one.
class SchemaTypeSelector extends StatelessWidget {
  const SchemaTypeSelector({super.key, required this.currentValue, required this.items, required this.onSelect});
  final String currentValue;
  final List<SchemaTypeItem> items;
  final ValueChanged<SchemaTypeItem> onSelect;

  @override
  Widget build(BuildContext context) {
    final text = items.where((i) => i.value == currentValue).firstOrNull?.text ?? currentValue;
    return DifyDropdownMenu(
      placement: DifyPlacement.bottomStart,
      sideOffset: 4,
      width: 160,
      builder: (context, c) => Semantics(
        expanded: c.isOpen,
        child: DifyPressable(
          semanticLabel: text,
          onPressed: c.toggle,
          builder: (context, hovered, focused) => Container(
            padding: const EdgeInsets.fromLTRB(4, 2, 2, 2),
            decoration: BoxDecoration(
              color: hovered || c.isOpen ? DifyColors.stateBaseHover : null,
              borderRadius: BorderRadius.circular(5),
            ),
            child: DifyText(text, DifyType.systemXsMedium, color: DifyColors.textTertiary),
          ),
        ),
      ),
      children: [
        for (final item in items)
          Semantics(
            selected: item.value == currentValue,
            child: DifyMenuItem(
              semanticLabel: item.text,
              onSelect: () => onSelect(item),
              child: Row(
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: DifyText(item.text, DifyType.systemSmMedium, color: DifyColors.textSecondary),
                    ),
                  ),
                  if (item.value == currentValue) const RemixIcon('check-line', size: 16, color: DifyColors.textAccent),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// The view tabs (TabsList over Visual Editor / JSON Schema): the segmented look, the active one raised; arrow keys
/// move the focus between tabs without activating them (Base UI's `activateOnFocus: false`).
class SchemaViewTabs extends StatefulWidget {
  const SchemaViewTabs({super.key, required this.value, required this.onChange});
  final SchemaView value;
  final bool Function(SchemaView view) onChange;

  @override
  State<SchemaViewTabs> createState() => _SchemaViewTabsState();
}

class _SchemaViewTabsState extends State<SchemaViewTabs> {
  late final _focus = {for (final v in SchemaView.values) v: FocusNode(debugLabel: 'schema tab ${v.name}')};

  static const _tabs = [
    (view: SchemaView.visualEditor, icon: 'timeline-view', text: 'Visual Editor'),
    (view: SchemaView.jsonSchema, icon: 'braces-line', text: 'JSON Schema'),
  ];

  @override
  void dispose() {
    for (final f in _focus.values) {
      f.dispose();
    }
    super.dispose();
  }

  KeyEventResult _onKey(int i, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    final next = k == LogicalKeyboardKey.arrowRight
        ? (i + 1) % _tabs.length
        : k == LogicalKeyboardKey.arrowLeft
        ? (i - 1 + _tabs.length) % _tabs.length
        : null;
    if (next == null) return KeyEventResult.ignored;
    _focus[_tabs[next].view]!.requestFocus();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => Semantics(
    role: SemanticsRole.tabBar,
    label: _w('nodes.llm.jsonSchema.title'),
    explicitChildNodes: true,
    child: Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: DifyColors.componentsSegmentedControlBgNormal,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 1,
        children: [
          for (final (i, t) in _tabs.indexed)
            Semantics(
              role: SemanticsRole.tab,
              selected: t.view == widget.value,
              onTap: () => widget.onChange(t.view),
              child: Focus(
                skipTraversal: true,
                onKeyEvent: (_, e) => _onKey(i, e),
                child: DifyPressable(
                  focusNode: _focus[t.view],
                  semanticLabel: t.text,
                  onPressed: () => widget.onChange(t.view),
                  builder: (context, hovered, focused) {
                    final active = t.view == widget.value;
                    final color = active ? DifyColors.textAccentLightModeOnly : DifyColors.textSecondary;
                    return Container(
                      height: 28,
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: active
                            ? DifyColors.componentsSegmentedControlItemActiveBg
                            : hovered
                            ? DifyColors.stateBaseHover
                            : null,
                        borderRadius: BorderRadius.circular(DifyRadius.lg),
                        border: Border.all(
                          color: active
                              ? DifyColors.componentsSegmentedControlItemActiveBorder
                              : focused
                              ? DifyColors.stateAccentSolid
                              : const Color(0x00000000),
                          width: focused && !active ? 2 : 0.5,
                        ),
                        boxShadow: active ? DifyShadows.xs : null,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        spacing: 2,
                        children: [
                          RemixIcon(t.icon, size: 16, color: color),
                          Padding(
                            padding: const EdgeInsets.all(2),
                            child: DifyText(t.text, DifyType.systemSmMedium, color: color),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
        ],
      ),
    ),
  );
}
