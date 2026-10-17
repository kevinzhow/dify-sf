import 'dart:math';

import 'package:collab_client/collab_client.dart';
import 'package:flutter/material.dart';

import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../card_kit.dart';
import '../node_body.dart';

List<Value> _items(Value? v) => switch (v) {
  VItems(:final items) => [for (final i in items) i.value],
  VList(:final items) => items,
  _ => const [],
};

String _str(Value? v) => v is VString ? v.value : '';

double _textWidth(String text, DifyTextStyle s) {
  final p = TextPainter(
    text: TextSpan(
      text: s.uppercase ? text.toUpperCase() : text,
      style: s.style.copyWith(fontFamily: cardFontFamily),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  final w = p.width;
  p.dispose();
  return w;
}

/// `n` rows of 24 px `space-y-0.5` inside `mb-1 px-3 py-1`.
double _rowsHeight(int n) => n == 0 ? 0 : 4 + 4 + n * 24 + (n - 1) * 2 + 4;

/// Code (nodes/code/node.tsx): no summary content (retry and error-handle rows come from the chrome).
class CodeBody extends NoBody {
  const CodeBody();
}

/// Template (nodes/template-transform/node.tsx): no summary content.
class TemplateTransformBody extends NoBody {
  const TemplateTransformBody();
}

/// HTTP Request (nodes/http/node.tsx): method badge and the URL (ReadonlyInputWithSelectVar, `text-xs break-all`,
/// variable chips) in one parameter box; nothing when the URL is empty.
class HttpRequestBody extends NodeBody {
  const HttpRequestBody();

  static const _method = DifyType.systemXsSemibold; // text-xs font-semibold uppercase

  static String _methodText(BodyContext ctx) =>
      (_str(ctx['method']).isEmpty ? 'get' : _str(ctx['method'])).toUpperCase();

  static String _url(BodyContext ctx) => _str(ctx['url']);

  /// 214 - p-1 x 2 - badge (px-1 + text) - pl-1.
  static double _urlWidth(BodyContext ctx) => 214 - 8 - (8 + _textWidth(_methodText(ctx), _method)) - 4;

  @override
  double height(BodyContext ctx) {
    if (_str(ctx['url']).isEmpty) return 0;
    final url = InlineVarText(_url(ctx), ctx, color: DifyColors.textSecondary).height(_urlWidth(ctx));
    // mb-1 + py-1 x 2 + p-1 x 2 + max(badge h-4, pt-1 + url).
    return 4 + 8 + 8 + max(16, 4 + url);
  }

  @override
  Widget build(BuildContext context, BodyContext ctx) {
    if (_str(ctx['url']).isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: DifyColors.workflowBlockParmaBg,
          borderRadius: BorderRadius.circular(DifyRadius.md),
        ),
        child: Row(
          children: [
            Container(
              height: 16,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: DifyColors.componentsBadgeWhiteToDark,
                borderRadius: BorderRadius.circular(DifyRadius.sm),
              ),
              child: DifyText(_methodText(ctx), _method, color: DifyColors.textSecondary),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(left: 4, top: 4),
                child: InlineVarText(_url(ctx), ctx, color: DifyColors.textSecondary).build(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "Input Variable" label and the variable (list-operator/node.tsx, document-extractor/node.tsx).
class _InputVariable extends StatelessWidget {
  const _InputVariable(this.ref);
  final VarRef ref;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const DifyText('Input Variable', DifyType.system2xsMediumUppercase, color: DifyColors.textTertiary),
      const SizedBox(height: 4),
      VariableLabel(ref: ref),
    ],
  );
}

/// List Operator (nodes/list-operator/node.tsx): `px-3` "Input Variable" + the input variable; nothing without one.
class ListOperatorBody extends NodeBody {
  const ListOperatorBody();

  @override
  double height(BodyContext ctx) => VarRef.of(ctx['variable'], ctx) == null ? 0 : 12 + 4 + 24;

  @override
  Widget build(BuildContext context, BodyContext ctx) => switch (VarRef.of(ctx['variable'], ctx)) {
    final r? => Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: _InputVariable(r)),
    null => const SizedBox.shrink(),
  };
}

/// Doc Extractor (nodes/document-extractor/node.tsx): `mb-1 px-3 py-1` "Input Variable" + the variable; nothing
/// without one.
class DocumentExtractorBody extends NodeBody {
  const DocumentExtractorBody();

  @override
  double height(BodyContext ctx) => VarRef.of(ctx['variable_selector'], ctx) == null ? 0 : 4 + 12 + 4 + 24 + 4 + 4;

  @override
  Widget build(BuildContext context, BodyContext ctx) => switch (VarRef.of(ctx['variable_selector'], ctx)) {
    final r? => Padding(padding: const EdgeInsets.fromLTRB(12, 4, 12, 8), child: _InputVariable(r)),
    null => const SizedBox.shrink(),
  };
}

/// Tool (nodes/tool/node.tsx): one row per `tool_configurations` key (raw key, value by type). The install button and
/// the "Authorization required" row need the backend's plugin and tool-collection state, which the canvas does not
/// have, so they are not drawn.
class ToolBody extends NodeBody {
  const ToolBody();

  static Map<String, Value> _configs(BodyContext ctx) => switch (ctx['tool_configurations']) {
    VMap(:final entries) => entries,
    _ => const {},
  };

  @override
  double height(BodyContext ctx) => _rowsHeight(_configs(ctx).length);

  static String _plain(Value v) => switch (v) {
    VString(:final value) => value,
    VInt(:final value) => '$value',
    VDouble(:final value) => '$value',
    VBool(:final value) => '$value',
    VNull() => '',
    _ => '$v',
  };

  /// The value texts Dify renders for a setting (none for boolean or object values).
  static List<String> _values(String key, Value config, BodyContext ctx) {
    if (config is! VMap) return const [];
    final secret = _items(ctx['paramSchemas']).whereType<VMap>().any(
      (s) => _str(s.entries['name']) == key && _str(s.entries['type']) == 'secret-input',
    );
    return [
      switch (config.entries['value']) {
        VString(:final value) => secret ? '********' : value,
        VInt(:final value) => '$value',
        VDouble(:final value) => '$value',
        VList(:final items) => items.map(_plain).join(', '),
        _ => null,
      },
      if (_str(config.entries['type']) == 'model-selector') _str(config.entries['model']),
    ].nonNulls.toList();
  }

  @override
  Widget build(BuildContext context, BodyContext ctx) {
    final configs = _configs(ctx);
    if (configs.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Column(
        children: [
          for (final (i, MapEntry(:key, :value)) in configs.entries.indexed) ...[
            if (i > 0) const SizedBox(height: 2),
            ParamRow(
              child: Row(
                children: [
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 100),
                    child: DifyText(key.toUpperCase(), DifyType.systemXsMedium, color: DifyColors.textTertiary),
                  ),
                  for (final v in _values(key, value, ctx)) ...[
                    const SizedBox(width: 4),
                    Expanded(
                      child: DifyText(
                        v,
                        DifyType.systemXsRegular,
                        color: DifyColors.textSecondary,
                        align: TextAlign.right,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Variable Aggregator (nodes/variable-assigner/node.tsx, also the legacy `variable-assigner`): one block per group
/// ("Assign variables" when grouping is off) with title, type, "+" and the variables or "Variable not set". Groups have
/// no handles of their own (a connection is assigned to a group by hovering while dragging).
class VariableAggregatorBody extends NodeBody {
  const VariableAggregatorBody();

  /// (title, type, variables) per group.
  static List<(String, String, List<Value>)> _groups(BodyContext ctx) {
    final adv = ctx['advanced_settings'];
    if (adv case VMap(:final entries) when entries['group_enabled'] == const VBool(true)) {
      return [
        for (final g in _items(entries['groups']).whereType<VMap>())
          (_str(g.entries['group_name']), _str(g.entries['output_type']), _items(g.entries['variables'])),
      ];
    }
    return [('Assign variables', _str(ctx['output_type']), _items(ctx['variables']))];
  }

  /// Border 1.5 + pt-1 + header h-4 + content + pb-1.5 + border 1.5; content is the 22 px pill or the labels.
  static double _groupHeight(int vars) => 1.5 + 4 + 16 + (vars == 0 ? 22 : vars * 24 + (vars - 1) * 2) + 6 + 1.5;

  @override
  double height(BodyContext ctx) {
    final groups = _groups(ctx);
    return groups.fold(0.0, (a, g) => a + _groupHeight(g.$3.length)) +
        (groups.isEmpty ? 0 : (groups.length - 1) * 2) +
        4; // mb-1
  }

  static VarRef _ref(Value v, BodyContext ctx) {
    final r = VarRef.of(v, ctx) ?? const VarRef(path: ['', '']);
    // isExceptionVariable: error outputs of nodes with error handling are drawn in text-warning.
    const errorHandling = {'llm', 'tool', 'http-request', 'code', 'agent', 'agent-v2'};
    final exception =
        (r.path.last == 'error_message' || r.path.last == 'error_type') && errorHandling.contains(r.node?.type ?? '');
    return exception ? r.copyWith(broken: true) : r;
  }

  @override
  Widget build(BuildContext context, BodyContext ctx) {
    final header = difyStyle(DifyType.system2xsMedium, DifyColors.textTertiary);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, (title, type, vars)) in _groups(ctx).indexed) ...[
            if (i > 0) const SizedBox(height: 2),
            Padding(
              padding: const EdgeInsets.fromLTRB(7.5, 5.5, 7.5, 7.5),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    height: 16,
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            title.toUpperCase(),
                            style: header,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(type, style: header, maxLines: 1),
                        const SizedBox(width: 8),
                        Container(width: 1, height: 10, color: DifyColors.dividerRegular),
                        const SizedBox(width: 4),
                        const SizedBox.square(
                          dimension: 16,
                          child: Center(
                            child: DifyIcon('vender/line/general/plus-02', size: 10, color: DifyColors.textTertiary),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (vars.isEmpty)
                    Container(
                      height: 22,
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      alignment: Alignment.centerLeft,
                      decoration: BoxDecoration(
                        color: DifyColors.workflowBlockParmaBg,
                        borderRadius: BorderRadius.circular(DifyRadius.md),
                      ),
                      child: const DifyText(
                        'Variable not set',
                        DifyType.system2xsRegularUppercase,
                        color: DifyColors.textTertiary,
                      ),
                    )
                  else
                    for (final (j, v) in vars.indexed) ...[
                      if (j > 0) const SizedBox(height: 2),
                      VariableLabel(ref: _ref(v, ctx)),
                    ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Variable Assigner (nodes/assigner/node.tsx): per operation with a variable, the variable and an operation badge;
/// "Variable NOT Set" when there is none. Legacy (not version 2) data: the assigned variable and its write mode, or
/// nothing.
class AssignerBody extends NodeBody {
  const AssignerBody();

  static const _operations = {
    'over-write': 'Overwrite',
    'overwrite': 'Overwrite',
    'clear': 'Clear',
    'append': 'Append',
    'extend': 'Extend',
    'set': 'Set',
    'remove-first': 'Remove First',
    'remove-last': 'Remove Last',
  };

  static bool _v2(BodyContext ctx) => _str(ctx['version']) == '2';

  /// (variable, operation) per row.
  static List<(VarRef, String)> _rows(BodyContext ctx) {
    if (!_v2(ctx)) {
      final r = VarRef.of(ctx['assigned_variable_selector'], ctx);
      return r == null ? const [] : [(r, _str(ctx['write_mode']))];
    }
    return [
      for (final item in _items(ctx['items']).whereType<VMap>())
        if (VarRef.of(item.entries['variable_selector'], ctx) case final r?) (r, _str(item.entries['operation'])),
    ];
  }

  @override
  double height(BodyContext ctx) {
    final n = _rows(ctx).length;
    if (n == 0) return _v2(ctx) ? 4 + 24 + 4 : 0;
    return 4 + n * 24 + (n - 1) * 2 + 4;
  }

  @override
  Widget build(BuildContext context, BodyContext ctx) {
    final rows = _rows(ctx);
    if (rows.isEmpty && !_v2(ctx)) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (rows.isEmpty)
            Container(
              height: 24,
              padding: const EdgeInsets.symmetric(horizontal: 5),
              alignment: Alignment.centerLeft,
              decoration: BoxDecoration(
                color: DifyColors.workflowBlockParmaBg,
                borderRadius: BorderRadius.circular(DifyRadius.md),
              ),
              child: const DifyText('Variable NOT Set', DifyType.systemXsMedium, color: DifyColors.textTertiary),
            ),
          for (final (i, (ref, op)) in rows.indexed) ...[
            if (i > 0) const SizedBox(height: 2),
            VariableLabel(
              ref: ref,
              rightSlot: op.isEmpty
                  ? null
                  : Container(
                      height: 20,
                      padding: const EdgeInsets.symmetric(horizontal: 5),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        border: Border.all(color: DifyColors.dividerDeep),
                        borderRadius: BorderRadius.circular(DifyRadius.badge),
                      ),
                      child: DifyText(
                        _operations[op] ?? op,
                        DifyType.system2xsMediumUppercase,
                        color: DifyColors.textTertiary,
                      ),
                    ),
            ),
          ],
        ],
      ),
    );
  }
}
