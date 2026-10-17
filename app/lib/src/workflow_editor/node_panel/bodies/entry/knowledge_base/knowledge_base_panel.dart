/// The Knowledge Base node's panel (nodes/knowledge-base/panel.tsx and components/**): Chunk Structure, then (once
/// one is chosen) the Chunks input, Index Method, Embedding Model, Summary Auto-Gen and Retrieval Setting. No output
/// variables.
library;

import 'package:flutter/widgets.dart';

import '../../../../../cards/card_kit.dart';
import '../../../../../design/dify_icon.dart';
import '../../../../../design/dify_tokens.g.dart';
import '../../../../../design/widgets/widgets.dart';
import '../../../../../i18n/dify_i18n.dart';
import '../../../../../workflow/model_catalog.dart';
import '../../../../../workflow/var_types.dart' show DeclaredVar;
import '../../../../header/checklist/use_checklist.dart'
    show DifyFlowEdge, DifyFlowNode, getBeforeNodesInSameBranchIncludeParent;
import '../../../../panel_fields/panel_fields.dart' hide Json;
import '../../../../store/store.dart';
import '../../../node_panel_bodies.dart';
import '../../../panel_edit.dart';
import 'kb_widgets.dart';
import 'knowledge_base_host.dart';
import 'knowledge_base_logic.dart';

String _wf(String key) => DifyI18n.tr('workflow', key);

const _multimodalDocUrl = 'https://dify.ai/blog/multimodal-retrieval-is-now-available-in-the-knowledge-base';

/// The `knowledge-index` body.
Widget knowledgeBasePanelBody(BuildContext context, NodePanelProps props) => KnowledgeBasePanel(props: props);

class KnowledgeBasePanel extends StatelessWidget {
  const KnowledgeBasePanel({super.key, required this.props});
  final NodePanelProps props;

  /// useAvailableVarList for the chunks picker: the upstream nodes in the same branch, the environment variables
  /// and the pipeline's input fields.
  VarScope _scope(BuildContext context, KnowledgeBaseHost host) {
    final doc = props.controller.doc;
    final flow = [for (final n in doc.nodes.values) DifyFlowNode.of(n)];
    final edges = [for (final e in doc.edges.values) DifyFlowEdge.of(e)];
    try {
      final before = [for (final b in getBeforeNodesInSameBranchIncludeParent(props.id, flow, edges)) ?b.node];
      final parentId = flow.where((n) => n.id == props.id).firstOrNull?.parentId;
      final parent = parentId == null ? null : doc.nodes[parentId];
      final store = context.getInheritedWidgetOfExactType<WorkflowStoreScope>()?.store;
      return VarScope.of(
        beforeNodes: [
          for (final n in before)
            if (n.id != parent?.id) n,
        ],
        parent: parent,
        environmentVariables: DeclaredVar.listOf(store?.environmentVariables.value ?? const []),
        ragVariables: host.ragVariables,
      );
    } on Object {
      return const VarScope();
    }
  }

  @override
  Widget build(BuildContext context) {
    final host = KnowledgeBaseHost.of(context);
    final catalog = host.catalog;
    final data = props.data;
    final readonly = props.readOnly;
    final embeddingList = catalog.modelList(ModelTypeEnum.textEmbedding);
    final rerankList = catalog.modelList(ModelTypeEnum.rerank);
    final chunkStructure = data['chunk_structure'] is String && (data['chunk_structure']! as String).isNotEmpty
        ? data['chunk_structure']! as String
        : null;
    final indexing = data['indexing_technique'] as String?;
    final embeddingModel = data['embedding_model'] as String?;
    final embeddingProvider = data['embedding_model_provider'] as String?;
    final retrieval = data['retrieval_model'] is Map ? data['retrieval_model']! as Map : const {};
    final rerankModel = retrieval['reranking_model'] is Map ? retrieval['reranking_model']! as Map : const {};
    final qualified = indexing == IndexMethod.qualified;
    final providerModels = qualified && (embeddingProvider ?? '').isNotEmpty
        ? host.providerModels?.call(embeddingProvider!)
        : null;
    final issue = knowledgeBaseValidationIssue({
      ...data,
      'retrieval_model': {
        'search_method': retrieval['search_method'],
        'reranking_enable': retrieval['reranking_enable'],
        'reranking_model': retrieval['reranking_model'],
      },
      '_embeddingModelList': embeddingList,
      '_embeddingProviderModelList': providerModels,
      '_rerankModelList': rerankList,
    });
    final status = embeddingModelStatus(
      embeddingModel: embeddingModel,
      embeddingModelProvider: embeddingProvider,
      embeddingModelList: embeddingList,
      providers: catalog.providers,
      credentialPanelOf: catalog.credentialPanelState,
    ).status;
    final config = KnowledgeBaseConfig(data);
    void update(Json partial) {
      if (!readonly) setInputs(props, {...data, ...partial});
    }

    void open(String url) => props.actions.options.openUrl?.call(url);
    String doc(String path) => host.link(path, product: props.actions.options.docsProduct);

    final selector = [for (final s in (data['index_chunk_variable_selector'] as List?) ?? const []) '$s'];
    final showMultiModalTip = checkShowMultiModalTip(
      embeddingProvider: embeddingProvider ?? '',
      embeddingModel: embeddingModel ?? '',
      rerankingEnable: retrieval['reranking_enable'] == true,
      rerankingProviderName: (rerankModel['reranking_provider_name'] as String?) ?? '',
      rerankingModelName: (rerankModel['reranking_model_name'] as String?) ?? '',
      indexMethod: indexing,
      embeddingModelList: embeddingList,
      rerankModelList: rerankList,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: chunkStructure == null
              ? null
              : const BoxDecoration(
                  border: Border(bottom: BorderSide(color: DifyColors.dividerSubtle)),
                ),
          child: KbChunkStructure(
            chunkStructure: chunkStructure,
            onChange: (v) => update(config.chunkStructureChange(v)),
            warningDot: issue == KnowledgeBaseIssue.chunkStructureRequired,
            readonly: readonly,
            learnMoreLink: doc('/use-dify/knowledge/create-knowledge/chunking-and-cleaning-text'),
            onOpenLink: open,
          ),
        ),
        if (chunkStructure != null) ...[
          BoxGroupField(
            boxBorderBottom: true,
            field: LayoutField(
              title: _wf('nodes.knowledgeBase.chunksInput'),
              tooltip: _wf('nodes.knowledgeBase.chunksInputTip'),
              warningDot: issue == KnowledgeBaseIssue.chunksVariableRequired,
              child: VarReferencePicker(
                value: selector,
                scope: _scope(context, host),
                readonly: readonly,
                isShowNodeName: true,
                filterVar: (v, _) => chunkSchemaTypes(chunkStructure).contains(v.schemaType),
                isFilterFileVar: true,
                isSupportFileVar: false,
                preferSchemaType: true,
                typePlaceHolder: chunkTypePlaceHolder(chunkStructure),
                onChange: (sel, _) => update(config.inputVariableChange(sel)),
              ),
            ),
          ),
          BoxGroup(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 12,
              children: [
                KbIndexMethod(
                  chunkStructure: chunkStructure,
                  indexMethod: indexing,
                  onIndexMethodChange: (v) => update(config.indexMethodChange(v)),
                  keywordNumber: (data['keyword_number'] as num?) ?? 0,
                  onKeywordNumberChange: (v) => update(config.keywordNumberChange(v)),
                  readonly: readonly,
                ),
                if (qualified)
                  KbEmbeddingModel(
                    embeddingModel: embeddingModel,
                    embeddingModelProvider: embeddingProvider,
                    embeddingModelList: embeddingList,
                    catalog: catalog,
                    dismissed: host.multimodalTipDismissed,
                    onChange: (m) => update(
                      config.embeddingModelChange(embeddingModel: m.model, embeddingModelProvider: m.provider),
                    ),
                    onOpenLink: () => open(_multimodalDocUrl),
                    warningDot: status != DerivedModelStatus.active,
                    readonly: readonly,
                  ),
                const _Split(),
                if (qualified &&
                    const [ChunkStructure.general, ChunkStructure.parentChild].contains(chunkStructure) &&
                    host.isNonCloudEdition) ...[
                  KbSummaryIndexSetting(
                    setting: data['summary_index_setting'] is Map ? data['summary_index_setting']! as Map : const {},
                    models: catalog.modelList(ModelTypeEnum.textGeneration),
                    catalog: catalog,
                    onChange: (s) => update(config.summaryIndexSettingChange(s)),
                    currentVersion: () => props.controller.seenVersion,
                    onPromptCommit: (text, base) {
                      if (readonly) return;
                      final next = config.summaryIndexSettingChange({'summary_prompt': text});
                      props.setData(
                        'summary_index_setting',
                        mergeValue(
                          props.node.config['summary_index_setting'],
                          next['summary_index_setting'],
                          props.controller.doc,
                        ),
                        base: base,
                      );
                    },
                    readonly: readonly,
                  ),
                  const _Split(),
                ],
                KbRetrievalSetting(
                  indexMethod: indexing,
                  retrieval: retrieval,
                  readonly: readonly,
                  catalog: catalog,
                  rerankModelList: rerankList,
                  topKMax: host.topKMax,
                  showMultiModalTip: showMultiModalTip,
                  learnMoreLink: doc('/use-dify/knowledge/create-knowledge/setting-indexing-methods'),
                  onOpenLink: open,
                  onSearchMethodChange: (v) => update(config.retrievalSearchMethodChange(v)),
                  onHybridSearchModeChange: (v) => update(config.hybridSearchModeChange(v)),
                  onWeightedScoreChange: (v) => update(config.weightedScoreChange(v)),
                  onRerankingModelEnabledChange: (v) => update(config.rerankingModelEnabledChange(v)),
                  onRerankingModelChange: (m) =>
                      update(config.rerankingModelChange(providerName: m.provider, modelName: m.model)),
                  onTopKChange: (v) => update(config.topKChange(v)),
                  onScoreThresholdChange: (v) => update(config.scoreThresholdChange(v)),
                  onScoreThresholdEnabledChange: (v) => update(config.scoreThresholdEnabledChange(v)),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// panel.tsx filterVar: the chunk variables' schema types per structure.
Set<String> chunkSchemaTypes(String? chunkStructure) => switch (chunkStructure) {
  ChunkStructure.general => const {'general_structure', 'multimodal_general_structure'},
  ChunkStructure.parentChild => const {'parent_child_structure', 'multimodal_parent_child_structure'},
  ChunkStructure.questionAnswer => const {'qa_structure'},
  _ => const {},
};

/// panel.tsx chunkTypePlaceHolder (first letter upper-cased).
String chunkTypePlaceHolder(String? chunkStructure) {
  final p = switch (chunkStructure) {
    ChunkStructure.general => '(multimodal_)general_structure',
    ChunkStructure.parentChild => '(multimodal_)parent_child_structure',
    ChunkStructure.questionAnswer => 'qa_structure',
    _ => '',
  };
  return p.isEmpty ? '' : p[0].toUpperCase() + p.substring(1);
}

/// `<div className="pt-1"><Split className="h-px" /></div>`.
class _Split extends StatelessWidget {
  const _Split();

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(top: 4),
    height: 1,
    color: DifyColors.dividerSubtle,
  );
}

// ---- Chunk Structure ---------------------------------------------------------------------------------------------

Widget Function(bool) _optionIcon(KbOption o, {double size = 18}) =>
    (highlighted) =>
        KbOptionIcon(icon: o.icon, activeColor: Color(o.activeColor), highlighted: highlighted, size: size);

/// ChunkStructure (components/chunk-structure/index.tsx): unset, a "+ Choose a chunk structure" button opening the
/// selector and the instruction card; set, the structure's card with a "Change" selector in the title.
class KbChunkStructure extends StatelessWidget {
  const KbChunkStructure({
    super.key,
    required this.chunkStructure,
    required this.onChange,
    this.warningDot = false,
    this.readonly = false,
    required this.learnMoreLink,
    required this.onOpenLink,
  });

  final String? chunkStructure;
  final ValueChanged<String> onChange;
  final bool warningDot, readonly;
  final String learnMoreLink;
  final ValueChanged<String> onOpenLink;

  @override
  Widget build(BuildContext context) {
    final options = chunkStructureOptions();
    final current = options.where((o) => o.id == chunkStructure).firstOrNull;
    return LayoutField(
      title: _wf('nodes.knowledgeBase.chunkStructure'),
      tooltip: _wf('nodes.knowledgeBase.chunkStructureTip.message'),
      warningDot: warningDot,
      operation: chunkStructure == null
          ? null
          : KbChunkStructureSelector(options: options, value: chunkStructure, onChange: onChange, readonly: readonly),
      child: current != null
          ? KbOptionCard(
              id: current.id,
              selectedId: chunkStructure,
              icon: _optionIcon(current),
              title: current.title,
              description: current.description,
              effect: current.effect,
              enableSelect: false,
              enableHighlightBorder: false,
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                KbChunkStructureSelector(
                  options: options,
                  onChange: onChange,
                  readonly: readonly,
                  trigger: (onTap) => SizedBox(
                    width: double.infinity,
                    child: DifyButton(
                      variant: DifyButtonVariant.secondaryAccent,
                      onPressed: onTap,
                      leading: const RemixIcon('add-line', size: 16),
                      child: Text(_wf('nodes.knowledgeBase.chooseChunkStructure')),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                KbInstruction(link: learnMoreLink, onOpen: onOpenLink),
              ],
            ),
    );
  }
}

/// The chunk structure Selector (chunk-structure/selector.tsx): a popover (bottom-end, alignOffset -8) titled
/// "Change Chunk Structure" with an option card per structure; picking one closes it. Read-only blocks opening.
class KbChunkStructureSelector extends StatefulWidget {
  const KbChunkStructureSelector({
    super.key,
    required this.options,
    this.value,
    required this.onChange,
    this.readonly = false,
    this.trigger,
  });

  final List<KbOption> options;
  final String? value;
  final ValueChanged<String> onChange;
  final bool readonly;

  /// A custom trigger, given what a tap does; the default is the small ghost-accent "Change" button.
  final Widget Function(VoidCallback onTap)? trigger;

  @override
  State<KbChunkStructureSelector> createState() => _KbChunkStructureSelectorState();
}

class _KbChunkStructureSelectorState extends State<KbChunkStructureSelector> {
  final _floating = DifyFloatingController();

  @override
  Widget build(BuildContext context) {
    final w = widget;
    return DifyPopover(
      controller: _floating,
      placement: DifyPlacement.bottomEnd,
      sideOffset: 0,
      alignOffset: -8,
      surface: false,
      builder: (context, controller) {
        void tap() {
          if (w.readonly && !controller.isOpen) return;
          controller.toggle();
        }

        return w.trigger?.call(tap) ??
            DifyButton(
              variant: DifyButtonVariant.ghostAccent,
              size: DifyButtonSize.small,
              onPressed: tap,
              child: Text(_wf('panel.change')),
            );
      },
      content: Container(
        width: 404,
        decoration: BoxDecoration(
          color: DifyColors.componentsPanelBgBlur,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: DifyColors.componentsPanelBorder, width: 0.5),
          boxShadow: DifyShadows.xl,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 14, 12, 0),
              child: DifyText(
                _wf('nodes.knowledgeBase.changeChunkStructure'),
                DifyType.systemSmSemibold,
                color: DifyColors.textPrimary,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 4,
                children: [
                  for (final o in w.options)
                    KbOptionCard(
                      id: o.id,
                      selectedId: w.value,
                      icon: _optionIcon(o),
                      title: o.title,
                      description: o.description,
                      effect: o.effect,
                      readonly: w.readonly,
                      onClick: (id) {
                        w.onChange(id);
                        _floating.close();
                      },
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

/// Instruction's decorative Line (instruction/line.tsx): a 2 x 132 vertical or 240 x 2 horizontal gradient stroke
/// that fades into `divider-subtle` near its end.
class KbInstructionLine extends StatelessWidget {
  const KbInstructionLine({super.key, this.vertical = true});
  final bool vertical;

  Size get size => vertical ? const Size(2, 132) : const Size(240, 2);

  @override
  Widget build(BuildContext context) => SizedBox.fromSize(
    size: size,
    child: Center(
      child: Container(
        width: vertical ? 1 : 240,
        height: vertical ? 132 : 1,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: vertical ? Alignment.bottomCenter : Alignment.centerRight,
            end: vertical ? Alignment.topCenter : Alignment.centerLeft,
            colors: const [
              DifyColors.backgroundGradientMaskTransparent,
              DifyColors.dividerSubtle,
              DifyColors.backgroundGradientMaskTransparent,
            ],
            stops: [0, vertical ? 0.877606 : 0.9031, 1],
          ),
        ),
      ),
    ),
  );
}

/// Instruction (chunk-structure/instruction): the `bg-workflow-process-bg` card with the AddChunks tile and its
/// guide lines, "Please choose a chunk structure", the tip and a "Learn more" link.
class KbInstruction extends StatelessWidget {
  const KbInstruction({super.key, required this.link, required this.onOpen});
  final String link;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    final learnMore = _wf('nodes.knowledgeBase.chunkStructureTip.learnMore');
    return Container(
      clipBehavior: Clip.hardEdge,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: DifyGradients.workflowProcessBg,
        borderRadius: BorderRadius.circular(DifyRadius.container),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 8,
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: DifyColors.componentsCardBg,
                  borderRadius: BorderRadius.circular(DifyRadius.container),
                  border: Border.all(color: DifyColors.componentsCardBorder, width: 0.5),
                  boxShadow: DifyShadows.lg,
                ),
                child: const DifyIcon('vender/knowledge/add-chunks', size: 20, color: DifyColors.textAccent),
              ),
              const Positioned(bottom: -76, left: -1, child: KbInstructionLine()),
              const Positioned(bottom: -76, right: -1, child: KbInstructionLine()),
              const Positioned(top: -1, right: -184, child: KbInstructionLine(vertical: false)),
              const Positioned(bottom: -1, right: -184, child: KbInstructionLine(vertical: false)),
            ],
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 4,
            children: [
              DifyText(
                _wf('nodes.knowledgeBase.chunkStructureTip.title'),
                DifyType.systemSmMedium,
                color: DifyColors.textSecondary,
                maxLines: null,
              ),
              DifyText(
                _wf('nodes.knowledgeBase.chunkStructureTip.message'),
                DifyType.systemXsRegular,
                color: DifyColors.textTertiary,
                maxLines: null,
              ),
              Semantics(
                link: true,
                label: learnMore,
                excludeSemantics: true,
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: () => onOpen(link),
                    child: DifyText(learnMore, DifyType.systemXsRegular, color: DifyColors.textAccent),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ---- Index Method ------------------------------------------------------------------------------------------------

/// IndexMethod (components/index-method.tsx): "High Quality" (recommended) and, for general chunks, "Economical"
/// with its keyword count (slider and number field) while active.
class KbIndexMethod extends StatelessWidget {
  const KbIndexMethod({
    super.key,
    required this.chunkStructure,
    this.indexMethod,
    required this.onIndexMethodChange,
    required this.keywordNumber,
    required this.onKeywordNumberChange,
    this.readonly = false,
  });

  final String chunkStructure;
  final String? indexMethod;
  final ValueChanged<String> onIndexMethodChange;
  final num keywordNumber;
  final ValueChanged<num> onKeywordNumberChange;
  final bool readonly;

  @override
  Widget build(BuildContext context) {
    final label = kbT('dataset-settings', 'form.numberOfKeywords');
    return LayoutField(
      title: kbT('dataset-creation', 'stepTwo.indexMode'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 4,
        children: [
          KbOptionCard(
            id: IndexMethod.qualified,
            selectedId: indexMethod,
            icon: (h) => KbOptionIcon(
              icon: 'vender/knowledge/high-quality',
              activeColor: DifyColors.utilColorsOrangeOrange500,
              highlighted: h,
              size: 15,
            ),
            title: kbT('dataset-creation', 'stepTwo.qualified'),
            description: kbT('dataset-settings', 'form.indexMethodHighQualityTip'),
            onClick: onIndexMethodChange,
            isRecommended: true,
            effect: 'orange',
          ),
          if (chunkStructure == ChunkStructure.general)
            KbOptionCard(
              id: IndexMethod.economical,
              selectedId: indexMethod,
              icon: (h) => KbOptionIcon(
                icon: 'vender/knowledge/economic',
                activeColor: DifyColors.utilColorsIndigoIndigo500,
                highlighted: h,
                size: 15,
              ),
              title: kbT('dataset-settings', 'form.indexMethodEconomy'),
              description: kbT('dataset-settings', 'form.indexMethodEconomyTip', {'count': keywordNumber}),
              onClick: onIndexMethodChange,
              effect: 'blue',
              child: Row(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        Flexible(child: DifyText(label, DifyType.systemXsMedium, color: DifyColors.textSecondary)),
                        const SizedBox(width: 2),
                        Infotip(label: label, content: Text(label)),
                      ],
                    ),
                  ),
                  Container(
                    width: 96,
                    margin: const EdgeInsets.only(right: 12),
                    child: DifySlider(
                      value: keywordNumber.round(),
                      min: 0,
                      max: 100,
                      disabled: readonly,
                      semanticLabel: label,
                      onChanged: onKeywordNumberChange,
                    ),
                  ),
                  SizedBox(
                    width: 72,
                    child: KbNumberField(
                      value: keywordNumber,
                      min: 0,
                      disabled: readonly,
                      semanticLabel: label,
                      onChanged: (v) {
                        if (v != null) onKeywordNumberChange(v);
                      },
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ---- Embedding Model ---------------------------------------------------------------------------------------------

/// EmbeddingModel (components/embedding-model.tsx): the multimodal guidance tip (unless dismissed or the model has
/// Vision) and the text-embedding ModelSelector.
class KbEmbeddingModel extends StatelessWidget {
  const KbEmbeddingModel({
    super.key,
    this.embeddingModel,
    this.embeddingModelProvider,
    required this.embeddingModelList,
    required this.catalog,
    required this.dismissed,
    required this.onChange,
    required this.onOpenLink,
    this.warningDot = false,
    this.readonly = false,
  });

  final String? embeddingModel, embeddingModelProvider;
  final List<ProviderWithModels> embeddingModelList;
  final ModelCatalog catalog;
  final ValueNotifier<bool> dismissed;
  final ValueChanged<DefaultModel> onChange;
  final VoidCallback onOpenLink;
  final bool warningDot, readonly;

  /// The selector's value: null unless both the model and its provider are set.
  DefaultModel? get value => (embeddingModel ?? '').isEmpty || (embeddingModelProvider ?? '').isEmpty
      ? null
      : (provider: embeddingModelProvider!, model: embeddingModel!);

  @override
  Widget build(BuildContext context) => LayoutField(
    title: kbT('dataset-settings', 'form.embeddingModel'),
    subTitle: KbLearnMore(
      link: kbT('dataset-settings', 'form.multimodalRetrievalGuidance.helpLink'),
      text: kbT('dataset-settings', 'form.multimodalRetrievalGuidance.helpDescription'),
      onOpen: onOpenLink,
    ),
    warningDot: warningDot,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        ValueListenableBuilder(
          valueListenable: dismissed,
          builder: (context, isDismissed, _) =>
              isDismissed || isVisionEmbeddingModel(value?.provider, value?.model, embeddingModelList)
              ? const SizedBox.shrink()
              : Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: KbTipCard(
                    title: kbT('dataset-settings', 'form.multimodalRetrievalGuidance.pipelineTitle'),
                    description: kbT('dataset-settings', 'form.multimodalRetrievalGuidance.pipelineDescription'),
                    onDismiss: () => dismissed.value = true,
                  ),
                ),
        ),
        KbModelSelector(
          value: value,
          models: embeddingModelList,
          catalog: catalog,
          onValueChange: onChange,
          disabled: readonly,
        ),
      ],
    ),
  );
}

// ---- Summary Auto-Gen --------------------------------------------------------------------------------------------

/// SummaryIndexSetting (datasets/settings/summary-index-setting.tsx, entry `knowledge-base`): the "Summary
/// Auto-Gen" switch; when on, the summary model and the instructions.
class KbSummaryIndexSetting extends StatelessWidget {
  const KbSummaryIndexSetting({
    super.key,
    required this.setting,
    required this.models,
    required this.catalog,
    required this.onChange,
    required this.onPromptCommit,
    required this.currentVersion,
    this.readonly = false,
  });

  final Map setting;
  final List<ProviderWithModels> models;
  final ModelCatalog catalog;
  final ValueChanged<Json> onChange;
  final void Function(String text, int base) onPromptCommit;
  final int Function() currentVersion;
  final bool readonly;

  @override
  Widget build(BuildContext context) {
    final enabled = setting['enable'] == true;
    final tip = kbT('dataset-settings', 'form.summaryAutoGenTip');
    final modelName = setting['model_name'] as String?, providerName = setting['model_provider_name'] as String?;
    final instructions = kbT('dataset-settings', 'form.summaryInstructions');
    Widget label(String text, EdgeInsets margin) => Container(
      height: 24,
      margin: margin,
      alignment: Alignment.centerLeft,
      child: DifyText(text, DifyType.systemXsMediumUppercase, color: DifyColors.textTertiary),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 24,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                child: Row(
                  children: [
                    Flexible(
                      child: DifyText(
                        kbT('dataset-settings', 'form.summaryAutoGen'),
                        DifyType.systemSmSemiboldUppercase,
                        color: DifyColors.textSecondary,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Infotip(label: tip, content: Text(tip)),
                  ],
                ),
              ),
              DifySwitch(
                checked: enabled,
                disabled: readonly,
                semanticLabel: kbT('dataset-settings', 'form.summaryAutoGen'),
                onCheckedChange: (v) => onChange({'enable': v}),
              ),
            ],
          ),
        ),
        if (enabled) ...[
          label(kbT('dataset-settings', 'form.summaryModel'), const EdgeInsets.only(top: 8, bottom: 6)),
          KbModelSelector(
            value: (modelName ?? '').isEmpty || (providerName ?? '').isEmpty
                ? null
                : (provider: providerName!, model: modelName!),
            models: models,
            catalog: catalog,
            disabled: readonly,
            onValueChange: (m) => onChange({'model_provider_name': m.provider, 'model_name': m.model}),
          ),
          label(instructions, const EdgeInsets.only(top: 12)),
          KbTextarea(
            value: (setting['summary_prompt'] as String?) ?? '',
            semanticLabel: instructions,
            placeholder: kbT('dataset-settings', 'form.summaryInstructionsPlaceholder'),
            disabled: readonly,
            currentVersion: currentVersion,
            onCommit: onPromptCommit,
          ),
        ],
      ],
    );
  }
}

// ---- Retrieval Setting -------------------------------------------------------------------------------------------

/// RetrievalSetting (components/retrieval-setting/index.tsx): the "Learn more about retrieval method." subtitle and
/// a radio card per search method.
class KbRetrievalSetting extends StatelessWidget {
  const KbRetrievalSetting({
    super.key,
    required this.indexMethod,
    required this.retrieval,
    required this.catalog,
    required this.rerankModelList,
    required this.onSearchMethodChange,
    required this.onHybridSearchModeChange,
    required this.onWeightedScoreChange,
    required this.onRerankingModelEnabledChange,
    required this.onRerankingModelChange,
    required this.onTopKChange,
    required this.onScoreThresholdChange,
    required this.onScoreThresholdEnabledChange,
    required this.learnMoreLink,
    required this.onOpenLink,
    this.topKMax = 10,
    this.showMultiModalTip = false,
    this.readonly = false,
  });

  final String? indexMethod;
  final Map retrieval;
  final ModelCatalog catalog;
  final List<ProviderWithModels> rerankModelList;
  final ValueChanged<String> onSearchMethodChange, onHybridSearchModeChange;
  final ValueChanged<List<num>> onWeightedScoreChange;
  final ValueChanged<bool> onRerankingModelEnabledChange, onScoreThresholdEnabledChange;
  final ValueChanged<DefaultModel> onRerankingModelChange;
  final ValueChanged<num> onTopKChange, onScoreThresholdChange;
  final String learnMoreLink;
  final ValueChanged<String> onOpenLink;
  final int topKMax;
  final bool showMultiModalTip, readonly;

  @override
  Widget build(BuildContext context) => LayoutField(
    title: kbT('dataset-settings', 'form.retrievalSetting.title'),
    subTitle: KbLearnMore(
      link: kbT('dataset-settings', 'form.retrievalSetting.learnMore'),
      text: _wf('nodes.knowledgeBase.aboutRetrieval'),
      onOpen: () => onOpenLink(learnMoreLink),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 4,
      children: [
        for (final o in retrievalOptions(indexMethod))
          KbSearchMethodOption(
            option: o,
            searchMethod: retrieval['search_method'] as String?,
            onSelect: onSearchMethodChange,
            hybridMode: retrieval['reranking_mode'] as String?,
            onHybridModeChange: onHybridSearchModeChange,
            weights: retrieval['weights'] is Map ? retrieval['weights']! as Map : null,
            onWeightedScoreChange: onWeightedScoreChange,
            rerankingEnabled: retrieval['reranking_enable'] == true,
            onRerankingEnabledChange: onRerankingModelEnabledChange,
            rerankingModel: retrieval['reranking_model'] is Map ? retrieval['reranking_model']! as Map : null,
            onRerankingModelChange: onRerankingModelChange,
            rerankModelList: rerankModelList,
            catalog: catalog,
            showMultiModalTip: showMultiModalTip,
            topK: (retrieval['top_k'] as num?) ?? 0,
            topKMax: topKMax,
            onTopKChange: onTopKChange,
            scoreThreshold: retrieval['score_threshold'] as num?,
            onScoreThresholdChange: onScoreThresholdChange,
            scoreThresholdEnabled: retrieval['score_threshold_enabled'] == true,
            onScoreThresholdEnabledChange: onScoreThresholdEnabledChange,
            readonly: readonly,
          ),
      ],
    ),
  );
}

/// SearchMethodOption (retrieval-setting/search-method-option.tsx): a radio card (Hybrid recommended); the active
/// one shows its settings: the hybrid mode cards, the weighted score or the rerank model (with its switch for
/// vector and full-text search), the multimodal rerank warning, Top K and Score Threshold.
class KbSearchMethodOption extends StatefulWidget {
  const KbSearchMethodOption({
    super.key,
    required this.option,
    required this.searchMethod,
    required this.onSelect,
    this.hybridMode,
    required this.onHybridModeChange,
    this.weights,
    required this.onWeightedScoreChange,
    this.rerankingEnabled = false,
    required this.onRerankingEnabledChange,
    this.rerankingModel,
    required this.onRerankingModelChange,
    required this.rerankModelList,
    required this.catalog,
    this.showMultiModalTip = false,
    required this.topK,
    this.topKMax = 10,
    required this.onTopKChange,
    this.scoreThreshold,
    required this.onScoreThresholdChange,
    this.scoreThresholdEnabled = false,
    required this.onScoreThresholdEnabledChange,
    this.readonly = false,
    this.hybridModes,
  });

  final KbOption option;

  /// The hybrid search modes (useRetrievalSetting's `hybridSearchModeOptions` by default).
  final List<({String id, String title, String description})>? hybridModes;
  final String? searchMethod, hybridMode;
  final ValueChanged<String> onSelect, onHybridModeChange;
  final Map? weights, rerankingModel;
  final ValueChanged<List<num>> onWeightedScoreChange;
  final bool rerankingEnabled, showMultiModalTip, scoreThresholdEnabled, readonly;
  final ValueChanged<bool> onRerankingEnabledChange, onScoreThresholdEnabledChange;
  final ValueChanged<DefaultModel> onRerankingModelChange;
  final List<ProviderWithModels> rerankModelList;
  final ModelCatalog catalog;
  final num topK;
  final int topKMax;
  final num? scoreThreshold;
  final ValueChanged<num> onTopKChange, onScoreThresholdChange;

  @override
  State<KbSearchMethodOption> createState() => _KbSearchMethodOptionState();
}

class _KbSearchMethodOptionState extends State<KbSearchMethodOption> {
  bool _hovered = false;

  /// getWeightedScoreValue.
  List<num> get _weights {
    final vector = widget.weights?['vector_setting'], keyword = widget.weights?['keyword_setting'];
    return [
      (vector is Map ? vector['vector_weight'] as num? : null) ?? defaultSemanticWeight,
      (keyword is Map ? keyword['keyword_weight'] as num? : null) ?? defaultKeywordWeight,
    ];
  }

  Widget _config() {
    final w = widget;
    final id = w.option.id;
    final isHybrid = id == SearchMethod.hybrid;
    final showSwitch = id == SearchMethod.semantic || id == SearchMethod.fullText;
    final showSelector = showSwitch || (isHybrid && w.hybridMode != HybridSearchMode.weightedScore);
    final rerankLabel = kbT('common', 'modelProvider.rerankModel.key');
    final rerankTip = kbT('common', 'modelProvider.rerankModel.tip');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 12,
      children: [
        if (isHybrid)
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 4,
            children: [
              for (final m in w.hybridModes ?? hybridSearchModeOptions())
                _HybridModeCard(
                  title: m.title,
                  description: m.description,
                  checked: w.hybridMode == m.id,
                  readonly: w.readonly,
                  onTap: () => w.onHybridModeChange(m.id),
                ),
            ],
          ),
        if (isHybrid && w.hybridMode == HybridSearchMode.weightedScore)
          KbWeightedScore(value: _weights, onChange: w.onWeightedScoreChange, readonly: w.readonly),
        if (showSelector)
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (showSwitch)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    children: [
                      DifySwitch(
                        checked: w.rerankingEnabled,
                        disabled: w.readonly,
                        semanticLabel: rerankLabel,
                        onCheckedChange: w.onRerankingEnabledChange,
                      ),
                      const SizedBox(width: 4),
                      Flexible(
                        child: DifyText(rerankLabel, DifyType.systemSmSemibold, color: DifyColors.textSecondary),
                      ),
                      const SizedBox(width: 2),
                      Infotip(label: rerankTip, content: Text(rerankTip)),
                    ],
                  ),
                ),
              KbRerankingModelSelector(
                rerankingModel: w.rerankingModel,
                models: w.rerankModelList,
                catalog: w.catalog,
                readonly: w.readonly,
                onRerankingModelChange: w.onRerankingModelChange,
              ),
              if (w.showMultiModalTip) const _MultiModalTip(),
            ],
          ),
        KbTopKAndScoreThreshold(
          topK: w.topK,
          topKMax: w.topKMax,
          onTopKChange: w.onTopKChange,
          scoreThresholdHidden: id == SearchMethod.keywordSearch,
          scoreThreshold: w.scoreThreshold,
          onScoreThresholdChange: w.onScoreThresholdChange,
          scoreThresholdEnabled: w.scoreThresholdEnabled,
          onScoreThresholdEnabledChange: w.onScoreThresholdEnabledChange,
          readonly: w.readonly,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final o = w.option;
    final active = o.id == w.searchMethod;
    final highlighted = active || _hovered;
    final header = Stack(
      clipBehavior: Clip.none,
      children: [
        if (o.effect != null && highlighted) Positioned(left: -2, top: -2, child: KbOptionEffect(o.effect!)),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 18,
                height: 18,
                margin: const EdgeInsets.only(right: 4),
                alignment: Alignment.center,
                child: KbOptionIcon(
                  icon: o.icon,
                  activeColor: Color(o.activeColor),
                  highlighted: highlighted,
                  size: 15,
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 1, bottom: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Flexible(child: DifyText(o.title, DifyType.systemSmMedium, color: DifyColors.textSecondary)),
                          if (o.id == SearchMethod.hybrid) const Flexible(child: KbRecommendBadge()),
                        ],
                      ),
                      if (o.description.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: DifyText(
                            o.description,
                            DifyType.systemXsRegular,
                            color: DifyColors.textTertiary,
                            maxLines: null,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: DifyColors.componentsOptionCardOptionBg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: active
                ? DifyColors.componentsOptionCardOptionSelectedBorder
                : DifyColors.componentsOptionCardOptionBorder,
            width: active ? 1.5 : 1,
          ),
          boxShadow: !w.readonly && _hovered ? DifyShadows.xs : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              inMutuallyExclusiveGroup: true,
              checked: active,
              enabled: !w.readonly,
              button: true,
              child: MouseRegion(
                cursor: w.readonly ? SystemMouseCursors.forbidden : SystemMouseCursors.click,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: w.readonly || active ? null : () => w.onSelect(o.id),
                  child: header,
                ),
              ),
            ),
            if (active) KbCardBody(child: _config()),
          ],
        ),
      ),
    );
  }
}

/// RerankingModelSelector (retrieval-setting/reranking-model-selector.tsx): the rerank ModelSelector, its value
/// only when both the provider and the model are set; a pick reports them back.
class KbRerankingModelSelector extends StatelessWidget {
  const KbRerankingModelSelector({
    super.key,
    this.rerankingModel,
    required this.models,
    required this.catalog,
    this.onRerankingModelChange,
    this.readonly = false,
  });

  final Map? rerankingModel;
  final List<ProviderWithModels> models;
  final ModelCatalog catalog;
  final ValueChanged<DefaultModel>? onRerankingModelChange;
  final bool readonly;

  DefaultModel? get value {
    final provider = rerankingModel?['reranking_provider_name'], model = rerankingModel?['reranking_model_name'];
    return provider is String && provider.isNotEmpty && model is String && model.isNotEmpty
        ? (provider: provider, model: model)
        : null;
  }

  @override
  Widget build(BuildContext context) => KbModelSelector(
    value: value,
    models: models,
    catalog: catalog,
    disabled: readonly,
    onValueChange: onRerankingModelChange,
  );
}

/// HybridSearchModeRadioCard: `rounded-xl border p-3`, checked `border-[1.5px]
/// bg-components-option-card-option-selected-bg`, the title and description beside a radio.
class _HybridModeCard extends StatelessWidget {
  const _HybridModeCard({
    required this.title,
    required this.description,
    required this.checked,
    required this.readonly,
    required this.onTap,
  });

  final String title, description;
  final bool checked, readonly;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    inMutuallyExclusiveGroup: true,
    checked: checked,
    enabled: !readonly,
    button: true,
    child: MouseRegion(
      cursor: readonly ? SystemMouseCursors.forbidden : SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: readonly || checked ? null : onTap,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: checked ? DifyColors.componentsOptionCardOptionSelectedBg : DifyColors.componentsOptionCardOptionBg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: DifyColors.componentsOptionCardOptionBorder, width: checked ? 1.5 : 1),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    DifyText(title, DifyType.systemSmMedium, color: DifyColors.textSecondary),
                    const SizedBox(height: 4),
                    DifyText(description, DifyType.systemXsRegular, color: DifyColors.textTertiary, maxLines: null),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: KbRadio(checked: checked, disabled: readonly),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// The multimodal rerank warning: `mt-2 flex h-10 items-center gap-x-0.5 rounded-xl border-[0.5px]
/// border-components-panel-border bg-components-panel-bg-blur p-2 shadow-xs` over the 40 % warning gradient.
class _MultiModalTip extends StatelessWidget {
  const _MultiModalTip();

  @override
  Widget build(BuildContext context) => Container(
    height: 40,
    margin: const EdgeInsets.only(top: 8),
    clipBehavior: Clip.antiAlias,
    decoration: BoxDecoration(
      color: DifyColors.componentsPanelBgBlur,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: DifyColors.componentsPanelBorder, width: 0.5),
      boxShadow: DifyShadows.xs,
    ),
    child: Stack(
      children: [
        Positioned.fill(
          child: Opacity(
            opacity: 0.4,
            child: DecoratedBox(decoration: BoxDecoration(gradient: DifyGradients.datasetWarningMessageBg)),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              const Padding(
                padding: EdgeInsets.all(4),
                child: DifyIcon(
                  'vender/solid/alertsAndFeedback/alert-triangle',
                  size: 16,
                  color: DifyColors.textWarningSecondary,
                ),
              ),
              const SizedBox(width: 2),
              Expanded(
                child: DifyText(
                  kbT('dataset-settings', 'form.retrievalSetting.multiModalTip'),
                  DifyType.systemXsMedium,
                  color: DifyColors.textPrimary,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

/// TopKAndScoreThreshold (retrieval-setting/top-k-and-score-threshold.tsx): two columns, Top K (1..[topKMax]) and
/// Score Threshold (switch, 0..1 by 0.01, disabled while off; hidden for Inverted Index). A cleared field gives 0.
class KbTopKAndScoreThreshold extends StatelessWidget {
  const KbTopKAndScoreThreshold({
    super.key,
    required this.topK,
    this.topKMax = 10,
    required this.onTopKChange,
    this.scoreThresholdHidden = false,
    this.scoreThreshold,
    required this.onScoreThresholdChange,
    this.scoreThresholdEnabled = false,
    required this.onScoreThresholdEnabledChange,
    this.readonly = false,
  });

  final num topK;
  final int topKMax;
  final ValueChanged<num> onTopKChange, onScoreThresholdChange;
  final bool scoreThresholdHidden, scoreThresholdEnabled, readonly;
  final num? scoreThreshold;
  final ValueChanged<bool> onScoreThresholdEnabledChange;

  @override
  Widget build(BuildContext context) {
    final topKLabel = DifyI18n.tr('app-debug', 'datasetConfig.top_k');
    final topKTip = DifyI18n.tr('app-debug', 'datasetConfig.top_kTip');
    final scoreLabel = DifyI18n.tr('app-debug', 'datasetConfig.score_threshold');
    final scoreTip = DifyI18n.tr('app-debug', 'datasetConfig.score_thresholdTip');
    final enabled = !scoreThresholdHidden && scoreThresholdEnabled;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 16,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                height: 24,
                margin: const EdgeInsets.only(bottom: 2),
                child: Row(
                  children: [
                    Flexible(child: DifyText(topKLabel, DifyType.systemXsMedium, color: DifyColors.textSecondary)),
                    const SizedBox(width: 2),
                    Infotip(label: topKTip, content: Text(topKTip)),
                  ],
                ),
              ),
              KbNumberField(
                value: topK,
                min: 1,
                max: topKMax,
                disabled: readonly,
                semanticLabel: topKLabel,
                onChanged: (v) => onTopKChange(v ?? 0),
              ),
            ],
          ),
        ),
        Expanded(
          child: scoreThresholdHidden
              ? const SizedBox.shrink()
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      height: 24,
                      margin: const EdgeInsets.only(bottom: 2),
                      child: Row(
                        children: [
                          DifySwitch(
                            checked: enabled,
                            disabled: readonly,
                            semanticLabel: scoreLabel,
                            onCheckedChange: onScoreThresholdEnabledChange,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: DifyText(scoreLabel, DifyType.systemSmMedium, color: DifyColors.textSecondary),
                          ),
                          const SizedBox(width: 2),
                          Infotip(label: scoreTip, content: Text(scoreTip)),
                        ],
                      ),
                    ),
                    KbNumberField(
                      value: scoreThreshold ?? 0,
                      min: 0,
                      max: 1,
                      step: 0.01,
                      disabled: readonly || !enabled,
                      semanticLabel: scoreLabel,
                      onChanged: (v) => onScoreThresholdChange(v ?? 0),
                    ),
                  ],
                ),
        ),
      ],
    );
  }
}
