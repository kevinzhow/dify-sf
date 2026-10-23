import 'package:flutter/widgets.dart';

import '../../canvas/canvas_input.dart';
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';
import '../store/workflow_store.dart';
import '../store/workflow_store_scope.dart';
import 'header_data.dart';
import 'header_widgets.dart';

String _tr(String key) => DifyI18n.tr('workflow', key);

/// header/view-history.tsx: the run history button (an icon with a tooltip, or "Show Run History" [withText]) and
/// its popup listing the runs; picking one shows that run read-only (Dify's view-history mode).
class ViewHistory extends StatefulWidget {
  const ViewHistory({super.key, this.withText = false});
  final bool withText;

  @override
  State<ViewHistory> createState() => _ViewHistoryState();
}

class _ViewHistoryState extends State<ViewHistory> {
  bool _open = false;

  /// The runs, fetched each time the popup opens (Dify's query is enabled by `open`); null while loading.
  List<DifyJson>? _history = const [];
  int _fetch = 0;

  void _setOpen(bool open) {
    if (open == _open) return;
    setState(() => _open = open);
    final fetch = WorkflowHeaderScope.of(context).fetchRunHistory;
    if (!open || fetch == null) return;
    final n = ++_fetch;
    setState(() => _history = null);
    fetch().then(
      (runs) {
        if (mounted && n == _fetch) setState(() => _history = runs);
      },
      onError: (Object _) {
        if (mounted && n == _fetch) setState(() => _history = const []);
      },
    );
  }

  void _pick(DifyJson item, WorkflowHeaderData data, WorkflowStore store) {
    store
      ..historyWorkflowData.value = item
      ..showInputsPanel.value = false
      ..showEnvPanel.value = false;
    data.closeAllInputFieldPanels?.call();
    data.handleBackupDraft?.call();
    _setOpen(false);
    data.handleNodesCancelSelected?.call();
    // useWorkflowInteractions' handleCancelDebugAndPreviewPanel.
    store
      ..showDebugAndPreviewPanel.value = false
      ..workflowRunningData.value = null;
    store.setControlMode(ControlMode.hand);
  }

  @override
  Widget build(BuildContext context) {
    final data = WorkflowHeaderScope.of(context);
    final store = WorkflowStoreScope.of(context);
    return DifyPopover(
      open: _open,
      onOpenChange: _setOpen,
      placement: widget.withText ? DifyPlacement.bottomStart : DifyPlacement.bottomEnd,
      sideOffset: 4,
      alignOffset: widget.withText ? -8 : 10,
      surface: false,
      builder: (context, c) => widget.withText ? _textTrigger(c) : _iconTrigger(c, data),
      content: Padding(
        padding: const EdgeInsets.only(left: 8),
        child: _HistoryPanel(
          history: _history,
          chatMode: data.isChatMode,
          formatters: data,
          onClose: () {
            data.onClearLogAndMessageModal?.call();
            _setOpen(false);
          },
          selectedId: store.historyWorkflowData,
          onPick: (item) => _pick(item, data, store),
        ),
      ),
    );
  }

  Widget _textTrigger(DifyFloatingController c) => HeaderPressable(
    onPressed: c.toggle,
    builder: (context, hovered) => Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: headerPillDecoration().copyWith(
        color: hovered || _open ? DifyColors.componentsButtonSecondaryBgHover : DifyColors.componentsButtonSecondaryBg,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          DifyIcon('vender/line/time/clock-play', size: 16, color: DifyColors.componentsButtonSecondaryText),
          const SizedBox(width: 4),
          DifyTextLine(
            _tr('common.showRunHistory'),
            // `text-[13px] font-medium`, centred in the h-8 button (the 16 px line lays out as the inherited one).
            style: difyTextStyle(DifyTw.text13MediumLeading16, DifyColors.componentsButtonSecondaryText),
          ),
        ],
      ),
    ),
  );

  Widget _iconTrigger(DifyFloatingController c, WorkflowHeaderData data) {
    final label = _tr('common.viewRunHistory');
    return DifyTooltip(
      content: DifyTextLine(label),
      child: HeaderPressable(
        semanticLabel: label,
        onPressed: () {
          data.onClearLogAndMessageModal?.call();
          c.toggle();
        },
        builder: (context, hovered) {
          final active = hovered || _open;
          return Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: active ? DifyColors.stateAccentHover : null,
              borderRadius: BorderRadius.circular(DifyRadius.md),
            ),
            alignment: Alignment.center,
            child: DifyIcon(
              'vender/line/time/clock-play',
              size: 16,
              color: active ? DifyColors.componentsButtonSecondaryAccentText : DifyColors.componentsButtonGhostText,
            ),
          );
        },
      ),
    );
  }
}

class _HistoryPanel extends StatelessWidget {
  const _HistoryPanel({
    required this.history,
    required this.chatMode,
    required this.formatters,
    required this.onClose,
    required this.selectedId,
    required this.onPick,
  });

  /// Null while loading.
  final List<DifyJson>? history;
  final bool chatMode;
  final WorkflowHeaderData formatters;
  final VoidCallback onClose;
  final ValueNotifier<DifyJson?> selectedId;
  final ValueChanged<DifyJson> onPick;

  @override
  Widget build(BuildContext context) => Container(
    width: 240,
    constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 2 / 3),
    decoration: headerPopupDecoration(),
    clipBehavior: Clip.antiAlias,
    child: Builder(
      builder: (context) {
        final loading = history == null;
        final items = history ?? const <DifyJson>[];
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // `sticky top-0 flex items-center justify-between px-4 pt-3 text-base font-semibold text-text-primary`
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Row(
                children: [
                  Expanded(
                    child: DifyTextLine(
                      _tr('common.runHistory'),
                      style: difyTextStyle(
                        DifyType.systemXlSemibold,
                        DifyColors.textPrimary,
                      ), // text-base font-semibold
                    ),
                  ),
                  HeaderCloseButton(onPressed: onClose, label: DifyI18n.tr('common', 'operation.close')),
                ],
              ),
            ),
            if (loading)
              const SizedBox(height: 40, child: DifyLoading())
            else
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(8),
                  child: items.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.symmetric(vertical: 48),
                          child: Column(
                            children: [
                              DifyIcon(
                                'vender/line/time/clock-play-slim',
                                size: 32,
                                color: DifyColors.textQuaternary,
                              ),
                              const SizedBox(height: 8),
                              DifyTextLine(
                                _tr('common.notRunning'),
                                textAlign: TextAlign.center,
                                style: difyTextStyle(DifyTw.text13Leading16, DifyColors.textQuaternary), // text-[13px]
                              ),
                            ],
                          ),
                        )
                      : ValueListenableBuilder(
                          valueListenable: selectedId,
                          builder: (context, selected, _) => Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (final item in items)
                                _HistoryRow(
                                  item: item,
                                  selected: selected != null && item['id'] == selected['id'],
                                  chatMode: chatMode,
                                  data: formatters,
                                  onTap: () => onPick(item),
                                ),
                            ],
                          ),
                        ),
                ),
              ),
          ],
        );
      },
    ),
  );
}

/// A run: `mb-0.5 flex rounded-lg px-2 py-1.75 hover:bg-state-base-hover` (selected `bg-state-accent-hover`), the
/// status icon (workflows only), "Test Run (time)" and "author ·time ago".
class _HistoryRow extends StatelessWidget {
  const _HistoryRow({
    required this.item,
    required this.selected,
    required this.chatMode,
    required this.data,
    required this.onTap,
  });

  final DifyJson item;
  final bool selected;
  final bool chatMode;
  final WorkflowHeaderData data;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final status = item['status'] as String?;
    final finishedAt = (item['finished_at'] as num?)?.toInt();
    final createdAt = (item['created_at'] as num?)?.toInt() ?? 0;
    final author = (item['created_by_account'] as Map?)?['name'] ?? '';
    final f = data.formatters;
    final icon = chatMode
        ? null
        : switch (status) {
            WorkflowRunningStatus.stopped || WorkflowRunningStatus.paused => DifyIcon(
              'vender/line/alertsAndFeedback/alert-triangle',
              size: 14,
              color: DifyViewHistoryColors.stopped,
            ),
            WorkflowRunningStatus.failed => RemixIcon(
              'error-warning-line',
              size: 14,
              color: DifyViewHistoryColors.failed,
            ),
            WorkflowRunningStatus.succeeded => RemixIcon(
              'checkbox-circle-line',
              size: 14,
              color: DifyViewHistoryColors.succeeded,
            ),
            _ => null,
          };
    return HeaderPressable(
      onPressed: onTap,
      builder: (context, hovered) => Container(
        margin: const EdgeInsets.only(bottom: 2),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
        decoration: BoxDecoration(
          color: selected
              ? DifyColors.stateAccentHover
              : hovered
              ? DifyColors.stateBaseHover
              : null,
          borderRadius: BorderRadius.circular(DifyRadius.lg),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (icon != null) Padding(padding: const EdgeInsets.only(top: 2, right: 6), child: icon),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DifyTextLine(
                    'Test ${chatMode ? 'Chat' : 'Run'}${f.formatWorkflowRunIdentifier(finishedAt, status ?? 'Running')}',
                    style: difyTextStyle(
                      DifyTw.text13MediumLeading18,
                      selected ? DifyColors.textAccent : DifyColors.textPrimary,
                    ),
                  ),
                  DifyTextLine(
                    '$author ·${f.formatTimeFromNow(((finishedAt ?? 0) != 0 ? finishedAt! : createdAt) * 1000)}',
                    style: difyTextStyle(DifyTw.textXsLeading18, DifyColors.textTertiary), // text-xs leading-4.5
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
