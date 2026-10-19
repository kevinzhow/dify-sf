/// base/form (Dify's tanstack-form forms) as far as the model provider credential modal uses it: the schema types
/// (types.ts), the form state ([FormController], the parts of tanstack's form API Dify relies on), the hooks
/// (useCheckValidated, useGetFormValues, useGetValidators), the secret-input utils (the `[__HIDDEN__]` round trip),
/// BaseForm and BaseField (components/base) and the auth scenario ([AuthForm]). Dify's other field components
/// (useAppForm's TextField, FileTypes, UploadMethod, …) serve its pipeline input-field forms, which dify-sf does not
/// have; dynamic selects need trigger plugins.
library;

import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';

import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';
import '../../open_url.dart';
import '../../workflow/model_catalog.dart' show renderI18nObject;
import '../../workflow_editor/panel_fields/controls.dart';
import '../../workflow_editor/panel_fields/form_controls.dart';
import '../../workflow_editor/panel_fields/selectors.dart';
import '../settings_kit.dart' show SettingsRadioDot;

// ---- types.ts -----------------------------------------------------------------------------------------------------

/// FormTypeEnum.
enum FormTypeEnum {
  textInput('text-input'),
  textNumber('number-input'),
  secretInput('secret-input'),
  select('select'),
  radio('radio'),
  checkbox('checkbox'),
  files('files'),
  file('file'),
  modelSelector('model-selector'),
  toolSelector('tool-selector'),
  multiToolSelector('array[tools]'),
  appSelector('app-selector'),
  dynamicSelect('dynamic-select'),
  boolean('boolean');

  const FormTypeEnum(this.value);
  final String value;

  static FormTypeEnum? of(Object? value) => values.where((t) => t.value == value).firstOrNull;
}

/// FormItemValidateStatusEnum.
enum FormItemValidateStatusEnum { success, warning, error, validating }

/// FormShowOnObject: shown while the form's [variable] equals [value].
typedef FormShowOn = ({String variable, String value});

/// FormOption: [label] is a string or an I18n object.
class FormOption {
  const FormOption({required this.label, required this.value, this.showOn = const [], this.icon});

  factory FormOption.fromJson(Object? json) {
    final m = json is Map ? json : const {};
    return FormOption(label: m['label'], value: '${m['value'] ?? ''}', showOn: _showOn(m['show_on']), icon: m['icon']);
  }

  final Object? label;
  final String value;
  final List<FormShowOn> showOn;
  final Object? icon;
}

List<FormShowOn> _showOn(Object? v) => [
  if (v is List)
    for (final c in v)
      if (c is Map) (variable: '${c['variable'] ?? ''}', value: '${c['value'] ?? ''}'),
];

/// A validator (tanstack's `({value}) => error | undefined`).
typedef FieldValidator = String? Function(Object? value);

/// The validators of a field, by when they run.
class FieldValidators {
  const FieldValidators({this.onMount, this.onChange, this.onBlur});
  final FieldValidator? onMount, onChange, onBlur;
}

/// FormSchema. [label], [description], [tooltip], [help] and [placeholder] are strings, I18n objects or (label only)
/// widgets.
class FormSchema {
  const FormSchema({
    required this.type,
    required this.name,
    this.label,
    this.required = false,
    this.multiple = false,
    this.defaultValue,
    this.description,
    this.tooltip,
    this.showOn = const [],
    this.url,
    this.help,
    this.placeholder,
    this.options,
    this.validators,
    this.showRadioUI = false,
    this.disabled = false,
    this.showCopy = false,
  });

  /// A credential form schema of a provider (`credential_form_schemas[]`: `variable`, `label`, `type`, `required`,
  /// `default`, `options`, `placeholder`, `show_on`, `help`, `url`, `tooltip`), named by its variable.
  factory FormSchema.fromCredentialSchema(Map<String, Object?> json, {bool showRadioUI = false, Object? description}) {
    final type = FormTypeEnum.of(json['type']) ?? FormTypeEnum.textInput;
    final options = json['options'];
    return FormSchema(
      type: type,
      name: '${json['variable'] ?? json['name'] ?? ''}',
      label: json['label'],
      required: json['required'] == true,
      defaultValue: json['default'],
      description: description ?? json['description'],
      tooltip: json['tooltip'],
      showOn: _showOn(json['show_on']),
      url: json['url'] is String ? json['url']! as String : null,
      help: json['help'],
      placeholder: json['placeholder'],
      options: options is List ? [for (final o in options) FormOption.fromJson(o)] : null,
      showRadioUI: showRadioUI,
    );
  }

  final FormTypeEnum type;
  final String name;
  final Object? label;
  final bool required, multiple;
  final Object? defaultValue;
  final Object? description, tooltip, help, placeholder;
  final List<FormShowOn> showOn;
  final String? url;
  final List<FormOption>? options;
  final FieldValidators? validators;
  final bool showRadioUI, disabled, showCopy;

  FormSchema copyWith({Object? description, bool? showRadioUI, String? name}) => FormSchema(
    type: type,
    name: name ?? this.name,
    label: label,
    required: required,
    multiple: multiple,
    defaultValue: defaultValue,
    description: description ?? this.description,
    tooltip: tooltip,
    showOn: showOn,
    url: url,
    help: help,
    placeholder: placeholder,
    options: options,
    validators: validators,
    showRadioUI: showRadioUI ?? this.showRadioUI,
    disabled: disabled,
    showCopy: showCopy,
  );
}

/// GetValuesOptions.
typedef GetValuesOptions = ({bool needCheckValidatedValues, bool needTransformWhenSecretFieldIsPristine});

/// FieldState: what setFields gives a field (external validation).
class FieldState {
  const FieldState({this.validateStatus, this.help, this.errors, this.warnings});
  final FormItemValidateStatusEnum? validateStatus;
  final String? help;
  final List<String>? errors, warnings;
}

/// SetFieldsParam.
class SetFieldsParam extends FieldState {
  const SetFieldsParam({
    required this.name,
    this.value,
    this.hasValue = false,
    super.validateStatus,
    super.help,
    super.errors,
    super.warnings,
  });

  /// A field whose value changes to [value] (also null).
  const SetFieldsParam.value(this.name, this.value, {super.errors, super.warnings, super.validateStatus})
    : hasValue = true,
      super(help: null);

  final String name;
  final Object? value;
  final bool hasValue;
}

// ---- the form state (tanstack's form API) ------------------------------------------------------------------------

/// A field's meta: touched (changed, blurred or marked), pristine (its value never changed) and its errors.
class FieldMeta {
  const FieldMeta({this.isTouched = false, this.isPristine = true, this.errors = const []});
  final bool isTouched, isPristine;
  final List<String> errors;

  FieldMeta copyWith({bool? isTouched, bool? isPristine, List<String>? errors}) => FieldMeta(
    isTouched: isTouched ?? this.isTouched,
    isPristine: isPristine ?? this.isPristine,
    errors: errors ?? this.errors,
  );
}

/// The parts of tanstack's form API the hooks read: the values, every field's errors and a field's meta.
abstract interface class FormApi {
  /// `form.store.state.values` (null: none).
  Map<String, Object?>? get values;

  /// `form.getAllErrors().fields`: the errors of each field that has some; null: no error information.
  Map<String, List<String>>? getAllErrors();

  FieldMeta? getFieldMeta(String name);
}

/// The form's values and its fields' meta (useForm). Fields run their validators on mount, change and blur; the
/// latest validation's error is the field's.
class FormController extends ChangeNotifier implements FormApi {
  FormController({Map<String, Object?> defaultValues = const {}}) : _values = {...defaultValues};

  final Map<String, Object?> _values;
  final _meta = <String, FieldMeta>{};
  final _validators = <String, FieldValidators?>{};

  @override
  Map<String, Object?> get values => Map.unmodifiable(_values);

  Object? value(String name) => _values[name];

  @override
  FieldMeta? getFieldMeta(String name) => _meta[name];

  @override
  Map<String, List<String>> getAllErrors() => {
    for (final e in _meta.entries)
      if (e.value.errors.isNotEmpty) e.key: e.value.errors,
  };

  /// A field mounted with [validators]: its onMount validator runs (once per mount).
  void mountField(String name, FieldValidators? validators) {
    _validators[name] = validators;
    final error = validators?.onMount?.call(_values[name]);
    _meta[name] = (_meta[name] ?? const FieldMeta()).copyWith(errors: [?error]);
  }

  /// `field.handleChange`: the user changed the value.
  void handleChange(String name, Object? value) => setFieldValue(name, value);

  /// `form.setFieldValue`: the value changes, the field is touched and no longer pristine, onChange validates.
  void setFieldValue(String name, Object? value) {
    _values[name] = value;
    final error = _validators[name]?.onChange?.call(value);
    _meta[name] = (_meta[name] ?? const FieldMeta()).copyWith(isTouched: true, isPristine: false, errors: [?error]);
    notifyListeners();
  }

  /// `field.handleBlur`: onBlur validates (when the field has an onBlur validator).
  void handleBlur(String name) {
    final onBlur = _validators[name]?.onBlur;
    if (onBlur == null) return;
    final error = onBlur(_values[name]);
    _meta[name] = (_meta[name] ?? const FieldMeta()).copyWith(isTouched: true, errors: [?error]);
    notifyListeners();
  }

  /// `form.setFieldMeta`.
  void setFieldMeta(String name, FieldMeta Function(FieldMeta meta) update) {
    _meta[name] = update(_meta[name] ?? const FieldMeta());
    notifyListeners();
  }
}

// ---- hooks ---------------------------------------------------------------------------------------------------------

/// Whether [schema] is shown for [values] (every show_on condition holds).
bool isSchemaShown(List<FormShowOn> showOn, Map<String, Object?>? values) =>
    showOn.every((c) => values?[c.variable] == c.value);

/// useCheckValidated's `checkValidated`: the first error of a shown field (schema order, then other fields) is
/// toasted and its field reported to [onInvalidField]; false when there was one.
bool checkValidated(
  FormApi form,
  List<FormSchema> schemas, {
  void Function(String name)? onInvalidField,
  void Function(String message)? toastError,
}) {
  final all = form.getAllErrors();
  if (all == null) return true;
  final values = form.values ?? const {};
  final names = {...schemas.map((s) => s.name), ...all.keys};
  String? first;
  final errors = <String>[];
  for (final name in names) {
    final schema = schemas.where((s) => s.name == name).firstOrNull;
    final shown = isSchemaShown(schema?.showOn ?? const [], values);
    final e = shown ? all[name] ?? const <String>[] : const <String>[];
    if (e.isNotEmpty) first ??= name;
    errors.addAll(e);
  }
  if (errors.isEmpty) return true;
  (toastError ?? toast.error)(errors.first);
  if (first != null) onInvalidField?.call(first);
  return false;
}

/// useGetFormValues's `getFormValues`: the values (after [checkValidated] unless not asked, with pristine secrets
/// replaced by `[__HIDDEN__]` when asked), or `{}` and false when a field is invalid.
({Map<String, Object?> values, bool isCheckValidated}) formValuesOf(
  FormApi form,
  List<FormSchema> schemas, {
  bool needCheckValidatedValues = true,
  bool needTransformWhenSecretFieldIsPristine = false,
  void Function(String name)? onInvalidField,
  bool Function()? check,
  Map<String, Object?> Function(List<FormSchema> schemas, FormApi form)? transform,
}) {
  final values = form.values ?? const <String, Object?>{};
  if (!needCheckValidatedValues) return (values: values, isCheckValidated: true);
  final ok = check != null ? check() : checkValidated(form, schemas, onInvalidField: onInvalidField);
  if (!ok) return (values: const {}, isCheckValidated: false);
  return (
    values: needTransformWhenSecretFieldIsPristine
        ? (transform ?? getTransformedValuesWhenSecretInputPristine)(schemas, form)
        : values,
    isCheckValidated: true,
  );
}

/// The text of a label / description / placeholder: a string as is, an I18n object in [language], else ''.
String translatedContent(Object? content, [String? language]) {
  if (content is String) return content;
  if (content is Map) {
    return renderI18nObject({
      for (final e in content.entries) '${e.key}': e.value?.toString(),
    }, language ?? _language());
  }
  return '';
}

String _language() {
  final t = DifyI18n.current;
  return t is DifyI18n ? t.language.replaceFirst('-', '_') : 'en_US';
}

/// useGetValidators's `getValidators`: the schema's validators, else for a required field "<label> is required" on
/// mount, change and blur (the field's name when the label is no text; blur uses the label alone).
FieldValidators? getValidators(FormSchema schema) {
  if (schema.validators != null || !schema.required) return schema.validators;
  final label = schema.label is Widget ? '' : translatedContent(schema.label);
  String required(String field) => DifyI18n.tr('common', 'errorMsg.fieldRequired', {'field': field});
  bool empty(Object? v) => v == null || v == '' || v == false || v == 0;
  return FieldValidators(
    onMount: (v) => empty(v) ? required(label.isEmpty ? schema.name : label) : null,
    onChange: (v) => empty(v) ? required(label.isEmpty ? schema.name : label) : null,
    onBlur: (v) => empty(v) ? required(label) : null,
  );
}

// ---- utils/secret-input --------------------------------------------------------------------------------------------

/// The value Dify sends for a secret the user did not touch (the server keeps the stored one).
const hiddenSecretValue = '[__HIDDEN__]';

/// transformFormSchemasSecretInput: [names] with a truthy value become `[__HIDDEN__]`.
Map<String, Object?> transformFormSchemasSecretInput(List<String> names, Map<String, Object?> values) {
  final out = {...values};
  for (final name in names) {
    final v = out[name];
    if (v != null && v != '' && v != 0 && v != false) out[name] = hiddenSecretValue;
  }
  return out;
}

/// getTransformedValuesWhenSecretInputPristine: the values with every pristine secret input hidden.
Map<String, Object?> getTransformedValuesWhenSecretInputPristine(List<FormSchema> schemas, FormApi form) {
  final values = form.values ?? const <String, Object?>{};
  final pristine = [
    for (final s in schemas)
      if (s.type == FormTypeEnum.secretInput && (form.getFieldMeta(s.name)?.isPristine ?? false)) s.name,
  ];
  return transformFormSchemasSecretInput(pristine, values);
}

// ---- BaseForm ------------------------------------------------------------------------------------------------------

/// The style of a form scenario: the label row, the gap between fields, the input's alignment.
class BaseFormStyle {
  const BaseFormStyle({this.gap = 0, this.labelHeight, this.labelGap = 0, this.labelStyle});

  /// `space-y-4` and the like.
  final double gap;

  /// The label row (`h-6 flex items-center mb-1 system-sm-medium text-text-secondary` in the auth scenario).
  final double? labelHeight;
  final double labelGap;
  final TextStyle? labelStyle;

  /// form-scenarios/auth.
  static const auth = BaseFormStyle(gap: 16, labelHeight: 24, labelGap: 4);
}

/// BaseForm: the fields of [formSchemas] shown by their show_on conditions, over a [FormController] (its own, from
/// [defaultValues] or the schemas' defaults, unless [form] is given). The ref API is the state's ([BaseFormState]):
/// getForm, getFormValues, setFields. Nothing without schemas.
class BaseForm extends StatefulWidget {
  const BaseForm({
    super.key,
    this.formSchemas = const [],
    this.defaultValues,
    this.form,
    this.disabled = false,
    this.onChange,
    this.onSubmit,
    this.style = const BaseFormStyle(),
  });

  final List<FormSchema> formSchemas;
  final Map<String, Object?>? defaultValues;

  /// `formFromProps`.
  final FormController? form;
  final bool disabled;
  final void Function(String field, Object? value)? onChange;

  /// Enter in a text field submits the form.
  final VoidCallback? onSubmit;
  final BaseFormStyle style;

  @override
  State<BaseForm> createState() => BaseFormState();
}

class BaseFormState extends State<BaseForm> {
  FormController? _own;
  final _focus = <String, FocusNode>{};
  Map<String, FieldState> _fieldStates = const {};

  FormController get form => widget.form ?? _own!;

  @override
  void initState() {
    super.initState();
    if (widget.form == null) {
      final defaults =
          widget.defaultValues ??
          {
            for (final s in widget.formSchemas)
              if (s.defaultValue != null && s.defaultValue != '' && s.defaultValue != false) s.name: s.defaultValue,
          };
      _own = FormController(defaultValues: defaults);
    }
  }

  @override
  void dispose() {
    _own?.dispose();
    for (final f in _focus.values) {
      f.dispose();
    }
    super.dispose();
  }

  FocusNode _focusOf(String name) => _focus[name] ??= FocusNode(debugLabel: 'form field $name');

  /// `getForm()`.
  FormController getForm() => form;

  /// `focusInvalidField`: marks the field touched (its error shows) and focuses its control.
  void _focusInvalidField(String name) {
    form.setFieldMeta(name, (m) => m.copyWith(isTouched: true));
    _focus[name]?.requestFocus();
  }

  /// `getFormValues(options)`.
  ({Map<String, Object?> values, bool isCheckValidated}) getFormValues({
    bool needCheckValidatedValues = true,
    bool needTransformWhenSecretFieldIsPristine = false,
  }) => formValuesOf(
    form,
    widget.formSchemas,
    needCheckValidatedValues: needCheckValidatedValues,
    needTransformWhenSecretFieldIsPristine: needTransformWhenSecretFieldIsPristine,
    onInvalidField: _focusInvalidField,
  );

  /// `setFields(fields)`: values and external validation states.
  void setFields(List<SetFieldsParam> fields) {
    final states = {..._fieldStates};
    for (final f in fields) {
      if (f.hasValue || f.value != null) form.setFieldValue(f.name, f.value);
      var status = f.validateStatus;
      if (status == null) {
        if (f.errors?.isNotEmpty ?? false) {
          status = FormItemValidateStatusEnum.error;
        } else if (f.warnings?.isNotEmpty ?? false) {
          status = FormItemValidateStatusEnum.warning;
        }
      }
      states[f.name] = FieldState(validateStatus: status, help: f.help, errors: f.errors, warnings: f.warnings);
    }
    setState(() => _fieldStates = states);
  }

  @override
  Widget build(BuildContext context) {
    final schemas = widget.formSchemas;
    if (schemas.isEmpty) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: form,
      builder: (context, _) {
        final values = form.values;
        final shown = [
          for (final s in schemas)
            if (isSchemaShown(s.showOn, values)) s,
        ];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (i, s) in shown.indexed)
              Padding(
                key: ValueKey('form-field-${s.name}'),
                padding: EdgeInsets.only(top: i == 0 ? 0 : widget.style.gap),
                child: _MountedField(
                  form: form,
                  name: s.name,
                  validators: getValidators(s),
                  child: BaseField(
                    form: form,
                    formSchema: s,
                    focusNode: _focusOf(s.name),
                    disabled: widget.disabled,
                    onChange: widget.onChange,
                    onSubmit: widget.onSubmit,
                    fieldState: _fieldStates[s.name],
                    style: widget.style,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// `form.Field`: registers the field's validators while it is shown (onMount runs when it appears).
class _MountedField extends StatefulWidget {
  const _MountedField({required this.form, required this.name, required this.validators, required this.child});
  final FormController form;
  final String name;
  final FieldValidators? validators;
  final Widget child;

  @override
  State<_MountedField> createState() => _MountedFieldState();
}

class _MountedFieldState extends State<_MountedField> {
  @override
  void initState() {
    super.initState();
    widget.form.mountField(widget.name, widget.validators);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// form-scenarios/auth: BaseForm with `space-y-4` and the `h-6 mb-1 system-sm-medium` labels.
class AuthForm extends StatelessWidget {
  const AuthForm({
    super.key,
    this.formKey,
    this.formSchemas = const [],
    this.defaultValues,
    this.form,
    this.disabled = false,
    this.onChange,
    this.onSubmit,
  });

  /// The inner form's key: its state is the ref API (getFormValues, setFields, getForm).
  final GlobalKey<BaseFormState>? formKey;
  final List<FormSchema> formSchemas;
  final Map<String, Object?>? defaultValues;
  final FormController? form;
  final bool disabled;
  final void Function(String field, Object? value)? onChange;
  final VoidCallback? onSubmit;

  @override
  Widget build(BuildContext context) => BaseForm(
    key: formKey,
    formSchemas: formSchemas,
    defaultValues: defaultValues,
    form: form,
    disabled: disabled,
    onChange: onChange,
    onSubmit: onSubmit,
    style: BaseFormStyle.auth,
  );
}

// ---- BaseField -----------------------------------------------------------------------------------------------------

/// BaseField: the label row (label, `*` when required, the tooltip's Infotip), the control by the schema's type, the
/// validation message (external errors first, else the field's own once touched; warnings), the description and the
/// help link.
class BaseField extends StatelessWidget {
  const BaseField({
    super.key,
    required this.form,
    required this.formSchema,
    this.focusNode,
    this.disabled = false,
    this.onChange,
    this.onSubmit,
    this.fieldState,
    this.style = const BaseFormStyle(),
  });

  final FormController form;
  final FormSchema formSchema;
  final FocusNode? focusNode;
  final bool disabled;
  final void Function(String field, Object? value)? onChange;
  final VoidCallback? onSubmit;
  final FieldState? fieldState;
  final BaseFormStyle style;

  void _change(Object? value) {
    form.handleChange(formSchema.name, value);
    onChange?.call(formSchema.name, value);
  }

  @override
  Widget build(BuildContext context) {
    final s = formSchema;
    final isDisabled = disabled || s.disabled;
    final meta = form.getFieldMeta(s.name);
    final external = fieldState?.errors;
    final errors = (external?.isNotEmpty ?? false) ? external! : (meta?.isTouched ?? false ? meta!.errors : const []);
    final status = fieldState?.validateStatus ?? (errors.isNotEmpty ? FormItemValidateStatusEnum.error : null);
    final messages = status == FormItemValidateStatusEnum.error
        ? errors
        : status == FormItemValidateStatusEnum.warning
        ? fieldState?.warnings ?? const []
        : const <String>[];
    final invalid = status == FormItemValidateStatusEnum.error;
    final label = s.label is Widget ? null : translatedContent(s.label);
    final shownLabel = label == null || label.isEmpty ? s.name : label;
    var placeholder = translatedContent(s.placeholder);
    if (placeholder.isEmpty) placeholder = DifyI18n.tr('common', 'placeholder.input');
    final tooltip = translatedContent(s.tooltip);
    final description = translatedContent(s.description);
    final help = translatedContent(s.help);
    final value = form.value(s.name);
    final watched = form.values;
    final options = [
      for (final o in s.options ?? const <FormOption>[])
        if (isSchemaShown(o.showOn, watched)) (value: o.value, label: translatedContent(o.label)),
    ];
    final describedBy = [if (description.isNotEmpty) description, ...messages].join(' ');

    final labelRow = Container(
      height: style.labelHeight,
      margin: EdgeInsets.only(bottom: style.labelGap),
      alignment: AlignmentDirectional.centerStart,
      child: DefaultTextStyle.merge(
        style: style.labelStyle ?? difyTextStyle(DifyType.systemSmMedium, DifyColors.textSecondary),
        child: Row(
          children: [
            Flexible(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => focusNode?.requestFocus(),
                child: s.label is Widget ? s.label! as Widget : ExcludeSemantics(child: Text(shownLabel)),
              ),
            ),
            if (s.required && s.label is! Widget)
              const Padding(
                padding: EdgeInsets.only(left: 4),
                child: ExcludeSemantics(
                  child: Text('*', style: TextStyle(color: DifyColors.textDestructiveSecondary)),
                ),
              ),
            if (tooltip.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 2),
                child: Infotip(label: tooltip, width: 200, content: Text(tooltip)),
              ),
          ],
        ),
      ),
    );

    Widget? control;
    switch (s.type) {
      case FormTypeEnum.textInput || FormTypeEnum.secretInput || FormTypeEnum.textNumber:
        control = Focus(
          canRequestFocus: false,
          skipTraversal: true,
          onFocusChange: (focused) => focused ? null : form.handleBlur(s.name),
          child: DifyInput(
            key: ValueKey('form-input-${s.name}'),
            value: value == null ? '' : '$value',
            focusNode: focusNode,
            onChanged: _change,
            onSubmitted: onSubmit == null ? null : (_) => onSubmit!(),
            disabled: isDisabled,
            invalid: invalid,
            placeholder: placeholder,
            obscureText: s.type == FormTypeEnum.secretInput,
            autofillHints: s.type == FormTypeEnum.secretInput ? const [AutofillHints.newPassword] : null,
            keyboardType: s.type == FormTypeEnum.textNumber ? TextInputType.number : null,
            semanticLabel: shownLabel,
          ),
        );
      case FormTypeEnum.select || FormTypeEnum.dynamicSelect:
        final selected = options.any((o) => o.value == value) ? value as String? : null;
        control = Focus(
          focusNode: focusNode,
          child: DifySelect<String>(
            key: ValueKey('form-select-${s.name}'),
            value: selected,
            options: options,
            placeholder: placeholder,
            disabled: isDisabled,
            paddingX: 8,
            semanticLabel: shownLabel,
            onChanged: _change,
          ),
        );
      case FormTypeEnum.radio:
        final vertical = options.length >= 3;
        final items = [
          for (final o in options)
            _RadioCard(
              key: ValueKey('form-radio-${s.name}-${o.value}'),
              label: o.label,
              selected: value == o.value,
              disabled: isDisabled,
              showRadio: s.showRadioUI,
              onTap: () => _change(o.value),
            ),
        ];
        control = Semantics(
          container: true,
          explicitChildNodes: true,
          label: shownLabel,
          hint: describedBy.isEmpty ? null : describedBy,
          validationResult: invalid ? SemanticsValidationResult.invalid : SemanticsValidationResult.none,
          child: Focus(
            focusNode: focusNode,
            child: vertical
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final (i, w) in items.indexed)
                        Padding(
                          padding: EdgeInsets.only(top: i == 0 ? 0 : 8),
                          child: w,
                        ),
                    ],
                  )
                : Row(
                    children: [
                      for (final (i, w) in items.indexed) ...[
                        if (i > 0) const SizedBox(width: 8),
                        Expanded(child: w),
                      ],
                    ],
                  ),
          ),
        );
      case FormTypeEnum.checkbox:
        control = Semantics(
          container: true,
          explicitChildNodes: true,
          label: shownLabel,
          hint: describedBy.isEmpty ? null : describedBy,
          validationResult: invalid ? SemanticsValidationResult.invalid : SemanticsValidationResult.none,
          child: CheckboxList(
            title: s.name,
            options: options,
            value: [
              if (value is List)
                for (final v in value) '$v',
            ],
            maxHeight: 200,
            disabled: isDisabled,
            onChange: (v) => form.handleChange(s.name, v),
          ),
        );
      case FormTypeEnum.boolean:
        Widget item(bool v, String text) => DifyPressable(
          key: ValueKey('form-boolean-${s.name}-$v'),
          semanticLabel: text,
          onPressed: isDisabled ? null : () => form.handleChange(s.name, v),
          builder: (context, hovered, _) => Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SettingsRadioDot(checked: value == v, hovered: hovered, disabled: isDisabled),
              const SizedBox(width: 6),
              Text(text, style: difyTextStyle(DifyType.systemSmRegular, DifyColors.textSecondary)),
            ],
          ),
        );
        control = Semantics(
          container: true,
          label: shownLabel,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [item(true, 'True'), const SizedBox(width: 12), item(false, 'False')],
          ),
        );
      default:
        control = null;
    }

    final message = messages.isEmpty
        ? null
        : Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(
                messages.join(' '),
                key: ValueKey('form-message-${s.name}'),
                semanticsLabel: '',
                style: difyTextStyle(
                  DifyType.systemXsRegular,
                  status == FormItemValidateStatusEnum.warning ? DifyColors.textWarning : DifyColors.textDestructive,
                ),
              ),
            ),
          );

    // The control is named by the label and described by the description and the message (aria-describedby).
    if (control != null &&
        (s.type == FormTypeEnum.textInput ||
            s.type == FormTypeEnum.secretInput ||
            s.type == FormTypeEnum.textNumber ||
            s.type == FormTypeEnum.select ||
            s.type == FormTypeEnum.dynamicSelect)) {
      control = MergeSemantics(
        child: Semantics(
          hint: describedBy.isEmpty ? null : describedBy,
          validationResult: invalid ? SemanticsValidationResult.invalid : SemanticsValidationResult.none,
          child: control,
        ),
      );
    }
    return Semantics(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          labelRow,
          ?control,
          ?message,
          if (description.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: ExcludeSemantics(
                child: Text(description, style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textTertiary)),
              ),
            ),
          if (s.url != null && s.url!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: _HelpLink(url: s.url!, text: help),
              ),
            ),
        ],
      ),
    );
  }
}

/// A radio option card: `flex h-8 w-full items-center justify-center gap-2 rounded-lg border
/// border-components-option-card-option-border bg-components-option-card-option-bg p-2 system-sm-regular
/// text-text-secondary`, selected `border-components-option-card-option-selected-border
/// bg-components-option-card-option-selected-bg text-text-primary shadow-xs`; the radio dot with `showRadioUI`.
class _RadioCard extends StatelessWidget {
  const _RadioCard({
    super.key,
    required this.label,
    required this.selected,
    required this.disabled,
    required this.showRadio,
    required this.onTap,
  });

  final String label;
  final bool selected, disabled, showRadio;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    inMutuallyExclusiveGroup: true,
    checked: selected,
    child: DifyPressable(
      semanticLabel: label,
      onPressed: disabled ? null : onTap,
      builder: (context, hovered, focused) => Opacity(
        opacity: disabled ? 0.5 : 1,
        child: Container(
          height: 32,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: selected
                ? DifyColors.componentsOptionCardOptionSelectedBg
                : hovered
                ? DifyColors.componentsOptionCardOptionBgHover
                : DifyColors.componentsOptionCardOptionBg,
            borderRadius: BorderRadius.circular(DifyRadius.lg),
            border: Border.all(
              color: selected
                  ? DifyColors.componentsOptionCardOptionSelectedBorder
                  : DifyColors.componentsOptionCardOptionBorder,
            ),
            boxShadow: selected ? DifyShadows.xs : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (showRadio) ...[
                SettingsRadioDot(checked: selected, hovered: hovered, disabled: disabled),
                const SizedBox(width: 8),
              ],
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: difyTextStyle(
                    DifyType.systemSmRegular,
                    selected ? DifyColors.textPrimary : DifyColors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// The help link: `mt-4 flex items-center system-xs-regular text-text-accent`, the text (`break-all`) and
/// `i-ri-external-link-line size-3`.
class _HelpLink extends StatelessWidget {
  const _HelpLink({required this.url, required this.text});
  final String url, text;

  @override
  Widget build(BuildContext context) => Semantics(
    link: true,
    label: text,
    linkUrl: Uri.tryParse(url),
    excludeSemantics: true,
    child: GestureDetector(
      onTap: () => openExternalUrl(url),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(child: Text(text, style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textAccent))),
            const SizedBox(width: 4),
            const RemixIcon('external-link-line', size: 12, color: DifyColors.textAccent),
          ],
        ),
      ),
    ),
  );
}
