/// The plugin trigger's panel body (nodes/trigger-plugin/panel.tsx with use-config.ts): the event parameter form once
/// a valid subscription is selected, then the output variables of the event's live output schema.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../../../../workflow/dify_json.dart';
import '../../../../panel_fields/panel_fields.dart';
import '../../../node_panel_bodies.dart';
import '../../../panel_edit.dart';
import 'plugin_form.dart';
import 'trigger_plugin_default.dart';
import 'trigger_plugin_host.dart';

export 'trigger_plugin_default.dart';
export 'trigger_plugin_host.dart';
export 'trigger_subscription.dart' show triggerPluginTabsRow, TriggerSubscription, SubscriptionSelectorEntry;

/// The `trigger-plugin` body.
Widget triggerPluginPanelBody(BuildContext context, NodePanelProps props) => TriggerPluginPanel(props: props);

class TriggerPluginPanel extends StatefulWidget {
  const TriggerPluginPanel({super.key, required this.props});
  final NodePanelProps props;

  @override
  State<TriggerPluginPanel> createState() => _TriggerPluginPanelState();
}

class _TriggerPluginPanelState extends State<TriggerPluginPanel> {
  bool _filling = false;

  /// use-config's effect: fills `event_parameters` / `config` from the legacy config or the schema defaults once the
  /// event's schema is known and nothing is stored (not while read-only: nothing is written then).
  void _initialFill(Json data, List<Json> schema) {
    if (_filling || widget.props.readOnly) return;
    final next = triggerPluginInitialFill(data, schema);
    if (next == null) return;
    _filling = true;
    scheduleMicrotask(() {
      _filling = false;
      if (mounted) setInputs(widget.props, next);
    });
  }

  @override
  Widget build(BuildContext context) {
    final props = widget.props;
    final data = props.data;
    final host = TriggerPluginHost.maybeOf(context);
    final provider = findTriggerProvider(host?.providers, data);
    final event = findTriggerEvent(provider, data['event_name']);
    final schema = triggerParameterSchemaOf(event);
    final subscriptionId = data['subscription_id'];
    final subscriptions = host?.subscriptionsOf?.call('${data['provider_id'] ?? ''}') ?? const [];
    final subscribed = subscriptions.any((s) => s['id'] == subscriptionId);
    _initialFill(data, schema);

    final outputSchema = event?['output_schema'] is Map
        ? (event!['output_schema']! as Map).cast<String, Object?>()
        : <String, Object?>{};
    final properties = jsEntries(outputSchema['properties']).toList();
    final indent = hasObjectOutputOf(outputSchema);

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (schema.isNotEmpty && subscribed) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: PluginForm(
                schema: schema,
                value: triggerParameterValueOf(data, schema),
                readOnly: props.readOnly,
                disableVariableInsertion: true,
                onChange: (v) => setInputs(props, setTriggerParameterValue(props.data, v)),
                dynamicOptionsOf: provider == null || event == null || host?.dynamicOptionsOf == null
                    ? null
                    : (p) => host!.dynamicOptionsOf!(provider, event, p),
                onShowSchema: host?.onShowSchema,
              ),
            ),
            const PanelSplit(),
          ],
          OutputVars(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final MapEntry(:key, :value) in properties)
                  VarItem(
                    name: key,
                    type: jsStr(jsGet(value, 'type')) ?? 'string',
                    description: jsStr(jsGet(value, 'description')) ?? '',
                    isIndent: indent,
                  ),
                for (final MapEntry(:key, :value) in properties)
                  if (jsGet(value, 'type') == 'object')
                    StructureOutputItem(
                      payload: {
                        'schema': {
                          'type': 'object',
                          'properties': {key: value},
                          'additionalProperties': false,
                        },
                      },
                    ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
