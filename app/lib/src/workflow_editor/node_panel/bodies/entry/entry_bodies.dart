/// The entry nodes' panels: the triggers (schedule, webhook, plugin), the workflow start placeholder and the
/// knowledge pipeline's data source and knowledge base, with their `checkValid`s and the hosts that hand them backend
/// data (each falls back to empty data when absent).
///
/// `datasource-empty` has no panel (Dify never selects it), so it has no body here.
library;

import '../../../header/checklist/node_validators.dart' show NodeCheckValid;
import '../../node_panel_bodies.dart';
import 'data_source/data_source_panel.dart';
import 'knowledge_base/knowledge_base_logic.dart';
import 'knowledge_base/knowledge_base_panel.dart';
import 'start_placeholder/start_placeholder_panel.dart';
import 'trigger_plugin/trigger_plugin_panel.dart';
import 'trigger_schedule/trigger_schedule_panel.dart';
import 'trigger_webhook/trigger_webhook_panel.dart';
import 'trigger_webhook/webhook_default.dart';

export 'data_source/data_source_host.dart';
export 'data_source/data_source_panel.dart';
export 'entry_common.dart';
export 'knowledge_base/knowledge_base_host.dart';
export 'knowledge_base/knowledge_base_panel.dart';
export 'start_placeholder/start_placeholder_panel.dart';
export 'trigger_plugin/trigger_plugin_host.dart';
export 'trigger_plugin/trigger_plugin_panel.dart';
export 'trigger_schedule/trigger_schedule_panel.dart';
export 'trigger_webhook/trigger_webhook_panel.dart';

/// The entry nodes' bodies by node type.
const Map<String, NodePanelBodyBuilder> entryPanelBodies = {
  'trigger-schedule': triggerSchedulePanelBody,
  'trigger-webhook': triggerWebhookPanelBody,
  'trigger-plugin': triggerPluginPanelBody,
  'start-placeholder': startPlaceholderPanelBody,
  'datasource': dataSourcePanelBody,
  'knowledge-index': knowledgeBasePanelBody,
};

/// The entry nodes' `checkValid`s (default.ts), for `nodeCheckValid`. Plugin, data source and knowledge base checks
/// read the extra data Dify's checklist adds (`getTriggerCheckParams`, `getDataSourceCheckParams`, the model lists).
const Map<String, NodeCheckValid> entryCheckValid = {
  'trigger-schedule': checkValidTriggerSchedule,
  'trigger-webhook': checkValidTriggerWebhook,
  'trigger-plugin': checkValidTriggerPlugin,
  'start-placeholder': checkValidStartPlaceholder,
  'datasource': checkValidDataSource,
  'datasource-empty': checkValidDataSourceEmpty,
  'knowledge-index': checkValidKnowledgeBase,
};
