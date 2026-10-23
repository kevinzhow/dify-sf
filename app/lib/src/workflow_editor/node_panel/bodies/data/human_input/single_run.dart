/// The Human Input single run (hooks/use-single-run-form-params.ts, components/single-run-form.tsx): the form
/// variables asked first, the generated form fetched from the server, then submitted with an action. The panel's
/// single run is the host's (dify-sf has no single-run panel yet); these are what it uses.
library;

import 'package:flutter/material.dart';

import '../../../../../design/dify_icon.dart';
import '../../../../../design/dify_tokens.g.dart';
import '../../../../../design/widgets/widgets.dart';
import '../../../../../workflow/dify_json.dart';
import 'human_input_kit.dart';
import 'human_input_model.dart';
import 'user_action.dart';
import '../../../../run/ui/human_input_content.dart' show HumanInputContentItem;

/// A before-run input (`InputVar`): `variable` is `#a.b#` (may be missing on broken data).
typedef RunInputVar = Map<String, Object?>;

/// The texts `getInputVars` reads for the form variables: each form input's variable source as `{{#a.b#}}`, then the
/// form content.
List<String> humanInputRunTexts(Json data) => [
  for (final s in humanInputFormDependencySelectors(jsList(data['inputs']))) '{{#${s.join('.')}#}}',
  jsStr(data['form_content']) ?? '',
];

/// `generatedInputs`: [vars] without the form's own `$output` variables.
List<RunInputVar> humanInputRunInputs(List<RunInputVar> vars) => [
  for (final v in vars)
    if (!isOutputSelector(jsList(v['value_selector']))) v,
];

/// `getDependentVars`.
List<List<String>> humanInputDependentVars(List<RunInputVar> inputs) => [
  for (final i in inputs)
    if (i['variable'] case final String v when v.length > 2) v.substring(1, v.length - 1).split('.'),
];

/// The draft form's URL: `/apps/<app>/workflows/draft/human-input/nodes/<id>/form` (`advanced-chat/` before
/// `workflows` in a chatflow); '' without an app.
String humanInputFormUrl({required String? appId, required bool isWorkflowMode, required String nodeId}) {
  if (appId == null || appId.isEmpty) return '';
  final chat = isWorkflowMode ? '' : 'advanced-chat/';
  return '/apps/$appId/${chat}workflows/draft/human-input/nodes/$nodeId/form';
}

/// The form data the server generates (`HumanInputFormData`).
typedef HumanInputFormData = Json;

/// Fetches the generated form (`fetchHumanInputNodeStepRunForm(url, {inputs})`).
typedef FetchHumanInputForm = Future<HumanInputFormData> Function(String url, Map<String, Object?> inputs);

/// Submits it (`submitHumanInputNodeStepRunForm(url, {inputs, form_inputs, action})`).
typedef SubmitHumanInputForm = Future<void> Function(String url, Json body);

/// use-single-run-form-params' state: the generated form, the inputs it was generated with, fetch and submit.
class HumanInputSingleRun extends ChangeNotifier {
  HumanInputSingleRun({
    required this.nodeId,
    required this.data,
    required this.fetch,
    required this.submit,
    this.appId,
    this.isWorkflowMode = true,
  });

  final String nodeId;
  final Json data;
  final FetchHumanInputForm fetch;
  final SubmitHumanInputForm submit;
  String? appId;
  bool isWorkflowMode;

  bool showGeneratedForm = false;
  HumanInputFormData? formData;
  Map<String, Object?> _required = const {};

  String get url => humanInputFormUrl(appId: appId, isWorkflowMode: isWorkflowMode, nodeId: nodeId);

  /// `handleFetchFormContent`: null without an app.
  Future<HumanInputFormData?> fetchFormContent(Map<String, Object?> inputs) async {
    if (url.isEmpty) return null;
    final params = {
      for (final e in inputs.entries)
        if (e.value != null) e.key: e.value,
    };
    final r = await fetch(url, params);
    formData = r;
    _required = params;
    notifyListeners();
    return r;
  }

  /// `handleShowGeneratedForm`.
  Future<void> showForm(Map<String, Object?> values) async {
    showGeneratedForm = true;
    notifyListeners();
    await fetchFormContent(values);
  }

  /// `handleHideGeneratedForm`.
  void hideForm() {
    showGeneratedForm = false;
    notifyListeners();
  }

  /// `handleSubmitHumanInputForm`.
  Future<void> submitForm({required Map<String, Object?>? inputs, required String action}) {
    final fromServer = jsList(formData?['inputs']);
    final formInputs = fromServer.isNotEmpty ? fromServer : jsList(data['inputs']);
    return submit(url, {
      'inputs': _required,
      'form_inputs': processedHumanInputFormInputs(formInputs, inputs),
      'action': action,
    });
  }
}

/// SingleRunForm: an optional "Back / node" row, the content with its inputs (paragraph text areas, select
/// fields; file inputs show their name: dify-sf has no uploader), and the action buttons (disabled while submitting
/// or while a select or file input is empty).
class HumanInputRunForm extends StatefulWidget {
  const HumanInputRunForm({
    super.key,
    required this.nodeName,
    required this.data,
    this.showBackButton = false,
    this.busy = false,
    this.onBack,
    this.onSubmit,
    this.onError,
  });

  final String nodeName;
  final HumanInputFormData data;
  final bool showBackButton;

  /// A request of the owner is in flight (the form was just fetched, or the answer is being sent): the actions wait.
  final bool busy;
  final VoidCallback? onBack;
  final Future<void> Function(Map<String, Object?> inputs, String action)? onSubmit;

  /// A refused or lost submission: the owner shows it (its toast), and this widget stays usable — the answers typed so
  /// far are kept and the actions work again.
  final void Function(Object error)? onError;

  /// Dify's console form definition (`GET /v1/form/human_input/{token}`: `rendered_content`, `user_actions`, `inputs`,
  /// `default_values`) as the panel's own JSON (`form_content`, `actions`, `inputs`, `resolved_default_values`): the two
  /// shapes Dify serves the same form in.
  static HumanInputFormData definitionOf(HumanInputFormData definition) => {
    ...definition,
    'form_content': definition['rendered_content'] ?? definition['form_content'],
    'actions': definition['actions'] ?? definition['user_actions'] ?? const <Object?>[],
    'resolved_default_values':
        definition['resolved_default_values'] ?? definition['default_values'] ?? const <String, Object?>{},
  };

  @override
  State<HumanInputRunForm> createState() => _HumanInputRunFormState();
}

class _HumanInputRunFormState extends State<HumanInputRunForm> {
  late final _content = jsStr(widget.data['form_content']) ?? '';
  late final _fields = jsList(widget.data['inputs']);
  late final Map<String, Object?> _inputs = initializeInputs(
    renderedFormInputs(_fields, _content),
    switch (widget.data['resolved_default_values']) {
      final Map<String, Object?> m => m,
      _ => const {},
    },
  );
  bool _submitting = false;

  Future<void> _submit(String action) async {
    setState(() => _submitting = true);
    try {
      await widget.onSubmit?.call({..._inputs}, action);
    } on Object catch (e) {
      // A refused or lost submission must not leave the buttons disabled or the future unhandled: the owner shows the
      // error, the form keeps what was typed, and the action can be pressed again.
      widget.onError?.call(e);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Widget _item(String piece) => HumanInputContentItem(
    content: piece,
    formInputFields: _fields,
    inputs: _inputs,
    onInputChange: (name, value) => setState(() => _inputs[name] = value),
  );

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final disabled =
        _submitting || widget.busy || hasInvalidSelectOrFileInput(renderedFormInputs(_fields, _content), _inputs);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (w.showBackButton)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Row(
              children: [
                DifyPressable(
                  semanticLabel: hi('singleRun.back'),
                  onPressed: w.onBack,
                  builder: (context, _, _) => Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      RemixIcon('arrow-left-line', size: 16, color: DifyColors.textAccent),
                      const SizedBox(width: 4),
                      DifyText(hi('singleRun.back'), DifyType.systemSmSemiboldUppercase, color: DifyColors.textAccent),
                    ],
                  ),
                ),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4),
                  child: DifyText('/', DifyType.systemXsRegular, color: DifyColors.dividerDeep),
                ),
                Flexible(
                  child: DifyText(w.nodeName, DifyType.systemSmSemiboldUppercase, color: DifyColors.textSecondary),
                ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final piece in splitByOutputVar(_content)) _item(piece),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: [
                    for (final a in jsList(w.data['actions']))
                      DifyButton(
                        variant: buttonVariantOf(jsStr(jsGet(a, 'button_style'))),
                        disabled: disabled,
                        onPressed: () => _submit('${jsGet(a, 'id')}'),
                        child: DifyTextLine('${jsGet(a, 'title') ?? ''}'),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
