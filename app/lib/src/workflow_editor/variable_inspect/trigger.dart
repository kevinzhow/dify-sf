import 'package:flutter/material.dart';

import '../../cards/card_kit.dart';
import '../../design/css_metrics.dart';
import '../../design/dify_tokens.g.dart';
import '../../i18n/dify_i18n.dart';
import '../../design/dify_icon.dart';
import '../../design/widgets/tooltip.dart';
import '../header/header_widgets.dart' show Spinning;
import '../operator/actions.dart' show OperatorReadOnly;
import 'inspect_vars.dart';

/// variable-inspect/trigger.tsx: "VARIABLE INSPECT" while there is nothing to inspect, "View cached variables" and
/// "Clear" once there are variables (environment, conversation and system variables count, as in Dify's
/// useCurrentVars); both open the variable inspect panel unless the nodes are read-only. While a run is going on:
/// "Caching running status" (opens the panel) and, for a preview run, Stop. Nothing while the panel is open.
class VariableInspectTrigger extends StatelessWidget {
  const VariableInspectTrigger({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = VariableInspectScope.of(context), crud = scope.crud, store = crud.store;
    return ListenableBuilder(
      listenable: Listenable.merge([store.showVariableInspectPanel, crud.changes, store.readOnlyChanges]),
      builder: (context, _) {
        if (store.showVariableInspectPanel.value) return const SizedBox.shrink();
        final readOnly = store.nodesReadOnly;
        void open() => readOnly ? null : store.setShowVariableInspectPanel(true);
        final result = store.workflowRunningData.value?['result'];
        // useNodes' `_singleRunningStatus` (a node run step by step) has no counterpart without a runtime.
        if (result is Map && result['status'] == 'running') {
          return Row(
            mainAxisSize: MainAxisSize.min,
            spacing: 4,
            children: [
              _Chip(
                height: 24,
                padding: 8,
                readOnly: false,
                accentHover: true,
                onTap: () => store.setShowVariableInspectPanel(true),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  spacing: 4,
                  children: [
                    const Spinning(child: RemixIcon('loader-2-line', size: 16, color: DifyColors.textAccent)),
                    DifyText(
                      DifyI18n.tr('workflow', 'debug.variableInspect.trigger.running'),
                      DifyType.systemXsMedium,
                      color: DifyColors.textAccent,
                    ),
                  ],
                ),
              ),
              DifyTooltip(
                content: Text(DifyI18n.tr('workflow', 'debug.variableInspect.trigger.stop')),
                child: _Chip(
                  height: 24,
                  padding: 4,
                  readOnly: false,
                  accentHover: true,
                  onTap: scope.onStop,
                  child: const RemixIcon('stop-circle-fill', size: 16, color: DifyColors.textAccent),
                ),
              ),
            ],
          );
        }
        if (!crud.hasVars) {
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
              onTap: readOnly
                  ? null
                  : () {
                      crud.deleteAllInspectorVars();
                      store.setCurrentFocusNodeId('');
                    },
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
