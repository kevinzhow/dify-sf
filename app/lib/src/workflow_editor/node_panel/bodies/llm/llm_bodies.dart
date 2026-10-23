/// The panel bodies of the model nodes: LLM, Question Classifier, Parameter Extractor, Knowledge Retrieval and
/// Agent (classic and v2). Register [llmPanelBodies] in NodePanelBodies; put an [LlmGroupScope] above the panel
/// to give them the workspace's models and the backend services they use.
library;

import 'package:flutter/widgets.dart';

import '../../node_panel_bodies.dart';
import 'agent_panel.dart';
import 'agent_v2_panel.dart';
import 'knowledge_retrieval_panel.dart';
import 'llm_panel.dart';
import 'parameter_extractor_panel.dart';
import 'question_classifier_panel.dart';

export 'group_host.dart' show LlmGroupScope, LlmGroupServices, LlmPage, LlmToastType;

/// `isAgentV2NodeData` (nodes/agent-v2/types.ts).
bool isAgentV2NodeData(Map<String, Object?> data) =>
    (data['type'] == 'agent' || data['type'] == 'agent-v2') &&
    data['agent_node_kind'] == 'dify_agent' &&
    data['version'] == '2';

/// PanelComponentMap['agent'] (WorkflowAgentPanel): Agent v2 for v2 data, else the classic agent.
Widget _agent(BuildContext context, NodePanelProps props) =>
    isAgentV2NodeData(props.data) ? agentV2PanelBody(context, props) : agentPanelBody(context, props);

/// The bodies by node type (`agent-v2` is the v2 catalog type; v2 nodes are stored as `agent`).
const Map<String, NodePanelBodyBuilder> llmPanelBodies = {
  'llm': llmPanelBody,
  'question-classifier': questionClassifierPanelBody,
  'parameter-extractor': parameterExtractorPanelBody,
  'knowledge-retrieval': knowledgeRetrievalPanelBody,
  'agent': _agent,
  'agent-v2': agentV2PanelBody,
};
