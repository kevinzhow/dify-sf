/// The Annotations page of a chatflow (Dify 1.17.1 web/app/components/app/annotation/index.tsx inside
/// log-annotation's `px-6 pt-3` frame, with empty-element.tsx): the title, the search and the header actions (the
/// Annotation Reply switch with its setup, Add, More), the paged list with checkboxes and the batch actions, the view
/// drawer. dify-sf stores the Annotation Reply setting; matching and hit history wait for a runtime (protocol 1.11).
library;

import 'dart:async';

import 'package:collab_client/collab_client.dart';
import 'package:flutter/widgets.dart';

import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';
import '../../workflow/model_catalog.dart';
import '../../workflow/workspace_models.dart';
import '../../auth/account_time.dart';
import '../access/access_point_utils.dart' show difyDocLink;
import '../detail_page_slot.dart';
import '../logs/log_widgets.dart' show LogPageTitle;
import 'annotation_list.dart';
import 'annotation_modals.dart';
import 'annotation_types.dart';
import 'batch_add_modal.dart' show PickAnnotationCsv, pickAnnotationCsv;
import 'config_param_modal.dart';
import 'header_opts.dart';

String _t(String ns, String key) => DifyI18n.tr(ns, key);
String _a(String key) => _t('appAnnotation', key);

/// The Annotations page of the open app ([AppDetailPageId.annotations]): the app's annotations on the session's
/// [AnnotationsApi], the workspace's embedding models for the reply setup. Without an API: Dify's empty page.
Widget buildAnnotationsPage(BuildContext context, AppDetailContext detail) {
  final api = detail.service<AnnotationsApi>();
  return ValueListenableBuilder<AppInfo>(
    valueListenable: detail.app,
    builder: (context, app, _) => AnnotationsPage(
      key: ValueKey('annotations-${app.id}'),
      services: api == null ? null : AnnotationsApiServices(api, app.id),
      models: detail.models,
    ),
  );
}

/// empty-element.tsx: the `w-140 rounded-2xl bg-background-section-burn px-5 py-4` card: "No annotations" with the
/// three-dots mark, and the description.
class AnnotationEmptyElement extends StatelessWidget {
  const AnnotationEmptyElement({super.key});

  @override
  Widget build(BuildContext context) => Center(
    child: Container(
      key: const ValueKey('annotation-empty'),
      width: 560,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      decoration: BoxDecoration(
        color: DifyColors.backgroundSectionBurn,
        borderRadius: BorderRadius.circular(DifyRadius.xxl),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text.rich(
            TextSpan(
              children: [
                TextSpan(text: _a('noData.title')),
                WidgetSpan(
                  child: Transform.translate(
                    offset: const Offset(-6, -12),
                    child: CustomPaint(size: const Size(16, 16), painter: _ThreeDots(DifyColors.textSecondary)),
                  ),
                ),
              ],
            ),
            style: difyTextStyle(DifyType.systemMdSemibold, DifyColors.textSecondary),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              _a('noData.description'),
              style: difyTextStyle(DifyType.systemSmRegular, DifyColors.textTertiary),
            ),
          ),
        ],
      ),
    ),
  );
}

/// ThreeDotsIcon: `M5 6.5V5 M8.94 7.56L10 6.5 M10.01 11.5H11.51`, stroke 2, round caps.
class _ThreeDots extends CustomPainter {
  _ThreeDots(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    canvas
      ..drawLine(const Offset(5, 6.5), const Offset(5, 5), p)
      ..drawLine(const Offset(8.93934, 7.56066), const Offset(10, 6.5), p)
      ..drawLine(const Offset(10.0103, 11.5), const Offset(11.5103, 11.5), p);
  }

  @override
  bool shouldRepaint(_ThreeDots old) => old.color != color;
}

/// Annotation (index.tsx). [services] null: the title and the empty state only.
class AnnotationsPage extends StatefulWidget {
  const AnnotationsPage({
    super.key,
    required this.services,
    this.models,
    this.isChatApp = true,
    this.toast,
    this.saveFile = saveAnnotationFile,
    this.pickCsv = pickAnnotationCsv,
    this.debounce = const Duration(milliseconds: 500),
    this.jobPollInterval = const Duration(seconds: 2),
    this.formatTime,
    this.configParamModal,
    this.viewModal,
  });

  final AnnotationServices? services;

  /// The workspace's embedding models (the reply setup's model selector).
  final WorkspaceModels? models;

  /// `appDetail.mode !== 'completion'` (always true here: only chatflows have the page).
  final bool isChatApp;
  final AnnotationToast? toast;
  final SaveAnnotationFile saveFile;
  final PickAnnotationCsv pickCsv;

  /// The search's `useDebounce` wait.
  final Duration debounce;

  /// `ensureJobCompleted`'s `sleep(2000)`.
  final Duration jobPollInterval;

  /// Null: the account's time zone ([AccountTime.of], Dify's `useTimestamp`).
  final AnnotationTimeFormatter? formatTime;

  /// Replace the setup modal and the view drawer (Dify's page tests mock them).
  final Widget Function(AnnotationConfigParamModal modal)? configParamModal;
  final Widget Function(ViewAnnotationModal modal)? viewModal;

  @override
  State<AnnotationsPage> createState() => AnnotationsPageState();
}

class AnnotationsPageState extends State<AnnotationsPage> {
  AnnotationServices? get _s => widget.services;
  AnnotationToast get _toast => widget.toast ?? difyToast;

  AnnotationSetting? annotationConfig;
  int _controlRefreshSwitch = 0;
  String _keyword = '', _debouncedKeyword = '';
  Timer? _debounce;
  int _currPage = 0, _limit = appPageLimit, _total = 0;
  List<Annotation> _list = const [];
  bool _isLoading = false, _isShowEdit = false, _isShowViewModal = false;
  int _controlUpdateList = 0;
  Annotation? _currItem;
  List<String> selectedIds = const [];
  int _fetchSeq = 0;

  @override
  void initState() {
    super.initState();
    if (_s == null) return;
    if (widget.isChatApp) unawaited(_fetchAnnotationConfig().then<void>((_) {}, onError: _requestFailed));
    unawaited(_fetchList(1));
    final models = widget.models;
    if (models != null) {
      unawaited(models.ensureModelList(ModelTypeEnum.textEmbedding));
      if (models.defaultModel(ModelTypeEnum.textEmbedding) == null) {
        unawaited(models.invalidateDefaultModel(ModelTypeEnum.textEmbedding));
      }
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<String?> _fetchAnnotationConfig() async {
    final res = await _s!.fetchConfig();
    if (mounted) setState(() => annotationConfig = res);
    return res.id;
  }

  void _requestFailed(Object e) {
    final m = errorMessageOf(e);
    _toast(DifyToastType.error, m.isNotEmpty ? m : _t('common', 'api.actionFailed'));
  }

  Future<void> _ensureJobCompleted(String jobId, AnnotationEnableStatus status) async {
    while (true) {
      final res = await _s!.jobStatus(status, jobId);
      if (res.jobStatus == AnnotationJobStatus.completed) break;
      await Future<void>.delayed(widget.jobPollInterval);
    }
  }

  Future<void> _fetchList([int page = 1]) async {
    final seq = ++_fetchSeq;
    setState(() => _isLoading = true);
    try {
      final res = await _s!.list(page: page, limit: _limit, keyword: _debouncedKeyword);
      if (!mounted || seq != _fetchSeq) return;
      setState(() {
        _list = res.data;
        _total = res.total;
      });
    } on Object catch (e) {
      // Dify's request layer toasts a failed request.
      _requestFailed(e);
    } finally {
      if (mounted && seq == _fetchSeq) setState(() => _isLoading = false);
    }
  }

  /// The effect on `[currPage, limit, debouncedQueryParams]`.
  void _refetchCurrent() => unawaited(_fetchList(_currPage + 1));

  void _onKeyword(String v) {
    setState(() => _keyword = v);
    _debounce?.cancel();
    void apply() {
      if (!mounted || _debouncedKeyword == v) return;
      setState(() => _debouncedKeyword = v);
      _refetchCurrent();
    }

    if (widget.debounce == Duration.zero) {
      apply();
    } else {
      _debounce = Timer(widget.debounce, apply);
    }
  }

  void _success() => _toast(DifyToastType.success, _t('common', 'api.actionSuccess'));

  Future<void> _handleAdd(AnnotationItemBasic payload) async {
    await _s!.add(payload);
    _success();
    unawaited(_fetchList());
    setState(() => _controlUpdateList = DateTime.now().microsecondsSinceEpoch);
  }

  Future<void> _handleRemove(String id) async {
    await _s!.delete(id);
    _success();
    unawaited(_fetchList());
    if (mounted) setState(() => _controlUpdateList = DateTime.now().microsecondsSinceEpoch);
  }

  /// `handleBatchDelete`.
  Future<void> handleBatchDelete() async {
    try {
      await _s!.deleteMany(selectedIds);
      _success();
      unawaited(_fetchList());
      if (mounted) {
        setState(() {
          _controlUpdateList = DateTime.now().microsecondsSinceEpoch;
          selectedIds = const [];
        });
      }
    } on Object catch (e) {
      final m = errorMessageOf(e);
      _toast(DifyToastType.error, m.isNotEmpty ? m : _t('common', 'api.actionFailed'));
    }
  }

  /// `setSelectedIds`.
  void setSelectedIds(List<String> ids) => setState(() => selectedIds = ids);

  void _handleView(Annotation item) => setState(() {
    _currItem = item;
    _isShowViewModal = true;
  });

  Future<void> _handleSave(String question, String answer) async {
    final item = _currItem;
    if (item == null) return;
    await _s!.edit(item.id, question: question, answer: answer);
    _success();
    unawaited(_fetchList());
    if (mounted) setState(() => _controlUpdateList = DateTime.now().microsecondsSinceEpoch);
  }

  void _setShowEdit(bool v) => setState(() {
    _isShowEdit = v;
    // The switch is re-keyed when the setup closes (Dify's controlRefreshSwitch), dropping a pending toggle.
    if (!v) _controlRefreshSwitch++;
  });

  Future<void> _onSwitch(bool value) async {
    if (value) {
      _setShowEdit(true);
      return;
    }
    final config = annotationConfig;
    final job = await _s!.updateStatus(
      AnnotationEnableStatus.disable,
      config == null ? null : embeddingModelOf(config),
      config?.scoreThreshold,
    );
    await _ensureJobCompleted(job.jobId ?? '', AnnotationEnableStatus.disable);
    await _fetchAnnotationConfig();
    _success();
  }

  Future<void> _onSaveConfig(EmbeddingModelConfig embeddingModel, double score) async {
    final old = annotationConfig;
    final oldModel = old == null ? null : embeddingModelOf(old);
    if (embeddingModel.embeddingModelName != oldModel?.embeddingModelName ||
        embeddingModel.embeddingProviderName != oldModel?.embeddingProviderName) {
      final job = await _s!.updateStatus(AnnotationEnableStatus.enable, embeddingModel, score);
      await _ensureJobCompleted(job.jobId ?? '', AnnotationEnableStatus.enable);
    }
    final annotationId = await _fetchAnnotationConfig();
    if (score != old?.scoreThreshold) await _s!.updateScore(annotationId ?? '', score);
    await _fetchAnnotationConfig();
    _success();
    _setShowEdit(false);
  }

  Widget _replySwitch() {
    final enabled = annotationConfig?.enabled ?? false;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          height: 28,
          padding: EdgeInsets.only(left: 8, right: enabled ? 0 : 8),
          decoration: BoxDecoration(
            color: DifyColors.componentsPanelBgBlur,
            borderRadius: BorderRadius.circular(DifyRadius.lg),
            border: Border.all(color: DifyColors.componentsPanelBorder),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            spacing: 4,
            children: [
              DifyIcon(
                'vender/solid/communication/message-fast',
                size: 16,
                color: DifyColors.utilColorsIndigoIndigo600,
              ),
              Text(_a('name'), style: difyTextStyle(DifyType.systemSmMedium, DifyColors.textPrimary)),
              DifySwitch(
                key: ValueKey('annotation-reply-switch-$_controlRefreshSwitch'),
                checked: enabled,
                size: DifySwitchSize.md,
                semanticLabel: _a('name'),
                onCheckedChange: (v) => unawaited(_onSwitch(v).catchError(_requestFailed)),
              ),
              if (enabled)
                Padding(
                  padding: const EdgeInsets.only(left: 6, right: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 1,
                        height: 14,
                        margin: const EdgeInsets.only(right: 4),
                        color: DifyColors.dividerSubtle,
                      ),
                      DifyIconButton(
                        label: _a('initSetup.configTitle'),
                        icon: RemixIcon('equalizer-2-line', size: 16, color: DifyColors.textTertiary),
                        onPressed: () => _setShowEdit(true),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        // `space-x-2` after the pill, then the divider's own `mx-3`.
        Container(
          width: 1,
          height: 14,
          margin: const EdgeInsets.only(left: 8 + 12, right: 12),
          color: DifyColors.dividerRegular,
        ),
      ],
    );
  }

  AnnotationConfigParamModal _configModal() {
    final models = widget.models;
    final list = models?.modelList(ModelTypeEnum.textEmbedding) ?? const <ProviderWithModels>[];
    final d = models?.defaultModelsMap[ModelTypeEnum.textEmbedding];
    final DefaultModel? defaultModel = d == null ? null : (provider: d.provider, model: d.model);
    return AnnotationConfigParamModal(
      isShow: true,
      isInit: !(annotationConfig?.enabled ?? false),
      onHide: () => _setShowEdit(false),
      onSave: (model, score) => _onSaveConfig(model, score).catchError(_requestFailed),
      annotationConfig: annotationConfig ?? AnnotationSetting.disabled,
      embeddingModels: list,
      defaultEmbeddingModel: defaultModel,
      isDefaultModelValid: getCurrentProviderAndModel(list, defaultModel).currentModel != null,
      toast: widget.toast,
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = _s;
    final totalPages = _total == 0 ? 1 : (_total / _limit).ceil().clamp(1, 1 << 30);
    final title = LogPageTitle(
      title: _a('title'),
      description: _a('noData.description'),
      learnMoreHref: difyDocLink('/use-dify/monitor/annotation-reply'),
      learnMoreLabel: _t('common', 'operation.learnMore'),
    );
    final page = Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          title,
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: s == null
                  ? const AnnotationEmptyElement()
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        AnnotationFilter(
                          services: s,
                          keyword: _keyword,
                          onKeywordChange: _onKeyword,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (widget.isChatApp) _replySwitch(),
                              AnnotationHeaderOptions(
                                services: s,
                                controlUpdateList: _controlUpdateList,
                                onAdd: _handleAdd,
                                onAdded: () => unawaited(_fetchList()),
                                saveFile: widget.saveFile,
                                pickCsv: widget.pickCsv,
                                toast: widget.toast,
                              ),
                            ],
                          ),
                        ),
                        Expanded(
                          child: _isLoading
                              ? const DifyLoading(key: ValueKey('logs-loading'), app: true)
                              : _total > 0
                              ? AnnotationList(
                                  list: _list,
                                  onRemove: (id) => unawaited(_handleRemove(id).catchError(_requestFailed)),
                                  onView: _handleView,
                                  selectedIds: selectedIds,
                                  onSelectedIdsChange: setSelectedIds,
                                  onBatchDelete: handleBatchDelete,
                                  formatTime: widget.formatTime,
                                )
                              : const AnnotationEmptyElement(),
                        ),
                        if (_total > appPageLimit)
                          DifyPagination(
                            page: _currPage + 1,
                            totalPages: totalPages,
                            onPageChange: (page) {
                              setState(() => _currPage = page - 1);
                              _refetchCurrent();
                            },
                            pageSize: _limit,
                            onPageSizeChange: (v) {
                              setState(() => _limit = v);
                              _refetchCurrent();
                            },
                          ),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
    // The drawer and the setup dialog sit at the page's root (their overlays' semantics follow the page's bounds).
    return Stack(
      fit: StackFit.expand,
      children: [
        page,
        if (s != null && _isShowViewModal && _currItem != null) _view(s),
        if (s != null && _isShowEdit)
          ListenableBuilder(
            listenable: widget.models ?? Listenable.merge(const []),
            builder: (context, _) => widget.configParamModal?.call(_configModal()) ?? _configModal(),
          ),
      ],
    );
  }

  Widget _view(AnnotationServices s) {
    final item = _currItem!;
    final modal = ViewAnnotationModal(
      key: ValueKey('view-${item.id}'),
      isShow: _isShowViewModal,
      item: item,
      onHide: () => setState(() => _isShowViewModal = false),
      onRemove: () => _handleRemove(item.id),
      onSave: _handleSave,
      fetchHitHistory: (id, page) => s.hitHistories(id, page: page, limit: 10),
      formatTime: widget.formatTime,
    );
    return widget.viewModal?.call(modal) ?? modal;
  }
}
