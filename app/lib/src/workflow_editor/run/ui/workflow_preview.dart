/// panel/workflow-preview.tsx and panel/inputs-panel.tsx: a workflow's Test Run panel — the INPUT tab (the Start
/// node's variables and Start Run) and the run's RESULT / DETAIL / TRACING tabs, resizable from its left edge.
library;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../../design/css_metrics.dart';
import '../../../design/dify_icon.dart';
import '../../../design/dify_tokens.g.dart';
import '../../../design/widgets/widgets.dart';
import '../../../i18n/dify_i18n.dart';
import '../../header/format.dart' as fmt;
import '../../node_panel/resize_handle.dart';
import '../../store/panel_width.dart' show getPreviewPanelMaxWidth;
import '../../store/workflow_store.dart';
import '../../store/workflow_store_scope.dart';
import '../run_scope.dart';
import '../run_types.dart';
import '../../node_panel/bodies/data/human_input/human_input_kit.dart' show HumanInputHost;
import 'before_run_form.dart';
import 'human_input_content.dart';
import 'result_panel.dart';
import 'run_widgets.dart';
import 'tracing_panel.dart';

String _tr(String key) => DifyI18n.tr('run-log', key);

/// What the run panels need from the editor besides the store: the Start node's variables, whether a node is
/// selected (the panel's max width), the run permission and how to start a run / close the panel.
class RunPanelContext {
  const RunPanelContext({
    this.startVariables = const [],
    this.hasSelectedNode = false,
    this.canRun = true,
    this.onRun,
    this.onCancel,
    this.pickFile,
    this.toast,
    this.onHumanInputFormSubmit,
  });

  /// The Start node's `variables` (InputVar JSON).
  final List<DifyJson> startVariables;
  final bool hasSelectedNode;

  /// `accessControl.canRun`.
  final bool canRun;

  /// useWorkflowRun's `handleRun({inputs, files})`; null: the editor's run controller.
  final void Function(DifyJson params)? onRun;

  /// handleCancelDebugAndPreviewPanel; null: the editor's run controller (or the store alone).
  final VoidCallback? onCancel;
  final RunFilePicker? pickFile;
  final void Function(DifyToastType type, String message)? toast;

  /// `submitHumanInputForm(token, data)`; null: the editor's run service.
  final HumanInputFormSubmit? onHumanInputFormSubmit;
}

/// A run panel's tab as a [DifyTab] with the run panels' className: `mr-6 border-b-2 py-3`, active
/// `border-[rgb(21,94,239)]`, the preview's `text-[13px] leading-4.5 font-semibold` (active `text-text-secondary`) or,
/// with [uppercaseStyle], run/index.tsx's `system-sm-semibold-uppercase` (active `text-text-primary` on
/// blue-brand-600). Disabled tabs are `opacity-30`.
DifyTab runPanelTab({
  required String label,
  required bool active,
  required VoidCallback onTap,
  bool disabled = false,
  bool uppercaseStyle = false,
}) {
  final style = uppercaseStyle
      ? DifyType.systemSmSemiboldUppercase.style
      : const TextStyle(fontSize: 13, height: 18 / 13, fontWeight: FontWeight.w600);
  final color = active ? (uppercaseStyle ? DifyColors.textPrimary : DifyColors.textSecondary) : DifyColors.textTertiary;
  return DifyTab(
    active: active,
    disabled: disabled,
    semanticLabel: label,
    onPressed: onTap,
    builder: (context, hovered, focused) => Opacity(
      opacity: disabled ? 0.3 : 1,
      child: Container(
        margin: const EdgeInsets.only(right: 24),
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              width: 2,
              color: active
                  ? (uppercaseStyle ? DifyColors.utilColorsBlueBrandBlueBrand600 : DifyColors.primary600)
                  : const Color(0x00000000),
            ),
          ),
          boxShadow: difyFocusRing(focused),
        ),
        child: Text(
          uppercaseStyle ? label.toUpperCase() : label,
          style: style.copyWith(color: color),
          strutStyle: Css.lineStrut(style),
        ),
      ),
    ),
  );
}

/// The run panels' [DifyTabsList] (the tabs carry their own `mr-6`); tabs past the panel's edge are clipped (the
/// browser lets them overflow).
Widget runPanelTabs(List<Widget> tabs) => SingleChildScrollView(
  scrollDirection: Axis.horizontal,
  physics: const NeverScrollableScrollPhysics(),
  child: DifyTabsList(gap: 0, children: tabs),
);

/// Base Loading (`<Loading />`, [DifyLoading]) on the panel's background ([color]).
class RunLoading extends StatelessWidget {
  const RunLoading({super.key, this.color});
  final Color? color;

  @override
  Widget build(BuildContext context) =>
      ColoredBox(color: color ?? DifyColors.componentsPanelBg, child: const DifyLoading());
}

/// InputsPanel: one FormItem per Start variable (plus `__image` files when image upload is on), Start Run.
class InputsPanel extends StatelessWidget {
  const InputsPanel({super.key, required this.panel, required this.onRun});
  final RunPanelContext panel;
  final VoidCallback onRun;

  @override
  Widget build(BuildContext context) {
    final store = WorkflowStoreScope.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([store.inputs, store.files, store.workflowRunningData, store.features]),
      builder: (context, _) {
        final inputs = store.inputs.value;
        final initialInputs = <String, Object?>{...inputs};
        for (final v in panel.startVariables) {
          final name = '${v['variable']}';
          final d = v['default'];
          if (d != null && d != '' && d != false && d != 0) initialInputs[name] = d;
          if (inputs.containsKey(name)) initialInputs[name] = inputs[name];
        }
        final imageEnabled = ((store.features.value['file_upload'] as Map?)?['image'] as Map?)?['enabled'] == true;
        final variables = [
          ...panel.startVariables,
          if (imageEnabled) {'type': InputVarType.files, 'variable': '__image', 'required': false, 'label': 'files'},
        ];
        final files = store.files.value;
        final uploadReady = !files.any(
          (f) => f['transfer_method'] == TransferMethod.localFile && (f['upload_file_id'] ?? '') == '',
        );
        final canRun = panel.canRun && uploadReady;
        final running = runningStatusOf(store.workflowRunningData.value) == WorkflowRunningStatus.running;
        void change(String variable, Object? v) {
          if (variable == '__image') {
            store.setFiles([for (final f in (v as List? ?? const [])) f as DifyJson]);
          } else {
            store.setInputs(
              {
                ...store.inputs.value,
                variable: ?v,
              }.cast<String, Object>(),
            );
          }
        }

        void doRun() {
          if (!canRun) return;
          if (checkInputsForm(initialInputs, variables, toast: panel.toast) != true) return;
          onRun();
          final params = {'inputs': getProcessedInputs(initialInputs, variables), 'files': files};
          final run = panel.onRun ?? WorkflowRunScope.maybeOf(context)?.run.handleRun;
          run?.call(params);
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (i, v) in variables.indexed)
                    Padding(
                      key: ValueKey('input-${v['variable']}'),
                      padding: EdgeInsets.only(bottom: i == variables.length - 1 ? 0 : 8),
                      child: RunFormItem(
                        autoFocus: i == 0,
                        payload: v,
                        value: initialInputs['${v['variable']}'],
                        onChange: (value) => change('${v['variable']}', value),
                        pickFile: panel.pickFile,
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: SizedBox(
                width: double.infinity,
                child: DifyButton(
                  variant: DifyButtonVariant.primary,
                  disabled: !canRun || running,
                  onPressed: doRun,
                  child: Text(DifyI18n.tr('workflow', 'singleRun.startRun')),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

enum _Tab { input, result, detail, tracing }

/// WorkflowPreview: "Test Run (time)" with the close button, the tabs and their content. Switches to INPUT when the
/// inputs panel opens, DETAIL while listening or after a run that produced no text or files, RESULT when paused.
class WorkflowPreview extends StatefulWidget {
  const WorkflowPreview({super.key, this.panel = const RunPanelContext()});
  final RunPanelContext panel;

  @override
  State<WorkflowPreview> createState() => _WorkflowPreviewState();
}

class _WorkflowPreviewState extends State<WorkflowPreview> {
  late final WorkflowStore store = WorkflowStoreScope.of(context);
  late _Tab _tab = store.showInputsPanel.value ? _Tab.input : _Tab.tracing;
  late final Listenable _watched = Listenable.merge([
    store.showDebugAndPreviewPanel,
    store.showInputsPanel,
    store.isListening,
    store.workflowRunningData,
  ]);
  bool _wasListening = false;
  (bool, bool)? _shown;
  DifyJson? _lastData;
  double _dragFrom = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _watched.removeListener(_react);
    _watched.addListener(_react);
  }

  @override
  void dispose() {
    _watched.removeListener(_react);
    super.dispose();
  }

  /// The tab effects of workflow-preview.tsx.
  void _react() {
    var tab = _tab;
    final show = (store.showDebugAndPreviewPanel.value, store.showInputsPanel.value);
    if (show != _shown && show.$1 && show.$2) tab = _Tab.input;
    _shown = show;
    final listening = store.isListening.value;
    if (listening && !_wasListening) tab = _Tab.detail;
    _wasListening = listening;
    final data = store.workflowRunningData.value;
    if (data != null && !identical(data, _lastData)) {
      final result = resultOf(data);
      final status = result['status'];
      final text = data['resultText'];
      final files = result['files'];
      if ((status == WorkflowRunningStatus.succeeded || status == WorkflowRunningStatus.failed) &&
          (text == null || text == '') &&
          !(files is List && files.isNotEmpty)) {
        tab = _Tab.detail;
      }
      if (status == WorkflowRunningStatus.paused) tab = _Tab.result;
    }
    _lastData = data;
    if (tab != _tab && mounted) setState(() => _tab = tab);
  }

  void _switch(_Tab tab) => setState(() => _tab = tab);

  void _close() {
    final cancel = widget.panel.onCancel ?? WorkflowRunScope.maybeOf(context)?.run.handleCancelDebugAndPreviewPanel;
    if (cancel != null) {
      cancel();
    } else {
      store
        ..setShowDebugAndPreviewPanel(false)
        ..workflowRunningData.value = null;
    }
  }

  double get _maxWidth => getPreviewPanelMaxWidth(store.workflowCanvasWidth.value, widget.panel.hasSelectedNode);

  void _resize(double w) {
    if (w >= 400 && w <= _maxWidth) store.setPreviewPanelWidth(w);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _react();
    });
  }

  Widget _tabs(DifyJson? data) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    decoration: BoxDecoration(
      border: Border(
        bottom: BorderSide(color: DifyColors.dividerSubtle, width: Css.hairline),
      ),
    ),
    child: runPanelTabs(
      [
        if (store.showInputsPanel.value)
          runPanelTab(label: _tr('input'), active: _tab == _Tab.input, onTap: () => _switch(_Tab.input)),
        for (final (tab, key) in const [(_Tab.result, 'result'), (_Tab.detail, 'detail'), (_Tab.tracing, 'tracing')])
          runPanelTab(
            label: _tr(key),
            active: _tab == tab,
            disabled: data == null,
            onTap: () {
              if (data == null) return;
              _switch(tab);
            },
          ),
      ],
    ),
  );

  Widget _content(DifyJson? data) {
    final result = data == null ? null : resultOf(data);
    switch (_tab) {
      case _Tab.input:
        if (!store.showInputsPanel.value) return const SizedBox.shrink();
        return SingleChildScrollView(
          child: InputsPanel(panel: widget.panel, onRun: () => _switch(_Tab.result)),
        );
      case _Tab.result:
        final status = result?['status'];
        final reasoning = data?['reasoningContent'];
        final text = data?['resultText'];
        final forms = [for (final f in (data?['humanInputFormDataList'] as List? ?? const [])) f as DifyJson];
        final filled = [for (final f in (data?['humanInputFilledFormDataList'] as List? ?? const [])) f as DifyJson];
        final scope = WorkflowRunScope.maybeOf(context);
        return SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (forms.isNotEmpty)
                  HumanInputFormList(
                    inPanel: true,
                    humanInputFormDataList: forms,
                    onHumanInputFormSubmit: widget.panel.onHumanInputFormSubmit ?? scope?.service.submitHumanInputForm,
                    getHumanInputNodeData: (id) => scope?.run.graph.nodes.where((n) => n.id == id).firstOrNull?.data,
                    pickFile: widget.panel.pickFile,
                    email: HumanInputHost.of(context).userEmail,
                  ),
                if (filled.isNotEmpty)
                  HumanInputFilledFormList(inPanel: true, first: forms.isEmpty, humanInputFilledFormDataList: filled),
                if (reasoning is Map && ReasoningPanel.textOf(reasoning).isNotEmpty)
                  ReasoningPanel(
                    content: reasoning,
                    done:
                        (text is String && text.trim().isNotEmpty) ||
                        data?['reasoningFinished'] == true ||
                        status != WorkflowRunningStatus.running,
                  ),
                ResultText(
                  isRunning: status == WorkflowRunningStatus.running || result == null || result.isEmpty,
                  isPaused: status == WorkflowRunningStatus.paused,
                  outputs: text,
                  allFiles: [for (final f in (result?['files'] as List? ?? const [])) f as DifyJson],
                  error: result?['error'] as String?,
                  onClick: () => _switch(_Tab.detail),
                ),
                if (status == WorkflowRunningStatus.succeeded && text is String && text.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(left: 16, bottom: 16),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: DifyButton(
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: text));
                          (widget.panel.toast ?? difyToast)(
                            DifyToastType.success,
                            DifyI18n.tr('common', 'actionMsg.copySuccessfully'),
                          );
                        },
                        leading: const RemixIcon('clipboard-line', size: 14),
                        child: Text(DifyI18n.tr('common', 'operation.copy')),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      case _Tab.detail:
        if (result == null || result.isEmpty) return const RunLoading();
        return SingleChildScrollView(
          child: ResultPanel.fromJson(
            result,
            createdBy: (result['created_by'] as Map?)?['name'] as String?,
            onOpenTracingTab: () => _switch(_Tab.tracing),
          ),
        );
      case _Tab.tracing:
        final tracing = tracingOf(data);
        if (tracing.isEmpty) return RunLoading(color: DifyColors.backgroundSectionBurn);
        return TracingPanel(list: tracing, background: DifyColors.backgroundSectionBurn, scrollable: true);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      store.workflowRunningData,
      store.showInputsPanel,
      store.previewPanelWidth,
      store.workflowCanvasWidth,
    ]),
    builder: (context, _) {
      final data = store.workflowRunningData.value;
      final result = data == null ? null : resultOf(data);
      final width = store.previewPanelWidth.value;
      final burn = _tab == _Tab.result || _tab == _Tab.tracing;
      return SizedBox(
        width: width,
        child: Stack(
          children: [
            Container(
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
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Test Run${fmt.formatWorkflowRunIdentifier((result?['finished_at'] as num?)?.toInt(), (result?['status'] as String?) ?? 'Running')}',
                            style: TextStyle(
                              fontSize: 16,
                              height: 24 / 16,
                              fontWeight: FontWeight.w600,
                              color: DifyColors.textPrimary,
                            ),
                          ),
                        ),
                        DifyPressable(
                          semanticLabel: DifyI18n.tr('common', 'operation.close'),
                          onPressed: _close,
                          builder: (context, h, f) => Padding(
                            padding: EdgeInsets.all(4),
                            child: RemixIcon('close-line', size: 16, color: DifyColors.textTertiary),
                          ),
                        ),
                      ],
                    ),
                  ),
                  _tabs(data),
                  Expanded(
                    child: ColoredBox(
                      color: burn ? DifyColors.backgroundSectionBurn : DifyColors.componentsPanelBg,
                      child: _content(data),
                    ),
                  ),
                ],
              ),
            ),
            // `absolute top-1/2 bottom-0 left-0.75 z-50 h-6 w-0.75 cursor-col-resize bg-state-base-handle`.
            Positioned(
              left: 3,
              top: 0,
              bottom: 0,
              width: 4,
              child: Align(
                alignment: const Alignment(0, 0.1),
                child: SizedBox(
                  height: 24,
                  child: ResizeHandle(
                    value: width,
                    min: 400,
                    max: _maxWidth,
                    label: DifyI18n.tr('workflow', 'singleRun.testRun'),
                    onResize: store.setPreviewPanelWidth,
                    onDragStart: () => _dragFrom = store.previewPanelWidth.value,
                    onDrag: (dx) => _resize(_dragFrom - dx),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}
