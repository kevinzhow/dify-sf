import 'package:collab_client/collab_client.dart';
import 'package:flutter/material.dart';

import '../canvas/canvas_graph.dart';
import '../canvas/node_card.dart';
import '../design/dify_icon.dart';
import '../design/dify_tokens.g.dart';
import '../workflow_editor/node_panel/bodies/data/tool/copy_id.dart';
import 'bodies/answer_body.dart';
import 'bodies/basic_bodies.dart';
import 'bodies/container_bodies.dart';
import 'bodies/data_bodies.dart';
import 'bodies/entry_bodies.dart';
import 'bodies/llm_bodies.dart';
import 'bodies/note_body.dart';
import 'card_chrome.dart';
import 'card_kit.dart';
import 'class_name_popover.dart';
import 'node_body.dart';
import '../workflow_editor/canvas_plus/iteration_add_block.dart';
import '../workflow_editor/canvas_plus/aggregator_controls.dart';
import 'node_extras.dart';
import 'node_helpers.dart';

/// Dify's node cards: the shared chrome (nodes/_base/node.tsx) around a body per node type.
class DifyCards extends CardSpec {
  const DifyCards();

  static bool hasCopyId(Node n) => n.type == 'tool' && n.config['provider_type'] == const VString('mcp');
  static const copyIdHeight = 26.0;

  @override
  List<({Rect rect, Widget child})> controls(BuildContext context, CanvasNode node, CanvasGraph graph) {
    if (node.type == 'question-classifier') {
      final ctx = DifyCards.context(node.node.value, (id) => graph[id]?.node.value, graph.startNode);
      return [
        for (final (i, topic) in QuestionClassifierBody.topicBoxes(ctx).indexed)
          if (topic.text.length > 50)
            (
              rect: topic.rect.shift(node.rect.topLeft + const Offset(1, 45)),
              child: ClassNamePopover(
                key: ValueKey('class-topic-${node.id}-$i'),
                text: topic.text,
                ctx: ctx,
                child: const SizedBox.expand(),
              ),
            ),
      ];
    }
    if (node.type == 'variable-aggregator' || node.type == 'variable-assigner') {
      final ctx = DifyCards.context(node.node.value, (id) => graph[id]?.node.value, graph.startNode);
      return [
        for (final group in VariableAggregatorBody.groupBoxes(ctx))
          (
            rect: Rect.fromLTWH(node.rect.left + 5, node.rect.top + 45 + group.top, node.rect.width - 10, group.height),
            child: AggregatorGroupControl(nodeId: node.id, groupId: group.id, type: group.type),
          ),
      ];
    }
    if (node.type == 'iteration') {
      final children = graph.nodes.where((n) => n.parentId == node.id).toList();
      final start = children.where((n) => n.type == 'iteration-start').firstOrNull;
      if (children.length == 1 && start != null) {
        return [
          (
            rect: Rect.fromLTWH(node.rect.left + 1 + 4 + 56, node.rect.top + 1 + header + 28, 210, 32),
            child: IterationAddBlock(startNodeId: start.id),
          ),
        ];
      }
    }
    if (!hasCopyId(node.node.value)) return const [];
    final content = node.node.value.config['provider_id'];
    return [
      (
        rect: Rect.fromLTWH(node.rect.left + 13, node.rect.bottom - 5 - copyIdHeight, node.rect.width - 26, 18),
        child: CopyId(content: content is VString ? content.value : ''),
      ),
    ];
  }

  static const width = 240.0;
  static const header = 44.0; // pt-3 + 24 px icon + pb-2
  static const border = 1.0;
  static const _bottom = 4.0; // pb-1

  /// EntryNodeContainer: the label row above the node (use-helpline ENTRY_NODE_WRAPPER_OFFSET).
  static const _entryLabel = 21.0;

  /// The "DATA SOURCE" tab: `absolute -inset-0.5 -top-5.5` around the node element.
  static const _tabTop = 22.0, _tabInset = 2.0;

  static const _handleLift = 8.0;

  static const bodies = <String, NodeBody>{
    'start': StartBody(),
    'end': EndBody(),
    'answer': AnswerBody(),
    'if-else': IfElseBody(),
    'iteration': ContainerBody(),
    'loop': ContainerBody(),
    'llm': LlmBody(),
    'knowledge-retrieval': KnowledgeRetrievalBody(),
    'question-classifier': QuestionClassifierBody(),
    'parameter-extractor': ParameterExtractorBody(),
    'agent': AgentBody(),
    'agent-v2': AgentV2Body(),
    'code': CodeBody(),
    'template-transform': TemplateTransformBody(),
    'http-request': HttpRequestBody(),
    'tool': ToolBody(),
    'document-extractor': DocumentExtractorBody(),
    'list-operator': ListOperatorBody(),
    'variable-aggregator': VariableAggregatorBody(),
    'variable-assigner': VariableAggregatorBody(),
    'assigner': AssignerBody(),
    'human-input': HumanInputBody(),
    'trigger-schedule': TriggerScheduleBody(),
    'trigger-webhook': TriggerWebhookBody(),
    'trigger-plugin': TriggerPluginBody(),
    'datasource': DataSourceBody(),
    'datasource-empty': DataSourceEmptyBody(),
    'knowledge-index': KnowledgeIndexBody(),
    'start-placeholder': StartPlaceholderBody(),
    'loop-end': LoopEndBody(),
    'iteration-start': IterationStartBody(),
    'loop-start': LoopStartBody(),
  };

  static NodeBody bodyOf(String type) => bodies[type] ?? const NoBody();

  /// Every icon (asset, colour) cards draw, decoded before the canvas starts (see IconCache).
  static Iterable<(String, Color)> get icons sync* {
    for (final t in bodies.keys) {
      yield ('assets/dify_icons/${blockGlyph(t)}.svg', Colors.white);
      yield ('assets/dify_icons/${varBlockGlyph(t)}.svg', DifyColors.textSecondary);
    }
    yield ('assets/dify_icons/${blockGlyph('start-placeholder')}.svg', DifyColors.textPrimary);
    yield* variableLabelIcons;
    for (final name in const [
      'align-left',
      'checkbox-multiple-line',
      'hashtag',
      'checkbox-line',
      'braces-line',
      'file-list-2-line',
      'file-copy-2-line',
      'text-snippet',
    ]) {
      yield ('assets/remix_icons/$name.svg', DifyColors.textTertiary);
    }
    yield ('assets/remix_icons/loader-2-line.svg', DifyColors.textAccent);
    yield ('assets/remix_icons/error-warning-fill.svg', DifyColors.textDestructive);
    yield ('assets/remix_icons/alert-fill.svg', DifyColors.textWarningSecondary);
    yield ('assets/remix_icons/checkbox-circle-fill.svg', DifyColors.textSuccess);
    yield ('assets/remix_icons/pause-circle-fill.svg', DifyColors.textWarningSecondary);
    yield ('assets/remix_icons/link-unlink-m.svg', DifyColors.textDestructive);
    yield ('assets/dify_icons/vender/line/general/plus-02.svg', DifyColors.textTertiary);
    yield ('assets/dify_icons/vender/other/group.svg', DifyColors.textTertiary);
    yield ('assets/dify_icons/vender/agent-v2/configure.svg', DifyColors.textTertiary);
    yield* entryBodyIcons;
    // Model chips (model_chip.dart).
    yield ('assets/remix_icons/alert-fill.svg', DifyColors.textWarning);
    yield ('assets/remix_icons/brain-2-line.svg', DifyColors.textQuaternary);
    for (final name in const ['image-circle-ai-line', 'file-text-line', 'voice-ai-fill', 'film-ai-line']) {
      yield ('assets/remix_icons/$name.svg', DifyColors.textTertiary);
    }
    yield ('assets/dify_icons/public/llm/openai-yellow.svg', DifyColors.componentsInputTextFilled);
  }

  static bool isEntry(String type) => isEntryWorkflowNode(type);

  /// Data source nodes sit on a "DATA SOURCE" tab.
  static bool hasTab(String type) => type == 'datasource' || type == 'datasource-empty';

  static String desc(Node n) {
    final d = n.config['desc'] is VString ? (n.config['desc']! as VString).value : '';
    // whitespace-pre-line: runs of spaces collapse, line breaks stay, spaces around them go.
    return d.replaceAll(RegExp(r'[ \t]+'), ' ').replaceAll(RegExp(r' ?\n ?'), '\n');
  }

  /// NodeDescription: `px-3 pt-1 pb-2 system-xs-regular`, hidden when empty.
  static double _descHeight(Node n) {
    final d = desc(n);
    if (d.isEmpty || n.type == 'start-placeholder') return 0;
    return 4 + textHeight(d, difyStyle(DifyType.systemXsRegular, DifyColors.textTertiary), width - 2 - 24) + 8;
  }

  static BodyContext context(Node n, Node? Function(String) lookup, Node? start, {Offset viewOrigin = Offset.zero}) =>
      BodyContext(n, lookup, start: start, viewOrigin: viewOrigin);

  @override
  bool layoutDependsOnRun(Node node) => NodeExtras.hasRetry(node);

  @override
  List<Rect> spinners(CanvasNode node, CanvasGraph graph) {
    final n = node.node.value, run = node.cardRun.value;
    if (isNoteCard(n)) return const [];
    final body = bodyOf(n.type);
    if (!body.chrome.header) return const [];
    final retry = NodeExtras.retrySpinner(n, run, selected: node.selected.value);
    if (!run.isLoading && retry == null) return const [];
    final card = node.rect;
    final ctx = context(n, (id) => graph[id]?.node.value, graph.startNode);
    return [
      // NodeHeaderMeta's last item, at the right end of the header (`px-3 pt-3`, a 24 px row).
      if (run.isLoading) Rect.fromLTWH(card.right - border - 12 - 14, card.top + border + 12 + 5, 14, 14),
      if (retry != null) retry.shift(Offset(card.left + border, card.top + border + header + body.height(ctx))),
    ];
  }

  @override
  CardLayout layoutOf(Node node, Document doc, {NodeRunView run = NodeRunView.idle, bool selected = false}) {
    // A note (custom-note) is its own card: the node element at its data's size, no handles, under everything.
    if (isNoteCard(node)) {
      return CardLayout(card: Offset.zero & NoteData.of(node).size, sources: const {}, target: false, underlay: true);
    }
    final ctx = context(node, (id) => doc.nodes[id], doc.nodes.values.where((n) => n.type == 'start').firstOrNull);
    final body = bodyOf(node.type);
    final chrome = body.chrome;
    // React Flow's node element is the selection frame; the card sits 1 px inside it, entry nodes below their label.
    final top = isEntry(node.type) ? _entryLabel + 1 : 1.0;
    final card = switch (chrome) {
      CardChrome.container => Offset(1, 1) & body.cardSize(ctx)!,
      CardChrome.marker || CardChrome.flatMarker => const Rect.fromLTWH(0, 4, 44, 44),
      CardChrome.bodyOnly => Rect.fromLTWH(1, 1, width, 2 * border + body.height(ctx)),
      CardChrome.base || CardChrome.simple => Rect.fromLTWH(
        1,
        top,
        width,
        border +
            header +
            body.height(ctx) +
            NodeExtras.height(node, run, selected) +
            (chrome == CardChrome.base ? _descHeight(node) : 0) +
            (hasCopyId(node) ? copyIdHeight : 0) +
            _bottom +
            border,
      ),
    };
    final bodyTop = chrome.header ? border + header : border;
    // Body handles are `top-1/2! -translate-y-1/2!` on their row; with React Flow's own translate(0, -50%) the
    // handle ends up half its height (8 px) above the row's middle.
    final own = body.sources(ctx);
    final failBranch = NodeExtras.failBranchY(node, run, selected);
    final sources = {
      if (own == null)
        'source': CanvasNode.defaultHandleY
      else
        for (final e in own.entries) e.key: bodyTop + e.value - _handleLift,
      if (failBranch != null) NodeExtras.failBranch: bodyTop + body.height(ctx) + failBranch - _handleLift,
    };
    return CardLayout(
      card: card,
      visual: isEntry(node.type)
          ? Rect.fromLTWH(0, 0, width + 2, card.bottom + 1)
          : hasTab(node.type)
          ? Rect.fromLTRB(
              card.left - 1 - _tabInset,
              card.top - 1 - _tabTop,
              card.right + 1 + _tabInset,
              card.bottom + 1 + _tabInset,
            )
          : card,
      sources: sources,
      target: body.target,
    );
  }

  @override
  Widget build(
    BuildContext context,
    CanvasNode node,
    CanvasGraph graph, {
    required bool live,
    VoidCallback? onPainted,
  }) => isNoteCard(node.node.value)
      ? NoteCard(node: node, onPainted: onPainted)
      : DifyNodeCard(node: node, graph: graph, live: live, onPainted: onPainted);
}
