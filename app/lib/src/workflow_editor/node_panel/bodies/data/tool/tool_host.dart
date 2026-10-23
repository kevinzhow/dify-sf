/// What the tool panel needs from the app that dify-sf has no service for yet: the account's language and timezone,
/// the plugin daemon's dynamic select options, the schema type definitions, the app and model selectors, the RAG
/// pipeline's input field panel. Every field has an empty default; the tool lists themselves come from the store
/// (`buildInTools`, `customTools`, `workflowTools`, `mcpTools`) unless [tools] overrides them.
library;

import 'package:flutter/widgets.dart';

import 'tool_model.dart';

/// Fetches a dynamic-select field's options (`useFetchDynamicOptions(plugin_id, provider, tool, parameter, 'tool')`):
/// Dify's `FormOption` JSON (`{value, label, icon?, show_on?}`).
typedef ToolDynamicOptionsFetch = Future<List<JsonMap>> Function({
  required String pluginId,
  required String provider,
  required String tool,
  required String parameter,
  Map<String, Object?>? extraParams,
});

/// Builds a field's app / model selector (AppSelector, ModelParameterModal): its current [value] and how to set it.
typedef ToolSelectorBuilder = Widget Function(
  BuildContext context, {
  required Object? value,
  required ValueChanged<Map<String, Object?>> onSelect,
  required bool readOnly,
  String? scope,
});

class ToolPanelHost extends InheritedWidget {
  const ToolPanelHost({
    super.key,
    this.language = 'en_US',
    this.timezone = 'UTC',
    this.tools,
    this.fetchDynamicOptions,
    this.schemaTypeDefinitions = const [],
    this.appSelector,
    this.modelSelector,
    this.onManageInputField,
    required super.child,
  });

  /// `useLanguage()` (`en_US`, `zh_Hans`, …).
  final String language;

  /// The user profile's timezone.
  final String timezone;

  /// The workspace's tools; null: the store's lists.
  final ToolCollections? tools;
  final ToolDynamicOptionsFetch? fetchDynamicOptions;

  /// `useSchemaTypeDefinitions()` (`/spec/schema-definitions`).
  final List<SchemaTypeDefinition> schemaTypeDefinitions;
  final ToolSelectorBuilder? appSelector, modelSelector;

  /// In a RAG pipeline (`pipelineId`): opens the input field panel; null elsewhere.
  final VoidCallback? onManageInputField;

  static const _none = ToolPanelHost(child: SizedBox.shrink());

  static ToolPanelHost of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<ToolPanelHost>() ?? _none;

  @override
  bool updateShouldNotify(ToolPanelHost old) =>
      language != old.language ||
      timezone != old.timezone ||
      tools != old.tools ||
      fetchDynamicOptions != old.fetchDynamicOptions ||
      schemaTypeDefinitions != old.schemaTypeDefinitions ||
      appSelector != old.appSelector ||
      modelSelector != old.modelSelector ||
      onManageInputField != old.onManageInputField;
}
