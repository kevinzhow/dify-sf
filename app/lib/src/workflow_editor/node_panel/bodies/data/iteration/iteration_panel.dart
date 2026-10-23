/// The Iteration panel (nodes/iteration/panel.tsx).
library;

import 'package:flutter/widgets.dart';

import '../../../../../design/dify_tokens.g.dart';
import '../../../../panel_fields/panel_fields.dart';
import '../../../node_panel_bodies.dart';
import '../data_common.dart';
import 'iteration_config.dart';
import '../../../panel_edit.dart';
import '../../../../../design/widgets/widgets.dart';

/// The Iteration node's body.
Widget iterationPanelBody(BuildContext context, NodePanelProps props) => IterationPanel(
  config: IterationConfig.of(props),
  inputScope: NodeVars.of(props).filtered((v, _) => filterIterationInputVar(v.type)),
);

/// The "Array" badge beside the Input and Output titles (`flex h-4.5 items-center rounded-[5px] border
/// border-divider-deep px-1 system-2xs-medium-uppercase text-text-tertiary`).
class ArrayBadge extends StatelessWidget {
  const ArrayBadge({super.key});

  @override
  Widget build(BuildContext context) => Container(
    height: 18,
    padding: const EdgeInsets.symmetric(horizontal: 4),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(5),
      border: Border.all(color: DifyColors.dividerDeep),
    ),
    // `system-2xs-medium-uppercase … capitalize`: the later `capitalize` wins.
    child: Center(
      widthFactor: 1,
      child: DifyText('Array', DifyType.system2xsMedium, color: DifyColors.textTertiary),
    ),
  );
}

/// panel.tsx over [config]; the input picker offers [inputScope]'s arrays.
class IterationPanel extends StatelessWidget {
  const IterationPanel({super.key, required this.config, required this.inputScope});

  final IterationConfig config;
  final VarScope inputScope;

  @override
  Widget build(BuildContext context) {
    final c = config, inputs = c.inputs;
    final limit = ContainerLimits.of(context).maxParallelLimit;
    final isParallel = inputs['is_parallel'] == true;
    final parallelNums = inputs['parallel_nums'] is num ? inputs['parallel_nums']! as num : 10;
    final maxTitle = wf('nodes.iteration.MaxParallelismTitle');
    final modes = iterationErrorModes();
    List<String> sel(Object? v) => [for (final s in v as List? ?? const []) '$s'];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Field(
              title: wf('nodes.iteration.input'),
              required: true,
              operations: const ArrayBadge(),
              child: VarReferencePicker(
                readonly: c.readOnly,
                value: sel(inputs['iterator_selector']),
                onChange: c.handleInputChange,
                scope: inputScope,
                filterVar: (v, _) => c.filterInputVar(v),
              ),
            ),
          ),
          const PanelSplit(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Field(
              title: wf('nodes.iteration.output'),
              required: true,
              operations: const ArrayBadge(),
              child: VarReferencePicker(
                readonly: c.readOnly,
                value: sel(inputs['output_selector']),
                onChange: c.handleOutputVarChange,
                scope: c.childrenNodeVars,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Field(
              title: wf('nodes.iteration.parallelMode'),
              tooltip: wf('nodes.iteration.parallelPanelDesc'),
              inline: true,
              child: DifySwitch(
                checked: isParallel,
                onCheckedChange: c.changeParallel,
                semanticLabel: wf('nodes.iteration.parallelMode'),
              ),
            ),
          ),
          if (isParallel)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Field(
                title: maxTitle,
                isSubTitle: true,
                tooltip: wf('nodes.iteration.MaxParallelismDesc'),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 16,
                  children: [
                    SizedBox(
                      width: 72,
                      child: DifyNumberField(
                        value: parallelNums,
                        min: minIterationParallelNum,
                        max: limit,
                        disabled: c.readOnly,
                        semanticLabel: maxTitle,
                        onChanged: (v) {
                          if (v != null) c.changeParallelNums(v);
                        },
                      ),
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: DifySlider(
                          value: parallelNums.round().clamp(minIterationParallelNum, limit),
                          min: minIterationParallelNum,
                          max: limit,
                          disabled: c.readOnly,
                          semanticLabel: maxTitle,
                          onChanged: c.changeParallelNums,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          const PanelSplit(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Field(
              title: wf('nodes.iteration.errorResponseMethod'),
              child: DifySelect<String>(
                value: modes.any((m) => m.value == inputs['error_handle_mode'])
                    ? inputs['error_handle_mode']! as String
                    : null,
                options: modes,
                placeholder: cm('placeholder.select'),
                onChanged: c.changeErrorResponseMode,
              ),
            ),
          ),
          const PanelSplit(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Field(
              title: wf('nodes.iteration.flattenOutput'),
              tooltip: wf('nodes.iteration.flattenOutputDesc'),
              inline: true,
              child: DifySwitch(
                checked: inputs['flatten_output'] == true,
                onCheckedChange: c.changeFlattenOutput,
                semanticLabel: wf('nodes.iteration.flattenOutput'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
