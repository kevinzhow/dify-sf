/// What the data source panel needs from the backend and the pipeline editor (Dify's `dataSourceList`, `pipelineId`,
/// `setShowInputFieldPanel`, the data-source settings page, schema type definitions, toasts), provided by the host.
library;

import 'package:flutter/widgets.dart';

import '../../../../../design/widgets/toast.dart';
import '../../../../panel_fields/panel_fields.dart';

class DataSourceHost extends InheritedWidget {
  const DataSourceHost({
    super.key,
    required super.child,
    this.dataSourceList,
    this.pipelineId,
    this.onShowInputFieldPanel,
    this.onJumpToDataSourcePage,
    this.schemaTypeDefinitions,
    this.availableVars = const [],
    this.onToastError = difyToastError,
  });

  /// `ToolWithProvider` JSON of the workspace's data sources (`plugin_id`, `is_authorized`, `allow_delete`,
  /// `tools: [{name, parameters, output_schema}]`); null while not loaded.
  final List<Json>? dataSourceList;

  /// The pipeline being edited (`showManageInputField` when set).
  final String? pipelineId;

  /// `setShowInputFieldPanel(true)`: opens the pipeline's Input Field panel.
  final VoidCallback? onShowInputFieldPanel;

  /// `handleJumpToDataSourcePage`: the settings page of data sources ("Connect" / "Authorizations").
  final VoidCallback? onJumpToDataSourcePage;

  /// `useSchemaTypeDefinitions` (`{name, schema}`).
  final List<Json>? schemaTypeDefinitions;

  /// The variables the parameter form's text fields can insert (the pipeline's input fields).
  final List<VarGroup> availableVars;

  /// `toast.error`.
  final ValueChanged<String>? onToastError;

  static DataSourceHost? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<DataSourceHost>();

  @override
  bool updateShouldNotify(DataSourceHost old) =>
      dataSourceList != old.dataSourceList ||
      pipelineId != old.pipelineId ||
      onShowInputFieldPanel != old.onShowInputFieldPanel ||
      onJumpToDataSourcePage != old.onJumpToDataSourcePage ||
      schemaTypeDefinitions != old.schemaTypeDefinitions ||
      availableVars != old.availableVars ||
      onToastError != old.onToastError;
}
