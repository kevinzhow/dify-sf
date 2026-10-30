import 'package:flutter/widgets.dart';

import '../../../../agents/model_inputs.dart';
import '../../../../design/widgets/widgets.dart';
import '../../../../i18n/dify_i18n.dart';
import '../../../panel_fields/panel_fields.dart';

/// Bind workflow inputs without changing the reusable agent's fixed configuration.
class AgentModelInputFields extends StatelessWidget {
  const AgentModelInputFields({
    super.key,
    required this.value,
    required this.scope,
    required this.onChange,
    this.readOnly = false,
  });
  final Map<String, Object?> value;
  final VarScope scope;
  final bool readOnly;
  final ValueChanged<Map<String, Object?>> onChange;

  String _t(String key) => DifyI18n.tr('agent-v-2', 'inline.$key');

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    spacing: 16,
    children: [
      // Existing bindings remain model-name inputs; newly enabled model inputs select a complete model.
      for (final key in [
        value.containsKey('model') ? 'model' : 'selection',
        'reasoning_effort',
      ])
        Field(
          title: _t(switch (key) {
            'selection' => 'runtimeSelection',
            'model' => 'runtimeModel',
            _ => 'runtimeReasoning',
          }),
          operations: FormInputTypeSwitch(
            value: value.containsKey(key)
                ? VarKindType.variable
                : VarKindType.constant,
            readonly: readOnly,
            onChanged: (kind) => onChange(
              {...value}
                ..remove(key)
                ..addAll(kind == VarKindType.variable ? {key: ''} : const {}),
            ),
          ),
          child: value.containsKey(key)
              ? VarReferencePicker(
                  key: ValueKey('agent-model-$key'),
                  value: agentModelInputSelector(value[key]) ?? const [],
                  scope: scope,
                  readonly: readOnly,
                  filterVar: (v, _) => v.type == 'string',
                  isShowNodeName: true,
                  onChange: (selector, _) => onChange({
                    ...value,
                    key: selector.isEmpty ? '' : '{{#${selector.join('.')}#}}',
                  }),
                )
              : DifyTextLine(_t('fromConfiguration')),
        ),
    ],
  );
}
