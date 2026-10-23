import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/workflow/dify_json.dart';
import 'package:dify_sf_app/src/workflow_editor/context_menu/context_menu.dart';
import 'package:dify_sf_app/src/workflow_editor/header/header_data.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/node_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/entry/trigger_webhook/trigger_webhook_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/entry/trigger_webhook/webhook_config.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../context_menu/harness.dart';

export '../../../../dify_test_i18n.dart';
export '../../../context_menu/harness.dart' show Harness, node;

/// [child] in a Material app, 400 px wide at the top left.
Widget wrap(Widget child) => MaterialApp(
  home: Material(
    child: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(width: 400, child: SingleChildScrollView(child: child)),
    ),
  ),
);

/// The control whose accessible name is [label] (Dify's `getByRole('button', { name })`).
Finder buttonNamed(String label) =>
    find.byWidgetPredicate((w) => w is DifyPressable && w.semanticLabel == label, description: 'button "$label"');

/// Dify's `getAllByRole('checkbox')`.
Finder checkboxes() => find.byWidgetPredicate((w) => w is Semantics && w.properties.checked != null);

/// Dify's `getAllByRole('textbox')`.
Finder textboxes() => find.byType(TextField);

Future<void> settle(WidgetTester t, [int ms = 400]) async {
  for (var i = 0; i < ms ~/ 100; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

/// A webhook node `n` with [data] (Dify JSON) in a [Harness] document, and its panel body (rebuilt on each change)
/// under [WebhookTriggerHost].
Future<Harness> startWebhook(WidgetTester t, Json data, {List<Node> others = const [], List<Edge> edges = const []}) =>
    Harness.start(t, [
      node(
        'n',
        type: 'trigger-webhook',
        title: 'Webhook',
        config: {for (final e in data.entries) e.key: Value.of(e.value)},
      ),
      ...others,
    ], edges: edges);

Widget webhookPanel(
  Harness h, {
  Future<WebhookUrls> Function(String nodeId)? fetch,
  HeaderToast? toast,
  bool readOnly = false,
}) => MaterialApp(
  home: Material(
    child: WebhookTriggerHost(
      fetchWebhookUrl: fetch,
      toast: toast,
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 400,
          child: SingleChildScrollView(
            child: ListenableBuilder(
              listenable: h.controller,
              builder: (context, _) => triggerWebhookPanelBody(
                context,
                NodePanelProps(
                  node: h['n']!,
                  controller: h.controller,
                  actions: h.actions(WorkflowMenuOptions(canEdit: !readOnly)),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  ),
);

/// The node's Dify data now.
Json dataOf(Harness h) => difyDataOf(h['n']!);
