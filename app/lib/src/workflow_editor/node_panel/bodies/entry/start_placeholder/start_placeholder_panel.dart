/// The workflow start placeholder's panel body (nodes/start-placeholder/panel.tsx, default.ts): a trigger search box
/// over the start blocks (block-selector/all-start-blocks.tsx in its panel variant, start-blocks.tsx,
/// trigger-plugin/list.tsx, item.tsx, action-item.tsx). Choosing one replaces the placeholder in place with that
/// block's defaults, which the host applies ([StartPlaceholderHost.onSelectStartBlock]).
///
/// Not ported (marketplace services): the tag filter, featured and marketplace triggers; installed trigger plugins
/// show the trigger block icon rather than the provider's.
library;

import 'package:flutter/widgets.dart';

import '../../../../../design/dify_icon.dart';
import '../../../../../design/dify_tokens.g.dart';
import '../../../../../design/widgets/widgets.dart';
import '../../../../../i18n/dify_i18n.dart';
import '../../../../../workflow/dify_json.dart';
import '../../../../header/checklist/node_validators.dart' show ChecklistTranslate;
import '../../../../panel_fields/panel_fields.dart';
import '../../../node_panel_bodies.dart';
import '../trigger_plugin/plugin_form.dart' show uiLanguage;
import '../trigger_plugin/trigger_plugin_default.dart' show labelOf, triggerPluginDefaultValue;
import '../trigger_plugin/trigger_plugin_host.dart';

String _wf(String key) => DifyI18n.tr('workflow', key);

// ---- default.ts -------------------------------------------------------------------------------------------------

/// `defaultValue`.
const Json startPlaceholderDefaultValue = {'title': 'Workflow start', 'desc': ''};

/// `checkValid`: never valid, a start node must be chosen.
String checkValidStartPlaceholder(Json data, ChecklistTranslate t, Json? moreData) =>
    t('workflow', 'nodes.startPlaceholder.validationRequired');

/// The `defaultValue`s of the start blocks (each node's default.ts) as `nodesMap` gives them: with `type` and the
/// localized `title`.
Map<String, Json> startBlockDefaults() => {
  for (final MapEntry(:key, :value) in const <String, Json>{
    'start': {'variables': <Object?>[]},
    'trigger-schedule': {
      'mode': 'visual',
      'frequency': 'daily',
      'visual_config': {
        'time': '12:00 AM',
        'weekdays': ['sun'],
        'on_minute': 0,
        'monthly_days': [1],
      },
      'cron_expression': '',
    },
    'trigger-webhook': {
      'webhook_url': '',
      'method': 'POST',
      'content_type': 'application/json',
      'headers': <Object?>[],
      'params': <Object?>[],
      'body': <Object?>[],
      'async_mode': true,
      'status_code': 200,
      'response_body': '',
      'variables': [
        {
          'variable': '_webhook_raw',
          'label': 'raw',
          'value_type': 'object',
          'value_selector': <Object?>[],
          'required': true,
        },
      ],
    },
    'trigger-plugin': triggerPluginDefaultValue,
  }.entries)
    key: {...value, 'type': key, 'title': _wf('blocks.$key')},
};

/// `getTriggerPluginNodeData`: a trigger plugin's node data from the block selector's `TriggerDefaultValue`.
Json getTriggerPluginNodeData(Json c, {Object? fallbackTitle, Object? fallbackDesc}) => {
  'plugin_id': c['plugin_id'],
  'provider_id': c['provider_name'],
  'provider_type': c['provider_type'],
  'provider_name': c['provider_name'],
  'event_name': c['event_name'],
  'event_label': c['event_label'],
  'event_description': c['event_description'],
  'title': jsTruthy(c['event_label']) ? c['event_label'] : (jsTruthy(c['title']) ? c['title'] : fallbackTitle),
  'desc': jsTruthy(c['event_description']) ? c['event_description'] : fallbackDesc,
  'output_schema': {...?(c['output_schema'] as Map?)?.cast<String, Object?>()},
  'parameters_schema': [...jsList(c['paramSchemas'])],
  'config': {...?(c['params'] as Map?)?.cast<String, Object?>()},
  'subscription_id': c['subscription_id'],
  'plugin_unique_identifier': c['plugin_unique_identifier'],
  'is_team_authorization': c['is_team_authorization'],
  'meta': c['meta'] is Map ? {...(c['meta']! as Map).cast<String, Object?>()} : null,
};

/// handleSelectStartNode's new data for the placeholder: the block's defaults with [toolConfig] (a trigger plugin's
/// mapped fields, its `config` merged), `type` and `selected: true`; null when the type has no defaults.
Json? startNodeDataOf(String type, Map<String, Json> nodeDefaults, [Json? toolConfig]) {
  final base = nodeDefaults[type];
  if (base == null) return null;
  final Json merged;
  if (type != 'trigger-plugin' || toolConfig == null) {
    merged = {...base, ...?toolConfig};
  } else {
    final trigger = getTriggerPluginNodeData(toolConfig, fallbackTitle: base['title'], fallbackDesc: base['desc']);
    merged = {
      ...base,
      ...trigger,
      'config': {...?(base['config'] as Map?)?.cast<String, Object?>(), ...trigger['config']! as Map<String, Object?>},
    };
  }
  return {...merged, 'type': type, 'selected': true};
}

// ---- host ----------------------------------------------------------------------------------------------------------

/// What the placeholder panel needs from the host. [onSelectStartBlock] replaces node `nodeId` in place (same id)
/// with [data] (its `type` and fields), deselects the other nodes, sets `hasSelectedStartNode` and
/// `shouldAutoOpenStartNodeSelector`, syncs the draft and then generates the webhook URL (Dify's
/// handleSelectStartNode); the document has no op that changes a node's type, so the host does it.
class StartPlaceholderHost extends InheritedWidget {
  const StartPlaceholderHost({
    super.key,
    required super.child,
    this.onSelectStartBlock,
    this.nodeDefaults,
    this.enableMarketplace = false,
    this.onOpenUrl,
  });

  final void Function(String nodeId, String type, Json data)? onSelectStartBlock;

  /// `availableNodesMetaData.nodesMap[type].defaultValue`; [startBlockDefaults] when null.
  final Map<String, Json>? nodeDefaults;

  /// `systemFeatures.enable_marketplace`: the "Browse more in Marketplace" footer.
  final bool enableMarketplace;

  /// Opens a link (the community request, the marketplace).
  final ValueChanged<String>? onOpenUrl;

  static StartPlaceholderHost? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<StartPlaceholderHost>();

  @override
  bool updateShouldNotify(StartPlaceholderHost old) =>
      onSelectStartBlock != old.onSelectStartBlock ||
      nodeDefaults != old.nodeDefaults ||
      enableMarketplace != old.enableMarketplace ||
      onOpenUrl != old.onOpenUrl;
}

/// The marketplace's trigger category page (`getMarketplaceCategoryUrl(trigger)`).
const marketplaceTriggerUrl = 'https://marketplace.dify.ai/?category=trigger';
const _requestUrl = 'https://github.com/langgenius/dify-plugins/issues/new?template=plugin_request.yaml';

// ---- panel ---------------------------------------------------------------------------------------------------------

/// The `start-placeholder` body.
Widget startPlaceholderPanelBody(BuildContext context, NodePanelProps props) => StartPlaceholderPanel(props: props);

class StartPlaceholderPanel extends StatefulWidget {
  const StartPlaceholderPanel({super.key, required this.props});
  final NodePanelProps props;

  @override
  State<StartPlaceholderPanel> createState() => _StartPlaceholderPanelState();
}

class _StartPlaceholderPanelState extends State<StartPlaceholderPanel> {
  String _search = '';
  final _focus = FocusNode(debugLabel: 'searchTrigger');

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _select(String type, [Json? toolConfig]) {
    final host = StartPlaceholderHost.maybeOf(context);
    final data = startNodeDataOf(type, host?.nodeDefaults ?? startBlockDefaults(), toolConfig);
    if (data == null) return;
    host?.onSelectStartBlock?.call(widget.props.id, type, data);
  }

  @override
  Widget build(BuildContext context) {
    final props = widget.props;
    final host = StartPlaceholderHost.maybeOf(context);
    final placeholder = _wf('tabs.searchTrigger');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: DifyInput(
            value: _search,
            onChanged: (v) => setState(() => _search = v),
            placeholder: placeholder,
            semanticLabel: placeholder,
            focusNode: _focus,
            leading: Padding(
              padding: EdgeInsets.only(left: 8, right: 4),
              child: RemixIcon('search-line', size: 16, color: DifyColors.componentsInputTextPlaceholder),
            ),
            trailing: _search.isEmpty
                ? null
                : Padding(
                    padding: const EdgeInsets.only(left: 2, right: 8),
                    child: DifyIconButton(
                      label: DifyI18n.tr('common', 'operation.clear'),
                      size: DifyIconButtonSize.xs,
                      onPressed: () {
                        setState(() => _search = '');
                        _focus.requestFocus();
                      },
                      icon: RemixIcon('close-circle-fill', size: 14, color: DifyColors.textQuaternary),
                    ),
                  ),
          ),
        ),
        AllStartBlocks(
          searchText: _search,
          onSelect: _select,
          hasStartNode: props.controller.doc.nodes.values.any((n) => n.type == 'start'),
          triggerProviders: TriggerPluginHost.maybeOf(context)?.providers ?? const [],
          enableMarketplace: host?.enableMarketplace ?? false,
          onOpenUrl: host?.onOpenUrl,
          allowUserInputSelection: true,
        ),
      ],
    );
  }
}

/// `START_BLOCKS` (block-selector/constants.tsx).
const startBlocks = [
  (type: 'start', title: 'User Input'),
  (type: 'trigger-schedule', title: 'Schedule Trigger'),
  (type: 'trigger-webhook', title: 'Webhook Trigger'),
];

/// AllStartBlocks, panel variant: the start blocks, the installed trigger plugins (a divider between), "No triggers
/// were found" for a search with no match, and the marketplace footer. [hasUserInputNode] shows the conflict banner
/// and disables everything (the placeholder panel never passes it).
class AllStartBlocks extends StatelessWidget {
  const AllStartBlocks({
    super.key,
    required this.searchText,
    required this.onSelect,
    this.availableBlocksTypes = const ['start', 'trigger-schedule', 'trigger-webhook', 'trigger-plugin'],
    this.triggerProviders = const [],
    this.allowUserInputSelection = false,
    this.hasUserInputNode = false,
    this.hasTriggerNode = false,
    this.hasStartNode = false,
    this.enableMarketplace = false,
    this.onOpenUrl,
  });

  final String searchText;
  final void Function(String type, [Json? trigger]) onSelect;
  final List<String> availableBlocksTypes;
  final List<Json> triggerProviders;
  final bool allowUserInputSelection, hasUserInputNode, hasTriggerNode;

  /// A Start node is on the canvas (StartBlocks then hides User Input).
  final bool hasStartNode;
  final bool enableMarketplace;
  final ValueChanged<String>? onOpenUrl;

  /// StartBlocks' `filteredBlocks`.
  List<({String type, String title})> filteredStartBlocks() {
    final search = searchText.trim().toLowerCase();
    final hideUserInput = !allowUserInputSelection && !hasTriggerNode;
    final showUserInputAdded = hasUserInputNode;
    final showUserInputDisabled = hasTriggerNode && !hasUserInputNode;
    String displayName(String type) => type == 'trigger-webhook' ? _wf('customWebhook') : _wf('blocks.$type');
    return [
      for (final b in startBlocks)
        if (!(b.type == 'start' && (hasStartNode || hideUserInput) && !showUserInputAdded && !showUserInputDisabled) &&
            (displayName(b.type).toLowerCase().contains(search) || b.title.toLowerCase().contains(search)) &&
            availableBlocksTypes.contains(b.type))
          b,
    ];
  }

  /// TriggerPluginList's `triggerPlugins`: providers with events; with a search, those whose label or name matches,
  /// else only their matching events.
  List<Json> filteredTriggerPlugins(String language) {
    final search = searchText.trim().toLowerCase();
    String localized(Object? text) {
      if (text is! Map) return '';
      final own = text[language] ?? text['en-US'];
      if (own is String && own.isNotEmpty) return own;
      return text.values.whereType<String>().where((v) => v.isNotEmpty).firstOrNull ?? '';
    }

    bool matches(Object? name, Object? label) {
      final texts = [localized(label), if (name is String) name].where((s) => s.isNotEmpty).toList();
      return (texts.isEmpty ? [''] : texts).any((t) => t.toLowerCase().contains(search));
    }

    final withEvents = triggerProviders.where((p) => jsList(p['events']).isNotEmpty);
    if (search.isEmpty) return withEvents.toList();
    return [
      for (final p in withEvents)
        if (matches(p['name'], p['label']))
          p
        else if (jsList(p['events']).where((e) => matches(jsGet(e, 'name'), jsGet(e, 'label'))).toList()
            case final events when events.isNotEmpty)
          {...p, 'events': events},
    ];
  }

  @override
  Widget build(BuildContext context) {
    final language = uiLanguage();
    final enableTriggerPlugin = availableBlocksTypes.contains('trigger-plugin');
    final blocks = filteredStartBlocks();
    final plugins = enableTriggerPlugin ? filteredTriggerPlugins(language) : const <Json>[];
    final hasFilter = searchText.trim().isNotEmpty;
    final shouldShowFeatured = enableTriggerPlugin && enableMarketplace && !hasFilter;
    final hasAnyContent = blocks.isNotEmpty || plugins.isNotEmpty || shouldShowFeatured;
    final showEmpty = hasFilter && !hasAnyContent;
    final disabled = hasUserInputNode;

    Widget list = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (blocks.isNotEmpty)
          Padding(
            padding: const EdgeInsets.all(4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final b in blocks)
                  _StartBlockRow(
                    type: b.type,
                    disabled:
                        disabled || (b.type == 'start' && (hasUserInputNode || (hasTriggerNode && !hasUserInputNode))),
                    added: b.type == 'start' && hasUserInputNode,
                    conflict: b.type == 'start' && hasTriggerNode && !hasUserInputNode,
                    onTap: () => onSelect(b.type),
                  ),
              ],
            ),
          ),
        if (blocks.isNotEmpty && plugins.isNotEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: DifyDivider(),
          ),
        if (plugins.isNotEmpty)
          Padding(
            padding: const EdgeInsets.all(4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final p in plugins)
                  _TriggerPluginItem(
                    key: ValueKey(p['id'] ?? p['name']),
                    payload: p,
                    language: language,
                    hasSearchText: hasFilter,
                    disabled: disabled,
                    onSelect: onSelect,
                  ),
              ],
            ),
          ),
      ],
    );
    if (disabled) list = IgnorePointer(child: Opacity(opacity: 0.3, child: list));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 48),
            child: Column(
              spacing: 12,
              children: [
                DifyIcon('vender/line/others/search-menu', size: 32, color: DifyColors.textQuaternary),
                Text(
                  _wf('nodes.startPlaceholder.noTriggersFound'),
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: DifyColors.textSecondary),
                ),
                DifyPressable(
                  semanticLabel: _wf('tabs.requestToCommunity'),
                  onPressed: () => onOpenUrl?.call(_requestUrl),
                  builder: (context, hovered, focused) => Container(
                    height: 24,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: hovered ? DifyColors.stateBaseHover : null,
                      borderRadius: BorderRadius.circular(DifyRadius.md),
                    ),
                    child: Text(
                      _wf('tabs.requestToCommunity'),
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: DifyColors.textAccent),
                    ),
                  ),
                ),
              ],
            ),
          )
        else ...[
          if (hasUserInputNode) const _ConflictBanner(),
          list,
        ],
        if (enableMarketplace)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 8,
              children: [
                const SizedBox(width: 32, height: 8, child: Center(child: DifyDivider())),
                DifyPressable(
                  semanticLabel: _wf('nodes.startPlaceholder.browseMoreOnMarketplace'),
                  onPressed: () => onOpenUrl?.call(marketplaceTriggerUrl),
                  builder: (context, hovered, focused) {
                    final color = hovered ? DifyColors.textSecondary : DifyColors.textTertiary;
                    return Row(
                      mainAxisSize: MainAxisSize.min,
                      spacing: 4,
                      children: [
                        DifyIcon('vender/workflow/marketplace', size: 12, color: color),
                        DifyText(
                          _wf('nodes.startPlaceholder.browseMoreOnMarketplace'),
                          DifyType.systemXsRegular,
                          color: color,
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// The "User Input cannot be combined with other triggers" banner.
class _ConflictBanner extends StatelessWidget {
  const _ConflictBanner();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(
      color: DifyColors.componentsPanelBgBlur,
      gradient: LinearGradient(
        colors: [
          DifyColors.utilColorsBlueLightBlueLight500.withValues(alpha: 0.2 * 0.4),
          const Color(0x00000000),
        ],
      ),
      border: Border(bottom: BorderSide(color: DifyColors.dividerSubtle, width: 0.5)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 2,
      children: [
        Padding(
          padding: EdgeInsets.all(4),
          child: RemixIcon('information-fill', size: 16, color: DifyColors.textAccent),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: DifyText(
              _wf('nodes.startPlaceholder.userInputConflictTip'),
              DifyType.systemXsRegular,
              color: DifyColors.textSecondary,
              maxLines: null,
            ),
          ),
        ),
      ],
    ),
  );
}

/// BlockSelectorRow: `flex h-8 w-full items-center rounded-lg pr-2 pl-3`, hover `bg-state-base-hover`.
class _Row extends StatelessWidget {
  const _Row({required this.label, required this.child, this.onTap, this.disabled = false});
  final String label;
  final Widget child;
  final VoidCallback? onTap;
  final bool disabled;

  @override
  Widget build(BuildContext context) => DifyPressable(
    semanticLabel: label,
    disabled: disabled,
    onPressed: onTap,
    builder: (context, hovered, focused) => Container(
      height: 32,
      padding: const EdgeInsets.only(left: 12, right: 8),
      decoration: BoxDecoration(
        color: hovered && !disabled ? DifyColors.stateBaseHover : null,
        borderRadius: BorderRadius.circular(DifyRadius.lg),
      ),
      child: child,
    ),
  );
}

/// A start block row: its icon, label and (User Input) "Most common" or "Added"; a User Input row disabled by a
/// trigger shows the conflict tip.
class _StartBlockRow extends StatelessWidget {
  const _StartBlockRow({
    required this.type,
    required this.onTap,
    this.disabled = false,
    this.added = false,
    this.conflict = false,
  });
  final String type;
  final VoidCallback onTap;
  final bool disabled, added, conflict;

  @override
  Widget build(BuildContext context) {
    final label = _wf('blocks.$type');
    final reason = _wf('nodes.startPlaceholder.userInputConflictTip');
    Widget content = Row(
      children: [
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: SmallBlockIcon(type: type),
        ),
        Expanded(child: DifyText(label, DifyType.systemSmMedium, color: DifyColors.textSecondary)),
        if (type == 'start' && added)
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: DifyText(
              DifyI18n.tr('common', 'operation.added'),
              DifyType.systemXsRegular,
              color: DifyColors.textTertiary,
            ),
          )
        else if (type == 'start')
          Container(
            margin: const EdgeInsets.only(left: 8),
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            decoration: BoxDecoration(
              border: Border.all(color: DifyColors.dividerDeep),
              borderRadius: BorderRadius.circular(5),
            ),
            child: DifyText(
              _wf('blocks.mostCommon'),
              DifyType.system2xsMediumUppercase,
              color: DifyColors.textTertiary,
            ),
          ),
      ],
    );
    if (conflict) content = Opacity(opacity: 0.3, child: content);
    final row = _Row(label: conflict ? '$label. $reason' : label, disabled: disabled, onTap: onTap, child: content);
    if (!conflict) return row;
    return DifyTooltip(content: Text(reason), child: row);
  }
}

/// TriggerPluginItem: the provider row (label, group, chevron) folding its events (open while searching); each
/// event row picks the trigger with its `TriggerDefaultValue`.
class _TriggerPluginItem extends StatefulWidget {
  const _TriggerPluginItem({
    super.key,
    required this.payload,
    required this.language,
    required this.hasSearchText,
    required this.onSelect,
    this.disabled = false,
  });
  final Json payload;
  final String language;
  final bool hasSearchText, disabled;
  final void Function(String type, [Json? trigger]) onSelect;

  @override
  State<_TriggerPluginItem> createState() => _TriggerPluginItemState();
}

class _TriggerPluginItemState extends State<_TriggerPluginItem> {
  late bool _fold = !widget.hasSearchText;

  @override
  void didUpdateWidget(_TriggerPluginItem old) {
    super.didUpdateWidget(old);
    if (old.hasSearchText != widget.hasSearchText) _fold = !widget.hasSearchText;
  }

  /// The `TriggerDefaultValue` of [event].
  Json _defaultValue(Json event) {
    final p = widget.payload;
    final lang = widget.language;
    return {
      'plugin_id': p['plugin_id'],
      'provider_id': p['name'],
      'provider_type': p['type'],
      'provider_name': p['name'],
      'event_name': event['name'],
      'event_label': jsGet(event['label'], lang),
      'event_description': jsGet(event['description'], lang),
      'title': jsGet(event['label'], lang),
      'plugin_unique_identifier': p['plugin_unique_identifier'],
      'is_team_authorization': p['is_team_authorization'],
      'output_schema': event['output_schema'] ?? <String, Object?>{},
      'paramSchemas': event['parameters'],
      'params': {for (final i in jsList(event['parameters'])) '${jsGet(i, 'name')}': ''},
      if (p['meta'] != null) 'meta': p['meta'],
    };
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.payload;
    final lang = widget.language;
    final events = [
      for (final e in jsList(p['events']))
        if (e is Map) e.cast<String, Object?>(),
    ];
    final notShowProvider = p['type'] == 'workflow';
    final hasAction = !notShowProvider;
    final groupName = switch (p['type']) {
      'builtin' => '${p['author'] ?? ''}',
      'api' => _wf('tabs.customTool'),
      'workflow' => _wf('tabs.workflowTool'),
      _ => '${p['author'] ?? ''}',
    };
    final label = notShowProvider && events.isNotEmpty
        ? labelOf(events.first['label'], lang)
        : labelOf(p['label'], lang);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Row(
            label: label,
            disabled: widget.disabled,
            onTap: () {
              if (hasAction) {
                setState(() => _fold = !_fold);
              } else if (events.isNotEmpty) {
                widget.onSelect('trigger-plugin', _defaultValue(events.first)..remove('meta'));
              }
            },
            child: Row(
              children: [
                const Padding(
                  padding: EdgeInsets.only(right: 8),
                  child: SmallBlockIcon(type: 'trigger-plugin'),
                ),
                Flexible(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 200),
                    child: DifyText(label, DifyType.systemSmRegular, color: DifyColors.textPrimary),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(child: DifyText(groupName, DifyType.systemXsRegular, color: DifyColors.textQuaternary)),
                if (hasAction)
                  RemixIcon(
                    _fold ? 'arrow-right-s-line' : 'arrow-down-s-line',
                    size: 16,
                    color: _fold ? DifyColors.textQuaternary : DifyColors.textTertiary,
                  ),
              ],
            ),
          ),
          if (hasAction && !_fold)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 240),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final e in events)
                      DifyPressable(
                        semanticLabel: labelOf(e['label'], lang),
                        disabled: widget.disabled,
                        onPressed: () => widget.onSelect('trigger-plugin', _defaultValue(e)),
                        builder: (context, hovered, focused) => Container(
                          padding: const EdgeInsets.only(left: 21, right: 4),
                          decoration: BoxDecoration(
                            color: hovered && !widget.disabled ? DifyColors.stateBaseHover : null,
                            borderRadius: BorderRadius.circular(DifyRadius.lg),
                          ),
                          child: Container(
                            padding: const EdgeInsets.only(left: 16, top: 8, bottom: 8),
                            decoration: BoxDecoration(
                              border: Border(left: BorderSide(color: DifyColors.dividerSubtle, width: 2)),
                            ),
                            child: Opacity(
                              opacity: widget.disabled ? 0.3 : 1,
                              child: DifyText(
                                labelOf(e['label'], lang),
                                DifyType.systemSmMedium,
                                color: DifyColors.textSecondary,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
