/// The data source's panel body (nodes/data-source/panel.tsx with hooks/use-config.ts): the parameter form of an
/// authorized online source, or the supported file formats of a local file source; then the output variables.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../../../../design/dify_tokens.g.dart';
import '../../../../../i18n/dify_i18n.dart';
import '../../../../../workflow/dify_json.dart';
import '../../../../panel_fields/panel_fields.dart';
import '../../../node_panel_bodies.dart';
import '../../../panel_edit.dart';
import '../trigger_plugin/plugin_form.dart';
import '../../../../panel_fields/tool_form_schema.dart' show toolParametersToFormSchemas;
import 'data_source_default.dart';
import 'data_source_host.dart';
import '../../../../../design/widgets/widgets.dart';

export 'before_run_form.dart';
export 'data_source_auth.dart' show dataSourceTabsRow, PluginAuthInDataSourceNode, AuthorizedInDataSourceNode;
export 'data_source_default.dart';
export 'data_source_host.dart';

String _wf(String key) => DifyI18n.tr('workflow', key);

/// The `datasource` body.
Widget dataSourcePanelBody(BuildContext context, NodePanelProps props) => DataSourcePanel(props: props);

class DataSourcePanel extends StatefulWidget {
  const DataSourcePanel({super.key, required this.props});
  final NodePanelProps props;

  @override
  State<DataSourcePanel> createState() => _DataSourcePanelState();
}

class _DataSourcePanelState extends State<DataSourcePanel> {
  @override
  void initState() {
    super.initState();
    // use-config's mount effect (not while read-only: nothing is written then).
    final next = widget.props.readOnly ? null : dataSourceLocalFileInit(widget.props.data);
    if (next != null) scheduleMicrotask(() => mounted ? setInputs(widget.props, next) : null);
  }

  @override
  Widget build(BuildContext context) {
    final props = widget.props;
    final data = props.data;
    final host = DataSourceHost.maybeOf(context);
    final list = host?.dataSourceList;
    final readOnly = props.readOnly;
    final isLocalFile = data['provider_type'] == localFileProviderType;
    final ds = findDataSource(list, data);
    final item = findDataSourceItem(ds, data);
    final formSchemas = item == null ? const <Json>[] : toolParametersToFormSchemas(item['parameters']);
    final outputSchema = dataSourceOutputSchema(list, data);
    final indent = dataSourceHasObjectOutput(list, data);
    final definitions = host?.schemaTypeDefinitions;
    final parameters = data['datasource_parameters'] is Map
        ? (data['datasource_parameters']! as Map).cast<String, Object?>()
        : <String, Object?>{};

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (ds?['is_authorized'] == true && !isLocalFile && formSchemas.isNotEmpty)
          BoxGroupField(
            boxBorderBottom: true,
            field: LayoutField(
              title: _wf('nodes.tool.inputVars'),
              supportCollapse: true,
              child: PluginForm(
                schema: formSchemas,
                value: parameters,
                readOnly: readOnly,
                wrapLabel: true,
                scope: VarScope(vars: host?.availableVars ?? const []),
                showManageInputField: host?.pipelineId != null && host!.pipelineId!.isNotEmpty,
                onManageInputField: host?.onShowInputFieldPanel,
                onChange: (v) => setInputs(props, {...props.data, 'datasource_parameters': v}),
              ),
            ),
          ),
        if (isLocalFile)
          BoxGroupField(
            boxBorderBottom: true,
            field: LayoutField(
              title: _wf('nodes.dataSource.supportedFileFormats'),
              child: Container(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
                decoration: BoxDecoration(
                  color: DifyColors.componentsInputBgNormal,
                  borderRadius: BorderRadius.circular(DifyRadius.lg),
                ),
                child: TagInput(
                  items: [for (final e in jsList(data['fileExtensions'])) '$e'],
                  onChange: (items) => props.setData('fileExtensions', items),
                  placeholder: _wf('nodes.dataSource.supportedFileFormatsPlaceholder'),
                  disableAdd: readOnly,
                  disableRemove: readOnly,
                  onError: host?.onToastError ?? difyToastError,
                ),
              ),
            ),
          ),
        OutputVars(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final o in commonOutput)
                VarItem(name: o.name, type: o.type, description: o.description, isIndent: indent),
              if (isLocalFile)
                for (final o in localFileOutput)
                  VarItem(
                    name: o.name,
                    type: o.type,
                    description: o.description,
                    subItems: [for (final s in o.subItems) (name: s.name, type: s.type, description: s.description)],
                  ),
              for (final o in outputSchema)
                if (o.value?['type'] == 'object')
                  StructureOutputItem(payload: wrapStructuredVarItem(o, getMatchedSchemaType(o.value, definitions)))
                else
                  VarItem(
                    name: o.name,
                    type: () {
                      final schemaType = getMatchedSchemaType(o.value, definitions);
                      return '${(o.type ?? '').toLowerCase()}${schemaType.isNotEmpty ? ' ($schemaType)' : ''}';
                    }(),
                    description: o.description ?? '',
                    isIndent: indent,
                  ),
            ],
          ),
        ),
      ],
    );
  }
}
