import 'package:flutter/widgets.dart';

import '../../../../design/widgets/widgets.dart';
import '../../../../i18n/dify_i18n.dart';
import '../../../panel_fields/panel_fields.dart';

class AgentSessionRetentionField extends StatelessWidget {
  const AgentSessionRetentionField({
    super.key,
    required this.enabled,
    required this.onChange,
    this.readOnly = false,
  });
  final bool enabled;
  final bool readOnly;
  final ValueChanged<bool> onChange;

  @override
  Widget build(BuildContext context) => Field(
    title: DifyI18n.tr('agent-v-2', 'inline.sessionCarry'),
    operations: DifySwitch(
      checked: enabled,
      disabled: readOnly,
      semanticLabel: DifyI18n.tr('agent-v-2', 'inline.sessionCarry'),
      onCheckedChange: onChange,
    ),
    child: DifyTextLine(DifyI18n.tr('agent-v-2', 'inline.sessionHelp')),
  );
}
