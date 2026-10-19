/// dify-ui's Pagination (packages/dify-ui/src/pagination).
library;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../i18n/dify_i18n.dart';
import '../css_metrics.dart';
import '../dify_icon.dart';
import '../dify_tokens.g.dart';
import 'widgets.dart';

String _c(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('common', key, params);

/// A page number, or an ellipsis (`ellipsis-start` / `ellipsis-end`).
typedef PageItem = Object;

int _clampPage(int page, int totalPages) => page.clamp(1, totalPages < 1 ? 1 : totalPages);

/// dify-ui's `getPageItems`.
List<PageItem> paginationPageItems({
  required int page,
  required int totalPages,
  int siblingCount = 1,
  int boundaryCount = 1,
}) {
  if (totalPages <= 0) return const [];
  List<int> range(int start, int end) => end < start ? const [] : [for (var i = start; i <= end; i++) i];
  final p = _clampPage(page, totalPages);
  final b = boundaryCount < 0 ? 0 : boundaryCount, s = siblingCount < 0 ? 0 : siblingCount;
  if (totalPages <= b * 2 + s * 2 + 3) return range(1, totalPages);
  final startPages = range(1, b < totalPages ? b : totalPages);
  final endPages = range((totalPages - b + 1) > b + 1 ? totalPages - b + 1 : b + 1, totalPages);
  final firstEnd = endPages.firstOrNull;
  var siblingStart = p - s < totalPages - b - s * 2 - 1 ? p - s : totalPages - b - s * 2 - 1;
  if (siblingStart < b + 2) siblingStart = b + 2;
  var siblingEnd = p + s > b + s * 2 + 2 ? p + s : b + s * 2 + 2;
  final cap = firstEnd != null ? firstEnd - 2 : totalPages - 1;
  if (siblingEnd > cap) siblingEnd = cap;
  final items = <PageItem>[...startPages];
  if (siblingStart > b + 2) {
    items.add('ellipsis-start');
  } else if (b + 1 < totalPages - b) {
    items.add(b + 1);
  }
  items.addAll(range(siblingStart, siblingEnd));
  if (siblingEnd < totalPages - b - 1) {
    items.add('ellipsis-end');
  } else if (totalPages - b > b) {
    items.add(totalPages - b);
  }
  items.addAll(endPages);
  return items;
}

/// dify-ui's Pagination facade as the logs use it: previous / "page / total" (click to type a page) / next on the
/// left, the page buttons in the middle, the page size control ("Items per page" on hover) on the right.
class LogPagination extends StatefulWidget {
  const LogPagination({
    super.key,
    required this.page,
    required this.totalPages,
    required this.onPageChange,
    this.pageSize,
    this.pageSizeOptions = const [10, 25, 50],
    this.onPageSizeChange,
  });

  /// One-based.
  final int page;
  final int totalPages;
  final ValueChanged<int> onPageChange;
  final int? pageSize;
  final List<int> pageSizeOptions;
  final ValueChanged<int>? onPageSizeChange;

  @override
  State<LogPagination> createState() => _LogPaginationState();
}

class _LogPaginationState extends State<LogPagination> {
  bool _editing = false, _sizeHover = false;

  void _go(int page) {
    final next = _clampPage(page, widget.totalPages);
    if (next != _clampPage(widget.page, widget.totalPages)) widget.onPageChange(next);
  }

  Widget _arrow(String label, String icon, bool disabled, VoidCallback onPressed) => DifyPressable(
    semanticLabel: label,
    disabled: disabled,
    onPressed: onPressed,
    builder: (context, hovered, focused) => Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        color: disabled
            ? DifyColors.componentsButtonSecondaryBgDisabled
            : hovered
            ? DifyColors.componentsButtonSecondaryBgHover
            : DifyColors.componentsButtonSecondaryBg,
        borderRadius: BorderRadius.circular(DifyRadius.lg),
        border: Border.all(
          color: focused
              ? DifyColors.stateAccentSolid
              : disabled
              ? DifyColors.componentsButtonSecondaryBorderDisabled
              : hovered
              ? DifyColors.componentsButtonSecondaryBorderHover
              : DifyColors.componentsButtonSecondaryBorder,
          width: focused ? 2 : Css.hairline,
        ),
        boxShadow: disabled ? null : DifyShadows.xs,
      ),
      child: Center(
        child: RemixIcon(
          icon,
          size: 16,
          color: disabled ? DifyColors.componentsButtonSecondaryTextDisabled : DifyColors.componentsButtonSecondaryText,
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final total = widget.totalPages < 0 ? 0 : widget.totalPages;
    if (total <= 0) return const SizedBox.shrink();
    final page = _clampPage(widget.page, total);
    final items = paginationPageItems(page: page, totalPages: total);
    final summary = Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 2,
        children: [
          Text('$page', style: difyTextStyle(DifyType.systemXsMedium, DifyColors.textSecondary)),
          Text('/', style: difyTextStyle(DifyType.systemXsMedium, DifyColors.textQuaternary)),
          Text('$total', style: difyTextStyle(DifyType.systemXsMedium, DifyColors.textSecondary)),
        ],
      ),
    );
    final jump = _editing
        ? SizedBox(
            width: 56,
            height: 28,
            child: _PageInput(
              initial: page,
              label: _c('pagination.pageNumber'),
              onCommit: (v) {
                setState(() => _editing = false);
                if (v != null) _go(v);
              },
            ),
          )
        : DifyPressable(
            semanticLabel: _c('pagination.editPageNumber', {'page': page, 'totalPages': total}),
            onPressed: () => setState(() => _editing = true),
            builder: (context, hovered, focused) => DecoratedBox(
              decoration: BoxDecoration(
                color: hovered ? DifyColors.stateBaseHoverAlt : null,
                borderRadius: BorderRadius.circular(DifyRadius.lg),
                border: focused ? Border.all(color: DifyColors.stateAccentSolid, width: 2) : null,
              ),
              child: MouseRegion(cursor: SystemMouseCursors.text, child: summary),
            ),
          );
    return Semantics(
      container: true,
      label: 'Pagination',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: Container(
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    color: DifyColors.backgroundSectionBurn,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    spacing: 2,
                    children: [
                      _arrow(_c('pagination.previous'), 'arrow-left-line', page <= 1, () => _go(page - 1)),
                      jump,
                      _arrow(_c('pagination.next'), 'arrow-right-line', page >= total, () => _go(page + 1)),
                    ],
                  ),
                ),
              ),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 2,
              children: [
                for (final item in items)
                  if (item is int)
                    _PageButton(page: item, current: item == page, onPressed: () => _go(item))
                  else
                    SizedBox.square(
                      dimension: 32,
                      child: Center(
                        child: Text('…', style: difyTextStyle(DifyType.systemSmMedium, DifyColors.textTertiary)),
                      ),
                    ),
              ],
            ),
            Expanded(
              child: widget.pageSize == null
                  ? const SizedBox.shrink()
                  : MouseRegion(
                      onEnter: (_) => setState(() => _sizeHover = true),
                      onExit: (_) => setState(() => _sizeHover = false),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        spacing: 8,
                        children: [
                          SizedBox(
                            width: 52,
                            child: Opacity(
                              opacity: _sizeHover ? 1 : 0,
                              child: Text(
                                difyTransform(DifyType.system2xsRegularUppercase, _c('pagination.perPage')),
                                textAlign: TextAlign.end,
                                style: difyTextStyle(DifyType.system2xsRegularUppercase, DifyColors.textTertiary),
                              ),
                            ),
                          ),
                          DifySegmentedControl<int>(
                            value: widget.pageSize!,
                            semanticLabel: _c('pagination.perPage'),
                            onChanged: widget.onPageSizeChange,
                            segments: [
                              for (final o in widget.pageSizeOptions)
                                (
                                  value: o,
                                  label: '$o',
                                  child: ConstrainedBox(
                                    constraints: const BoxConstraints(minWidth: 20),
                                    child: Text('$o', textAlign: TextAlign.center),
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PageButton extends StatelessWidget {
  const _PageButton({required this.page, required this.current, required this.onPressed});
  final int page;
  final bool current;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Semantics(
    selected: current,
    child: DifyPressable(
      semanticLabel: current ? 'Page $page, current page' : 'Go to page $page',
      onPressed: onPressed,
      builder: (context, hovered, focused) => Container(
        height: 32,
        constraints: const BoxConstraints(minWidth: 32),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        decoration: BoxDecoration(
          color: hovered
              ? DifyColors.componentsButtonGhostBgHover
              : current
              ? DifyColors.componentsButtonTertiaryBg
              : null,
          borderRadius: BorderRadius.circular(DifyRadius.lg),
          border: focused ? Border.all(color: DifyColors.stateAccentSolid, width: 2) : null,
        ),
        child: Center(
          child: Text(
            '$page',
            style: difyTextStyle(
              DifyType.systemSmMedium,
              current
                  ? DifyColors.componentsButtonTertiaryText
                  : hovered
                  ? DifyColors.textSecondary
                  : DifyColors.textTertiary,
            ),
          ),
        ),
      ),
    ),
  );
}

class _PageInput extends StatefulWidget {
  const _PageInput({required this.initial, required this.label, required this.onCommit});
  final int initial;
  final String label;
  final ValueChanged<int?> onCommit;

  @override
  State<_PageInput> createState() => _PageInputState();
}

class _PageInputState extends State<_PageInput> {
  late String _text = '${widget.initial}';
  final _focus = FocusNode(debugLabel: 'pagination page input');
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _commit();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => mounted ? _focus.requestFocus() : null);
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _commit({bool cancel = false}) {
    if (_done) return;
    _done = true;
    widget.onCommit(cancel ? null : int.tryParse(_text.trim()));
  }

  @override
  Widget build(BuildContext context) => DifyInput(
    value: _text,
    focusNode: _focus,
    height: 28,
    semanticLabel: widget.label,
    keyboardType: TextInputType.number,
    formatters: [FilteringTextInputFormatter.digitsOnly],
    onChanged: (v) => _text = v,
    onSubmitted: (_) => _commit(),
    onKeyEvent: (_, e) {
      if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.escape) {
        _commit(cancel: true);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    },
  );
}
