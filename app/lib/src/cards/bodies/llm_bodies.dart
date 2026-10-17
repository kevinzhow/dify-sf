import 'dart:math';

import 'package:collab_client/collab_client.dart';
import 'package:flutter/material.dart';

import '../../design/css_metrics.dart';
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../workflow/model_catalog.dart';
import '../card_kit.dart';
import '../model_chip.dart';
import '../node_body.dart';

List<Value> _items(Value? v) => switch (v) {
  VItems(:final items) => [for (final i in items) i.value],
  VList(:final items) => items,
  _ => const [],
};

String _str(Value? v) => v is VString ? v.value : '';

Map<String, Value> _map(Value? v) => v is VMap ? v.entries : const {};

/// `{provider, model}` of a `model` config (`provider` and `name`; an agent's model parameter has `model` instead,
/// [key]), or null when either is empty (Dify's `hasSetModel`).
DefaultModel? _model(Value? v, {String key = 'name'}) {
  final m = _map(v);
  final provider = _str(m['provider']), model = _str(m[key]);
  if (provider.isEmpty || model.isEmpty) return null;
  return (provider: provider, model: model);
}

/// The disabled small ModelSelector the LLM, Question Classifier and Parameter Extractor cards show, over the
/// workspace's text generation models.
Widget _modelChip(DefaultModel m, BodyContext ctx) =>
    ModelChip(value: m, models: ctx.models.textGenerationModelList, catalog: ctx.models);

/// SettingItem (_base/components/setting-item.tsx): 24 px `rounded-md bg-workflow-block-parma-bg px-1.5 py-1`, label
/// left (`max-w-25` with a value), value right, an error dot at the top right.
class _SettingItem extends StatelessWidget {
  const _SettingItem({required this.label, this.value = '', this.error = false});
  final String label;
  final String value;
  final bool error;

  @override
  Widget build(BuildContext context) => Stack(
    clipBehavior: Clip.none,
    children: [
      Container(
        height: 24,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(
          color: DifyColors.workflowBlockParmaBg,
          borderRadius: BorderRadius.circular(DifyRadius.md),
        ),
        child: Row(
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: value.isEmpty ? double.infinity : 100),
              child: DifyText(label, DifyType.systemXsMediumUppercase, color: DifyColors.textTertiary),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: DifyText(
                value,
                DifyType.systemXsMedium,
                color: DifyColors.textSecondary,
                align: TextAlign.right,
              ),
            ),
          ],
        ),
      ),
      if (error) const Positioned(top: -2, right: -2, child: ErrorStatusDot()),
    ],
  );
}

/// LLM (nodes/llm/node.tsx): the model chip in `mb-1 px-3 py-1`; nothing when no model is set.
class LlmBody extends NodeBody {
  const LlmBody();

  @override
  double height(BodyContext ctx) => _model(ctx['model']) == null ? 0 : 4 + 24 + 4 + 4;

  @override
  Widget build(BuildContext context, BodyContext ctx) {
    final m = _model(ctx['model']);
    if (m == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: _modelChip(m, ctx),
    );
  }
}

/// Parameter Extractor (nodes/parameter-extractor/node.tsx): like LLM, but the empty `mb-1 px-3 py-1` wrapper stays
/// when no model is set.
class ParameterExtractorBody extends NodeBody {
  const ParameterExtractorBody();

  @override
  double height(BodyContext ctx) => (_model(ctx['model']) == null ? 0 : 24) + 4 + 4 + 4;

  @override
  Widget build(BuildContext context, BodyContext ctx) {
    final m = _model(ctx['model']);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: m == null ? const SizedBox(width: double.infinity) : _modelChip(m, ctx),
    );
  }
}

/// Knowledge Retrieval (nodes/knowledge-retrieval/node.tsx): one `h-6.5` row per dataset (AppIcon xs + name) in
/// `mb-1 px-3 py-1 space-y-0.5`. Dify takes name and icon from the datasets the backend returns; the document only has
/// `dataset_ids`, so each row shows Dify's fallback icon (📙 on #FFF4ED) and the dataset id.
class KnowledgeRetrievalBody extends NodeBody {
  const KnowledgeRetrievalBody();

  static List<String> _ids(BodyContext ctx) => [
    for (final v in _items(ctx['dataset_ids']))
      if (_str(v).isNotEmpty) _str(v),
  ];

  @override
  double height(BodyContext ctx) {
    final n = _ids(ctx).length;
    return n == 0 ? 0 : 4 + n * 26 + (n - 1) * 2 + 4 + 4;
  }

  @override
  Widget build(BuildContext context, BodyContext ctx) {
    final ids = _ids(ctx);
    if (ids.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Column(
        children: [
          for (final (i, id) in ids.indexed) ...[
            if (i > 0) const SizedBox(height: 2),
            Container(
              height: 26,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              decoration: BoxDecoration(
                color: DifyColors.workflowBlockParmaBg,
                borderRadius: BorderRadius.circular(DifyRadius.md),
              ),
              child: Row(
                children: [
                  Container(
                    width: 16,
                    height: 16,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF4ED),
                      borderRadius: BorderRadius.circular(DifyRadius.sm),
                      border: Border.all(color: DifyColors.dividerRegular, width: Css.hairline),
                    ),
                    child: const Text('📙', style: TextStyle(fontSize: 12, height: 1)),
                  ),
                  const SizedBox(width: 4),
                  Expanded(child: DifyText(id, DifyType.systemXsRegular, color: DifyColors.textSecondary)),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Question Classifier (nodes/question-classifier/node.tsx): model chip, then (`mt-2 space-y-0.5`) one box per class
/// with its label and topic text and a source handle (id = class id) centred on the box; nothing without model and
/// classes. No `source` handle of its own.
class QuestionClassifierBody extends NodeBody {
  const QuestionClassifierBody();

  static const _textWidth = 214.0 - 10; // px-1.25
  static final _labelStyle = difyStyle(DifyType.systemXsSemibold, DifyColors.textSecondary);

  static List<VMap> _classes(BodyContext ctx) => _items(ctx['classes']).whereType<VMap>().toList();

  /// getDisplayClassLabel: the trimmed label, else "CLASS n".
  static String _label(VMap c, int i) {
    final l = _str(c.entries['label']).trim();
    return l.isEmpty ? 'CLASS ${i + 1}' : l;
  }

  /// The topic line: cut at 50 characters plus "...", on one line (`truncate` collapses white space).
  static String _topic(VMap c) {
    final name = _str(c.entries['name']);
    final cut = name.length > 50 ? '${name.substring(0, 50)}...' : name;
    return cut.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static double _topicHeight(VMap c, BodyContext ctx) {
    final t = _topic(c);
    return t.isEmpty ? 0 : InlineVarText(t, ctx, breakAll: false, truncate: true).height(_textWidth);
  }

  /// `py-0.75` + label + `gap-y-0.5` + topic line.
  static double _rowHeight(VMap c, int i, BodyContext ctx) =>
      3 + textHeight(_label(c, i), _labelStyle, _textWidth) + 2 + _topicHeight(c, ctx) + 3;

  @override
  double height(BodyContext ctx) {
    final hasModel = _model(ctx['model']) != null;
    final classes = _classes(ctx);
    if (!hasModel && classes.isEmpty) return 0;
    var h = 4 + (hasModel ? 24.0 : 0);
    if (classes.isNotEmpty) {
      h += 8 + max(0, classes.length - 1) * 2;
      for (final (i, c) in classes.indexed) {
        h += _rowHeight(c, i, ctx);
      }
    }
    return h + 4 + 4;
  }

  @override
  Map<String, double> sources(BodyContext ctx) {
    final out = <String, double>{};
    var y = 4 + (_model(ctx['model']) != null ? 24.0 : 0) + 8;
    for (final (i, c) in _classes(ctx).indexed) {
      final h = _rowHeight(c, i, ctx);
      out[_str(c.entries['id'])] = y + h / 2;
      y += h + 2;
    }
    return out;
  }

  @override
  Widget build(BuildContext context, BodyContext ctx) {
    final m = _model(ctx['model']);
    final classes = _classes(ctx);
    if (m == null && classes.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (m != null) _modelChip(m, ctx),
          if (classes.isNotEmpty) const SizedBox(height: 8),
          for (final (i, c) in classes.indexed) ...[
            if (i > 0) const SizedBox(height: 2),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
              decoration: BoxDecoration(
                color: DifyColors.workflowBlockParmaBg,
                borderRadius: BorderRadius.circular(DifyRadius.md),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(_label(c, i), style: _labelStyle),
                  const SizedBox(height: 2),
                  SizedBox(
                    height: _topicHeight(c, ctx),
                    child: InlineVarText(_topic(c), ctx, breakAll: false, truncate: true).build(),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Agent (nodes/agent/node.tsx), in `mb-1 space-y-1 px-3`: the strategy SettingItem, a "model" group with one model
/// chip per model parameter, a "toolbox" group with a 10-column grid of tool icons. Nodes with v2 data
/// (`agent_node_kind: dify_agent`, `version: '2'`) render as [AgentV2Body], as Dify's WorkflowAgentNode does.
///
/// Dify picks model and tool parameters by the strategy's parameter schema (from the plugin backend); here they are
/// recognised by their values: `{provider, model}` maps are models, `{provider_name}` maps (or lists of them) tools.
/// Tool icons show Dify's placeholder (the provider icons come from the backend).
class AgentBody extends NodeBody {
  const AgentBody();

  static bool isV2(BodyContext ctx) => _str(ctx['agent_node_kind']) == 'dify_agent' && _str(ctx['version']) == '2';

  static Iterable<Value> _values(BodyContext ctx) =>
      _map(ctx['agent_parameters']).values.map((p) => _map(p)['value']).nonNulls;

  static List<DefaultModel> _models(BodyContext ctx) => [for (final v in _values(ctx)) ?_model(v, key: 'model')];

  static int _tools(BodyContext ctx) {
    bool isTool(Value v) => _map(v).containsKey('provider_name');
    var n = 0;
    for (final v in _values(ctx)) {
      if (isTool(v)) n++;
      if (v is VList) n += v.items.where(isTool).length;
    }
    return n;
  }

  /// Group (`py-1`) with GroupLabel (`mt-1 mb-1`, 12 px) around [content], after the `space-y-1` gap.
  static double _group(double content) => 4 + 4 + 4 + 12 + 4 + content + 4;

  @override
  double height(BodyContext ctx) {
    if (isV2(ctx)) return const AgentV2Body().height(ctx);
    final m = _models(ctx).length;
    final rows = (_tools(ctx) / 10).ceil();
    return 24 +
        (m == 0 ? 0 : _group(m * 24 + (m - 1) * 2.0)) +
        (rows == 0 ? 0 : _group(rows * 20 + (rows - 1) * 2.0)) +
        4;
  }

  static Widget _groupLabel(String text) => Padding(
    padding: const EdgeInsets.only(top: 8, bottom: 4),
    child: DifyText(text, DifyType.system2xsMediumUppercase, color: DifyColors.textTertiary),
  );

  @override
  Widget build(BuildContext context, BodyContext ctx) {
    if (isV2(ctx)) return const AgentV2Body().build(context, ctx);
    final strategy = _str(ctx['agent_strategy_name']);
    final models = _models(ctx);
    final tools = _tools(ctx);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          strategy.isEmpty
              ? const _SettingItem(label: 'Agentic strategy Not Set')
              : _SettingItem(label: 'Strategy', value: _str(ctx['agent_strategy_label'])),
          if (models.isNotEmpty) ...[
            const SizedBox(height: 4),
            _groupLabel('model'),
            for (final (i, m) in models.indexed) ...[
              if (i > 0) const SizedBox(height: 2),
              ModelBar(value: m, catalog: ctx.models),
            ],
            const SizedBox(height: 4),
          ],
          if (tools > 0) ...[
            const SizedBox(height: 4),
            _groupLabel('toolbox'),
            Wrap(
              spacing: 1.5,
              runSpacing: 2,
              children: [
                for (var i = 0; i < tools; i++)
                  // ToolIcon before the tool lists load: `size-5 rounded-md border-[0.5px]` with the Group placeholder.
                  Container(
                    width: 20,
                    height: 20,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: DifyColors.backgroundDefaultDodge,
                      borderRadius: BorderRadius.circular(DifyRadius.md),
                      border: Border.all(color: DifyColors.componentsPanelBorderSubtle, width: Css.hairline),
                    ),
                    child: const Opacity(
                      opacity: 0.35,
                      child: DifyIcon('vender/other/group', size: 12, color: DifyColors.textTertiary),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
          ],
        ],
      ),
    );
  }
}

/// Agent v2 (nodes/agent-v2/node.tsx). Inline or valid roster binding: the "Agent" label and the agent chip in
/// `flex flex-col gap-0.5 py-1` (px-2.5); inline shows "Inline setup" / "Only in this node". A roster agent's name and
/// icon come from the backend (GET agent/{id}), so it shows the skeleton Dify shows until they load. No valid
/// binding: the "Agent" SettingItem with the error dot.
class AgentV2Body extends NodeBody {
  const AgentV2Body();

  static Map<String, Value> _binding(BodyContext ctx) => _map(ctx['agent_binding']);
  static bool _inline(BodyContext ctx) => _str(_binding(ctx)['binding_type']) == 'inline_agent';
  static bool _roster(BodyContext ctx) =>
      _str(_binding(ctx)['binding_type']) == 'roster_agent' && _str(_binding(ctx)['agent_id']).isNotEmpty;

  @override
  double height(BodyContext ctx) => _inline(ctx) || _roster(ctx) ? 4 + 16 + 2 + 40 + 4 : 24 + 4;

  static Color _quaternary(double k) => DifyColors.textQuaternary.withValues(alpha: DifyColors.textQuaternary.a * k);

  static Widget _bar(double width, double k) => Container(
    width: width,
    height: 8,
    decoration: BoxDecoration(color: _quaternary(k), borderRadius: BorderRadius.circular(DifyRadius.xs)),
  );

  @override
  Widget build(BuildContext context, BodyContext ctx) {
    final inline = _inline(ctx);
    if (!inline && !_roster(ctx)) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(12, 0, 12, 4),
        child: _SettingItem(label: 'Agent', error: true),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(
            height: 16,
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 2),
              child: DifyText('Agent', DifyType.system2xsMediumUppercase, color: DifyColors.textTertiary),
            ),
          ),
          const SizedBox(height: 2),
          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: DifyColors.workflowBlockParmaBg,
              borderRadius: BorderRadius.circular(DifyRadius.lg),
            ),
            child: Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: inline ? DifyColors.backgroundDefaultBurn : _quaternary(0.2),
                  ),
                  child: inline
                      ? const DifyIcon('vender/agent-v2/configure', size: 14, color: DifyColors.textTertiary)
                      : null,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: inline
                      ? const Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            DifyText('Inline setup', DifyType.systemXsRegular, color: DifyColors.textSecondary),
                            DifyText('Only in this node', DifyType.system2xsRegular, color: DifyColors.textTertiary),
                          ],
                        )
                      : Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [_bar(80, 0.2), const SizedBox(height: 6), _bar(56, 0.15)],
                          ),
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
