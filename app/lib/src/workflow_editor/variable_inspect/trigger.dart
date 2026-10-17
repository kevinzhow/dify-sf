import 'package:flutter/material.dart';

import '../../cards/card_kit.dart';
import '../../design/css_metrics.dart';
import '../../design/dify_tokens.g.dart';
import '../../i18n/dify_i18n.dart';
import '../store/store.dart';

/// variable-inspect/trigger.tsx, the state with nothing inspected and nothing running: "VARIABLE INSPECT", opening
/// the variable inspect panel. (The cached-variables and running states come with the panel.)
class VariableInspectTrigger extends StatefulWidget {
  const VariableInspectTrigger({super.key, this.readOnly = false});

  final bool readOnly;

  @override
  State<VariableInspectTrigger> createState() => _VariableInspectTriggerState();
}

class _VariableInspectTriggerState extends State<VariableInspectTrigger> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final store = WorkflowStoreScope.of(context);
    return ValueListenableBuilder(
      valueListenable: store.showVariableInspectPanel,
      builder: (context, open, _) {
        if (open) return const SizedBox.shrink();
        final ro = widget.readOnly;
        return MouseRegion(
          cursor: ro ? SystemMouseCursors.forbidden : SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            onTap: ro ? null : () => store.setShowVariableInspectPanel(true),
            child: Container(
              height: 20,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: _hovered && !ro ? DifyColors.backgroundDefaultHover : DifyColors.componentsActionbarBg,
                borderRadius: BorderRadius.circular(DifyRadius.md),
                border: Border.all(color: DifyColors.effectsHighlight, width: Css.hairline),
                boxShadow: DifyShadows.lg,
              ),
              child: DifyText(
                DifyI18n.tr('workflow', 'debug.variableInspect.trigger.normal'),
                DifyType.system2xsSemiboldUppercase,
                color: ro ? DifyColors.textDisabled : DifyColors.textTertiary,
              ),
            ),
          ),
        );
      },
    );
  }
}
