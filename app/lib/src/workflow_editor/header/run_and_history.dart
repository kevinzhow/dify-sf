import 'package:flutter/widgets.dart';

import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';
import '../store/workflow_store_scope.dart';
import 'checklist/checklist.dart';
import 'header_data.dart';
import 'header_widgets.dart';
import 'hotkey.dart';
import 'test_run_menu.dart';
import 'view_history.dart';

String _tr(String key) => DifyI18n.tr('workflow', key);

/// header/run-and-history.tsx: the pill with the run button (Test Run in workflows, Preview in chatflows), the run
/// history and the checklist.
class RunAndHistory extends StatelessWidget {
  const RunAndHistory({
    super.key,
    this.showRunButton = false,
    this.runButtonText,
    this.showPreviewButton = false,
    this.runMode,
  });

  final bool showRunButton;
  final String? runButtonText;
  final bool showPreviewButton;

  /// `components.RunMode`: replaces the run button, given its text and whether it is disabled.
  final Widget Function(String? text, bool disabled)? runMode;

  @override
  Widget build(BuildContext context) {
    final data = WorkflowHeaderScope.of(context);
    final store = WorkflowStoreScope.of(context);
    final disabled = !data.canRun;
    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 2),
      decoration: headerPillDecoration(),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showRunButton) runMode?.call(runButtonText, disabled) ?? RunMode(text: runButtonText, disabled: disabled),
          if (showPreviewButton) PreviewMode(disabled: disabled),
          const HeaderDivider(margin: 2),
          const ViewHistory(),
          ListenableBuilder(
            listenable: nodesReadOnlyListenable(store),
            builder: (context, _) => WorkflowChecklist(disabled: nodesReadOnlyOf(store, canEdit: data.canEdit)),
          ),
        ],
      ),
    );
  }
}

/// run-and-history.tsx PreviewMode: `flex h-7 items-center rounded-md px-2.5 text-[13px] font-medium
/// text-components-button-secondary-accent-text hover:bg-state-accent-hover`, play icon, "Preview".
class PreviewMode extends StatelessWidget {
  const PreviewMode({super.key, this.disabled = false});
  final bool disabled;

  @override
  Widget build(BuildContext context) {
    final data = WorkflowHeaderScope.of(context);
    final off = disabled || !data.canRun;
    return HeaderPressable(
      disabled: off,
      onPressed: data.onRunInChatflow,
      builder: (context, hovered) => Opacity(
        opacity: off ? 0.5 : 1,
        child: Container(
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: hovered ? DifyColors.stateAccentHover : null,
            borderRadius: BorderRadius.circular(DifyRadius.md),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const RemixIcon('play-large-line', size: 16, color: DifyColors.componentsButtonSecondaryAccentText),
              const SizedBox(width: 4),
              Text(
                _tr('common.debugAndPreview'),
                style: const TextStyle(
                  fontSize: 13,
                  height: 16 / 13,
                  fontWeight: FontWeight.w500,
                  color: DifyColors.componentsButtonSecondaryAccentText,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// header/run-mode.tsx: "Test Run" (Alt+R opens the start-node menu), "Running"/"Listening" with Stop while a run
/// goes on, dimmed without run permission. A start option with checklist warnings is refused with a toast.
class RunMode extends StatefulWidget {
  const RunMode({super.key, this.text, this.disabled = false});
  final String? text;
  final bool disabled;

  @override
  State<RunMode> createState() => _RunModeState();
}

class _RunModeState extends State<RunMode> {
  final _menu = TestRunMenuController();

  void _select(WorkflowHeaderData data, TriggerOption option, bool disabled) {
    if (disabled) return;
    if (data.facts.checklist.any((n) => n.id == option.nodeId)) {
      data.toast?.call(HeaderToastType.error, _tr('panel.checklistTip'));
      return;
    }
    data.onRun?.call(option);
  }

  @override
  Widget build(BuildContext context) {
    final data = WorkflowHeaderScope.of(context);
    final store = WorkflowStoreScope.of(context);
    final disabled = widget.disabled || !data.canRun;
    return PageHotkey(
      hotkey: testRunMenuHotkey,
      onPressed: () {
        if (!disabled) _menu.toggle();
      },
      child: ListenableBuilder(
        listenable: Listenable.merge([store.workflowRunningData, store.isListening, ?data.graph]),
        builder: (context, _) {
          final isListening = store.isListening.value;
          final running = runningStatusOf(store.workflowRunningData.value) == WorkflowRunningStatus.running;
          final isRunning = running || isListening;
          final label = widget.text ?? _tr('common.run');
          Widget button(bool hovered, {required bool dim}) => _RunButtonFace(label: label, hovered: hovered, dim: dim);
          final Widget main;
          if (disabled) {
            main = HeaderPressable(disabled: true, builder: (context, _) => button(false, dim: true));
          } else if (isRunning) {
            main = Semantics(
              button: true,
              enabled: false,
              child: Container(
                height: 28,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                decoration: const BoxDecoration(
                  color: DifyColors.stateAccentHover,
                  borderRadius: BorderRadius.horizontal(left: Radius.circular(DifyRadius.md)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Spinning(child: RemixIcon('loader-2-line', size: 16, color: DifyColors.textAccent)),
                    const SizedBox(width: 8),
                    Text(
                      _tr(isListening ? 'common.listening' : 'common.running'),
                      style: difyTextStyle(DifyType.systemXsMedium, DifyColors.textAccent),
                    ),
                  ],
                ),
              ),
            );
          } else {
            main = TestRunMenu(
              controller: _menu,
              options: testRunOptionsOf(data.facts.nodes),
              onSelect: (o) => _select(data, o, disabled),
              builder: (context, activate) =>
                  HeaderPressable(onPressed: activate, builder: (context, hovered) => button(hovered, dim: false)),
            );
          }
          return Row(
            mainAxisSize: MainAxisSize.min,
            spacing: 1,
            children: [
              main,
              if (isRunning && !disabled)
                HeaderPressable(
                  semanticLabel: _tr('debug.variableInspect.trigger.stop'),
                  onPressed: () => data.onStopRun?.call('${store.workflowRunningData.value?['task_id'] ?? ''}'),
                  builder: (context, _) => Container(
                    width: 28,
                    height: 28,
                    decoration: const BoxDecoration(
                      color: DifyColors.stateAccentActive,
                      borderRadius: BorderRadius.horizontal(right: Radius.circular(DifyRadius.md)),
                    ),
                    alignment: Alignment.center,
                    child: const RemixIcon('stop-circle-line', size: 16, color: DifyColors.textAccent),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// The run button's face: `flex h-7 items-center gap-x-1 rounded-md px-1.5 system-xs-medium text-text-accent`,
/// `mr-1` play icon, the label and the Alt R keycaps; hover `bg-state-accent-hover`, disabled `opacity-50`.
class _RunButtonFace extends StatelessWidget {
  const _RunButtonFace({required this.label, required this.hovered, required this.dim});
  final String label;
  final bool hovered;
  final bool dim;

  @override
  Widget build(BuildContext context) => Opacity(
    opacity: dim ? 0.5 : 1,
    child: Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: hovered ? DifyColors.stateAccentHover : null,
        borderRadius: BorderRadius.circular(DifyRadius.md),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const RemixIcon('play-large-line', size: 16, color: DifyColors.textAccent),
          const SizedBox(width: 8),
          Text(label, style: difyTextStyle(DifyType.systemXsMedium, DifyColors.textAccent)),
          const SizedBox(width: 4),
          const DifyShortcutKbd(hotkey: testRunMenuHotkey, secondaryText: true),
        ],
      ),
    ),
  );
}
