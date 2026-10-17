import 'package:flutter/widgets.dart';

import '../../design/css_metrics.dart';
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../editor/undo_manager.dart';
import '../../i18n/dify_i18n.dart';
import 'action_bar.dart';
import 'actions.dart';

/// use-workflow-history.ts getHistoryLabel.
String historyLabel(HistoryEvent event) => switch (event) {
  HistoryEvent.nodeTitleChange => tw('changeHistory.nodeTitleChange'),
  HistoryEvent.nodeDescriptionChange => tw('changeHistory.nodeDescriptionChange'),
  HistoryEvent.layoutOrganize || HistoryEvent.nodeDragStop => tw('changeHistory.nodeDragStop'),
  HistoryEvent.nodeChange => tw('changeHistory.nodeChange'),
  HistoryEvent.nodeConnect => tw('changeHistory.nodeConnect'),
  HistoryEvent.nodePaste => tw('changeHistory.nodePaste'),
  HistoryEvent.nodeDelete => tw('changeHistory.nodeDelete'),
  HistoryEvent.nodeAdd => tw('changeHistory.nodeAdd'),
  HistoryEvent.edgeDelete || HistoryEvent.edgeDeleteByDeleteBranch => tw('changeHistory.edgeDelete'),
  HistoryEvent.nodeResize => tw('changeHistory.nodeResize'),
  HistoryEvent.noteAdd => tw('changeHistory.noteAdd'),
  HistoryEvent.noteChange => tw('changeHistory.noteChange'),
  HistoryEvent.noteDelete => tw('changeHistory.noteDelete'),
  HistoryEvent.edgeSourceHandleChange => 'Unknown Event',
};

/// One row of the change history: the state after [step] (null: the session start), [index] steps from now
/// (positive: forward).
typedef HistoryEntry = ({HistoryStep? step, int index});

/// view-workflow-history.tsx calculateChangeList: the future states (farthest first), the current state, then the
/// past states (latest first). Empty when nothing was changed.
List<HistoryEntry> historyEntries(UndoManager history) {
  final past = history.past, future = history.future;
  final p = past.length, f = future.length;
  if (p + f == 0) return const [];
  return [
    for (var k = f; k >= 1; k--) (step: future[f - k], index: k),
    (step: p > 0 ? past[p - 1] : null, index: 0),
    for (var i = p - 1; i >= 0; i--) (step: i >= 1 ? past[i - 1] : null, index: i - p),
  ];
}

/// A row's text: `{node title} {event} ({n} steps forward/backward | Current State)`.
String historyEntryText(UndoManager history, HistoryEntry e) {
  final s = e.step;
  final base = s == null ? tw('changeHistory.sessionStart') : historyLabel(s.event);
  final title = s?.nodeTitle?.isNotEmpty == true
      ? s!.nodeTitle!
      : s?.nodeId == null
      ? ''
      : history.doc().nodes[s!.nodeId]?.title ?? '';
  final count = e.index.abs();
  final steps = e.index == 0
      ? tw('changeHistory.currentState')
      : tw(e.index > 0 ? 'changeHistory.stepForward' : 'changeHistory.stepBackward', {'count': count});
  return '${title.isEmpty ? base : '$title $base'} ($steps)';
}

/// header/view-workflow-history.tsx: the Change History button and its popover. Choosing a row undoes or redoes
/// up to it.
class ViewWorkflowHistory extends StatefulWidget {
  const ViewWorkflowHistory({super.key, required this.history, this.disabled = false});

  final UndoManager history;
  final bool disabled;

  @override
  State<ViewWorkflowHistory> createState() => _ViewWorkflowHistoryState();
}

class _ViewWorkflowHistoryState extends State<ViewWorkflowHistory> {
  bool _open = false;

  void _close() => setState(() => _open = false);

  @override
  Widget build(BuildContext context) {
    final title = tw('changeHistory.title');
    return DifyPopover(
      open: _open,
      onOpenChange: (open) {
        if (!widget.disabled) setState(() => _open = open);
      },
      placement: DifyPlacement.bottomEnd,
      surface: false,
      content: _HistoryPanel(history: widget.history, onClose: _close),
      builder: (context, c) => DifyTipPopup(
        title: title,
        child: OperatorButton(
          label: title,
          icon: const RemixIcon('history-line'),
          active: _open,
          disabled: widget.disabled,
          onPressed: c.toggle,
        ),
      ),
    );
  }
}

class _HistoryPanel extends StatelessWidget {
  const _HistoryPanel({required this.history, required this.onClose});

  final UndoManager history;
  final VoidCallback onClose;

  void _jump(int index) {
    for (var i = 0; i < index.abs(); i++) {
      index < 0 ? history.undo() : history.redo();
    }
    onClose();
  }

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(DifyRadius.xl);
    const rowText = TextStyle(
      fontSize: 13,
      height: 18 / 13,
      fontWeight: FontWeight.w500,
      color: DifyColors.textSecondary,
    );
    Widget row(
      String text,
      VoidCallback onTap, {
      bool current = false,
      EdgeInsets margin = const EdgeInsets.only(bottom: 2),
    }) => Padding(
      padding: margin,
      child: DifyPressable(
        onPressed: onTap,
        builder: (context, hovered, focused) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          decoration: BoxDecoration(
            color: hovered || current ? DifyColors.stateBaseHover : null,
            borderRadius: BorderRadius.circular(DifyRadius.lg),
          ),
          child: Text(text, style: rowText),
        ),
      ),
    );
    return ListenableBuilder(
      listenable: history,
      builder: (context, _) {
        final entries = historyEntries(history);
        return DifyBlurredBox(
          blur: 5,
          borderRadius: r,
          decoration: BoxDecoration(
            color: DifyColors.componentsPanelBgBlur,
            border: Border.all(color: DifyColors.componentsPanelBorder, width: Css.hairline),
            borderRadius: r,
            boxShadow: DifyShadows.xl,
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 240, maxWidth: 360),
            child: IntrinsicWidth(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            tw('changeHistory.title'),
                            style: const TextStyle(fontSize: 16, height: 1.5, color: DifyColors.textSecondary),
                          ),
                        ),
                        DifyIconButton(
                          label: DifyI18n.tr('common', 'operation.close'),
                          variant: DifyButtonVariant.ghost,
                          icon: const RemixIcon('close-line', color: DifyColors.textSecondary),
                          onPressed: onClose,
                        ),
                      ],
                    ),
                  ),
                  ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height / 2),
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (entries.isEmpty)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 48),
                              child: Column(
                                children: [
                                  const RemixIcon('history-line', size: 32, color: DifyColors.textTertiary),
                                  const SizedBox(height: 8),
                                  Text(
                                    tw('changeHistory.placeholder'),
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(fontSize: 13, color: DifyColors.textTertiary),
                                  ),
                                ],
                              ),
                            ),
                          for (final e in entries)
                            row(historyEntryText(history, e), () => _jump(e.index), current: e.index == 0),
                        ],
                      ),
                    ),
                  ),
                  if (entries.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const DifyDivider(margin: EdgeInsets.zero),
                          row(
                            tw('changeHistory.clearHistory'),
                            () {
                              history.clear();
                              onClose();
                            },
                            margin: const EdgeInsets.symmetric(vertical: 2),
                          ),
                        ],
                      ),
                    ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Container(
                      width: 240,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            height: 22,
                            margin: const EdgeInsets.only(bottom: 4),
                            alignment: Alignment.centerLeft,
                            child: Text(
                              tw('changeHistory.hint').toUpperCase(),
                              style: const TextStyle(
                                fontSize: 12,
                                height: 16 / 12,
                                fontWeight: FontWeight.w500,
                                color: DifyColors.textTertiary,
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Text(
                              tw('changeHistory.hintText'),
                              style: const TextStyle(fontSize: 12, height: 18 / 12, color: DifyColors.textTertiary),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
