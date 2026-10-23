/// run/index.tsx (RunPanel: a past run's RESULT / DETAIL / TRACING, fetched) and panel/record.tsx (the run history
/// view's "Test Run (time)" panel around it).
library;

import 'package:flutter/widgets.dart';

import '../../../design/css_metrics.dart';
import '../../../design/dify_tokens.g.dart';
import '../../../design/widgets/widgets.dart';
import '../../../i18n/dify_i18n.dart';
import '../../header/format.dart' as fmt;
import '../../store/workflow_store.dart';
import '../../store/workflow_store_scope.dart';
import '../run_scope.dart';
import 'result_panel.dart';
import 'run_widgets.dart';
import 'status.dart';
import 'tracing_panel.dart';
import 'workflow_preview.dart' show RunLoading, runPanelTab, runPanelTabs;

String _tr(String key) => DifyI18n.tr('run-log', key);

enum RunPanelTabType { result, detail, tracing }

/// RunPanel: fetches the run's detail and node executions ([fetchRunDetail], [fetchTracingList]; the editor's run
/// controller by default) and shows them under RESULT (outputs), DETAIL (status, input/output, metadata) and TRACING.
class RunPanel extends StatefulWidget {
  const RunPanel({
    super.key,
    required this.runId,
    this.hideResult = false,
    this.activeTab = RunPanelTabType.result,
    this.getResultCallback,
    this.fetchRunDetail,
    this.fetchTracingList,
    this.toast,
  });

  final String runId;
  final bool hideResult;
  final RunPanelTabType activeTab;
  final ValueChanged<DifyJson>? getResultCallback;
  final Future<DifyJson> Function(String runId)? fetchRunDetail;
  final Future<List<DifyJson>> Function(String runId)? fetchTracingList;
  final void Function(DifyToastType type, String message)? toast;

  @override
  State<RunPanel> createState() => _RunPanelState();
}

class _RunPanelState extends State<RunPanel> {
  late RunPanelTabType _tab = widget.activeTab;
  bool _loading = true;
  DifyJson? _runDetail;
  List<DifyJson> _list = const [];
  WorkflowStore? _store;

  Future<DifyJson> Function(String)? get _fetchDetail =>
      widget.fetchRunDetail ?? WorkflowRunScope.maybeOf(context)?.run.fetchRunDetail;
  Future<List<DifyJson>> Function(String)? get _fetchTracing =>
      widget.fetchTracingList ?? WorkflowRunScope.maybeOf(context)?.run.fetchTracingList;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final s = WorkflowStoreScope.of(context);
    if (s != _store) {
      _store?.isListening.removeListener(_listening);
      _store = s..isListening.addListener(_listening);
      _listening();
    }
    if (_runDetail == null && _loading) _getData();
  }

  @override
  void didUpdateWidget(RunPanel old) {
    super.didUpdateWidget(old);
    if (old.runId != widget.runId) _getData();
  }

  @override
  void dispose() {
    _store?.isListening.removeListener(_listening);
    super.dispose();
  }

  void _listening() {
    if (_store?.isListening.value == true && mounted) setState(() => _tab = RunPanelTabType.detail);
  }

  void _error(Object e) => (widget.toast ?? difyToast)(DifyToastType.error, '$e');

  Future<void> _getResult() async {
    final fetch = _fetchDetail;
    if (fetch == null) return;
    try {
      final res = await fetch(widget.runId);
      if (!mounted) return;
      setState(() => _runDetail = res);
      widget.getResultCallback?.call(res);
    } catch (e) {
      _error(e);
    }
  }

  Future<void> _getTracingList() async {
    final fetch = _fetchTracing;
    if (fetch == null) return;
    try {
      final list = await fetch(widget.runId);
      if (mounted) setState(() => _list = list);
    } catch (e) {
      _error(e);
    }
  }

  Future<void> _getData() async {
    setState(() => _loading = true);
    await _getResult();
    await _getTracingList();
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _switchTab(RunPanelTabType tab) async {
    setState(() => _tab = tab);
    if (tab == RunPanelTabType.result) await _getResult();
    await _getTracingList();
  }

  String get _executor {
    final d = _runDetail;
    return switch (d?['created_by_role']) {
      'account' => '${(d!['created_by_account'] as Map?)?['name'] ?? ''}',
      'end_user' => '${(d!['created_by_end_user'] as Map?)?['session_id'] ?? ''}',
      _ => 'N/A',
    };
  }

  @override
  Widget build(BuildContext context) {
    final d = _runDetail;
    final listening = _store?.isListening.value ?? false;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: DifyColors.dividerSubtle, width: Css.hairline),
            ),
          ),
          child: runPanelTabs(
            [
              if (!widget.hideResult)
                runPanelTab(
                  uppercaseStyle: true,
                  label: _tr('result'),
                  active: _tab == RunPanelTabType.result,
                  onTap: () => _switchTab(RunPanelTabType.result),
                ),
              runPanelTab(
                uppercaseStyle: true,
                label: _tr('detail'),
                active: _tab == RunPanelTabType.detail,
                onTap: () => _switchTab(RunPanelTabType.detail),
              ),
              runPanelTab(
                uppercaseStyle: true,
                label: _tr('tracing'),
                active: _tab == RunPanelTabType.tracing,
                onTap: () => _switchTab(RunPanelTabType.tracing),
              ),
            ],
          ),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: const BorderRadius.vertical(bottom: Radius.circular(DifyRadius.xl)),
            child: ColoredBox(
              color: DifyColors.componentsPanelBg,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  if (_loading) return const RunLoading();
                  switch (_tab) {
                    case RunPanelTabType.result:
                      if (d == null) return const SizedBox.shrink();
                      return SingleChildScrollView(
                        child: OutputPanel(
                          outputs: d['outputs'],
                          error: d['error'] as String?,
                          height: constraints.maxHeight - 16 - 16 - 2 - 1,
                        ),
                      );
                    case RunPanelTabType.detail:
                      if (d == null) {
                        return listening
                            ? const SingleChildScrollView(child: StatusPanel(status: 'running', isListening: true))
                            : const SizedBox.shrink();
                      }
                      return SingleChildScrollView(
                        child: ResultPanel.fromJson(
                          d,
                          createdBy: _executor,
                          isListening: listening,
                          onOpenTracingTab: () => _switchTab(RunPanelTabType.tracing),
                        ),
                      );
                    case RunPanelTabType.tracing:
                      return TracingPanel(list: _list, background: DifyColors.backgroundSectionBurn, scrollable: true);
                  }
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Record (panel/record.tsx): the viewed history run (`historyWorkflowData`) in a 400 px panel — "Test Run (time)"
/// over its [RunPanel]. dify-sf keeps the shared document on the canvas (Dify swaps in the run's graph, a document
/// change here); [onResult] receives the run detail for the host to use.
class RunRecord extends StatelessWidget {
  const RunRecord({super.key, this.onResult, this.fetchRunDetail, this.fetchTracingList});
  final ValueChanged<DifyJson>? onResult;
  final Future<DifyJson> Function(String runId)? fetchRunDetail;
  final Future<List<DifyJson>> Function(String runId)? fetchTracingList;

  @override
  Widget build(BuildContext context) {
    final store = WorkflowStoreScope.of(context);
    return ValueListenableBuilder(
      valueListenable: store.historyWorkflowData,
      builder: (context, history, _) {
        if (history == null) return const SizedBox.shrink();
        return Container(
          width: DifyAdaptive.panelWidth(context, 400),
          decoration: BoxDecoration(
            color: DifyColors.componentsPanelBg,
            borderRadius: const BorderRadius.horizontal(left: Radius.circular(DifyRadius.xxl)),
            border: Border.all(color: DifyColors.componentsPanelBorder, width: Css.hairline),
            boxShadow: DifyShadows.xl,
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: DifyTextLine(
                  'Test Run${fmt.formatWorkflowRunIdentifier((history['finished_at'] as num?)?.toInt())}',
                  style: difyTextStyle(DifyType.systemXlSemibold, DifyColors.textPrimary),
                ),
              ),
              Expanded(
                child: RunPanel(
                  key: ValueKey(history['id']),
                  runId: '${history['id'] ?? ''}',
                  getResultCallback: onResult,
                  fetchRunDetail: fetchRunDetail,
                  fetchTracingList: fetchTracingList,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
