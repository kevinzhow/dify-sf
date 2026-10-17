/// The Answer node's panel (nodes/answer/panel.tsx, use-config.ts).
library;

import 'package:flutter/widgets.dart';

import '../../../../workflow/var_types.dart' show VarType;
import '../../../panel_fields/panel_fields.dart';
import '../../../prompt_editor/prompt_editor_panel.dart';
import '../../node_panel_bodies.dart';
import 'core_kit.dart';
import 'end_panel.dart' show jsonListOf;

/// use-config.ts (with `useVarList` over `variables`, which the panel does not show).
class AnswerConfig {
  AnswerConfig(this.crud, {required this.readOnly, this.base});
  final PanelInputs crud;
  final bool readOnly;

  /// The base of the answer's typed text.
  final int Function()? base;

  Map<String, Object?> get inputs => crud.inputs;

  void handleAnswerChange(String value) => crud.setInputs({...inputs, 'answer': value}, textKey: 'answer', base: base);

  void handleVarListChange(List<Object?> list) => crud.setInputs({...inputs, 'variables': list});

  void handleAddVariable() => crud.setInputs({
    ...inputs,
    'variables': [
      ...jsonListOf(inputs['variables']),
      {'variable': '', 'value_selector': <Object?>[]},
    ],
  });

  /// The prompt editor offers every variable but `array[object]` ones.
  static bool filterVar(PickerVar v, List<String> _) => v.type != VarType.arrayObject;
}

Widget answerPanelBody(BuildContext context, NodePanelProps props) => _AnswerPanel(props: props);

class _AnswerPanel extends StatefulWidget {
  const _AnswerPanel({required this.props});
  final NodePanelProps props;

  @override
  State<_AnswerPanel> createState() => _AnswerPanelState();
}

class _AnswerPanelState extends State<_AnswerPanel> {
  late final _base = TypingBase(() => widget.props.controller.seenVersion);

  @override
  Widget build(BuildContext context) {
    final p = widget.props;
    final config = AnswerConfig(PanelInputs(p), readOnly: p.readOnly, base: _base.call);
    final vars = panelVars(p);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: DifyPromptEditorPanel(
        readOnly: config.readOnly,
        justVar: true,
        title: tw('nodes.answer.answer'),
        value: jsStrOrEmpty(config.inputs['answer']),
        onChange: config.handleAnswerChange,
        nodesOutputVars: vars.scope.filtered(AnswerConfig.filterVar).vars,
        availableNodes: vars.availableNodes,
        isSupportFileVar: true,
        expandedWidth: p.actions.store.nodePanelWidth.value - 1,
      ),
    );
  }
}

String jsStrOrEmpty(Object? x) => x is String ? x : '';
