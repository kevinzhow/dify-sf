/// The Loop panel (nodes/loop/panel.tsx). Exit Loop (loop-end) has none.
library;

import 'package:flutter/widgets.dart';

import '../../../../../cards/card_kit.dart';
import '../../../../../design/dify_icon.dart';
import '../../../../../design/dify_tokens.g.dart';
import '../../../../../workflow/dify_json.dart';
import '../../../../../workflow/var_types.dart';
import '../../../../panel_fields/panel_fields.dart';
import '../../../../prompt_editor/prompt_editor_panel.dart' show workflowNodesMapOf;
import '../../../node_panel_bodies.dart';
import '../data_common.dart';
import '../iteration/iteration_config.dart' show ContainerLimits;
import 'loop_conditions.dart';
import 'loop_config.dart';
import 'loop_variables.dart';
import '../../../panel_edit.dart';

/// The Loop node's body.
Widget loopPanelBody(BuildContext context, NodePanelProps props) {
  final config = LoopConfig.of(props);
  final doc = props.controller.doc;
  final byId = {for (final n in config.loopChildrenNodes) n.id: n};
  final start = doc.nodes.values.where((n) => n.type == 'start').firstOrNull;
  return LoopPanel(
    config: config,
    variableScope: NodeVars.of(props).scope,
    vars: ConditionVars(
      availableVars: config.childrenNodeVars.vars,
      lookup: (id) => byId[id],
      start: start,
      numberVariables: NodeVars.of(props).filtered(typeIn(const {VarType.number})).vars,
      allNodes: (id) => doc.nodes[id],
      nodesMap: workflowNodesMapOf(config.loopChildrenNodes),
    ),
  );
}

/// Exit Loop has no panel in Dify (it is not in PanelComponentMap); the shell's sections stay.
Widget loopEndPanelBody(BuildContext context, NodePanelProps props) => const SizedBox.shrink();

/// A Field whose title sits `pl-3` inside the full-width row (panel.tsx wraps the titles in `<div class="pl-3">`).
class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child, this.tooltip, this.operations});
  final String title;
  final String? tooltip;
  final Widget? operations;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      SizedBox(
        height: 24,
        child: Row(
          children: [
            const SizedBox(width: 12),
            Flexible(child: DifyText(title, DifyType.systemSmSemiboldUppercase, color: DifyColors.textSecondary)),
            if (tooltip != null) ...[const SizedBox(width: 4), Infotip(label: tooltip!, content: Text(tooltip!))],
            const Spacer(),
            ?operations,
          ],
        ),
      ),
      const SizedBox(height: 4),
      child,
    ],
  );
}

/// panel.tsx over [config]: loop variables (their variable-mode values reference [variableScope]), the termination
/// conditions over [vars] and the maximum loop count.
class LoopPanel extends StatelessWidget {
  const LoopPanel({super.key, required this.config, required this.vars, this.variableScope = const VarScope()});

  final LoopConfig config;
  final ConditionVars vars;
  final VarScope variableScope;

  @override
  Widget build(BuildContext context) {
    final c = config, inputs = c.inputs;
    List<Json> maps(Object? v) => [
      for (final e in jsList(v))
        if (e is Map) e.cast<String, Object?>(),
    ];
    final count = inputs['loop_count'];
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Section(
            title: wf('nodes.loop.loopVariables'),
            operations: Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Semantics(
                button: true,
                label: cm('operation.add'),
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: c.handleAddLoopVariable,
                    child: const SizedBox.square(
                      dimension: 20,
                      child: Center(child: RemixIcon('add-line', size: 16, color: DifyColors.textTertiary)),
                    ),
                  ),
                ),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: LoopVariables(
                variables: maps(inputs['loop_variables']),
                scope: variableScope,
                onRemove: c.handleRemoveLoopVariable,
                onUpdate: c.handleUpdateLoopVariable,
              ),
            ),
          ),
          const PanelSplit(margin: EdgeInsets.symmetric(vertical: 8)),
          _Section(
            title: wf('nodes.loop.breakCondition'),
            tooltip: wf('nodes.loop.breakConditionTip'),
            child: ConditionWrap(
              readOnly: c.readOnly,
              conditions: maps(inputs['break_conditions']),
              logicalOperator: jsStr(inputs['logical_operator']),
              handlers: ConditionHandlers.of(c),
              vars: vars,
            ),
          ),
          const PanelSplit(margin: EdgeInsets.only(top: 8)),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: _Section(
              title: wf('nodes.loop.loopMaxCount'),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: InputNumberWithSlider(
                  label: wf('nodes.loop.loopMaxCount'),
                  min: 1,
                  max: ContainerLimits.of(context).loopNodeMaxCount,
                  value: count is num ? count : double.nan,
                  onChange: (v) {
                    final rounded = v.isNaN ? null : v.round();
                    c.handleUpdateLoopCount(rounded ?? 1);
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
