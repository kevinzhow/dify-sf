/// The browser's automatic table layout (CSS 2.1 `table-layout: auto`, as Chrome's TablesNG distributes it) for a table
/// whose rows are separate widgets: [AutoTableScope] measures every [AutoTableCells] row below it (each cell's minimum
/// and maximum intrinsic width) and gives all of them the same column widths, so cells line up as in a `<table>` while
/// each row stays its own widget (hover, semantics, keys).
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// The column widths of a table of [fixed] columns (`w-*` on a cell: that width, or the content's minimum if wider;
/// null: automatic) [width] wide, from each column's minimum and maximum content widths:
/// * room for every maximum: automatic columns share the rest in proportion to their maximum (fixed columns only when
///   there is no automatic one);
/// * less: every column gets its minimum, then fixed columns grow towards their width, then automatic columns towards
///   their maximum, in proportion to what each still lacks;
/// * less than the minimums: the minimums (the table overflows).
List<double> autoTableColumnWidths(double width, List<double?> fixed, List<double> mins, List<double> maxes) {
  final n = fixed.length;
  final minW = [for (var i = 0; i < n; i++) math.max(mins[i], fixed[i] ?? 0)];
  final maxW = [for (var i = 0; i < n; i++) fixed[i] != null ? minW[i] : math.max(maxes[i], minW[i])];
  final minOf = [for (var i = 0; i < n; i++) mins[i]];
  final sumMax = maxW.fold(0.0, (a, b) => a + b);
  final auto = [
    for (var i = 0; i < n; i++)
      if (fixed[i] == null) i,
  ];
  if (width >= sumMax) {
    final out = [...maxW];
    var excess = width - sumMax;
    if (excess <= 0) return out;
    final targets = auto.isNotEmpty ? auto : [for (var i = 0; i < n; i++) i];
    final total = targets.fold(0.0, (a, i) => a + maxW[i]);
    for (final i in targets) {
      out[i] += total > 0 ? excess * maxW[i] / total : excess / targets.length;
    }
    return out;
  }
  final sumMin = minOf.fold(0.0, (a, b) => a + b);
  if (width <= sumMin) return minOf;
  // Grow from the minimums: fixed columns first, then automatic ones.
  final out = [...minOf];
  var rest = width - sumMin;
  for (final group in [
    [
      for (var i = 0; i < n; i++)
        if (fixed[i] != null) i,
    ],
    auto,
  ]) {
    final lack = group.fold(0.0, (a, i) => a + (maxW[i] - out[i]));
    if (lack <= 0) continue;
    final share = math.min(1.0, rest / lack);
    for (final i in group) {
      out[i] += (maxW[i] - out[i]) * share;
    }
    rest -= lack * share;
    if (rest <= 0) break;
  }
  return out;
}

/// Shared between a scope and its rows: the rows to measure and the widths last computed.
class _TableColumns {
  _TableColumns(this.fixed);

  List<double?> fixed;
  List<double> widths = const [];
  final Set<_RenderAutoTableCells> rows = {};
  _RenderAutoTableScope? scope;
}

/// The table: lays its [child] out after giving every [AutoTableCells] row below it the columns' widths for the
/// width it gets (its maximum width constraint).
class AutoTableScope extends StatefulWidget {
  const AutoTableScope({super.key, required this.fixed, required this.child});

  /// Per column: a fixed width (`w-*`), or null (automatic).
  final List<double?> fixed;
  final Widget child;

  @override
  State<AutoTableScope> createState() => _AutoTableScopeState();
}

class _AutoTableScopeState extends State<AutoTableScope> {
  late final _TableColumns _columns = _TableColumns(widget.fixed);

  @override
  Widget build(BuildContext context) => _AutoTableColumns(
    columns: _columns,
    child: _AutoTableScopeRender(columns: _columns, fixed: widget.fixed, child: widget.child),
  );
}

class _AutoTableColumns extends InheritedWidget {
  const _AutoTableColumns({required this.columns, required super.child});

  final _TableColumns columns;

  @override
  bool updateShouldNotify(_AutoTableColumns old) => old.columns != columns;
}

class _AutoTableScopeRender extends SingleChildRenderObjectWidget {
  const _AutoTableScopeRender({required this.columns, required this.fixed, super.child});

  final _TableColumns columns;
  final List<double?> fixed;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderAutoTableScope(columns)..fixed = fixed;

  @override
  void updateRenderObject(BuildContext context, _RenderAutoTableScope renderObject) => renderObject.fixed = fixed;
}

class _RenderAutoTableScope extends RenderProxyBox {
  _RenderAutoTableScope(this.columns);

  final _TableColumns columns;

  set fixed(List<double?> value) {
    if (listEquals(value, columns.fixed)) return;
    columns.fixed = value;
    markNeedsLayout();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    columns.scope = this;
  }

  @override
  void detach() {
    if (columns.scope == this) columns.scope = null;
    super.detach();
  }

  List<double> _measure(double width) {
    final n = columns.fixed.length;
    final mins = List.filled(n, 0.0), maxes = List.filled(n, 0.0);
    for (final row in columns.rows) {
      var i = 0;
      for (var c = row.firstChild; c != null && i < n; c = row.childAfter(c), i++) {
        final max = c.getMaxIntrinsicWidth(double.infinity);
        maxes[i] = math.max(maxes[i], max);
        mins[i] = math.max(mins[i], row.nowrap ? max : c.getMinIntrinsicWidth(double.infinity));
      }
    }
    return autoTableColumnWidths(width, columns.fixed, mins, maxes);
  }

  @override
  void performLayout() {
    final widths = _measure(constraints.maxWidth);
    if (!listEquals(widths, columns.widths)) {
      invokeLayoutCallback<BoxConstraints>((_) {
        columns.widths = widths;
        for (final row in columns.rows) {
          row.markNeedsLayout();
        }
      });
    }
    super.performLayout();
  }
}

/// One row of an [AutoTableScope]'s table: its [children] are the row's cells, one per column, each as wide as its
/// column and centred vertically in the row. [nowrap]: the cells' content does not wrap (`whitespace-nowrap`, the
/// header's), so their minimum width is their maximum.
class AutoTableCells extends MultiChildRenderObjectWidget {
  const AutoTableCells({super.key, this.nowrap = false, super.children});

  final bool nowrap;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderAutoTableCells(
    context.getInheritedWidgetOfExactType<_AutoTableColumns>()?.columns ?? _TableColumns(const []),
    nowrap,
  );

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) =>
      (renderObject as _RenderAutoTableCells).nowrap = nowrap;
}

class _AutoTableCellsParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderAutoTableCells extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _AutoTableCellsParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _AutoTableCellsParentData> {
  _RenderAutoTableCells(this.columns, this._nowrap);

  final _TableColumns columns;

  bool get nowrap => _nowrap;
  bool _nowrap;
  set nowrap(bool value) {
    if (value == _nowrap) return;
    _nowrap = value;
    columns.scope?.markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _AutoTableCellsParentData) child.parentData = _AutoTableCellsParentData();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    columns.rows.add(this);
    columns.scope?.markNeedsLayout();
  }

  @override
  void detach() {
    columns.rows.remove(this);
    columns.scope?.markNeedsLayout();
    super.detach();
  }

  /// The column widths, or (outside a scope, before the first measure) equal shares of [width].
  List<double> _widths(double width) {
    if (columns.widths.length == childCount) return columns.widths;
    final share = width.isFinite && childCount > 0 ? width / childCount : 0.0;
    return List.filled(childCount, share);
  }

  Iterable<RenderBox> get _children sync* {
    for (var c = firstChild; c != null; c = childAfter(c)) {
      yield c;
    }
  }

  @override
  double computeMinIntrinsicWidth(double height) => _children.fold(0.0, (a, c) => a + c.getMinIntrinsicWidth(height));

  @override
  double computeMaxIntrinsicWidth(double height) => _children.fold(0.0, (a, c) => a + c.getMaxIntrinsicWidth(height));

  double _height(double width, double Function(RenderBox, double) of) {
    final widths = _widths(width);
    var h = 0.0, i = 0;
    for (final c in _children) {
      h = math.max(h, of(c, widths[i++]));
    }
    return h;
  }

  @override
  double computeMinIntrinsicHeight(double width) => _height(width, (c, w) => c.getMinIntrinsicHeight(w));

  @override
  double computeMaxIntrinsicHeight(double width) => _height(width, (c, w) => c.getMaxIntrinsicHeight(w));

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final widths = _widths(constraints.maxWidth);
    var h = 0.0, i = 0;
    for (final c in _children) {
      h = math.max(h, c.getDryLayout(BoxConstraints.tightFor(width: widths[i++])).height);
    }
    return constraints.constrain(Size(widths.fold(0.0, (a, b) => a + b), h));
  }

  @override
  void performLayout() {
    final widths = _widths(constraints.maxWidth);
    var h = 0.0, i = 0;
    for (final c in _children) {
      c.layout(BoxConstraints.tightFor(width: widths[i++]), parentUsesSize: true);
      h = math.max(h, c.size.height);
    }
    size = constraints.constrain(Size(widths.fold(0.0, (a, b) => a + b), h));
    var x = 0.0;
    for (final c in _children) {
      (c.parentData! as _AutoTableCellsParentData).offset = Offset(x, (size.height - c.size.height) / 2);
      x += c.size.width;
    }
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);

  @override
  void paint(PaintingContext context, Offset offset) => defaultPaint(context, offset);
}
