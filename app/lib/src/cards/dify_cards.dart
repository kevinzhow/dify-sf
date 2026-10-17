import 'package:collab_client/collab_client.dart';
import 'package:flutter/material.dart';

import '../canvas/canvas_graph.dart';
import '../canvas/node_card.dart';
import '../design/dify_icon.dart';
import '../design/dify_tokens.g.dart';
import 'bodies/answer_body.dart';
import 'bodies/basic_bodies.dart';
import 'bodies/container_bodies.dart';
import 'bodies/data_bodies.dart';
import 'bodies/entry_bodies.dart';
import 'bodies/llm_bodies.dart';
import 'card_chrome.dart';
import 'card_kit.dart';
import 'node_body.dart';
import 'node_extras.dart';

/// Dify's node cards: the shared chrome (nodes/_base/node.tsx) around a body per node type.
class DifyCards extends CardSpec {
  const DifyCards();

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
    for (final k in VarKind.values) {
      yield ('assets/dify_icons/${varIcon(k)}.svg', varColor(k));
      yield ('assets/dify_icons/${varIcon(k)}.svg', DifyColors.textWarning);
    }
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
    yield ('assets/remix_icons/more-line.svg', DifyColors.textSecondary);
    yield ('assets/dify_icons/vender/line/general/plus-02.svg', DifyColors.textTertiary);
    yield ('assets/dify_icons/vender/other/group.svg', DifyColors.textTertiary);
    yield ('assets/dify_icons/vender/agent-v2/configure.svg', DifyColors.textTertiary);
    yield* entryBodyIcons;
  }

  static bool isEntry(String type) => type == 'start' || type == 'start-placeholder' || type.startsWith('trigger-');

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
  CardLayout layoutOf(Node node, Document doc) {
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
            NodeExtras.height(node) +
            (chrome == CardChrome.base ? _descHeight(node) : 0) +
            _bottom +
            border,
      ),
    };
    final bodyTop = chrome.header ? border + header : border;
    // Body handles are `top-1/2! -translate-y-1/2!` on their row; with React Flow's own translate(0, -50%) the
    // handle ends up half its height (8 px) above the row's middle.
    final own = body.sources(ctx);
    final failBranch = NodeExtras.failBranchY(node);
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
  }) => DifyNodeCard(node: node, graph: graph, live: live, onPainted: onPainted);
}
