/// The Template node's panel (nodes/template-transform/panel.tsx, use-config.ts).
library;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../../../../design/dify_icon.dart';
import '../../../../design/dify_tokens.g.dart';
import '../../../../design/widgets/widgets.dart';
import '../../../../workflow/dify_json.dart';
import '../../../../workflow/output_vars.dart' show VarType;
import '../../../code_editor/code_editor.dart';
import '../../../panel_fields/panel_fields.dart';
import '../../node_panel_bodies.dart';
import '../../panel_edit.dart';
import 'code_editor_support_vars.dart';
import 'code_panel.dart' show writeCoreInputs;
import 'core_kit.dart';

/// The Jinja docs the editor's header links to.
const jinjaDocsUrl = 'https://jinja.palletsprojects.com/en/3.1.x/templates/';

/// use-config.ts over Dify's data: [inputs] read live (Dify's `inputsRef`), every change through [setInputs].
class TemplateConfig {
  TemplateConfig({required this.inputs, required this.setInputs, this.readOnly = false, this.defaultConfig});

  final Map<String, Object?> Function() inputs;
  final ValueChanged<Map<String, Object?>> setInputs;
  final bool readOnly;

  /// `nodesDefaultConfigs['template-transform']`.
  final Map<String, Object?>? defaultConfig;

  /// The mount effect: an empty template takes the backend's default config.
  void init() {
    final i = inputs();
    if (jsTruthy(i['template'])) return;
    final d = defaultConfig;
    if (d != null && d.isNotEmpty) setInputs({...i, ...d});
  }

  void handleVarListChange(List<Object?> list) => setInputs({...inputs(), 'variables': list});

  /// handleAddVariable (an editor pick of a variable not among the inputs).
  void handleAddVariable(Map<String, Object?> payload) {
    final i = inputs();
    setInputs({
      ...i,
      'variables': [...jsList(i['variables']), payload],
    });
  }

  /// useVarList's handleAddVariable.
  void handleAddEmptyVariable() {
    final i = inputs();
    setInputs({
      ...i,
      'variables': [
        ...jsList(i['variables']),
        {'variable': '', 'value_selector': <Object?>[]},
      ],
    });
  }

  /// Renames `{{ old }}` (space padded only) in the template.
  void handleVarNameChange(String oldName, String newName) {
    final i = inputs();
    setInputs({...i, 'template': '${i['template'] ?? ''}'.replaceAll('{{ $oldName }}', '{{ $newName }}')});
  }

  void handleCodeChange(String template) => setInputs({...inputs(), 'template': template});

  static const _types = {
    VarType.string,
    VarType.number,
    VarType.boolean,
    VarType.object,
    VarType.array,
    VarType.arrayNumber,
    VarType.arrayString,
    VarType.arrayBoolean,
    VarType.arrayObject,
  };

  /// The input variables' types.
  static bool filterVar(String? type) => _types.contains(type);
}

Widget templatePanelBody(BuildContext context, NodePanelProps props) => _TemplatePanel(props: props);

class _TemplatePanel extends StatefulWidget {
  const _TemplatePanel({required this.props});
  final NodePanelProps props;

  @override
  State<_TemplatePanel> createState() => _TemplatePanelState();
}

class _TemplatePanelState extends State<_TemplatePanel> {
  late final _base = TypingBase(() => widget.props.controller.seenVersion);
  late final TemplateConfig _config = TemplateConfig(
    inputs: () => PanelInputs(widget.props).inputs,
    setInputs: _write,
    readOnly: widget.props.readOnly,
    defaultConfig: CorePanelHost.of(context).nodesDefaultConfigs['template-transform'],
  );

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (mounted && !widget.props.readOnly) _config.init();
    });
  }

  void _write(Map<String, Object?> next) => writeCoreInputs(widget.props, next, textKey: 'template', base: _base.call);

  @override
  Widget build(BuildContext context) {
    final props = widget.props, c = _config, readOnly = props.readOnly;
    final inputs = c.inputs();
    final variables = inputs['variables'];
    final vars = NodeVars.of(props);
    final title = tw('nodes.templateTransform.inputVars');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 16,
            children: [
              Field(
                title: title,
                operations: readOnly
                    ? null
                    : FieldAddButton(label: '${tc('operation.add')} $title', onPressed: c.handleAddEmptyVariable),
                child: VarList(
                  readonly: readOnly,
                  list: varListItemsOf(variables),
                  scope: vars.scope,
                  filterVar: (v, _) => TemplateConfig.filterVar(v.type),
                  isSupportFileVar: false,
                  onVarNameChange: c.handleVarNameChange,
                  onChange: (rows) => c.handleVarListChange(varListDataOf(rows, variables)),
                  onError: CorePanelHost.of(context).toastError,
                ),
              ),
              const PanelSplit(),
              CodeEditorSupportVars(
                availableVars: vars.scope.vars,
                varList: jsList(variables),
                onAddVar: c.handleAddVariable,
                isInNode: true,
                readOnly: readOnly,
                language: CodeLanguage.python3,
                titleWidget: Text(tw('nodes.templateTransform.code').toUpperCase()),
                headerRight: _JinjaTip(onOpen: () => props.actions.options.openUrl?.call(jinjaDocsUrl)),
                value: jsStr(inputs['template']) ?? '',
                onChange: c.handleCodeChange,
              ),
            ],
          ),
        ),
        const PanelSplit(),
        OutputVars(
          child: VarItem(
            name: 'output',
            type: VarType.string,
            description: tw('nodes.templateTransform.outputVars.output'),
          ),
        ),
      ],
    );
  }
}

/// The header's "Only supports Jinja2 ?" link (`flex h-4.5 items-center space-x-0.5 text-xs text-text-tertiary`)
/// and the divider after it (`mx-1.5 h-3 w-px bg-divider-regular`).
class _JinjaTip extends StatelessWidget {
  const _JinjaTip({required this.onOpen});
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final label = tw('nodes.templateTransform.codeSupportTip');
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          link: true,
          linkUrl: Uri.parse(jinjaDocsUrl),
          label: label,
          excludeSemantics: true,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: onOpen,
              child: SizedBox(
                height: 18,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  spacing: 2,
                  children: [
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 200),
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: difyTextStyle(DifyTw.textXsLeading18, DifyColors.textTertiary),
                      ),
                    ),
                    RemixIcon('question-line', size: 12, color: DifyColors.textTertiary),
                  ],
                ),
              ),
            ),
          ),
        ),
        Container(
          width: 1,
          height: 12,
          margin: const EdgeInsets.symmetric(horizontal: 6),
          color: DifyColors.dividerRegular,
        ),
      ],
    );
  }
}
