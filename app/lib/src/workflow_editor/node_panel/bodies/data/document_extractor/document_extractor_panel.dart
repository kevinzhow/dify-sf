/// The Doc Extractor's panel (nodes/document-extractor/panel.tsx with use-config.ts and
/// use-single-run-form-params.ts): the file input with the supported file types, and the extracted text output.
library;

import 'package:flutter/widgets.dart';

import '../../../../../cards/card_kit.dart';
import '../../../../../design/dify_tokens.g.dart';
import '../../../../../workflow/dify_json.dart';
import '../../../../panel_fields/panel_fields.dart';
import '../../../node_panel_bodies.dart';
import '../data_common.dart';
import '../../../panel_edit.dart';

/// What the panel needs from the backend: `GET /files/support-type`'s `allowed_extensions`, the docs link of the
/// node (`useNodeHelpLink`) and whether the UI language is Chinese (`LanguagesSupported[1]`, which joins with "、 ").
class DocExtractorHost extends InheritedWidget {
  const DocExtractorHost({
    super.key,
    this.allowedExtensions = difyDocumentExtensions,
    this.helpLink = '',
    this.chineseSeparator = false,
    required super.child,
  });

  final List<String> allowedExtensions;
  final String helpLink;
  final bool chineseSeparator;

  static const _none = DocExtractorHost(child: SizedBox.shrink());

  static DocExtractorHost of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DocExtractorHost>() ?? _none;

  @override
  bool updateShouldNotify(DocExtractorHost old) =>
      allowedExtensions != old.allowedExtensions ||
      helpLink != old.helpLink ||
      chineseSeparator != old.chineseSeparator;
}

/// What a default Dify deployment answers for `allowed_extensions` (api/constants: the document extensions without
/// the Unstructured ETL, in lower and upper case); dify-sf has no such endpoint, so the panel shows these.
const difyDocumentExtensions = [
  'txt',
  'TXT',
  'markdown',
  'MARKDOWN',
  'md',
  'MD',
  'mdx',
  'MDX',
  'pdf',
  'PDF',
  'html',
  'HTML',
  'htm',
  'HTM',
  'xlsx',
  'XLSX',
  'xls',
  'XLS',
  'docx',
  'DOCX',
  'csv',
  'CSV',
  'vtt',
  'VTT',
  'properties',
  'PROPERTIES',
  'odt',
  'ODT',
];

/// `supportTypesShowNames`: the extensions as shown (md as markdown, htm as html), lower-cased, without duplicates.
String supportTypesShowNames(List<String> extensions, {bool chinese = false}) {
  const map = {'md': 'markdown', 'pptx': 'pptx', 'htm': 'html', 'xlsx': 'xlsx', 'docx': 'docx'};
  final seen = <String>{};
  return [
    for (final e in extensions)
      if (seen.add((map[e] ?? e).toLowerCase())) (map[e] ?? e).toLowerCase(),
  ].join(chinese ? '、 ' : ', ');
}

/// use-config.ts' filterVar: files and file arrays.
bool docExtractorFilterVar(PickerVar v, List<String> _) => v.type == 'file' || v.type == 'array[file]';

/// use-config.ts' `handleVarChanges`: the selector and whether it is a file array.
Map<String, Object?> docExtractorVarChange(Map<String, Object?> data, List<String> selector, String? type) => {
  ...data,
  'variable_selector': selector,
  'is_array_file': type == 'array[file]',
};

/// One form of the single-run panel (`forms` of use-single-run-form-params.ts).
typedef SingleRunForm = ({
  List<Map<String, Object?>> inputs,
  Map<String, Object?> values,
  void Function(Map<String, Object?> keyValue) onChange,
});

/// use-single-run-form-params.ts: one required multi-file input `files`; it depends on the node's variable.
({
  List<SingleRunForm> forms,
  List<List<String>> Function() getDependentVars,
  List<String>? Function(String variable) getDependentVar,
})
docExtractorSingleRunFormParams({
  required Map<String, Object?> payload,
  required Map<String, Object?> runInputData,
  required void Function(Map<String, Object?> data) setRunInputData,
}) {
  final selector = [for (final s in jsList(payload['variable_selector'])) jsKey(s)];
  return (
    forms: [
      (
        inputs: [
          {'label': wf('nodes.docExtractor.inputVar'), 'variable': 'files', 'type': 'file-list', 'required': true},
        ],
        values: {'files': runInputData['files']},
        onChange: (kv) => setRunInputData({...runInputData, 'files': kv['files']}),
      ),
    ],
    getDependentVars: () => [selector],
    getDependentVar: (variable) => variable == 'files' ? selector : null,
  );
}

/// The panel body.
Widget documentExtractorPanelBody(BuildContext context, NodePanelProps props) => _DocExtractorPanel(props: props);

class _DocExtractorPanel extends StatelessWidget {
  const _DocExtractorPanel({required this.props});
  final NodePanelProps props;

  @override
  Widget build(BuildContext context) {
    final p = props;
    final data = p.data;
    final host = DocExtractorHost.of(context);
    final scope = NodeVars.of(p).scope;
    final types = supportTypesShowNames(host.allowedExtensions, chinese: host.chineseSeparator);
    final openUrl = DataPanelHost.of(context).openUrl ?? p.actions.options.openUrl;
    final tertiary = difyStyle(DifyType.bodyXsRegular, DifyColors.textTertiary);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Field(
              title: wf('nodes.docExtractor.inputVar'),
              required: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  VarReferencePicker(
                    readonly: p.readOnly,
                    value: [for (final s in jsList(data['variable_selector'])) jsKey(s)],
                    scope: scope,
                    filterVar: docExtractorFilterVar,
                    typePlaceHolder: 'File | Array[File]',
                    onChange: (selector, _) =>
                        setInputs(p, docExtractorVarChange(data, selector, scope.typeOf?.call(selector))),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text.rich(
                        TextSpan(
                          text: wf('nodes.docExtractor.supportFileTypes', {'types': types}),
                          children: [
                            WidgetSpan(
                              alignment: PlaceholderAlignment.baseline,
                              baseline: TextBaseline.alphabetic,
                              child: _Link(
                                text: wf('nodes.docExtractor.learnMore'),
                                style: tertiary.copyWith(color: DifyColors.textAccent),
                                onTap: () => openUrl?.call(host.helpLink),
                              ),
                            ),
                          ],
                        ),
                        style: tertiary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const PanelSplit(),
          OutputVars(
            child: VarItem(
              name: 'text',
              type: jsTruthy(data['is_array_file']) ? 'array[string]' : 'string',
              description: wf('nodes.docExtractor.outputVars.text'),
            ),
          ),
        ],
      ),
    );
  }
}

/// `<a target="_blank">`: [text] that opens a link on a tap.
class _Link extends StatelessWidget {
  const _Link({required this.text, required this.style, required this.onTap});
  final String text;
  final TextStyle style;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    link: true,
    child: MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Text(text, style: style),
      ),
    ),
  );
}
