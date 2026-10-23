/// The panel body of the classic Agent (nodes/agent/panel.tsx with _base/components/agent-strategy.tsx,
/// agent-strategy-selector.tsx, the branches of model-modal/Form.tsx agent strategies use, and
/// plugin-detail-panel/tool-selector/** and multiple-tool-selector/**).
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../../../design/dify_icon.dart';
import '../../../../design/dify_tokens.g.dart';
import '../../../../design/widgets/widgets.dart';
import '../../../../i18n/dify_i18n.dart';
import '../../../../workflow/dify_json.dart';
import '../../../../workflow/model_catalog.dart';
import '../../../panel_fields/panel_fields.dart';
import '../../../prompt_editor/prompt_editor_panel.dart';
import '../../../store/store.dart';
import '../../node_panel_bodies.dart';
import 'agent_model.dart';
import 'group_host.dart';
import 'llm_config.dart' show jsonClone;
import 'llm_panel.dart' show promptEditorEnvOf;
import 'model_parameter_modal.dart';
import '../../panel_edit.dart';
import 'llm_vars.dart';
import 'tool_picker.dart';

String _w(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('workflow', key, params);
String _p(String key) => DifyI18n.tr('plugin', key);

/// The text of an I18n object (or a plain string) in [language].
String _i18n(Object? v, String language) =>
    v is Map ? renderI18nObject({for (final e in v.entries) '${e.key}': e.value?.toString()}, language) : '${v ?? ''}';

/// The panel body of the classic Agent (nodes/agent/panel.tsx).
Widget agentPanelBody(BuildContext context, NodePanelProps props) =>
    AgentPanel(key: ValueKey('agent-${props.id}'), props: props);

/// The classic Agent's panel: the strategy field (selector and the strategy's parameters), memory for strategies with
/// history in a chatflow, and the output variables.
class AgentPanel extends StatefulWidget {
  const AgentPanel({super.key, required this.props});
  final NodePanelProps props;

  @override
  State<AgentPanel> createState() => _AgentPanelState();
}

class _AgentPanelState extends State<AgentPanel> {
  /// The strategy provider detail by provider name (useStrategyProviderDetail): null while loading, an error marker
  /// when it failed.
  final _details = <String, ({Json? detail, bool error})>{};
  final _loading = <String>{};
  String? _migratedFor;

  NodePanelProps get props => widget.props;

  /// The provider detail of [providerName]: the services' loader, else the strategy providers' entry.
  ({Json? detail, bool error, bool loading}) _detail(LlmGroupServices s, String providerName) {
    if (providerName.isEmpty) return (detail: null, error: false, loading: false);
    final known = _details[providerName];
    if (known != null) return (detail: known.detail, error: known.error, loading: false);
    final fetch = s.fetchStrategy;
    if (fetch == null) {
      final list = s.strategyProviders;
      if (list == null) return (detail: null, error: false, loading: true);
      final hit = list
          .where(
            (p) => p['provider'] == providerName || jsGet(jsGet(p['declaration'], 'identity'), 'name') == providerName,
          )
          .firstOrNull;
      return (detail: hit, error: hit == null, loading: false);
    }
    if (_loading.add(providerName)) {
      fetch(providerName).then(
        (d) {
          if (mounted) setState(() => _details[providerName] = (detail: d, error: d == null));
        },
        onError: (Object _) {
          if (mounted) setState(() => _details[providerName] = (detail: null, error: true));
        },
      );
    }
    return (detail: null, error: false, loading: true);
  }

  void _refetch(String providerName) => setState(() {
    _details.remove(providerName);
    _loading.remove(providerName);
  });

  @override
  Widget build(BuildContext context) {
    final s = LlmGroupScope.of(context);
    final inputs = props.data;
    final readOnly = props.readOnly;
    final ref = agentStrategyOf(inputs);
    final info = _detail(s, ref?.providerName ?? '');
    final strategy = findStrategy(info.detail, ref?.strategyName);
    final status = ref == null
        ? null
        : strategyStatusOf(loading: info.loading, isError: info.error, strategy: strategy);

    // formatting legacy data, once the strategy is known.
    final key = strategy == null ? null : '${ref?.providerName}/${ref?.strategyName}';
    if (key != null && key != _migratedFor && !readOnly) {
      _migratedFor = key;
      final next = formattingLegacyData(inputs, strategy);
      if (!identical(next, inputs)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setInputs(props, next);
        });
      }
    }

    final vars = NodeVars.of(props);
    final schemas = [for (final p in jsList(strategy?['parameters'])) strategyParamToCredentialForm(jsMap(p))];
    final features = jsList(strategy?['features']);
    final outputs = agentOutputSchema(inputs);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Field(
              title: _w('nodes.agent.strategy.label'),
              required: true,
              tooltip: _w('nodes.agent.strategy.tooltip'),
              child: AgentStrategy(
                strategy: ref,
                status: status,
                onRefetch: ref == null ? null : () => _refetch(ref.providerName),
                readOnly: readOnly,
                isMcpSupported: isSupportMCP(jsStr(jsGet(inputs['meta'], 'version'))),
                onStrategyChange: (next) {
                  setInputs(props, withAgentStrategy(props.data, next));
                  final store = WorkflowStoreScope.of(context);
                  store.setControlPromptEditorRerenderKey(DateTime.now().millisecondsSinceEpoch);
                },
                formSchemas: schemas,
                formValue: agentFormData(inputs, strategy),
                onFormValueChange: (value) => setInputs(props, {
                  ...props.data,
                  'agent_parameters': agentParametersOf(value, strategy),
                }),
                vars: vars,
                props: props,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: props.chatMode && features.contains(agentFeatureHistoryMessages)
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const PanelSplit(),
                      Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: MemoryConfig(
                          memory: inputs['memory'] is Map ? jsMap(inputs['memory']) : null,
                          readonly: readOnly,
                          onChange: (m) => setInputs(props, {...props.data, 'memory': m}),
                        ),
                      ),
                    ],
                  )
                : const SizedBox.shrink(),
          ),
          OutputVars(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                VarItem(name: 'text', type: 'String', description: _w('nodes.agent.outputVars.text')),
                VarItem(name: 'usage', type: 'object', description: _w('nodes.agent.outputVars.usage')),
                VarItem(name: 'files', type: 'Array[File]', description: _w('nodes.agent.outputVars.files.title')),
                VarItem(name: 'json', type: 'Array[Object]', description: _w('nodes.agent.outputVars.json')),
                for (final o in outputs) VarItem(name: o.name, type: o.type, description: o.description),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---- agent-strategy.tsx ------------------------------------------------------------------------------------------

/// AgentStrategy: the selector, then the strategy's parameter form, or the "Please configure agentic strategy."
/// empty state.
class AgentStrategy extends StatelessWidget {
  const AgentStrategy({
    super.key,
    required this.strategy,
    required this.onStrategyChange,
    required this.formSchemas,
    required this.formValue,
    required this.onFormValueChange,
    required this.vars,
    required this.props,
    this.status,
    this.onRefetch,
    this.readOnly = false,
    this.isMcpSupported = false,
  });

  final AgentStrategyRef? strategy;
  final AgentStrategyStatus? status;
  final VoidCallback? onRefetch;
  final ValueChanged<AgentStrategyRef> onStrategyChange;
  final List<Json> formSchemas;
  final Json formValue;
  final ValueChanged<Json> onFormValueChange;
  final NodeVars vars;
  final NodePanelProps props;
  final bool readOnly, isMcpSupported;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    spacing: 8,
    children: [
      AgentStrategySelector(value: strategy, status: status, onChange: onStrategyChange, disabled: readOnly),
      if (strategy != null)
        AgentStrategyForm(
          schemas: formSchemas,
          value: formValue,
          onChange: onFormValueChange,
          vars: vars,
          props: props,
          readOnly: readOnly,
          isMcpSupported: isMcpSupported,
        )
      else
        _ListEmpty(
          title: _w('nodes.agent.strategy.configureTip'),
          description: _w('nodes.agent.strategy.configureTipDesc'),
          linkText: _w('nodes.agent.learnMore'),
          onLink: () => props.actions.options.openUrl?.call(
            agentDocLink(props.actions.options.docsProduct),
          ),
        ),
    ],
  );
}

/// The docs page of the agent node (`docLink('/use-dify/nodes/agent')`).
String agentDocLink(String product) => 'https://docs.dify.ai/en/$product/use-dify/nodes/agent';

/// ListEmpty (base/list-empty): `rounded-[10px] bg-workflow-process-bg p-4` with the Agent icon tile, the title and
/// the description with its link.
class _ListEmpty extends StatelessWidget {
  const _ListEmpty({required this.title, required this.description, required this.linkText, required this.onLink});
  final String title, description, linkText;
  final VoidCallback onLink;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      gradient: DifyGradients.workflowProcessBg,
      borderRadius: BorderRadius.circular(10),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 8,
      children: [
        Container(
          width: 40,
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: DifyColors.componentsCardBg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: DifyColors.componentsCardBorder, width: 0.5),
            boxShadow: DifyShadows.lg,
          ),
          child: DifyIcon('vender/workflow/agent', size: 20, color: DifyColors.textAccent),
        ),
        DifyText(title, DifyType.systemMdMedium, color: DifyColors.textSecondary, maxLines: null),
        DifyTextLine.rich(
          TextSpan(
            text: '$description\n',
            children: [
              WidgetSpan(
                child: DifyPressable(
                  semanticLabel: linkText,
                  onPressed: onLink,
                  builder: (context, hovered, focused) => DifyTextLine(
                    linkText,
                    style: difyStyle(DifyType.systemXsRegular, DifyColors.textAccentSecondary),
                  ),
                ),
              ),
            ],
          ),
          style: difyStyle(DifyType.systemXsRegular, DifyColors.textTertiary),
        ),
      ],
    ),
  );
}

// ---- agent-strategy-selector.tsx ---------------------------------------------------------------------------------

/// AgentStrategySelector: the `h-8 rounded-lg bg-components-input-bg-normal p-1` trigger (provider icon, the
/// strategy label or "Select agentic strategy", a chevron or the not-installed / unsupported warning) opening a
/// `w-97` popover with the search and the strategy providers' strategies.
class AgentStrategySelector extends StatefulWidget {
  const AgentStrategySelector({super.key, this.value, this.status, required this.onChange, this.disabled = false});
  final AgentStrategyRef? value;
  final AgentStrategyStatus? status;
  final ValueChanged<AgentStrategyRef> onChange;
  final bool disabled;

  @override
  State<AgentStrategySelector> createState() => _AgentStrategySelectorState();
}

class _AgentStrategySelectorState extends State<AgentStrategySelector> {
  final _popup = DifyFloatingController();
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final s = LlmGroupScope.of(context);
    final language = s.models.language;
    final value = widget.value, status = widget.status;
    final list = formatStrategies(s.strategyProviders ?? const []);
    final icon = list
        .where((p) => p.tools.any((t) => jsGet(t['identity'], 'name') == value?.strategyName))
        .firstOrNull
        ?.icon;
    final notInstalled = status?.source == 'external' && !status!.installed && value != null;
    final unsupported = status?.source == 'external' && !status!.isExistInPlugin && value != null;
    return DifyFloating(
      controller: _popup,
      placement: DifyPlacement.bottom,
      builder: (context, c) => DifyPressable(
        semanticLabel: value?.label.isNotEmpty == true ? value!.label : _w('nodes.agent.strategy.selectTip'),
        disabled: widget.disabled,
        onPressed: c.toggle,
        builder: (context, hovered, focused) => Container(
          height: 32,
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: hovered ? DifyColors.stateBaseHoverAlt : DifyColors.componentsInputBgNormal,
            borderRadius: BorderRadius.circular(DifyRadius.lg),
          ),
          child: Row(
            spacing: 2,
            children: [
              if (icon != null) SizedBox(width: 24, height: 24, child: Center(child: _ProviderIcon(icon, size: 20))),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: DifyText(
                    value?.label.isNotEmpty == true ? value!.label : _w('nodes.agent.strategy.selectTip'),
                    DifyType.systemXsRegular,
                    color: value != null
                        ? DifyColors.componentsInputTextFilled
                        : DifyColors.componentsInputTextPlaceholder,
                  ),
                ),
              ),
              if (notInstalled)
                _NotFoundWarn(
                  title: _w('nodes.agent.pluginNotInstalled'),
                  description: _w('nodes.agent.pluginNotInstalledDesc'),
                )
              else if (unsupported)
                _NotFoundWarn(
                  title: _w('nodes.agent.unsupportedStrategy'),
                  description: _w('nodes.agent.strategyNotFoundDesc'),
                )
              else
                RemixIcon('arrow-down-s-line', size: 16, color: DifyColors.textTertiary),
            ],
          ),
        ),
      ),
      popupBuilder: (context) => StatefulBuilder(
        builder: (context, setLocal) {
          final q = _query.toLowerCase();
          final filtered = [
            for (final p in list)
              if (p.name.toLowerCase().contains(q)) p,
          ];
          return Container(
            width: 388,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: DifyColors.componentsPanelBgBlur,
              borderRadius: BorderRadius.circular(DifyRadius.md),
              border: Border.all(color: DifyColors.componentsPanelBorder, width: 0.5),
              boxShadow: DifyShadows.md,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: DifyInput(
                    value: _query,
                    semanticLabel: _w('nodes.agent.strategy.searchPlaceholder'),
                    placeholder: _w('nodes.agent.strategy.searchPlaceholder'),
                    leading: RemixIcon('search-line', size: 16, color: DifyColors.componentsInputTextPlaceholder),
                    onChanged: (v) => setLocal(() => _query = v),
                  ),
                ),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 400),
                  child: ListView(
                    shrinkWrap: true,
                    padding: const EdgeInsets.only(bottom: 4),
                    children: [
                      for (final p in filtered) ...[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
                          child: Row(
                            spacing: 6,
                            children: [
                              if (p.icon != null) _ProviderIcon(p.icon, size: 16),
                              Expanded(
                                child: DifyText(
                                  _i18n(p.label, language).isEmpty ? p.name : _i18n(p.label, language),
                                  DifyType.systemXsMedium,
                                  color: DifyColors.textTertiary,
                                ),
                              ),
                            ],
                          ),
                        ),
                        for (final t in p.tools)
                          _StrategyRow(
                            label: _i18n(jsGet(t['identity'], 'label'), language),
                            selected:
                                value?.providerName == p.name && value?.strategyName == jsGet(t['identity'], 'name'),
                            onTap: () {
                              widget.onChange(strategyRefOf(p, t, language));
                              _popup.close();
                            },
                          ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _StrategyRow extends StatelessWidget {
  const _StrategyRow({required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => DifyPressable(
    semanticLabel: label,
    onPressed: onTap,
    builder: (context, hovered, focused) => Container(
      height: 32,
      margin: const EdgeInsets.symmetric(horizontal: 4),
      padding: const EdgeInsets.only(left: 21, right: 8),
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        color: hovered ? DifyColors.stateBaseHover : null,
        borderRadius: BorderRadius.circular(DifyRadius.lg),
      ),
      child: Row(
        children: [
          Expanded(child: DifyText(label, DifyType.systemSmMedium, color: DifyColors.textSecondary)),
          if (selected) RemixIcon('check-line', size: 16, color: DifyColors.textAccent),
        ],
      ),
    ),
  );
}

/// NotFoundWarn: `i-ri-error-warning-fill` with a tooltip (title, description, "Link to Integrations").
class _NotFoundWarn extends StatelessWidget {
  const _NotFoundWarn({required this.title, required this.description});
  final String title, description;

  @override
  Widget build(BuildContext context) => DifyTooltip(
    content: SizedBox(
      width: 180,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        spacing: 4,
        children: [
          DifyText(title, DifyType.systemXsSemibold, color: DifyColors.textPrimary, maxLines: null),
          DifyText(description, DifyType.systemXsRegular, color: DifyColors.textSecondary, maxLines: null),
          DifyText(_w('nodes.agent.linkToPlugin'), DifyType.systemXsRegular, color: DifyColors.textAccent),
        ],
      ),
    ),
    child: Semantics(
      label: title,
      child: RemixIcon('error-warning-fill', size: 16, color: DifyColors.textDestructive),
    ),
  );
}

/// A provider icon: an image URL, an emoji `{content, background}`, else the blank tile.
class _ProviderIcon extends StatelessWidget {
  const _ProviderIcon(this.icon, {this.size = 20});
  final Object? icon;
  final double size;

  @override
  Widget build(BuildContext context) {
    final i = icon;
    Widget child;
    if (i is String && (i.startsWith('http://') || i.startsWith('https://') || i.startsWith('/'))) {
      child = Image.network(
        i,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => const SizedBox(),
      );
    } else if (i is Map) {
      child = Container(
        color: _hex(jsStr(i['background'])) ?? DifyColors.stateBaseHover,
        alignment: Alignment.center,
        child: DifyTextLine('${i['content'] ?? ''}', style: difyEmojiTextStyle(size * 0.6)),
      );
    } else {
      child = ColoredBox(color: DifyColors.stateBaseHover);
    }
    return Container(
      width: size,
      height: size,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: DifyColors.backgroundDefaultDodge,
        borderRadius: BorderRadius.circular(DifyRadius.md),
        border: Border.all(color: DifyColors.componentsPanelBorderSubtle, width: 0.5),
      ),
      child: child,
    );
  }
}

Color? _hex(String? s) {
  if (s == null || !s.startsWith('#')) return null;
  final v = int.tryParse(s.substring(1), radix: 16);
  if (v == null) return null;
  return Color(s.length == 7 ? 0xFF000000 | v : v);
}

// ---- model-modal/Form.tsx (agent strategy parameters) ------------------------------------------------------------

/// The strategy parameter form (Form.tsx with agent-strategy.tsx's overrides): one item per schema, its label row
/// (`py-2 system-sm-semibold uppercase` + `*` + infotip) over the control, `py-3` apart.
class AgentStrategyForm extends StatelessWidget {
  const AgentStrategyForm({
    super.key,
    required this.schemas,
    required this.value,
    required this.onChange,
    required this.vars,
    required this.props,
    this.readOnly = false,
    this.isMcpSupported = false,
  });

  final List<Json> schemas;
  final Json value;
  final ValueChanged<Json> onChange;
  final NodeVars vars;
  final NodePanelProps props;
  final bool readOnly, isMcpSupported;

  void _set(String key, Object? v) => onChange({...value, key: v});

  Widget _label(BuildContext context, Json schema, String language) {
    final tip = _i18n(schema['tooltip'], language);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Flexible(
            child: DifyText(
              _i18n(schema['label'], language).toUpperCase(),
              DifyType.systemSmSemibold,
              color: DifyColors.textSecondary,
            ),
          ),
          if (schema['required'] == true)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: DifyTextLine('*', style: difyStyle(DifyType.systemSmSemibold, DifyColors.textDestructive)),
            ),
          if (tip.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: DifyInfotip(label: tip, width: 200, content: DifyTextLine(tip)),
            ),
        ],
      ),
    );
  }

  Widget? _field(BuildContext context, Json schema, LlmGroupServices s) {
    final language = s.models.language;
    final name = '${schema['variable']}';
    final type = '${schema['type']}';
    final current = value[name];
    Widget item(Widget child, {bool label = true}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [if (label) _label(context, schema, language), child],
      ),
    );
    switch (type) {
      case AgentFormType.textInput:
        final env = promptEditorEnvOf(context, props, vars, filterMemoryPromptVar, s);
        final tip = _i18n(schema['tooltip'], language);
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: DifyPromptEditorPanel(
            key: ValueKey('agent-param-$name'),
            title: DifyTextLine(
              _i18n(schema['label'], language).toUpperCase(),
              style: difyStyle(DifyType.systemSmSemiboldUppercase, DifyColors.textSecondary).copyWith(fontSize: 13),
            ),
            titleTooltip: tip.isEmpty ? null : tip,
            required: schema['required'] == true,
            value: '${current ?? schema['default'] ?? ''}',
            onChange: (v) => _set(name, v),
            readOnly: readOnly,
            gradientBorder: false,
            isSupportJinja: jsGet(schema['template'], 'enabled') == true,
            nodesOutputVars: env.nodesOutputVars,
            availableNodes: env.availableNodes,
            getVarType: env.getVarType,
            onOpenUrl: env.onOpenUrl,
          ),
        );
      case AgentFormType.textNumber:
        final min = schema['min'] is num ? schema['min']! as num : null;
        final max = schema['max'] is num ? schema['max']! as num : null;
        if (min != null && max != null) {
          final def = int.tryParse('${schema['default'] ?? ''}') ?? 1;
          final v = current is num ? current : def;
          final label = _i18n(schema['label'], language);
          final tip = _i18n(schema['tooltip'], language);
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Field(
              title: label,
              required: schema['required'] == true,
              tooltip: tip.isEmpty ? null : tip,
              inline: true,
              child: SizedBox(
                width: 200,
                child: Row(
                  spacing: 12,
                  children: [
                    Expanded(
                      child: DifySlider(
                        value: v.round(),
                        min: min.round(),
                        max: max.round(),
                        semanticLabel: label,
                        disabled: readOnly,
                        onChanged: (n) => _set(name, n),
                      ),
                    ),
                    SizedBox(
                      width: 48,
                      child: DifyNumberField(
                        value: v,
                        min: min,
                        max: max,
                        semanticLabel: label,
                        disabled: readOnly,
                        onChanged: (n) => _set(name, n ?? def),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }
        return item(
          DifyNumberField(
            value: current is num ? current : (num.tryParse('${schema['default'] ?? ''}') ?? 0),
            min: min,
            max: max,
            disabled: readOnly,
            semanticLabel: _i18n(schema['label'], language),
            onChanged: (n) => _set(name, n),
          ),
        );
      case AgentFormType.secretInput:
        return item(
          DifyInput(
            value: '${current ?? ''}',
            placeholder: _i18n(schema['placeholder'], language),
            semanticLabel: _i18n(schema['label'], language),
            readOnly: readOnly,
            onChanged: (v) => _set(name, v),
          ),
        );
      case AgentFormType.checkbox:
        return item(
          _TrueFalse(value: current is bool ? current : null, disabled: readOnly, onChange: (v) => _set(name, v)),
        );
      case AgentFormType.select:
        final options = [
          for (final o in jsList(schema['options']))
            (value: '${jsGet(o, 'value')}', label: _i18n(jsGet(o, 'label'), language)),
        ];
        return item(
          DifySelect<String>(
            value: current is String ? current : null,
            options: options,
            placeholder: _i18n(schema['placeholder'], language),
            readonly: readOnly,
            onChanged: (v) => _set(name, v),
          ),
        );
      case AgentFormType.radio:
        final options = jsList(schema['options']);
        return item(
          Row(
            spacing: 12,
            children: [
              for (final o in options)
                Expanded(
                  child: OptionCard(
                    title: _i18n(jsGet(o, 'label'), language),
                    selected: current == jsGet(o, 'value'),
                    disabled: readOnly,
                    onSelect: () => _set(name, jsGet(o, 'value')),
                  ),
                ),
            ],
          ),
        );
      case AgentFormType.modelSelector:
        final m = jsMap(current);
        final scope = jsStr(schema['scope']);
        return item(
          ModelParameterModal(
            provider: jsStr(m['provider']) ?? '',
            modelId: jsStr(m['model']) ?? '',
            completionParams: jsMap(m['completion_params']),
            readonly: readOnly,
            modelList: s.models.modelList(scope == null || scope.isEmpty ? ModelTypeEnum.textGeneration : scope),
            onModelChange: (c) => _set(name, {
              ...m,
              'provider': c.provider,
              'model': c.modelId,
              'model_type': scope == null || scope.isEmpty ? ModelTypeEnum.textGeneration : scope,
              'mode': ?c.mode,
              'type': AgentFormType.modelSelector,
            }),
            onCompletionParamsChange: (p) =>
                _set(name, {...m, 'completion_params': p, 'type': AgentFormType.modelSelector}),
          ),
        );
      case AgentFormType.toolSelector:
        return item(
          AgentToolSelector(
            value: current is Map ? jsMap(current) : null,
            disabled: readOnly,
            onSelect: (v) => _set(name, v),
            onDelete: () => _set(name, null),
          ),
        );
      case AgentFormType.multiToolSelector:
        return item(
          MultipleToolSelector(
            value: [for (final t in jsList(current)) jsMap(t)],
            label: _i18n(schema['label'], language),
            required: schema['required'] == true,
            tooltip: _i18n(schema['tooltip'], language),
            disabled: readOnly,
            isMcpAllowed: isMcpSupported,
            onChange: (v) => _set(name, v),
          ),
          label: false,
        );
      case AgentFormType.any:
        final scope = jsStr(schema['scope']);
        return item(
          VarReferencePicker(
            value: jsSelector(current),
            scope: vars.scope,
            isShowNodeName: true,
            filterVar: scope == null || scope.isEmpty ? null : (v, _) => scope.split('&').contains(v.type),
            onChange: (sel, _) => _set(name, sel),
          ),
        );
    }
    // app-selector and the types Form has no branch for render nothing.
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final s = LlmGroupScope.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final schema in schemas) ?_field(context, schema, s),
      ],
    );
  }
}

/// The True / False radio group (`flex items-center justify-between gap-3 py-2`).
class _TrueFalse extends StatelessWidget {
  const _TrueFalse({required this.value, required this.onChange, this.disabled = false});
  final bool? value;
  final ValueChanged<bool> onChange;
  final bool disabled;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: DifyRadioGroup<bool>(
      value: value,
      disabled: disabled,
      spacing: 12,
      onValueChange: onChange,
      children: [
        for (final v in const [true, false]) DifyRadio<bool>(value: v, label: v ? 'True' : 'False'),
      ],
    ),
  );
}

// ---- plugin-detail-panel/tool-selector ---------------------------------------------------------------------------

/// The provider name shown on a tool card: the last `/` segment, or the show name for MCP tools.
String _providerShortName(Json value) {
  final show = jsStr(value['provider_show_name']);
  if (value['type'] == ToolCollectionType.mcp && show != null) return show;
  final name = jsStr(value['provider_name']) ?? '';
  return name.split('/').last;
}

/// The store's provider of a tool value (`provider_name` is the provider id).
Json? _providerOf(BuildContext context, Json value) {
  final store = context.getInheritedWidgetOfExactType<WorkflowStoreScope>()?.store;
  final id = value['provider_name'];
  return storeToolProviders(store).where((p) => p['id'] == id || p['name'] == id).firstOrNull;
}

/// ToolSelector (single): "Configure tool" when empty, else the ToolItem card; either opens (left) the "Add tool" /
/// "Tool Settings" popover with the tool picker and the tool description.
class AgentToolSelector extends StatefulWidget {
  const AgentToolSelector({
    super.key,
    required this.value,
    required this.onSelect,
    this.onDelete,
    this.onSelectMultiple,
    this.selected = const {},
    this.disabled = false,
    this.supportEnableSwitch = false,
    this.isMcpAllowed = true,
    this.trigger,
  });

  final Json? value;
  final ValueChanged<Json> onSelect;
  final VoidCallback? onDelete;
  final ValueChanged<List<Json>>? onSelectMultiple;
  final Set<String> selected;
  final bool disabled, supportEnableSwitch, isMcpAllowed;

  /// A trigger of its own (the multiple selector's add button).
  final DifyTriggerBuilder? trigger;

  @override
  State<AgentToolSelector> createState() => _AgentToolSelectorState();
}

class _AgentToolSelectorState extends State<AgentToolSelector> {
  final _popup = DifyFloatingController();

  @override
  Widget build(BuildContext context) {
    final language = LlmGroupScope.of(context).models.language;
    final value = widget.value;
    return DifyFloating(
      controller: _popup,
      placement: DifyPlacement.left,
      sideOffset: 4,
      builder:
          widget.trigger ??
          (context, c) => value == null
              ? DifyPressable(
                  semanticLabel: _p('detailPanel.configureTool'),
                  disabled: widget.disabled,
                  onPressed: c.toggle,
                  builder: (context, hovered, focused) => Container(
                    height: 32,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: hovered ? DifyColors.componentsButtonGhostBgHover : DifyColors.componentsInputBgNormal,
                      borderRadius: BorderRadius.circular(DifyRadius.lg),
                    ),
                    child: Row(
                      spacing: 4,
                      children: [
                        Expanded(
                          child: DifyText(
                            _p('detailPanel.configureTool'),
                            DifyType.systemSmRegular,
                            color: DifyColors.componentsInputTextPlaceholder,
                          ),
                        ),
                        RemixIcon('equalizer-2-line', size: 16, color: DifyColors.textTertiary),
                      ],
                    ),
                  ),
                )
              : _ToolItem(
                  value: value,
                  provider: _providerOf(context, value),
                  supportEnableSwitch: widget.supportEnableSwitch,
                  isMcpAllowed: widget.isMcpAllowed,
                  disabled: widget.disabled,
                  onOpen: c.toggle,
                  onDelete: widget.onDelete,
                  onSwitch: (on) => widget.onSelect({...value, 'enabled': on}),
                ),
      popupBuilder: (context) => _ToolSelectorPopup(
        value: value,
        language: language,
        selected: widget.selected,
        onSelect: (v) => widget.onSelect(v),
        onSelectMultiple: widget.onSelectMultiple,
        onClose: _popup.close,
      ),
    );
  }
}

/// The tool selector popover: `w-90.25 rounded-xl border-[0.5px] bg-components-panel-bg-blur shadow-lg`.
class _ToolSelectorPopup extends StatefulWidget {
  const _ToolSelectorPopup({
    required this.value,
    required this.language,
    required this.onSelect,
    required this.onClose,
    this.onSelectMultiple,
    this.selected = const {},
  });

  final Json? value;
  final String language;
  final ValueChanged<Json> onSelect;
  final ValueChanged<List<Json>>? onSelectMultiple;
  final VoidCallback onClose;
  final Set<String> selected;

  @override
  State<_ToolSelectorPopup> createState() => _ToolSelectorPopupState();
}

class _ToolSelectorPopupState extends State<_ToolSelectorPopup> {
  late Json? _value = widget.value;
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _pick(PickedTool t) {
    final next = toolValueOf(t.provider, t.tool, widget.language);
    setState(() => _value = next);
    widget.onSelect(next);
    if (widget.value == null) widget.onClose();
  }

  @override
  Widget build(BuildContext context) {
    final value = _value;
    final description = jsStr(jsGet(value?['extra'], 'description')) ?? '';
    return Container(
      width: 361,
      padding: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: DifyColors.componentsPanelBgBlur,
        borderRadius: BorderRadius.circular(DifyRadius.xl),
        border: Border.all(color: DifyColors.componentsPanelBorder, width: 0.5),
        boxShadow: DifyShadows.lg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
            child: DifyText(
              value == null ? _p('detailPanel.toolSelector.title') : _p('detailPanel.toolSelector.toolSetting'),
              DifyType.systemXlSemibold,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 4,
              children: [
                SizedBox(
                  height: 24,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: DifyText(
                      _p('detailPanel.toolSelector.toolLabel'),
                      DifyType.systemSmSemibold,
                      color: DifyColors.textSecondary,
                    ),
                  ),
                ),
                ToolPicker(
                  placement: DifyPlacement.bottomStart,
                  selected: widget.selected,
                  language: widget.language,
                  onSelect: _pick,
                  onSelectMultiple: widget.onSelectMultiple == null
                      ? null
                      : (ts) {
                          widget.onSelectMultiple!([
                            for (final t in ts) toolValueOf(t.provider, t.tool, widget.language),
                          ]);
                          widget.onClose();
                        },
                  trigger: (context, c) => DifyPressable(
                    semanticLabel: _p('detailPanel.toolSelector.placeholder'),
                    onPressed: c.toggle,
                    builder: (context, hovered, focused) => Container(
                      height: 32,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      alignment: Alignment.centerLeft,
                      decoration: BoxDecoration(
                        color: hovered ? DifyColors.stateBaseHoverAlt : DifyColors.componentsInputBgNormal,
                        borderRadius: BorderRadius.circular(DifyRadius.lg),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: DifyText(
                              value == null
                                  ? _p('detailPanel.toolSelector.placeholder')
                                  : '${value['tool_label'] ?? ''}',
                              DifyType.systemSmRegular,
                              color: value == null
                                  ? DifyColors.componentsInputTextPlaceholder
                                  : DifyColors.componentsInputTextFilled,
                            ),
                          ),
                          RemixIcon('arrow-down-s-line', size: 16, color: DifyColors.textTertiary),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 24,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: DifyText(
                      _p('detailPanel.toolSelector.descriptionLabel'),
                      DifyType.systemSmSemibold,
                      color: DifyColors.textSecondary,
                    ),
                  ),
                ),
                DifyInput(
                  value: description,
                  disabled: value == null,
                  placeholder: _p('detailPanel.toolSelector.descriptionPlaceholder'),
                  semanticLabel: _p('detailPanel.toolSelector.descriptionLabel'),
                  onChanged: (d) {
                    final v = _value;
                    if (v == null) return;
                    final next = {
                      ...jsonClone(v),
                      'extra': {...jsMap(v['extra']), 'description': d},
                    };
                    _value = next;
                    _debounce?.cancel();
                    _debounce = Timer(const Duration(milliseconds: 300), () => widget.onSelect(next));
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

/// ToolItem: `rounded-lg border-[0.5px] bg-components-panel-on-panel-item-bg p-1.5 pr-2 shadow-xs`, the provider icon,
/// the provider (`system-2xs-medium-uppercase`) over the tool label, then the enable switch, the not-installed /
/// not-authorized states, the settings icon and delete.
class _ToolItem extends StatefulWidget {
  const _ToolItem({
    required this.value,
    required this.provider,
    required this.onOpen,
    required this.onSwitch,
    this.onDelete,
    this.supportEnableSwitch = false,
    this.isMcpAllowed = true,
    this.disabled = false,
  });

  final Json value;
  final Json? provider;
  final VoidCallback onOpen;
  final VoidCallback? onDelete;
  final ValueChanged<bool> onSwitch;
  final bool supportEnableSwitch, isMcpAllowed, disabled;

  @override
  State<_ToolItem> createState() => _ToolItemState();
}

class _ToolItemState extends State<_ToolItem> {
  bool _deleteHover = false;

  @override
  Widget build(BuildContext context) {
    final v = widget.value, provider = widget.provider;
    final uninstalled = provider == null;
    final noAuth = provider != null && provider['is_team_authorization'] == false;
    final mcpBlocked = v['type'] == ToolCollectionType.mcp && !widget.isMcpAllowed;
    return DifyPressable(
      semanticLabel: '${v['tool_label'] ?? v['tool_name'] ?? ''}',
      onPressed: widget.onOpen,
      builder: (context, hovered, focused) => Opacity(
        opacity: mcpBlocked ? 0.3 : 1,
        child: Container(
          padding: const EdgeInsets.fromLTRB(6, 6, 8, 6),
          decoration: BoxDecoration(
            color: _deleteHover ? DifyColors.stateDestructiveHover : DifyColors.componentsPanelOnPanelItemBg,
            borderRadius: BorderRadius.circular(DifyRadius.lg),
            border: Border.all(
              color: _deleteHover ? DifyColors.stateDestructiveBorder : DifyColors.componentsPanelBorderSubtle,
              width: 0.5,
            ),
            boxShadow: DifyShadows.xs,
          ),
          child: Row(
            spacing: 8,
            children: [
              Opacity(
                opacity: uninstalled || noAuth ? 0.5 : 1,
                child: _ProviderIcon(provider?['icon'], size: 28),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DifyText(
                      _providerShortName(v).toUpperCase(),
                      DifyType.system2xsMediumUppercase,
                      color: DifyColors.textTertiary,
                    ),
                    DifyText('${v['tool_label'] ?? ''}', DifyType.systemXsMedium, color: DifyColors.textSecondary),
                  ],
                ),
              ),
              if (hovered && !widget.disabled) ...[
                RemixIcon('equalizer-2-line', size: 16, color: DifyColors.textTertiary),
                MouseRegion(
                  onEnter: (_) => setState(() => _deleteHover = true),
                  onExit: (_) => setState(() => _deleteHover = false),
                  child: DifyIconButton(
                    label: DifyI18n.tr('common', 'operation.delete'),
                    tone: DifyButtonTone.destructive,
                    icon: const RemixIcon('delete-bin-line', size: 16),
                    onPressed: widget.onDelete,
                  ),
                ),
              ],
              if (noAuth)
                DifyButton(
                  size: DifyButtonSize.small,
                  onPressed: widget.onOpen,
                  child: DifyTextLine(DifyI18n.tr('tools', 'notAuthorized')),
                )
              else if (uninstalled)
                DifyTooltip(
                  content: DifyTextLine(_w('nodes.agent.toolNotInstallTooltip', {'tool': v['tool_label'] ?? ''})),
                  child: RemixIcon('error-warning-fill', size: 16, color: DifyColors.textDestructive),
                ),
              if (widget.supportEnableSwitch && !uninstalled)
                DifySwitch(
                  size: DifySwitchSize.md,
                  checked: v['enabled'] == true && !mcpBlocked,
                  disabled: widget.disabled || mcpBlocked,
                  semanticLabel: '${v['tool_label'] ?? ''}',
                  onCheckedChange: widget.onSwitch,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// MultipleToolSelector: the collapsible header (label, `*`, infotip, "{enabled}/{total} Enabled", add), then the
/// empty hint or one tool selector per tool (with the enable switch).
class MultipleToolSelector extends StatefulWidget {
  const MultipleToolSelector({
    super.key,
    required this.value,
    required this.label,
    required this.onChange,
    this.required = false,
    this.tooltip = '',
    this.disabled = false,
    this.isMcpAllowed = true,
  });

  final List<Json> value;
  final String label, tooltip;
  final ValueChanged<List<Json>> onChange;
  final bool required, disabled, isMcpAllowed;

  @override
  State<MultipleToolSelector> createState() => _MultipleToolSelectorState();
}

class _MultipleToolSelectorState extends State<MultipleToolSelector> {
  bool _open = true;

  String _key(Json t) => '${t['provider_name']}:${t['tool_name']}';

  @override
  Widget build(BuildContext context) {
    final value = widget.value;
    final enabled = value.where(
      (t) => t['enabled'] == true && (t['type'] != ToolCollectionType.mcp || widget.isMcpAllowed),
    );
    final selectedKeys = {for (final t in value) '${t['provider_name']}/${t['tool_name']}'};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(
            children: [
              Expanded(
                child: Row(
                  spacing: 2,
                  children: [
                    Flexible(
                      child: DifyPressable(
                        semanticLabel: widget.label,
                        onPressed: () => setState(() => _open = !_open),
                        builder: (context, hovered, focused) => SizedBox(
                          height: 24,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            spacing: 2,
                            children: [
                              Flexible(
                                child: DifyText(
                                  widget.label.toUpperCase(),
                                  DifyType.systemSmSemiboldUppercase,
                                  color: DifyColors.textSecondary,
                                ),
                              ),
                              if (widget.required)
                                DifyTextLine(
                                  '*',
                                  style: difyStyle(DifyType.systemSmSemibold, DifyColors.textDestructive),
                                ),
                              AnimatedRotation(
                                turns: _open ? 0 : 0.75,
                                duration: difyTransitionDuration,
                                child: DifyIcon(
                                  'vender/solid/general/arrow-down-round-fill',
                                  size: 16,
                                  color: hovered ? DifyColors.textSecondary : DifyColors.textQuaternary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    if (widget.tooltip.isNotEmpty)
                      DifyInfotip(label: widget.tooltip, content: DifyTextLine(widget.tooltip)),
                  ],
                ),
              ),
              if (value.isNotEmpty) ...[
                Flexible(
                  child: DifyText(
                    '${enabled.length}/${value.length} ${DifyI18n.tr('app-debug', 'agent.tools.enabled')}',
                    DifyType.systemXsMedium,
                    color: DifyColors.textTertiary,
                  ),
                ),
                Container(
                  width: 1,
                  height: 12,
                  margin: const EdgeInsets.only(left: 12, right: 4),
                  color: DifyColors.dividerRegular,
                ),
              ],
              if (!widget.disabled)
                AgentToolSelector(
                  value: null,
                  selected: selectedKeys,
                  onSelect: (t) => widget.onChange(addToolValues(value, [t])),
                  onSelectMultiple: (ts) => widget.onChange(addToolValues(value, ts)),
                  trigger: (context, c) => DifyIconButton(
                    label: _p('detailPanel.toolSelector.title'),
                    variant: DifyButtonVariant.ghost,
                    icon: const RemixIcon('add-line', size: 16),
                    onPressed: () {
                      setState(() => _open = true);
                      c.toggle();
                    },
                  ),
                ),
            ],
          ),
        ),
        if (_open)
          if (value.isEmpty)
            Container(
              padding: const EdgeInsets.all(12),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: DifyColors.backgroundSection,
                borderRadius: BorderRadius.circular(10),
              ),
              child: DifyText(
                _p('detailPanel.toolSelector.empty'),
                DifyType.systemXsRegular,
                color: DifyColors.textTertiary,
                maxLines: null,
                align: TextAlign.center,
              ),
            )
          else
            for (final (i, t) in value.indexed)
              Padding(
                key: ValueKey(_key(t)),
                padding: const EdgeInsets.only(bottom: 4),
                child: AgentToolSelector(
                  value: t,
                  supportEnableSwitch: true,
                  isMcpAllowed: widget.isMcpAllowed,
                  disabled: widget.disabled,
                  selected: selectedKeys,
                  onSelect: (next) => widget.onChange([for (final (j, o) in value.indexed) j == i ? next : o]),
                  onSelectMultiple: (ts) => widget.onChange(addToolValues(value, ts)),
                  onDelete: () => widget.onChange([
                    for (final (j, o) in value.indexed)
                      if (j != i) o,
                  ]),
                ),
              ),
      ],
    );
  }
}
