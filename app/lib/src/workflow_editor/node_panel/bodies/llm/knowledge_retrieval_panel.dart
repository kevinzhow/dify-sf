/// The panel body of Knowledge Retrieval (nodes/knowledge-retrieval/panel.tsx and use-config.ts).
library;

import 'package:flutter/widgets.dart';

import '../../../../design/dify_tokens.g.dart';
import '../../../../i18n/dify_i18n.dart';
import '../../../../workflow/dify_json.dart';
import '../../../../workflow/model_catalog.dart';
import '../../../../workflow/var_types.dart';
import '../../../panel_fields/panel_fields.dart';
import '../../node_panel_bodies.dart';
import 'group_host.dart';
import 'kr_config.dart';
import 'kr_datasets.dart';
import 'kr_metadata.dart';
import 'kr_retrieval_config.dart';
import '../../panel_edit.dart';
import 'llm_vars.dart';

String _w(String key) => DifyI18n.tr('workflow', key);
const _p = 'nodes.knowledgeRetrieval';

/// The panel body of Knowledge Retrieval (nodes/knowledge-retrieval/panel.tsx).
Widget knowledgeRetrievalPanelBody(BuildContext context, NodePanelProps props) =>
    KnowledgeRetrievalPanel(key: ValueKey('knowledge-retrieval-${props.id}'), props: props);

bool _numberVar(PickerVar v, List<String> _) => v.type == VarType.number;

/// The Knowledge Retrieval panel. Its State holds what use-config's hooks keep: the selected datasets' details,
/// the rerank popover's open state.
class KnowledgeRetrievalPanel extends StatefulWidget {
  const KnowledgeRetrievalPanel({super.key, required this.props});
  final NodePanelProps props;

  @override
  State<KnowledgeRetrievalPanel> createState() => _KnowledgeRetrievalPanelState();
}

class _KnowledgeRetrievalPanelState extends State<KnowledgeRetrievalPanel> {
  NodePanelProps get props => widget.props;

  late final _input = KrInputManager(inputs: props.data, doSetInputs: _write);
  late final _selection = KrDatasetSelection(
    inputsOf: () => _input.inputs,
    setInputs: _input.setInputs,
    payloadRetrievalMode: () => jsStr(props.data['retrieval_mode']),
  );
  late final _model = KrModelConfig(
    inputsOf: () => _input.inputs,
    setInputs: _input.setInputs,
    selectedDatasets: () => _selection.selectedDatasets,
  );
  late final _metadata = KrMetadataConfig(inputsOf: () => _input.inputs, setInputs: _input.setInputs);

  String? _modelsKey;
  bool _started = false;

  /// Writes are skipped while the canvas is read-only (Dify's effects write regardless).
  void _write(Json next) {
    if (!props.readOnly) setInputs(props, next);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final s = LlmGroupScope.of(context);
    _selection
      ..fetchDatasets = s.fetchDatasets
      ..updateDatasetsDetail = s.updateDatasetsDetail;
    final textDefault = s.defaultModels[ModelTypeEnum.textGeneration];
    final (currentProvider: tp, currentModel: tm) = getCurrentProviderAndModel(
      s.models.textGenerationModelList,
      textDefault == null ? null : (provider: textDefault.provider, model: textDefault.model),
    );
    final rerankDefault = s.defaultModels[ModelTypeEnum.rerank];
    final (currentProvider: rp, currentModel: rm) = getCurrentProviderAndModel(
      s.models.modelList(ModelTypeEnum.rerank),
      rerankDefault == null ? null : (provider: rerankDefault.provider, model: rerankDefault.model),
    );
    final fallback = (provider: rp?.provider, model: rm?.model);
    _selection.fallbackRerankModel = fallback;
    _model
      ..currentModel = tp == null || tm == null
          ? null
          : (provider: tp.provider, model: tm.model, mode: jsStr(tm.modelProperties['mode']))
      ..fallbackRerankModel = fallback
      ..hasRerankDefaultModel = rm != null && rerankDefault != null;
    final key = '${tp?.provider}/${tm?.model}|${rp?.provider}/${rm?.model}';
    final rerun = _modelsKey != null && _modelsKey != key;
    _modelsKey = key;
    if (!_started) {
      _started = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _mount());
    } else if (rerun) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _model.init();
      });
    }
  }

  /// The mount effects: the datasets' details, the chat-mode query default and the model defaults.
  Future<void> _mount() async {
    if (!mounted) return;
    final load = _selection.load();
    _queryDefault();
    _model.init();
    await load;
    if (mounted) setState(() {});
  }

  /// use-config's effect: in a chatflow an empty query becomes the upstream Start node's `sys.query`.
  void _queryDefault() {
    final start = NodeVars.of(props).beforeNodes.where((n) => n.type == 'start').firstOrNull;
    final current = _input.inputs;
    final query = jsList(current['query_variable_selector']);
    _input.setInputs({
      ...current,
      'query_variable_selector': props.chatMode && query.isEmpty && start != null ? [start.id, 'sys.query'] : query,
    });
  }

  @override
  Widget build(BuildContext context) {
    final readOnly = props.readOnly;
    final inputs = props.data;
    _input.inputs = inputs;
    final vars = NodeVars.of(props);
    final datasets = [
      for (final d in _selection.selectedDatasets)
        if (jsTruthy(d['name'])) d,
    ];
    final metadataList = metadataIntersection(datasets);
    final shape = MetadataShape(
      metadataList: metadataList,
      selectedDatasetsLoaded: _selection.selectedDatasetsLoaded,
      conditions: inputs['metadata_filtering_conditions'] is Map
          ? jsMap(inputs['metadata_filtering_conditions'])
          : null,
      onAddCondition: _metadata.handleAddCondition,
      onRemoveCondition: _metadata.handleRemoveCondition,
      onToggleLogicalOperator: _metadata.handleToggleConditionLogicalOperator,
      onUpdateCondition: _metadata.handleUpdateCondition,
      stringVars: vars.filtered(filterStringVar),
      numberVars: vars.filtered(_numberVar),
    );
    void onDatasetsChange(List<Json> list) => setState(() => _selection.handleOnDatasetsChange(list));

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 16,
              children: [
                Field(
                  title: _w('$_p.queryText'),
                  child: VarReferencePicker(
                    value: jsSelector(inputs['query_variable_selector']),
                    scope: vars.scope,
                    readonly: readOnly,
                    isShowNodeName: true,
                    filterVar: filterStringVar,
                    onChange: (sel, _) => _input.handleQueryVarChange(sel),
                  ),
                ),
                if (_selection.showImageQueryVarSelector)
                  Field(
                    title: _w('$_p.queryAttachment'),
                    child: VarReferencePicker(
                      value: jsSelector(inputs['query_attachment_selector']),
                      scope: vars.scope,
                      readonly: readOnly,
                      isShowNodeName: true,
                      filterVar: filterFileVar,
                      onChange: (sel, _) => _input.handleQueryAttachmentChange(sel),
                    ),
                  ),
                Field(
                  title: _w('$_p.knowledge'),
                  required: true,
                  operations: Row(
                    mainAxisSize: MainAxisSize.min,
                    spacing: 4,
                    children: [
                      RetrievalConfig(
                        retrievalMode: jsStr(inputs['retrieval_mode']),
                        multipleRetrievalConfig: inputs['multiple_retrieval_config'] is Map
                            ? jsMap(inputs['multiple_retrieval_config'])
                            : null,
                        singleRetrievalModelConfig: jsGet(inputs['single_retrieval_config'], 'model') is Map
                            ? jsMap(jsGet(inputs['single_retrieval_config'], 'model'))
                            : null,
                        onRetrievalModeChange: _model.handleRetrievalModeChange,
                        onMultipleRetrievalConfigChange: _model.handleMultipleRetrievalConfigChange,
                        onSingleRetrievalModelChange: (m) =>
                            _model.handleModelChanged((provider: m.provider, modelId: m.modelId, mode: m.mode)),
                        onSingleRetrievalModelParamsChange: _model.handleCompletionParamsChange,
                        readonly: readOnly || datasets.isEmpty,
                        open: _selection.rerankModelOpen,
                        onOpenChange: (v) => setState(() => _selection.rerankModelOpen = v),
                        selectedDatasets: datasets,
                      ),
                      if (!readOnly) Container(width: 1, height: 12, color: DifyColors.dividerRegular),
                      if (!readOnly)
                        AddDataset(
                          selectedIds: [for (final id in jsList(inputs['dataset_ids'])) jsKey(id)],
                          onChange: onDatasetsChange,
                        ),
                    ],
                  ),
                  child: DatasetList(list: datasets, readonly: readOnly, onChange: onDatasetsChange),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 8, top: 8),
            child: Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: MetadataFilter(
                shape: shape,
                mode: jsStr(inputs['metadata_filtering_mode']) ?? MetadataFilteringMode.disabled,
                onModeChange: _metadata.handleMetadataFilterModeChange,
                modelConfig: inputs['metadata_model_config'] is Map ? jsMap(inputs['metadata_model_config']) : null,
                onModelChange: (m) =>
                    _metadata.handleMetadataModelChange((provider: m.provider, modelId: m.modelId, mode: m.mode)),
                onCompletionParamsChange: _metadata.handleMetadataCompletionParamsChange,
              ),
            ),
          ),
          const PanelSplit(),
          OutputVars(
            child: VarItem(
              name: 'result',
              type: 'Array[Object]',
              description: _w('$_p.outputVars.output'),
              subItems: [
                (name: 'content', type: 'string', description: _w('$_p.outputVars.content')),
                (name: 'title', type: 'string', description: _w('$_p.outputVars.title')),
                (name: 'url', type: 'string', description: _w('$_p.outputVars.url')),
                (name: 'icon', type: 'string', description: _w('$_p.outputVars.icon')),
                (name: 'metadata', type: 'object', description: _w('$_p.outputVars.metadata')),
                (name: 'files', type: 'Array[File]', description: _w('$_p.outputVars.files')),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
