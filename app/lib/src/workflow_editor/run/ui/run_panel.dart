/// run/index.tsx (RunPanel: a past run's RESULT / DETAIL / TRACING, fetched) and panel/record.tsx (the run history
/// view's "Test Run (time)" panel around it).
library;

import 'package:flutter/widgets.dart';

import '../../../design/css_metrics.dart';
import '../../../agents/canvas_progress.dart';
import '../../../canvas/agent_progress_view.dart';
import '../run_service.dart';
import '../run_types.dart' show jsonCopy;
import '../run_observation.dart';
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

enum RunPanelTabType { result, detail, tracing, progress }

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
    this.observeService,
    this.toast,
  });

  final String runId;
  final bool hideResult;
  final RunPanelTabType activeTab;
  final ValueChanged<DifyJson>? getResultCallback;
  final Future<DifyJson> Function(String runId)? fetchRunDetail;
  final Future<List<DifyJson>> Function(String runId)? fetchTracingList;
  final WorkflowRunService? observeService;
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
  final _viewStore = WorkflowStore();
  WorkflowRunObservation? _observation;
  int _generation = 0;
  bool _openedProgress = false;
  bool _projected = false;
  Map<String, DifyJson>? _beforeNodes, _beforeEdges, _lastNodes, _lastEdges;
  DifyJson? _beforeRunning, _lastRunning;

  void _releaseProjection() {
    final store = _store;
    if (!_projected || store == null) return;
    final beforeNodes = _beforeNodes!,
        beforeEdges = _beforeEdges!,
        beforeRunning = _beforeRunning;
    final lastNodes = _lastNodes,
        lastEdges = _lastEdges,
        lastRunning = _lastRunning;
    _projected = false;
    // Unmount and run-ID changes happen while the widget tree is locked. Other editor listeners remain alive.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (store.isDisposed) return;
      if (identical(store.nodeRunData.value, lastNodes)) {
        store.nodeRunData.value = beforeNodes;
      }
      if (identical(store.edgeRunData.value, lastEdges)) {
        store.edgeRunData.value = beforeEdges;
      }
      if (identical(store.workflowRunningData.value, lastRunning)) {
        store.workflowRunningData.value = beforeRunning;
      }
    });
  }

  void _observed() {
    if (!mounted) return;
    final data = _viewStore.workflowRunningData.value;
    if (data == null) return;
    final result = data['result'];
    final tracing = data['tracing'];
    setState(() {
      if (result is Map) _runDetail = {...?_runDetail, ...result.cast<String, Object?>()};
      if (tracing is List) _list = tracing.whereType<Map>().map((v) => v.cast<String, Object?>()).toList();
      if (!_openedProgress &&
          _tab == RunPanelTabType.result &&
          const {'running', 'paused'}.contains(_runDetail?['status']) &&
          _list.any((n) => n['node_type'] == 'agent')) {
        _openedProgress = true;
        _tab = RunPanelTabType.progress;
      }
    });
    // The editor's history is a local run view, never a collaborative document change.
    if (_store?.historyWorkflowData.value?['id'] == widget.runId) {
      if (!_projected) {
        _projected = true;
        _beforeNodes = _store!.nodeRunData.value;
        _beforeEdges = _store!.edgeRunData.value;
        _beforeRunning = _store!.workflowRunningData.value;
      }
      _store!.workflowRunningData.value = _lastRunning = jsonCopy(data);
      _store!.nodeRunData.value = _lastNodes = {..._viewStore.nodeRunData.value};
      _store!.edgeRunData.value = _lastEdges = {..._viewStore.edgeRunData.value};
    }
  }

  void _followIfActive() {
    if (_observation != null || !const {'running', 'paused'}.contains(_runDetail?['status'])) return;
    final scope = WorkflowRunScope.maybeOf(context);
    final service = widget.observeService ?? scope?.run.service;
    if (service == null) return;
    _observation = WorkflowRunObservation(store: _viewStore, service: service, graph: scope?.run.graph);
    _observation!.follow(widget.runId);
  }

  @override
  void initState() {
    super.initState();
    _viewStore.workflowRunningData.addListener(_observed);
  }

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
    if (old.runId != widget.runId) {
      _releaseProjection();
      _observation?.dispose();
      _observation = null;
      _runDetail = null;
      _openedProgress = false;
      _list = const [];
      _getData();
    }
  }

  @override
  void dispose() {
    _store?.isListening.removeListener(_listening);
    _generation++;
    _releaseProjection();
    _observation?.dispose();
    _viewStore.workflowRunningData.removeListener(_observed);
    _viewStore.dispose();
    super.dispose();
  }

  void _listening() {
    if (_store?.isListening.value == true && mounted) setState(() => _tab = RunPanelTabType.detail);
  }

  void _error(Object e) => (widget.toast ?? difyToast)(DifyToastType.error, '$e');

  Future<void> _getResult() async {
    final fetch = _fetchDetail;
    if (fetch == null) return;
    final generation = _generation, runId = widget.runId;
    try {
      final res = await fetch(runId);
      if (!mounted || generation != _generation || runId != widget.runId) return;
      setState(() => _runDetail = res);
      widget.getResultCallback?.call(res);
    } catch (e) {
      _error(e);
    }
  }

  Future<void> _getTracingList() async {
    final fetch = _fetchTracing;
    if (fetch == null) return;
    final generation = _generation, runId = widget.runId;
    try {
      final list = await fetch(runId);
      if (mounted && generation == _generation && runId == widget.runId) {
        setState(() => _list = list);
        _viewStore.workflowRunningData.value = {'result': _runDetail ?? const <String, Object?>{}, 'tracing': list};
      }
    } catch (e) {
      _error(e);
    }
  }

  Future<void> _getData() async {
    final generation = ++_generation;
    final runId = widget.runId;
    setState(() => _loading = true);
    DifyJson? detail;
    List<DifyJson> list = const [];
    try {
      detail = await _fetchDetail?.call(runId);
    } catch (e) {
      if (mounted && generation == _generation) _error(e);
    }
    try {
      list = await _fetchTracing?.call(runId) ?? const <DifyJson>[];
    } catch (e) {
      if (mounted && generation == _generation) _error(e);
    }
    if (!mounted || generation != _generation) return;
    setState(() {
      _runDetail = detail;
      _list = list;
      _loading = false;
    });
    if (detail != null) widget.getResultCallback?.call(detail);
    final projected = <String, DifyJson>{};
    for (final node in list) {
      final id = node['node_id'];
      if (id is! String) continue;
      final progress = node['node_type'] == 'agent'
          ? AgentProgressView.finished(null, AgentProgressView.map(node['execution_metadata']))
          : null;
      projected[id] = {'_runningStatus': node['status'], if (progress != null) '_agentProgress': progress.json};
    }
    _viewStore.nodeRunData.value = projected;
    _viewStore.edgeRunData.value = {};
    _viewStore.workflowRunningData.value = {
      'result': detail ?? const <String, Object?>{},
      'tracing': [for (final item in list) jsonCopy(item)],
    };
    _followIfActive();
  }

  Future<void> _switchTab(RunPanelTabType tab) async {
    setState(() => _tab = tab);
    if (_observation != null) return;
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
    final seen = <Object?>{};
    final agents = _list.reversed.where((n) => n['node_type'] == 'agent' && seen.add(n['node_id'])).toList();
    return WorkflowStoreScope(
      store: _viewStore,
      child: Column(
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
                if (agents.isNotEmpty)
                  runPanelTab(
                    label: DifyI18n.tr('agent-v-2', 'inline.progressDetails'),
                    active: _tab == RunPanelTabType.progress,
                    onTap: () => _switchTab(RunPanelTabType.progress),
                  ),
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
                        return TracingPanel(
                          list: _list,
                          background: DifyColors.backgroundSectionBurn,
                          scrollable: true,
                        );
                      case RunPanelTabType.progress:
                        return ListView(
                          children: [
                            for (final node in agents)
                              AgentCanvasProgress(
                                nodeId: '${node['node_id']}',
                                progress:
                                    AgentProgressView.finished(
                                      null,
                                      AgentProgressView.map(node['execution_metadata']),
                                    ) ??
                                    AgentProgressView(run: '${node['id']}', cursor: 0),
                              ),
                          ],
                        );
                    }
                  },
                ),
              ),
            ),
          ),
        ],
      ),
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
