import '../../i18n/dify_i18n.dart';

/// A block's metadata (utils/gen-node-meta-data.ts and each node's default.ts, as workflow-app's
/// use-available-nodes-meta-data.ts offers them): what the node menus may do with it.
class NodeMeta {
  const NodeMeta({this.isSingleton = false, this.isUndeletable = false, this.isTypeFixed = false, this.helpLinkUri});

  final bool isSingleton;
  final bool isUndeletable;
  final bool isTypeFixed;

  /// The docs page under `/use-dify/nodes/` (defaults to the type).
  final String? helpLinkUri;

  /// `blocksAbout.<type>`.
  static String descriptionOf(String type) => DifyI18n.tr('workflow', 'blocksAbout.$type');

  /// Blocks are Dify's own (tools and data sources carry their provider's author, not known here).
  static const author = 'Dify';
}

const _common = <String, NodeMeta>{
  'llm': NodeMeta(),
  'knowledge-retrieval': NodeMeta(),
  'agent': NodeMeta(helpLinkUri: 'agent#classic-agent'),
  'agent-v2': NodeMeta(helpLinkUri: 'agent#new-agent'),
  'question-classifier': NodeMeta(),
  'if-else': NodeMeta(helpLinkUri: 'ifelse'),
  'iteration': NodeMeta(isTypeFixed: true),
  'iteration-start': NodeMeta(),
  'loop': NodeMeta(isTypeFixed: true),
  'loop-start': NodeMeta(),
  'loop-end': NodeMeta(isSingleton: true),
  'code': NodeMeta(),
  'template-transform': NodeMeta(helpLinkUri: 'template'),
  'variable-aggregator': NodeMeta(),
  'document-extractor': NodeMeta(helpLinkUri: 'doc-extractor'),
  'assigner': NodeMeta(helpLinkUri: 'variable-assigner'),
  'parameter-extractor': NodeMeta(),
  'http-request': NodeMeta(),
  'list-operator': NodeMeta(),
  'tool': NodeMeta(helpLinkUri: 'tools'),
  'human-input': NodeMeta(),
};

const _workflowOnly = <String, NodeMeta>{
  'start-placeholder': NodeMeta(isSingleton: true, isTypeFixed: true, helpLinkUri: 'start'),
  'end': NodeMeta(helpLinkUri: 'output'),
  'trigger-webhook': NodeMeta(helpLinkUri: 'trigger/webhook-trigger'),
  'trigger-schedule': NodeMeta(helpLinkUri: 'trigger/schedule-trigger'),
  'trigger-plugin': NodeMeta(helpLinkUri: 'trigger/plugin-trigger'),
};

/// The metadata of [type] in a workflow (or, with [chatMode], a chatflow); null for blocks the app does not offer
/// there (Dify then neither copies nor pastes them).
NodeMeta? nodeMetaOf(String type, {bool chatMode = false}) {
  if (type == 'start') {
    // The start node can't be deleted in a chatflow (use-nodes-interactions.ts handleNodeDelete).
    return NodeMeta(isSingleton: true, isUndeletable: chatMode, helpLinkUri: 'start');
  }
  if (type == 'answer') return chatMode ? const NodeMeta() : null;
  return _common[type] ?? (chatMode ? null : _workflowOnly[type]);
}

/// The doc paths Dify links to (types/doc-paths.ts, `/use-dify/nodes/*`).
const _docPaths = {
  'agent', 'answer', 'code', 'doc-extractor', 'http-request', 'human-input', 'ifelse', 'iteration', //
  'knowledge-retrieval', 'list-operator', 'llm', 'loop', 'output', 'parameter-extractor', 'question-classifier',
  'start', 'template', 'tools', 'trigger/overview', 'trigger/plugin-trigger', 'trigger/schedule-trigger',
  'trigger/webhook-trigger', 'user-input', 'variable-aggregator', 'variable-assigner',
};

/// The "View Docs" link of [type] (useDocLink: `https://docs.dify.ai/<en|zh|ja>/<product>/use-dify/nodes/<uri>`),
/// or null when Dify has no page for it. [product] is `self-host`, or `cloud` on Dify Cloud.
String? nodeHelpLink(String type, {bool chatMode = false, String product = 'self-host'}) {
  final meta = nodeMetaOf(type, chatMode: chatMode);
  if (meta == null) return null;
  final uri = meta.helpLinkUri ?? type;
  if (!_docPaths.contains(uri.split('#').first)) return null;
  final language = switch (DifyI18n.current) {
    DifyI18n(:final language) => language,
    _ => DifyI18n.fallbackLanguage,
  };
  final docLanguage = const {'zh-Hans': 'zh', 'ja-JP': 'ja'}[language] ?? 'en';
  return 'https://docs.dify.ai/$docLanguage/$product/use-dify/nodes/$uri';
}

/// utils/workflow.ts canRunBySingle: the blocks "Run this step" runs (an assigner inside a container cannot).
bool canRunBySingle(String type, {required bool isChildNode}) {
  if (isChildNode && type == 'assigner') return false;
  return const {
    'llm', 'knowledge-retrieval', 'code', 'template-transform', 'question-classifier', 'http-request', 'tool', //
    'parameter-extractor', 'iteration', 'agent', 'agent-v2', 'document-extractor', 'loop', 'start', 'if-else',
    'variable-aggregator', 'assigner', 'human-input', 'datasource', 'trigger-schedule', 'trigger-webhook',
    'trigger-plugin',
  }.contains(type);
}
