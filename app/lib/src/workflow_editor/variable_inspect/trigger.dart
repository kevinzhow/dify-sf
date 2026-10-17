import 'package:flutter/material.dart';

import '../../cards/card_kit.dart';
import '../../design/css_metrics.dart';
import '../../design/dify_tokens.g.dart';
import '../../i18n/dify_i18n.dart';
import '../store/store.dart';

/// variable-inspect/trigger.tsx: "VARIABLE INSPECT" while there is nothing to inspect, "View cached variables" and
/// "Clear" once there are variables (environment and conversation variables count, as in Dify's useCurrentVars);
/// both open the variable inspect panel. (The running state comes with runs.)
class VariableInspectTrigger extends StatelessWidget {
  const VariableInspectTrigger({super.key, this.readOnly = false, this.onClearAll});

  final bool readOnly;

  /// deleteAllInspectorVars: the cached values of this editor's inspected nodes.
  final VoidCallback? onClearAll;

  @override
  Widget build(BuildContext context) {
    final store = WorkflowStoreScope.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([
        store.showVariableInspectPanel,
        store.environmentVariables,
        store.conversationVariables,
      ]),
      builder: (context, _) {
        if (store.showVariableInspectPanel.value) return const SizedBox.shrink();
        void open() => readOnly ? null : store.setShowVariableInspectPanel(true);
        final cached = store.environmentVariables.value.isNotEmpty || store.conversationVariables.value.isNotEmpty;
        if (!cached) {
          return _Chip(
            height: 20,
            padding: 8,
            readOnly: readOnly,
            onTap: open,
            child: DifyText(
              DifyI18n.tr('workflow', 'debug.variableInspect.trigger.normal'),
              DifyType.system2xsSemiboldUppercase,
              color: readOnly ? DifyColors.textDisabled : DifyColors.textTertiary,
            ),
          );
        }
        return Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 4,
          children: [
            _Chip(
              height: 24,
              padding: 8,
              readOnly: readOnly,
              accentHover: true,
              onTap: open,
              child: DifyText(
                DifyI18n.tr('workflow', 'debug.variableInspect.trigger.cached'),
                DifyType.systemXsMedium,
                color: readOnly ? DifyColors.textDisabled : DifyColors.textAccent,
              ),
            ),
            _Chip(
              height: 24,
              padding: 4,
              readOnly: readOnly,
              accentHover: true,
              onTap: readOnly ? null : onClearAll,
              child: DifyText(
                DifyI18n.tr('workflow', 'debug.variableInspect.trigger.clear'),
                DifyType.systemXsMedium,
                color: readOnly ? DifyColors.textDisabled : DifyColors.textTertiary,
              ),
            ),
          ],
        );
      },
    );
  }
}

/// `flex shrink-0 items-center rounded-md border-[0.5px] border-effects-highlight bg-components-actionbar-bg shadow-lg`.
class _Chip extends StatefulWidget {
  const _Chip({
    required this.height,
    required this.padding,
    required this.readOnly,
    required this.child,
    this.onTap,
    this.accentHover = false,
  });

  final double height;
  final double padding;
  final bool readOnly;
  final bool accentHover;
  final VoidCallback? onTap;
  final Widget child;

  @override
  State<_Chip> createState() => _ChipState();
}

class _ChipState extends State<_Chip> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final hover = _hovered && !w.readOnly;
    return MouseRegion(
      cursor: w.readOnly ? SystemMouseCursors.forbidden : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: w.onTap,
        child: Container(
          height: w.height,
          padding: EdgeInsets.symmetric(horizontal: w.padding),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: hover
                ? (w.accentHover ? DifyColors.componentsActionbarBgAccent : DifyColors.backgroundDefaultHover)
                : DifyColors.componentsActionbarBg,
            borderRadius: BorderRadius.circular(DifyRadius.md),
            border: Border.all(color: DifyColors.effectsHighlight, width: Css.hairline),
            boxShadow: DifyShadows.lg,
          ),
          child: w.child,
        ),
      ),
    );
  }
}
