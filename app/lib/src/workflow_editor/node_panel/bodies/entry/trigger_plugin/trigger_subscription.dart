/// The plugin trigger's subscription controls in the panel's tab row (workflow-panel/trigger-subscription.tsx,
/// plugins/plugin-detail-panel/subscription-list/selector-entry.tsx and selector-view.tsx).
library;

import 'package:flutter/widgets.dart';

import '../../../../../design/dify_icon.dart';
import '../../../../../design/dify_tokens.g.dart';
import '../../../../../design/widgets/widgets.dart';
import '../../../../../i18n/dify_i18n.dart';
import '../../../../panel_fields/panel_fields.dart';
import '../../../node_panel_bodies.dart';
import 'trigger_plugin_default.dart' show findTriggerProvider;
import 'trigger_plugin_host.dart';

String _pt(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('plugin-trigger', key, params);

/// The tab row of a plugin trigger's panel: with no subscription a full-width "New subscription" button above
/// [tabs]; otherwise [tabs] on the left and the [SubscriptionSelectorEntry] on the right. Choosing a subscription
/// writes `subscription_id`. The shell puts this around its tabs for `trigger-plugin` nodes; null (the plain row)
/// while the node's provider is not among the host's (Dify's `currentTriggerPlugin`).
Widget? triggerPluginTabsRow(BuildContext context, NodePanelProps props, Widget tabs) {
  final host = TriggerPluginHost.maybeOf(context);
  if (findTriggerProvider(host?.providers, props.data) == null) return null;
  final providerId = '${props.data['provider_id'] ?? ''}';
  return TriggerSubscription(
    subscriptions: host?.subscriptionsOf?.call(providerId) ?? const [],
    selectedId: props.data['subscription_id'] as String?,
    onCreate: host?.onCreateSubscription == null ? null : () => host!.onCreateSubscription!(providerId),
    confirmDelete: host?.confirmDeleteSubscription,
    onSubscriptionChange: props.readOnly ? null : (id) => props.setData('subscription_id', id),
    child: tabs,
  );
}

/// TriggerSubscription: `px-4`, and `flex items-center justify-between pr-3` once there are subscriptions.
class TriggerSubscription extends StatelessWidget {
  const TriggerSubscription({
    super.key,
    required this.subscriptions,
    required this.child,
    this.selectedId,
    this.onSubscriptionChange,
    this.onCreate,
    this.confirmDelete,
  });

  final List<Json> subscriptions;
  final String? selectedId;
  final ValueChanged<String>? onSubscriptionChange;
  final VoidCallback? onCreate;
  final Future<bool> Function(Json subscription)? confirmDelete;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (subscriptions.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DifyButton(
              variant: DifyButtonVariant.primary,
              onPressed: onCreate,
              disabled: onCreate == null,
              leading: const RemixIcon('add-line', size: 16),
              child: DifyTextLine(_pt('subscription.empty.button')),
            ),
            child,
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(left: 16, right: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(child: child),
          SubscriptionSelectorEntry(
            subscriptions: subscriptions,
            selectedId: selectedId,
            onSelect: onSubscriptionChange,
            onCreate: onCreate,
            confirmDelete: confirmDelete,
          ),
        ],
      ),
    );
  }
}

/// SubscriptionSelectorEntry: the status button (webhook icon, label, chevron; red when none is selected or the
/// selected one is gone) opening the subscription list 4 px below.
class SubscriptionSelectorEntry extends StatefulWidget {
  const SubscriptionSelectorEntry({
    super.key,
    required this.subscriptions,
    this.selectedId,
    this.onSelect,
    this.onCreate,
    this.confirmDelete,
  });

  final List<Json> subscriptions;
  final String? selectedId;
  final ValueChanged<String>? onSelect;
  final VoidCallback? onCreate;
  final Future<bool> Function(Json subscription)? confirmDelete;

  /// The button's label and whether it is red (`statusConfig`).
  static (String, bool) status(List<Json> subscriptions, String? selectedId, {required bool open}) {
    if (selectedId == null || selectedId.isEmpty) {
      return open ? (_pt('subscription.selectPlaceholder'), false) : (_pt('subscription.noSubscriptionSelected'), true);
    }
    if (subscriptions.isNotEmpty) {
      final selected = subscriptions.where((s) => s['id'] == selectedId).firstOrNull;
      if (selected == null) return (_pt('subscription.subscriptionRemoved'), true);
      return ('${selected['name'] ?? ''}', false);
    }
    return (_pt('subscription.noSubscriptionSelected'), true);
  }

  @override
  State<SubscriptionSelectorEntry> createState() => _SubscriptionSelectorEntryState();
}

class _SubscriptionSelectorEntryState extends State<SubscriptionSelectorEntry> {
  final _controller = DifyFloatingController();

  @override
  Widget build(BuildContext context) {
    final w = widget;
    return DifyPopover(
      controller: _controller,
      placement: DifyPlacement.bottomStart,
      sideOffset: 4,
      surface: false,
      builder: (context, controller) => Builder(
        builder: (context) {
          final open = controller.isOpen;
          final (label, red) = SubscriptionSelectorEntry.status(w.subscriptions, w.selectedId, open: open);
          final color = red ? DifyColors.componentsButtonDestructiveSecondaryText : null;
          return DifyPressable(
            semanticLabel: label,
            onPressed: controller.toggle,
            builder: (context, hovered, focused) => Container(
              height: 32,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: hovered || open ? DifyColors.stateBaseHoverAlt : null,
                borderRadius: BorderRadius.circular(DifyRadius.lg),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                spacing: 4,
                children: [
                  RemixIcon('webhook-line', size: 14, color: color ?? DifyColors.textSecondary),
                  Flexible(
                    child: DifyText(
                      label,
                      DifyType.systemXsMedium,
                      color: color ?? DifyColors.componentsButtonGhostText,
                    ),
                  ),
                  AnimatedRotation(
                    turns: open ? 0.5 : 0,
                    duration: const Duration(milliseconds: 150),
                    child: RemixIcon('arrow-down-s-line', size: 16, color: color ?? DifyColors.textQuaternary),
                  ),
                ],
              ),
            ),
          );
        },
      ),
      content: Builder(
        builder: (context) => Container(
          decoration: BoxDecoration(
            color: DifyColors.componentsPanelBg,
            border: Border.all(color: DifyColors.componentsPanelBorder),
            borderRadius: BorderRadius.circular(DifyRadius.xl),
            boxShadow: DifyShadows.lg,
          ),
          child: SubscriptionSelectorView(
            subscriptions: w.subscriptions,
            selectedId: w.selectedId,
            onCreate: w.onCreate,
            confirmDelete: w.confirmDelete,
            onSelect: (id) {
              w.onSelect?.call(id);
              _controller.close();
            },
          ),
        ),
      ),
    );
  }
}

/// SubscriptionSelectorView (`w-[320px] p-1`): "N subscriptions" with its tip and a create button, then one row per
/// subscription (check on the selected one, a delete button on hover; deleting asks [confirmDelete] and then
/// selects none).
class SubscriptionSelectorView extends StatelessWidget {
  const SubscriptionSelectorView({
    super.key,
    required this.subscriptions,
    this.selectedId,
    this.onSelect,
    this.onCreate,
    this.confirmDelete,
  });

  final List<Json> subscriptions;
  final String? selectedId;
  final ValueChanged<String>? onSelect;
  final VoidCallback? onCreate;
  final Future<bool> Function(Json subscription)? confirmDelete;

  @override
  Widget build(BuildContext context) => Container(
    width: 320,
    padding: const EdgeInsets.all(4),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (subscriptions.isNotEmpty)
          Container(
            height: 32,
            margin: const EdgeInsets.only(left: 28, right: 6),
            child: Row(
              children: [
                DifyText(
                  _pt('subscription.listNum', {'num': subscriptions.length}),
                  DifyType.systemSmSemiboldUppercase,
                  color: DifyColors.textSecondary,
                ),
                const SizedBox(width: 4),
                DifyInfotip(label: _pt('subscription.list.tip'), content: DifyTextLine(_pt('subscription.list.tip'))),
                const Spacer(),
                DifyIconButton(
                  label: _pt('subscription.empty.button'),
                  onPressed: onCreate,
                  disabled: onCreate == null,
                  icon: const RemixIcon('add-line', size: 16),
                ),
              ],
            ),
          ),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 320),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [for (final s in subscriptions) _SubscriptionRow(this, s)],
            ),
          ),
        ),
      ],
    ),
  );
}

class _SubscriptionRow extends StatefulWidget {
  const _SubscriptionRow(this.view, this.subscription);
  final SubscriptionSelectorView view;
  final Json subscription;

  @override
  State<_SubscriptionRow> createState() => _SubscriptionRowState();
}

class _SubscriptionRowState extends State<_SubscriptionRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final v = widget.view;
    final s = widget.subscription;
    final selected = v.selectedId == s['id'];
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: _hovered || selected ? DifyColors.stateBaseHover : null,
          borderRadius: BorderRadius.circular(DifyRadius.lg),
        ),
        child: Row(
          children: [
            Expanded(
              child: DifyPressable(
                semanticLabel: '${s['name'] ?? ''}',
                onPressed: () => v.onSelect?.call('${s['id']}'),
                builder: (context, hovered, focused) => Row(
                  children: [
                    if (selected)
                      Padding(
                        padding: EdgeInsets.only(right: 8),
                        child: RemixIcon('check-line', size: 16, color: DifyColors.textAccent),
                      ),
                    Padding(
                      padding: EdgeInsets.only(left: selected ? 0 : 24, right: 6),
                      child: RemixIcon('webhook-line', size: 14, color: DifyColors.textSecondary),
                    ),
                    Flexible(
                      child: DifyText('${s['name'] ?? ''}', DifyType.systemMdRegular, color: DifyColors.textSecondary),
                    ),
                  ],
                ),
              ),
            ),
            if (_hovered && v.confirmDelete != null)
              DifyIconButton(
                label: DifyI18n.tr('common', 'operation.delete'),
                tone: DifyButtonTone.destructive,
                onPressed: () async {
                  if (await v.confirmDelete!(s)) v.onSelect?.call('');
                },
                icon: const RemixIcon('delete-bin-line', size: 16),
              ),
          ],
        ),
      ),
    );
  }
}
