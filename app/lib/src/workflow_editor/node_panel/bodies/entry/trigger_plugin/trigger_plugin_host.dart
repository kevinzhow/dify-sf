/// What the plugin trigger panel needs from the backend (Dify's `useAllTriggerPlugins`, `useTriggerSubscriptions`,
/// the subscription create / delete flows, schema type definitions, dynamic options), provided by the host app.
library;

import 'package:flutter/widgets.dart';

import '../../../../panel_fields/node_config.dart' show Json;

/// The plugin trigger's backend data. Without one in scope the panel shows no providers (so no form) and no
/// subscriptions.
class TriggerPluginHost extends InheritedWidget {
  const TriggerPluginHost({
    super.key,
    required super.child,
    this.providers,
    this.subscriptionsOf,
    this.onCreateSubscription,
    this.confirmDeleteSubscription,
    this.dynamicOptionsOf,
    this.onShowSchema,
  });

  /// `TriggerWithProvider` JSON (`name`, `id`, `plugin_id`, `label`, `icon`, `events: [{name, label, description,
  /// parameters, output_schema}]`, …); null while not loaded.
  final List<Json>? providers;

  /// `useTriggerSubscriptions(provider_id)`: `TriggerSubscription` JSON (`id`, `name`, `workflows_in_use`, …).
  final List<Json> Function(String providerId)? subscriptionsOf;

  /// CreateSubscriptionButton (OAuth / API key / manual flows live in the host).
  final void Function(String providerId)? onCreateSubscription;

  /// DeleteConfirm: true when the subscription was deleted.
  final Future<bool> Function(Json subscription)? confirmDeleteSubscription;

  /// Dynamic select options of an event parameter (`useTriggerPluginDynamicOptions`), null while not loaded.
  final List<Json>? Function(Json provider, Json event, String parameter)? dynamicOptionsOf;

  /// SchemaModal for an object / array parameter's `input_schema`.
  final void Function(String name, Object? inputSchema)? onShowSchema;

  static TriggerPluginHost? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TriggerPluginHost>();

  @override
  bool updateShouldNotify(TriggerPluginHost old) =>
      providers != old.providers ||
      subscriptionsOf != old.subscriptionsOf ||
      onCreateSubscription != old.onCreateSubscription ||
      confirmDeleteSubscription != old.confirmDeleteSubscription ||
      dynamicOptionsOf != old.dynamicOptionsOf ||
      onShowSchema != old.onShowSchema;
}
