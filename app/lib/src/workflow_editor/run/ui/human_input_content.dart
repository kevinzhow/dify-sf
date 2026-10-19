/// The human input forms a run shows while it is paused at a Human Input node, and the forms it filled
/// (Dify 1.17.1 base/chat/chat/answer/human-input-content/*, human-input-form-list.tsx,
/// human-input-filled-form-list.tsx, and workflow/panel/human-input-form-list.tsx /
/// human-input-filled-form-list.tsx): in the chatflow preview's answers and in the test run panel's RESULT tab.
/// Forms are Dify's HumanInputFormData / HumanInputFilledFormData JSON; submitting goes through the
/// WorkflowRunService (`submitHumanInputForm(token, {inputs, action})`), after which the run continues.
library;

import 'package:flutter/widgets.dart';

import '../../../cards/card_chrome.dart' show BlockIcon, BlockIconSize;
import '../../../cards/card_kit.dart';
import '../../../design/dify_icon.dart';
import '../../../design/dify_tokens.g.dart';
import '../../../design/widgets/widgets.dart';
import '../../../i18n/dify_i18n.dart';
import '../../../workflow/dify_json.dart';
import '../../header/format.dart' show formatTimeFromNow;
import '../../node_panel/bodies/data/human_input/human_input_kit.dart' show transSpans;
import '../../node_panel/bodies/data/human_input/human_input_model.dart';
import '../../node_panel/bodies/data/human_input/user_action.dart' show buttonVariantOf;
import '../../panel_fields/form_controls.dart' show DifyTextarea;
import '../../panel_fields/selectors.dart' show DifySelect;
import '../../store/workflow_store.dart' show DifyJson;
import 'before_run_form.dart' show RunFileInput, RunFilePicker;
import 'markdown.dart';
import 'run_widgets.dart' show RunFileList;

/// `onHumanInputFormSubmit(formToken, {inputs, action})`.
typedef HumanInputFormSubmit = Future<void> Function(String formToken, DifyJson data);

/// The node data of a form's Human Input node (`getHumanInputNodeData`), null when it is not in the graph.
typedef HumanInputNodeData = DifyJson? Function(String nodeId);

/// `getRelativeTime` (dayjs `fromNow`, English for every locale).
String getRelativeTime(int utcMilliseconds, [String locale = 'en-US']) => formatTimeFromNow(utcMilliseconds);

final _outputVar = RegExp(r'\{\{#\$output\.([^#]+)#\}\}');

String _ts(String key, [Map<String, Object?> p = const {}]) => DifyI18n.tr('share', key, p);
String _tw(String key, [Map<String, Object?> p = const {}]) => DifyI18n.tr('workflow', key, p);

/// ContentWrapper: `rounded-2xl border-[0.5px] border-components-panel-border bg-background-section p-2 shadow-md`;
/// a `p-2 gap-2` header (the Human Input block icon, the node title, the expand toggle when [showExpandIcon]), the
/// content in `px-2 py-1` (hidden while collapsed).
class HumanInputContentWrapper extends StatefulWidget {
  const HumanInputContentWrapper({
    super.key,
    required this.nodeTitle,
    required this.child,
    this.showExpandIcon = false,
    this.expanded = false,
    this._background,
  });

  final String nodeTitle;
  final Widget child;
  final bool showExpandIcon;
  final bool expanded;

  /// `bg-background-section`, or the caller's class (`bg-components-panel-bg` in the test run panel).
  final Color? _background;
  Color get background => _background ?? DifyColors.backgroundSection;

  @override
  State<HumanInputContentWrapper> createState() => _HumanInputContentWrapperState();
}

class _HumanInputContentWrapperState extends State<HumanInputContentWrapper> {
  late bool _expanded = widget.expanded;

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final label = '${_ts(_expanded ? 'chat.collapse' : 'chat.expand')} ${w.nodeTitle}';
    return Container(
      key: const Key('content-wrapper'),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: w.background,
        borderRadius: BorderRadius.circular(DifyRadius.xxl),
        border: Border.all(color: DifyColors.componentsPanelBorder, width: 0.5),
        boxShadow: DifyShadows.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              spacing: 8,
              children: [
                const BlockIcon(type: 'human-input', size: BlockIconSize.sm),
                Expanded(
                  child: DifyText(w.nodeTitle, DifyType.systemSmSemiboldUppercase, color: DifyColors.textPrimary),
                ),
                if (w.showExpandIcon)
                  DifyPressable(
                    onPressed: () => setState(() => _expanded = !_expanded),
                    // `aria-expanded`, `aria-label` "<Expand|Collapse> <title>".
                    builder: (context, _, _) => Semantics(
                      label: label,
                      expanded: _expanded,
                      child: ExcludeSemantics(
                        child: RemixIcon(_expanded ? 'arrow-down-s-line' : 'arrow-right-s-line', size: 16),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (!w.showExpandIcon || _expanded)
            Padding(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), child: w.child),
        ],
      ),
    );
  }
}

/// HumanInputFieldRenderer: a paragraph's text area (`h-26`), a select (`size="large"`), a file or file list input
/// (FileUploaderInAttachmentWrapper: one file, or `number_limits` (5 by default)); nothing for other types. File
/// values are [HumanInputFile]s.
class HumanInputFieldRenderer extends StatelessWidget {
  const HumanInputFieldRenderer({super.key, required this.field, this.value, required this.onChange, this.pickFile});

  final Object? field;
  final Object? value;
  final ValueChanged<Object?> onChange;

  /// Picks a file to upload (none: the upload buttons are disabled, as dify-sf has no file service).
  final RunFilePicker? pickFile;

  @override
  Widget build(BuildContext context) {
    final name = inputNameOf(field);
    if (isParagraphFormInput(field)) {
      return DifyTextarea(
        key: const Key('content-item-textarea'),
        value: value is String ? value! as String : '',
        semanticLabel: name,
        minHeight: 104,
        onChanged: onChange,
      );
    }
    if (isSelectFormInput(field)) {
      final options = [for (final o in jsList(jsGet(jsGet(field, 'option_source'), 'value'))) jsKey(o)];
      final v = value is String && (value! as String).isNotEmpty ? value! as String : null;
      return DifySelect<String>(
        value: v,
        large: true,
        semanticLabel: name,
        options: [for (final o in options) (value: o, label: o)],
        onChanged: onChange,
      );
    }
    List<DifyJson> entries(Object? v) => [
      for (final f in v is List ? v : [?v])
        if (f is HumanInputFile) f.toEntryJson(),
    ];
    if (isFileFormInput(field)) {
      return RunFileInput(
        files: entries(value),
        limit: 1,
        pickFile: pickFile,
        onChange: (files) => onChange(files.isEmpty ? null : HumanInputFile.fromJson(files.first)),
      );
    }
    if (isFileListFormInput(field)) {
      final limit = (jsGet(field, 'number_limits') as num?)?.toInt() ?? 0;
      return RunFileInput(
        files: entries(value),
        limit: limit == 0 ? 5 : limit,
        pickFile: pickFile,
        onChange: (files) => onChange([for (final f in files) HumanInputFile.fromJson(f)]),
      );
    }
    return const SizedBox.shrink();
  }
}

/// ContentItem: literal content as Markdown; an output variable as its field (`py-3`), nothing when the field is
/// unknown.
class HumanInputContentItem extends StatelessWidget {
  const HumanInputContentItem({
    super.key,
    required this.content,
    required this.formInputFields,
    required this.inputs,
    required this.onInputChange,
    this.pickFile,
  });

  final String content;
  final List<Object?> formInputFields;
  final Map<String, Object?> inputs;
  final void Function(String name, Object? value) onInputChange;
  final RunFilePicker? pickFile;

  @override
  Widget build(BuildContext context) {
    final m = _outputVar.firstMatch(content);
    if (m == null) return DifyMarkdown(content: content);
    final name = m[1]!;
    final field = formInputFields.where((f) => inputNameOf(f) == name).firstOrNull;
    if (field == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: HumanInputFieldRenderer(
        field: field,
        value: inputs[name],
        pickFile: pickFile,
        onChange: (v) => onInputChange(name, v),
      ),
    );
  }
}

/// HumanInputForm: the content pieces with their fields, then the actions (`flex flex-wrap gap-1 py-1`), disabled
/// while submitting, without a form token, or while a rendered select / file input has no (uploaded) value.
class HumanInputForm extends StatefulWidget {
  const HumanInputForm({super.key, required this.formData, this.onSubmit, this.pickFile, this.itemBuilder});

  final DifyJson formData;
  final HumanInputFormSubmit? onSubmit;
  final RunFilePicker? pickFile;

  /// Replaces [HumanInputContentItem] (Dify's specs mock it).
  @visibleForTesting
  final Widget Function(String content, void Function(String name, Object? value) onInputChange)? itemBuilder;

  @override
  State<HumanInputForm> createState() => _HumanInputFormState();
}

class _HumanInputFormState extends State<HumanInputForm> {
  String get _content => jsStr(widget.formData['form_content']) ?? '';
  List<Object?> get _fields => jsList(widget.formData['inputs']);
  List<Object?> get _rendered => renderedFormInputs(_fields, _content);
  late Map<String, Object?> _inputs = initializeInputs(
    _rendered,
    switch (widget.formData['resolved_default_values']) {
      final Map<String, Object?> m => m,
      _ => const {},
    },
  );
  bool _submitting = false;

  void _change(String name, Object? value) => setState(() => _inputs = {..._inputs, name: value});

  Future<void> _submit(String token, String action) async {
    setState(() => _submitting = true);
    await widget.onSubmit?.call(token, {
      'inputs': processedHumanInputFormInputs(_rendered, _inputs) ?? const <String, Object?>{},
      'action': action,
    });
    if (mounted) setState(() => _submitting = false);
  }

  @override
  Widget build(BuildContext context) {
    final token = jsStr(widget.formData['form_token']) ?? '';
    final disabled = _submitting || token.isEmpty || hasInvalidSelectOrFileInput(_rendered, _inputs);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final piece in splitByOutputVar(_content))
          widget.itemBuilder?.call(piece, _change) ??
              HumanInputContentItem(
                content: piece,
                formInputFields: _fields,
                inputs: _inputs,
                pickFile: widget.pickFile,
                onInputChange: _change,
              ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              for (final a in jsList(widget.formData['actions']))
                DifyButton(
                  variant: buttonVariantOf(jsStr(jsGet(a, 'button_style'))),
                  disabled: disabled,
                  onPressed: () => token.isEmpty ? null : _submit(token, '${jsGet(a, 'id')}'),
                  child: Text('${jsGet(a, 'title') ?? ''}'),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Tips: a `my-2 w-7.5` divider, then (`space-y-1 pt-1`) the email delivery tip (in debug mode: sent to the
/// account's email) and the "debug preview only" tip when the web app delivery is off.
class HumanInputTips extends StatelessWidget {
  const HumanInputTips({
    super.key,
    required this.showEmailTip,
    required this.isEmailDebugMode,
    required this.showDebugModeTip,
    this.email = '',
  });

  final bool showEmailTip, isEmailDebugMode, showDebugModeTip;

  /// The account's email (EmailDebugTip).
  final String email;

  @override
  Widget build(BuildContext context) {
    final regular = difyStyle(DifyType.systemXsRegular, DifyColors.textSecondary);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Align(
          alignment: Alignment.centerLeft,
          child: DifyDivider(length: 30),
        ),
        Padding(
          key: const Key('tips'),
          padding: const EdgeInsets.only(top: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            spacing: 4,
            children: [
              if (showEmailTip && !isEmailDebugMode) Text(_tw('common.humanInputEmailTip'), style: regular),
              if (showEmailTip && isEmailDebugMode)
                Text.rich(
                  TextSpan(
                    style: regular,
                    children: transSpans(_tw('common.humanInputEmailTipInDebugMode', {'email': email}), {
                      'email': (inner) => TextSpan(
                        text: inner,
                        style: difyStyle(DifyType.systemXsSemibold, DifyColors.textSecondary),
                      ),
                    }),
                  ),
                ),
              if (showDebugModeTip)
                DifyText(_tw('common.humanInputWebappTip'), DifyType.systemXsMedium, color: DifyColors.textWarning),
            ],
          ),
        ),
      ],
    );
  }
}

/// ExpirationTime: `mt-1 gap-x-1 system-xs-regular`: "This action will expire in …" with a clock (tertiary), or
/// "This action has expired." with an alert (warning).
class HumanInputExpirationTime extends StatelessWidget {
  const HumanInputExpirationTime({super.key, required this.expirationTime, this.now});

  /// Milliseconds since the epoch (UTC).
  final int expirationTime;

  /// The current time (tests).
  final DateTime Function()? now;

  @override
  Widget build(BuildContext context) {
    final current = now?.call() ?? DateTime.now();
    final future = isRelativeTimeSameOrAfter(expirationTime, now: current);
    final color = future ? DifyColors.textTertiary : DifyColors.textWarning;
    return Padding(
      key: const Key('expiration-time'),
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        spacing: 4,
        children: [
          RemixIcon(future ? 'time-line' : 'alert-fill', size: 14, color: color),
          Expanded(
            child: DifyText(
              future
                  ? _ts('humanInput.expirationTimeNowOrFuture', {
                      'relativeTime': formatTimeFromNow(expirationTime, now: current),
                    })
                  : _ts('humanInput.expiredTip'),
              DifyType.systemXsRegular,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

/// UnsubmittedHumanInputContent: the form, the tips (when any shows), the expiration time (when the form has one).
class UnsubmittedHumanInputContent extends StatelessWidget {
  const UnsubmittedHumanInputContent({
    super.key,
    required this.formData,
    this.showEmailTip = false,
    this.isEmailDebugMode = false,
    this.showDebugModeTip = false,
    this.onSubmit,
    this.pickFile,
    this.email = '',
  });

  final DifyJson formData;
  final bool showEmailTip, isEmailDebugMode, showDebugModeTip;
  final HumanInputFormSubmit? onSubmit;
  final RunFilePicker? pickFile;
  final String email;

  @override
  Widget build(BuildContext context) {
    final expiration = formData['expiration_time'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        HumanInputForm(formData: formData, onSubmit: onSubmit, pickFile: pickFile),
        if (showEmailTip || showDebugModeTip)
          HumanInputTips(
            showEmailTip: showEmailTip,
            isEmailDebugMode: isEmailDebugMode,
            showDebugModeTip: showDebugModeTip,
            email: email,
          ),
        if (expiration is num) HumanInputExpirationTime(expirationTime: (expiration * 1000).toInt()),
      ],
    );
  }
}

/// A submitted file value (FileResponse) as the file list shows it (`getProcessedFilesFromResponse`).
DifyJson _fileEntry(Map f) => {
  'name': f['filename'] ?? f['name'] ?? '',
  'size': f['size'],
  'type': f['mime_type'] ?? f['type'],
  'url': f['url'] ?? f['remote_url'],
  'transfer_method': f['transfer_method'],
  'upload_file_id': f['upload_file_id'],
};

Widget _fileList(Key key, List<Map> files) => Padding(
  key: key,
  padding: const EdgeInsets.symmetric(vertical: 12),
  child: RunFileList(key: const Key('file-list'), files: [for (final f in files) _fileEntry(f)]),
);

/// SubmittedContentItem: literal content as Markdown; an output variable as its submitted value in the form's layout
/// (a paragraph's text, a disabled select, a read-only file list), nothing when the field or value is missing or
/// has another shape.
class SubmittedHumanInputContentItem extends StatelessWidget {
  const SubmittedHumanInputContentItem({
    super.key,
    required this.content,
    required this.formInputFields,
    required this.values,
  });

  final String content;
  final List<Object?> formInputFields;
  final Map<String, Object?> values;

  @override
  Widget build(BuildContext context) {
    final m = _outputVar.firstMatch(content);
    if (m == null) return DifyMarkdown(content: content);
    final name = m[1]!;
    final field = formInputFields.where((f) => inputNameOf(f) == name).firstOrNull;
    final value = values[name];
    if (field == null || value == null) return const SizedBox.shrink();
    final key = Key('submitted-field-$name');
    if (isParagraphFormInput(field)) {
      return Text(
        value is String ? value : '',
        key: key,
        style: difyStyle(DifyType.bodyMdRegular, DifyColors.textPrimary),
      );
    }
    if (isSelectFormInput(field)) {
      final options = [for (final o in jsList(jsGet(jsGet(field, 'option_source'), 'value'))) jsKey(o)];
      return Padding(
        key: key,
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: DifySelect<String>(
          value: value is String && value.isNotEmpty ? value : null,
          large: true,
          disabled: true,
          semanticLabel: name,
          options: [for (final o in options) (value: o, label: o)],
        ),
      );
    }
    if (isFileFormInput(field)) return value is Map ? _fileList(key, [value]) : const SizedBox.shrink();
    if (isFileListFormInput(field)) {
      return value is List ? _fileList(key, value.whereType<Map>().toList()) : const SizedBox.shrink();
    }
    return const SizedBox.shrink();
  }
}

/// SubmittedFieldValues: each submitted value (`flex flex-col gap-3`): text as `body-md-regular`, files as file
/// lists; the kind comes from [fields] or, without them, from the value's shape.
class SubmittedHumanInputFieldValues extends StatelessWidget {
  const SubmittedHumanInputFieldValues({super.key, this.fields, required this.values});

  final List<Object?>? fields;
  final Map<String, Object?> values;

  @override
  Widget build(BuildContext context) {
    final names = fields?.map(inputNameOf).toList() ?? values.keys.toList();
    final byName = {for (final f in fields ?? const <Object?>[]) inputNameOf(f): f};
    return Column(
      key: const Key('submitted-field-values'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      spacing: 12,
      children: [
        for (final name in names) ?_value(name, byName[name]),
      ],
    );
  }

  Widget? _value(String name, Object? field) {
    final value = values[name];
    if (value == null) return null;
    final key = Key('submitted-field-$name');
    return switch (_kind(field, value)) {
      'file' => value is Map ? _fileList(key, [value]) : null,
      'file-list' => value is List ? _fileList(key, value.whereType<Map>().toList()) : null,
      _ => Text('$value', key: key, style: difyStyle(DifyType.bodyMdRegular, DifyColors.textPrimary)),
    };
  }

  static String _kind(Object? field, Object value) {
    if (field != null && isFileFormInput(field)) return 'file';
    if (field != null && isFileListFormInput(field)) return 'file-list';
    if (value is String) return 'text';
    if (value is List) return 'file-list';
    return 'file';
  }
}

/// ExecutedAction: a `mt-1 mb-2 w-7.5` divider, then the trigger icon and "(action id) has been triggered".
class HumanInputExecutedAction extends StatelessWidget {
  const HumanInputExecutedAction({super.key, required this.actionId});
  final String actionId;

  @override
  Widget build(BuildContext context) => Padding(
    key: const Key('executed-action'),
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      spacing: 4,
      children: [
        const DifyDivider(length: 30, margin: EdgeInsets.only(top: 4, bottom: 8)),
        Row(
          spacing: 4,
          children: [
            DifyIcon('vender/workflow/trigger-all', size: 14, color: DifyColors.textTertiary),
            Expanded(
              child: Text.rich(
                TextSpan(
                  style: difyStyle(DifyType.systemXsRegular, DifyColors.textTertiary),
                  children: transSpans(_tw('nodes.humanInput.userActions.triggered', {'actionName': actionId}), {
                    'strong': (inner) =>
                        TextSpan(text: inner, style: difyStyle(DifyType.systemXsMedium, DifyColors.textSecondary)),
                  }),
                ),
              ),
            ),
          ],
        ),
      ],
    ),
  );
}

/// SubmittedHumanInputContent: the submitted values in the form's layout (when the form content and inputs came
/// with them), else the values alone, else the rendered content as Markdown; then the executed action.
class SubmittedHumanInputContent extends StatelessWidget {
  const SubmittedHumanInputContent({super.key, required this.formData});
  final DifyJson formData;

  @override
  Widget build(BuildContext context) {
    final submitted = switch (formData['submitted_data']) {
      final Map<String, Object?> m when m.isNotEmpty => m,
      _ => null,
    };
    final formContent = jsStr(formData['form_content']);
    final inputs = formData['inputs'];
    final Widget content;
    if (formContent != null && formContent.isNotEmpty && inputs is List && submitted != null) {
      content = Column(
        key: const Key('submitted-form-content'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final piece in splitByOutputVar(formContent))
            SubmittedHumanInputContentItem(content: piece, formInputFields: inputs, values: submitted),
        ],
      );
    } else if (submitted != null) {
      content = SubmittedHumanInputFieldValues(values: submitted);
    } else {
      content = KeyedSubtree(
        key: const Key('submitted-content'),
        child: DifyMarkdown(content: jsStr(formData['rendered_content']) ?? ''),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        content,
        HumanInputExecutedAction(actionId: jsStr(formData['action_id']) ?? ''),
      ],
    );
  }
}

/// The delivery tips of a form's node (human-input-form-list.tsx `deliveryMethodsConfig`): the email tip when the
/// email delivery is on (its debug mode), the debug preview tip when the web app delivery is off; none without
/// delivery methods.
({bool showEmailTip, bool isEmailDebugMode, bool showDebugModeTip}) humanInputDeliveryTips(DifyJson? nodeData) {
  final methods = jsList(nodeData?['delivery_methods']);
  if (methods.isEmpty) return (showEmailTip: false, isEmailDebugMode: false, showDebugModeTip: false);
  bool any(bool Function(Object? m) test) => methods.any(test);
  return (
    showEmailTip: any((m) => jsGet(m, 'type') == DeliveryMethodType.email && jsGet(m, 'enabled') == true),
    isEmailDebugMode: any(
      (m) => jsGet(m, 'type') == DeliveryMethodType.email && jsGet(jsGet(m, 'config'), 'debug_mode') == true,
    ),
    showDebugModeTip: !any((m) => jsGet(m, 'type') == DeliveryMethodType.webapp && jsGet(m, 'enabled') == true),
  );
}

/// HumanInputFormList: the forms shown in the UI (`display_in_ui`), each in a ContentWrapper with its node's
/// delivery tips. The chat's (`mt-2 gap-y-2`) or, with [inPanel], the test run panel's (`gap-y-3`, panel
/// background). A new form of the same node starts afresh (keyed by form id).
class HumanInputFormList extends StatelessWidget {
  const HumanInputFormList({
    super.key,
    required this.humanInputFormDataList,
    this.onHumanInputFormSubmit,
    this.getHumanInputNodeData,
    this.inPanel = false,
    this.pickFile,
    this.email = '',
  });

  final List<DifyJson> humanInputFormDataList;
  final HumanInputFormSubmit? onHumanInputFormSubmit;
  final HumanInputNodeData? getHumanInputNodeData;
  final bool inPanel;
  final RunFilePicker? pickFile;

  /// The account's email (the email debug tip).
  final String email;

  @override
  Widget build(BuildContext context) => Padding(
    key: const Key('human-input-form-list'),
    padding: EdgeInsets.only(top: inPanel ? 0 : 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      spacing: inPanel ? 12 : 8,
      children: [
        for (final form in humanInputFormDataList)
          if (form['display_in_ui'] == true)
            if (humanInputDeliveryTips(getHumanInputNodeData?.call('${form['node_id']}')) case final tips)
              KeyedSubtree(
                key: ValueKey('human-input-form-${form['form_id']}'),
                child: HumanInputContentWrapper(
                  key: const Key('human-input-form-item'),
                  nodeTitle: '${form['node_title'] ?? ''}',
                  background: inPanel ? DifyColors.componentsPanelBg : DifyColors.backgroundSection,
                  child: UnsubmittedHumanInputContent(
                    formData: form,
                    showEmailTip: tips.showEmailTip,
                    isEmailDebugMode: tips.isEmailDebugMode,
                    showDebugModeTip: tips.showDebugModeTip,
                    onSubmit: onHumanInputFormSubmit,
                    pickFile: pickFile,
                    email: email,
                  ),
                ),
              ),
      ],
    ),
  );
}

/// HumanInputFilledFormList: each filled form in a collapsible ContentWrapper (`mt-2 gap-y-2`; in the test run
/// panel, [inPanel]: `mt-3 first:mt-0 gap-y-3`, panel background, expanded).
class HumanInputFilledFormList extends StatelessWidget {
  const HumanInputFilledFormList({
    super.key,
    required this.humanInputFilledFormDataList,
    this.inPanel = false,
    this.first = false,
  });

  final List<DifyJson> humanInputFilledFormDataList;
  final bool inPanel;

  /// The panel list is the first item of its container (`first:mt-0`).
  final bool first;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(top: inPanel ? (first ? 0 : 12) : 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      spacing: inPanel ? 12 : 8,
      children: [
        for (final form in humanInputFilledFormDataList)
          HumanInputContentWrapper(
            key: ValueKey('human-input-filled-${form['node_id']}'),
            nodeTitle: '${form['node_title'] ?? ''}',
            showExpandIcon: true,
            expanded: inPanel,
            background: inPanel ? DifyColors.componentsPanelBg : DifyColors.backgroundSection,
            child: SubmittedHumanInputContent(formData: form),
          ),
      ],
    ),
  );
}
