import 'dart:math';

import 'package:collab_client/collab_client.dart';
import 'package:flutter/material.dart';

import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../card_kit.dart';
import '../node_body.dart';
import '../../workflow/var_types.dart';
import '../../design/widgets/widgets.dart';

List<Value> _items(Value? v) => switch (v) {
  VItems(:final items) => [for (final i in items) i.value],
  VList(:final items) => items,
  _ => const [],
};

String _str(Value? v) => v is VString ? v.value : '';

/// Rows `space-y-0.5` of 24 px inside `px-3 py-1` with a 4 px bottom margin: mb-1 + py-1 + n x 24 + (n - 1) x 2.
double _rowsHeight(int n) => n == 0 ? 0 : 4 + 4 + n * 24 + (n - 1) * 2 + 4;

/// Start (nodes/start/node.tsx): one row per input variable (key, REQUIRED, type icon); nothing when there are none.
class StartBody extends NodeBody {
  const StartBody();

  @override
  bool get target => false;

  @override
  double height(BodyContext ctx) => _rowsHeight(_items(ctx['variables']).length);

  static String typeIcon(String type) => switch (type) {
    'paragraph' => 'align-left',
    'select' => 'checkbox-multiple-line',
    'number' => 'hashtag',
    'checkbox' => 'checkbox-line',
    'json_object' => 'braces-line',
    'file' => 'file-list-2-line',
    'file-list' => 'file-copy-2-line',
    _ => 'text-snippet',
  };

  @override
  Widget build(BuildContext context, BodyContext ctx) {
    final vars = _items(ctx['variables']).whereType<VMap>().toList();
    if (vars.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Column(
        children: [
          for (final (i, v) in vars.indexed) ...[
            if (i > 0) const SizedBox(height: 2),
            ParamRow(
              child: Row(
                children: [
                  DifyIcon('vender/solid/development/variable-02', size: 14, color: DifyColors.textAccent),
                  const SizedBox(width: 4),
                  Expanded(
                    child: DifyText(
                      _str(v.entries['variable']),
                      DifyType.systemXsRegular,
                      color: DifyColors.textSecondary,
                    ),
                  ),
                  const SizedBox(width: 4),
                  if (v.entries['required'] case VBool(value: true)) ...[
                    DifyText('required', DifyType.system2xsRegularUppercase, color: DifyColors.textTertiary),
                    const SizedBox(width: 4),
                  ],
                  RemixIcon(typeIcon(_str(v.entries['type'])), size: 12, color: DifyColors.textTertiary),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// End (nodes/end/node.tsx): one variable label per output that references something.
class EndBody extends NodeBody {
  const EndBody();

  List<VarRef> _refs(BodyContext ctx) => [
    for (final o in _items(ctx['outputs']).whereType<VMap>())
      if (VarRef.of(o.entries['value_selector'], ctx) case final r?)
        VarRef(node: r.node ?? ctx.start, path: r.path, broken: r.broken, short: r.short),
  ];

  @override
  double height(BodyContext ctx) => _rowsHeight(_refs(ctx).length);

  @override
  Widget build(BuildContext context, BodyContext ctx) {
    final refs = _refs(ctx);
    if (refs.isEmpty) return const SizedBox.shrink();
    final types = VarTypes(lookup: ctx.lookup, start: ctx.start);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Column(
        children: [
          for (final (i, r) in refs.indexed) ...[
            if (i > 0) const SizedBox(height: 2),
            VariableLabel.of(r, variant: VarLabelStyle.inNode, variableType: types.typeOf(r.path)),
          ],
        ],
      ),
    );
  }
}

/// IF/ELSE (nodes/if-else/node.tsx): per case a 24 px header row (CASE n, IF/ELIF) with its source handle and the
/// condition lines, then the ELSE row with the `false` handle.
class IfElseBody extends NodeBody {
  const IfElseBody();

  List<VMap> _cases(BodyContext ctx) => _items(ctx['cases']).whereType<VMap>().toList();
  static List<VMap> _conditions(VMap c) => _items(c.entries['conditions']).whereType<VMap>().toList();

  static bool _valueShown(VMap cond) {
    final op = _str(cond.entries['comparison_operator']);
    return !const {'empty', 'not empty', 'null', 'not null', 'exists', 'not exists'}.contains(op);
  }

  /// A condition line is 24 px with a value, 18 px (the chip) without one.
  static double _lineHeight(VMap cond) => _valueShown(cond) ? 24 : 18;

  @override
  double height(BodyContext ctx) {
    var h = 0.0;
    for (final c in _cases(ctx)) {
      final conds = _conditions(c);
      h += 24 + conds.fold(0.0, (a, x) => a + _lineHeight(x)) + max(0, conds.length - 1) * 2;
    }
    return h + 24; // ELSE
  }

  @override
  Map<String, double> sources(BodyContext ctx) {
    final out = <String, double>{};
    var y = 0.0;
    for (final c in _cases(ctx)) {
      out[_str(c.entries['case_id'])] = y + 12;
      final conds = _conditions(c);
      y += 24 + conds.fold(0.0, (a, x) => a + _lineHeight(x)) + max(0, conds.length - 1) * 2;
    }
    out['false'] = y + 12;
    return out;
  }

  @override
  Widget build(BuildContext context, BodyContext ctx) {
    final cases = _cases(ctx);
    final header = DifyType.system2xsMedium.style.copyWith(
      fontSize: 10,
      fontWeight: FontWeight.w600,
      color: DifyColors.textTertiary,
    );
    // `text-[12px] font-semibold` in a 16 px line.
    final keyword = difyTextStyle(DifyType.systemXsSemibold, DifyColors.textSecondary);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, c) in cases.indexed) ...[
            SizedBox(
              height: 24,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Row(
                  children: [
                    DifyTextLine(cases.length > 1 ? 'CASE ${i + 1}' : '', style: header),
                    const Spacer(),
                    DifyTextLine(i == 0 ? 'IF' : 'ELIF', style: keyword),
                  ],
                ),
              ),
            ),
            for (final (j, cond) in _conditions(c).indexed) ...[
              if (j > 0) const SizedBox(height: 2),
              _ConditionLine(cond: cond, ctx: ctx, height: _lineHeight(cond)),
            ],
          ],
          SizedBox(
            height: 24,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 4),
              child: Align(
                alignment: Alignment.centerRight,
                child: DifyTextLine('ELSE', style: keyword),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// ConditionValue (if-else/components/condition-value.tsx): variable chip, operator, value; or "Condition NOT setup".
class _ConditionLine extends StatelessWidget {
  const _ConditionLine({required this.cond, required this.ctx, required this.height});
  final VMap cond;
  final BodyContext ctx;
  final double height;

  static const _operators = {
    'contains': 'contains',
    'not contains': 'not contains',
    'start with': 'start with',
    'end with': 'end with',
    'is': 'is',
    'is not': 'is not',
    'empty': 'is empty',
    'not empty': 'is not empty',
    'in': 'in',
    'not in': 'not in',
    'all of': 'all of',
    'exists': 'exists',
    'not exists': 'not exists',
  };

  @override
  Widget build(BuildContext context) {
    final ref = VarRef.of(cond.entries['variable_selector'], ctx);
    if (ref == null) {
      return ParamRow(
        child: Align(
          alignment: Alignment.centerLeft,
          child: DifyTextLine(
            'Condition NOT setup',
            style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textSecondary), // text-xs font-normal
          ),
        ),
      );
    }
    final op = _str(cond.entries['comparison_operator']);
    final value = switch (cond.entries['value']) {
      VString(:final value) => value.replaceAllMapped(RegExp(r'\{\{#([^#]+)#\}\}'), (m) {
        final parts = m.group(1)!.split('.');
        return parts.first == 'sys' ? '{{${parts.join('.')}}}' : '{{${parts.skip(1).join('.')}}}';
      }),
      VBool(:final value) => value ? 'True' : 'False',
      VInt(:final value) => '$value',
      VDouble(:final value) => '$value',
      VList(:final items) when items.isNotEmpty => switch (items.first) {
        VString(:final value) => value,
        final v => '$v',
      },
      _ => '',
    };
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: DifyColors.workflowBlockParmaBg,
        borderRadius: BorderRadius.circular(DifyRadius.md),
      ),
      child: Row(
        children: [
          Flexible(child: VariableLabel.of(ref, variant: VarLabelStyle.inText, bare: true)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: DifyTextLine(
              _operators[op] ?? op,
              style: difyTextStyle(DifyType.systemXsMedium, DifyColors.textPrimary), // text-xs font-medium
            ),
          ),
          if (height == 24)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: DifyTextLine(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: difyTextStyle(DifyTw.textXsLeading24, DifyColors.textSecondary),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
