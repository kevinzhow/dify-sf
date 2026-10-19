/// Tables as Dify writes them (no dify-ui component; the same markup repeats): `<table class="w-full min-w-110
/// border-collapse">` with a `<thead class="system-xs-medium-uppercase text-text-tertiary">` row on
/// `bg-background-section-burn` (`rounded-l-lg` / `rounded-r-lg` ends) and `<tr class="border-b border-divider-subtle
/// hover:bg-background-default-hover">` rows (web/app/components/app/log/list.tsx, app/workflow-log/list.tsx,
/// app/annotation/list.tsx, app/annotation/view-annotation-modal/index.tsx), and the `table-fixed` one of
/// web/app/components/api-key/api-key-table.tsx.
///
/// The layout is the browser's: automatic (CSS 2.1 `table-layout: auto`, as Chrome's TablesNG distributes it) for a
/// table whose rows are separate widgets: [DifyAutoTableScope] measures every [DifyAutoTableCells] row below it (each
/// cell's minimum and maximum intrinsic width) and gives all of them the same column widths, so cells line up as in a
/// `<table>` while each row stays its own widget (hover, semantics, keys); or fixed (`table-fixed`).
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../dify_tokens.g.dart';
import 'text.dart';

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

/// `table-fixed`: the columns' widths ([fixed]; null: automatic) as the browser's fixed table layout gives them for a
/// table [width] wide: automatic columns share what the fixed ones leave; with none (or no room left), every column
/// stretches or shrinks in proportion to its width.
List<double> fixedTableColumnWidths(double width, List<double?> fixed) {
  final sum = fixed.fold(0.0, (a, w) => a + (w ?? 0));
  final autos = fixed.where((w) => w == null).length;
  if (autos > 0 && width > sum) return [for (final w in fixed) w ?? (width - sum) / autos];
  final scale = sum > 0 && width.isFinite ? width / sum : 1.0;
  return [for (final w in fixed) (w ?? 0) * scale];
}

/// Shared between a scope and its rows: the rows to measure and the widths last computed.
class _TableColumns {
  _TableColumns(this.fixed);

  List<double?> fixed;
  bool fixedLayout = false;
  List<double> widths = const [];
  final Set<_RenderAutoTableCells> rows = {};
  _RenderAutoTableScope? scope;
}

/// The table: lays its [child] out after giving every [DifyAutoTableCells] row below it the columns' widths for the
/// width it gets (its maximum width constraint).
class DifyAutoTableScope extends StatefulWidget {
  const DifyAutoTableScope({super.key, required this.fixed, this.fixedLayout = false, required this.child});

  /// Per column: a fixed width (`w-*`), or null (automatic).
  final List<double?> fixed;

  /// `table-fixed`: [fixedTableColumnWidths], no measuring.
  final bool fixedLayout;
  final Widget child;

  @override
  State<DifyAutoTableScope> createState() => _DifyAutoTableScopeState();
}

class _DifyAutoTableScopeState extends State<DifyAutoTableScope> {
  late final _TableColumns _columns = _TableColumns(widget.fixed);

  @override
  Widget build(BuildContext context) => _AutoTableColumns(
    columns: _columns,
    child: _AutoTableScopeRender(
      columns: _columns,
      fixed: widget.fixed,
      fixedLayout: widget.fixedLayout,
      child: widget.child,
    ),
  );
}

class _AutoTableColumns extends InheritedWidget {
  const _AutoTableColumns({required this.columns, required super.child});

  final _TableColumns columns;

  @override
  bool updateShouldNotify(_AutoTableColumns old) => old.columns != columns;
}

class _AutoTableScopeRender extends SingleChildRenderObjectWidget {
  const _AutoTableScopeRender({
    required this.columns,
    required this.fixed,
    required this.fixedLayout,
    super.child,
  });

  final _TableColumns columns;
  final List<double?> fixed;
  final bool fixedLayout;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderAutoTableScope(columns)
    ..fixed = fixed
    ..fixedLayout = fixedLayout;

  @override
  void updateRenderObject(BuildContext context, _RenderAutoTableScope renderObject) => renderObject
    ..fixed = fixed
    ..fixedLayout = fixedLayout;
}

class _RenderAutoTableScope extends RenderProxyBox {
  _RenderAutoTableScope(this.columns);

  final _TableColumns columns;

  set fixed(List<double?> value) {
    if (listEquals(value, columns.fixed)) return;
    columns.fixed = value;
    markNeedsLayout();
  }

  set fixedLayout(bool value) {
    if (value == columns.fixedLayout) return;
    columns.fixedLayout = value;
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
    if (columns.fixedLayout) return fixedTableColumnWidths(width, columns.fixed);
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

  /// Lays the table out [constraints.maxWidth] wide or, unbounded (in a horizontal scroll view), at least
  /// [constraints.minWidth]: wider when the columns' minimums need more (the table overflows its box, as a browser's
  /// automatic table does), clipped to a bounded maximum.
  @override
  void performLayout() {
    final available = constraints.hasBoundedWidth ? constraints.maxWidth : constraints.minWidth;
    final widths = _measure(available);
    if (!listEquals(widths, columns.widths)) {
      invokeLayoutCallback<BoxConstraints>((_) {
        columns.widths = widths;
        for (final row in columns.rows) {
          row.markNeedsLayout();
        }
      });
    }
    final width = constraints.constrainWidth(math.max(available, widths.fold(0.0, (a, b) => a + b)));
    final c = child;
    if (c == null) {
      size = constraints.constrain(Size(width, 0));
      return;
    }
    c.layout(constraints.copyWith(minWidth: width, maxWidth: width), parentUsesSize: true);
    size = c.size;
  }
}

/// One row of an [DifyAutoTableScope]'s table: its [children] are the row's cells, one per column, each as wide as its
/// column and centred vertically in the row. [nowrap]: the cells' content does not wrap (`whitespace-nowrap`, the
/// header's), so their minimum width is their maximum.
class DifyAutoTableCells extends MultiChildRenderObjectWidget {
  const DifyAutoTableCells({super.key, this.nowrap = false, super.children});

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

// ---- the table ---------------------------------------------------------------------------------------------------

/// A [DifyTable] column: its [header] cell's content (null: an empty cell) inside [headerPadding] (`py-1.5 pl-3` by
/// default), and its [width] (`w-*` on its cells; null: automatic).
class DifyTableColumn {
  const DifyTableColumn({this.header, this.width, this.headerPadding = const EdgeInsets.fromLTRB(12, 6, 0, 6)});

  final Widget? header;
  final double? width;
  final EdgeInsetsGeometry headerPadding;
}

/// Dify's `<table class="w-full min-w-110">`: the header row (`whitespace-nowrap` cells in [headerStyle]
/// `text-text-tertiary`, at least [headerHeight] tall, on [headerDecoration]: `bg-background-section-burn` with
/// `rounded-lg` ends by default), then [rows] (usually [DifyTableRow]s), all sharing the columns' widths ([layout]:
/// automatic, or `table-fixed`). Narrower than [minWidth] or than its columns' minimums, an automatic table keeps
/// that width and scrolls sideways (`overflow-x-auto`). [scrollBody]: the header stays (`sticky top-0`) and the rows scroll below it, the table as tall
/// as its content up to the height it gets. [decoration] is the table's own (e.g. `border-y`).
class DifyTable extends StatelessWidget {
  const DifyTable({
    super.key,
    required this.columns,
    required this.rows,
    this.layout = DifyTableLayout.auto,
    this.minWidth = 440,
    this.headerKey,
    this.headerStyle,
    this.headerDecoration,
    this.headerHeight = 28,
    this.decoration,
    this.scrollBody = false,
  });

  final List<DifyTableColumn> columns;
  final List<Widget> rows;
  final DifyTableLayout layout;
  final double minWidth;
  final Key? headerKey;

  /// `system-xs-medium-uppercase` by default.
  final DifyTextStyle? headerStyle;
  final Decoration? headerDecoration;
  final double headerHeight;
  final Decoration? decoration;
  final bool scrollBody;

  Widget _header() => Semantics(
    container: true,
    child: Container(
      key: headerKey,
      decoration:
          headerDecoration ??
          BoxDecoration(color: DifyColors.backgroundSectionBurn, borderRadius: BorderRadius.circular(DifyRadius.lg)),
      child: DefaultTextStyle.merge(
        style: difyTextStyle(headerStyle ?? DifyType.systemXsMediumUppercase, DifyColors.textTertiary),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: headerHeight),
          child: DifyAutoTableCells(
            nowrap: true,
            children: [
              for (final c in columns)
                c.header == null ? const SizedBox.shrink() : Padding(padding: c.headerPadding, child: c.header),
            ],
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = math.max(constraints.maxWidth, minWidth);
      Widget body = scrollBody
          ? Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _header(),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: rows,
                    ),
                  ),
                ),
              ],
            )
          : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [_header(), ...rows]);
      // A Container insets the body by the border (CSS: the border is outside the rows).
      if (decoration case final d?) body = Container(decoration: d, child: body);
      final table = DifyAutoTableScope(
        fixed: [for (final c in columns) c.width],
        fixedLayout: layout == DifyTableLayout.fixed,
        child: Semantics(container: true, child: body),
      );
      // `table-fixed` keeps the table's width (cells clip); an automatic table at least [minWidth] wide grows with its
      // columns' minimums and scrolls sideways.
      if (layout == DifyTableLayout.fixed) return SizedBox(width: width, child: table);
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: width),
          child: table,
        ),
      );
    },
  );
}

/// `table-layout`.
enum DifyTableLayout { auto, fixed }

/// A table row (`<tr>`): its [cells] (one per column; the body's `system-sm-regular text-text-secondary`), the bottom
/// divider ([dividerColor], `border-divider-subtle` by default; none without [divider]: `last:border-b-0`), the
/// `hover:bg-background-default-hover` background ([hoverable]) also while [selected]. [onTap]: a click anywhere that
/// is not a button opens the row. [selected] non-null also marks the row's selected state for assistive technology.
/// [nowrap]: the cells do not wrap (`truncate` / `whitespace-nowrap`), so each needs its whole content's width.
class DifyTableRow extends StatefulWidget {
  const DifyTableRow({
    super.key,
    required this.cells,
    this.onTap,
    this.selected,
    this.hoverable = true,
    this.divider = true,
    this.dividerColor,
    this.nowrap = false,
  });

  final List<Widget> cells;
  final VoidCallback? onTap;
  final bool? selected;
  final bool hoverable, divider, nowrap;
  final Color? dividerColor;

  @override
  State<DifyTableRow> createState() => _DifyTableRowState();
}

class _DifyTableRowState extends State<DifyTableRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final w = widget;
    Widget row = Container(
      decoration: BoxDecoration(
        color: w.hoverable && (_hover || w.selected == true) ? DifyColors.backgroundDefaultHover : null,
        border: w.divider ? Border(bottom: BorderSide(color: w.dividerColor ?? DifyColors.dividerSubtle)) : null,
      ),
      child: DefaultTextStyle.merge(
        style: difyTextStyle(DifyType.systemSmRegular, DifyColors.textSecondary),
        child: DifyAutoTableCells(nowrap: w.nowrap, children: w.cells),
      ),
    );
    if (w.onTap != null) row = GestureDetector(behavior: HitTestBehavior.opaque, onTap: w.onTap, child: row);
    if (w.hoverable || w.onTap != null) {
      row = MouseRegion(
        cursor: w.onTap != null ? SystemMouseCursors.click : MouseCursor.defer,
        onEnter: w.hoverable ? (_) => setState(() => _hover = true) : null,
        onExit: w.hoverable ? (_) => setState(() => _hover = false) : null,
        child: row,
      );
    }
    return Semantics(container: true, selected: w.selected, child: row);
  }
}
