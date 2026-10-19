/// The Logs pages' building blocks, Dify 1.17.1: log-annotation/page-title.tsx, base/chip, base/sort, dify-ui's
/// Pagination facade and StatusDot, the log drawer (dify-ui Drawer, `swipeDirection="right"`), log/empty-element.tsx,
/// log/var-panel.tsx, the filters' TIME_PERIOD_MAPPING and the logs' loading state.
library;

import 'package:collab_client/collab_client.dart' show AppModes;
import 'package:flutter/semantics.dart' show SemanticsRole;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart' show SvgPicture;

import '../../design/css_metrics.dart';
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';
import '../../open_url.dart';
import '../../workflow_editor/node_panel/bodies/llm/model_selector.dart' show StatusDot, StatusDotKind;
import '../../workflow_editor/panel_fields/controls.dart' show DifyInput, DifySegmentedControl;

export '../../workflow_editor/node_panel/bodies/llm/model_selector.dart' show StatusDot, StatusDotKind;

String _l(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('app-log', key, params);
String _c(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('common', key, params);

/// `APP_PAGE_LIMIT`.
const appPageLimit = 10;

// ---------------------------------------------------------------------------------------------------------------------
// TIME_PERIOD_MAPPING (log/filter.tsx and workflow-log/filter.tsx share it)
// ---------------------------------------------------------------------------------------------------------------------

/// One period option: how many days back (`-1`: all time) and its `appLog.filter.period.*` name.
typedef TimePeriod = ({int value, String name});

/// `TIME_PERIOD_MAPPING`, computed from [today] like Dify's module-level `dayjs()` (calendar months, quarters and
/// years for keys 4 to 8).
Map<String, TimePeriod> timePeriodMapping([DateTime? today]) {
  final t = today ?? DateTime.now();
  final day = DateTime(t.year, t.month, t.day);
  int diff(DateTime from) => day.difference(DateTime(from.year, from.month, from.day)).inDays;
  final quarterStart = DateTime(t.year, ((t.month - 1) ~/ 3) * 3 + 1);
  return {
    '1': (value: 0, name: 'today'),
    '2': (value: 7, name: 'last7days'),
    '3': (value: 28, name: 'last4weeks'),
    '4': (value: diff(DateTime(t.year, t.month - 3, t.day)), name: 'last3months'),
    '5': (value: diff(DateTime(t.year - 1, t.month, t.day)), name: 'last12months'),
    '6': (value: diff(DateTime(t.year, t.month)), name: 'monthToDate'),
    '7': (value: diff(quarterStart), name: 'quarterToDate'),
    '8': (value: diff(DateTime(t.year)), name: 'yearToDate'),
    '9': (value: -1, name: 'allTime'),
  };
}

String _two(int n) => n.toString().padLeft(2, '0');

/// The local start of the day [days] days before [now] (`dayjs().subtract(days, 'day').startOf('day')`).
DateTime periodStart(int days, DateTime now) => DateTime(now.year, now.month, now.day - days);

/// The local end of [now]'s day (`dayjs().endOf('day')`).
DateTime periodEnd(DateTime now) => DateTime(now.year, now.month, now.day, 23, 59, 59, 999);

/// dayjs `format('YYYY-MM-DD HH:mm')`.
String formatDayjsMinute(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)} ${_two(d.hour)}:${_two(d.minute)}';

/// dayjs `format('YYYY-MM-DDTHH:mm:ssZ')` in local time (`+08:00`).
String formatDayjsIso(DateTime d) {
  final o = d.timeZoneOffset;
  final sign = o.isNegative ? '-' : '+';
  final m = o.inMinutes.abs();
  return '${d.year}-${_two(d.month)}-${_two(d.day)}T${_two(d.hour)}:${_two(d.minute)}:${_two(d.second)}'
      '$sign${_two(m ~/ 60)}:${_two(m % 60)}';
}

// ---------------------------------------------------------------------------------------------------------------------
// PageTitle
// ---------------------------------------------------------------------------------------------------------------------

/// log-annotation/page-title.tsx: the `title-2xl-semi-bold` heading (`h-6`) over the `system-xs-regular` tertiary
/// description and an optional "Learn more" link.
class LogPageTitle extends StatelessWidget {
  const LogPageTitle({
    super.key,
    required this.title,
    required this.description,
    this.learnMoreHref,
    this.learnMoreLabel,
  });

  final String title, description;
  final String? learnMoreHref, learnMoreLabel;

  @override
  Widget build(BuildContext context) {
    final href = learnMoreHref, label = learnMoreLabel;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      spacing: 2,
      children: [
        SizedBox(
          height: 24,
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: Semantics(
              header: true,
              child: Text(title, style: difyTextStyle(DifyType.title2xlSemiBold, DifyColors.textPrimary)),
            ),
          ),
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 2,
          children: [
            Flexible(
              child: Text(
                description,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textTertiary),
              ),
            ),
            if (href != null && label != null)
              LogLink(
                url: href,
                label: label,
                onTap: () => openExternalUrl(href),
                builder: (hovered) => Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textAccent).copyWith(
                        decoration: hovered ? TextDecoration.underline : null,
                        decorationColor: DifyColors.textAccent,
                      ),
                    ),
                    RemixIcon('external-link-line', size: 12, color: DifyColors.textAccent),
                  ],
                ),
              ),
          ],
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// Chip (base/chip)
// ---------------------------------------------------------------------------------------------------------------------

/// A chip option (`Item`): its value and name.
typedef ChipItem = ({String value, String name});

/// base/chip: a select whose trigger shows the selected item's name (with a filter icon, or [leftIcon]); with a value
/// it turns into a secondary button with a clear button on its right (`aria-label` "Clear `name`"), else it shows a
/// down arrow. The popup (`w-60`, or [panelWidth]) lists the items with a check on the selected one.
class LogChip extends StatefulWidget {
  const LogChip({
    super.key,
    required this.value,
    required this.items,
    required this.onSelect,
    required this.onClear,
    this.showLeftIcon = true,
    this.leftIcon,
    this.minWidth,
    this.panelWidth = 240,
  });

  final String value;
  final List<ChipItem> items;
  final ValueChanged<ChipItem> onSelect;
  final VoidCallback onClear;
  final bool showLeftIcon;
  final Widget? leftIcon;

  /// A call site's `min-w-*` (`min-w-37.5` for the period and annotation chips).
  final double? minWidth;
  final double panelWidth;

  @override
  State<LogChip> createState() => _LogChipState();
}

class _LogChipState extends State<LogChip> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.items.where((i) => i.value == widget.value).firstOrNull;
    final trigger = selected?.name ?? '';
    final hasValue = selected != null && widget.value.isNotEmpty;
    final clearLabel = trigger.isNotEmpty ? '${_c('operation.clear')} $trigger' : _c('operation.clear');
    return Stack(
      children: [
        DifyDropdownMenu(
          placement: DifyPlacement.bottomStart,
          width: widget.panelWidth,
          open: _open,
          onOpenChange: (v) => setState(() => _open = v),
          builder: (context, controller) => Semantics(
            expanded: _open,
            child: DifyPressable(
              semanticLabel: trigger.isNotEmpty ? trigger : _c('placeholder.select'),
              onPressed: controller.toggle,
              builder: (context, hovered, focused) {
                final active = hovered || _open;
                final chip = Container(
                  constraints: BoxConstraints(minHeight: 32, minWidth: widget.minWidth ?? 0),
                  padding: EdgeInsets.fromLTRB(8, 4, hasValue ? 24 : 8, 4),
                  decoration: BoxDecoration(
                    color: hasValue
                        ? (active
                              ? DifyColors.componentsButtonSecondaryBgHover
                              : DifyColors.componentsButtonSecondaryBg)
                        : (active ? DifyColors.stateBaseHoverAlt : DifyColors.componentsInputBgNormal),
                    borderRadius: BorderRadius.circular(DifyRadius.lg),
                    border: Border.all(
                      color: focused
                          ? DifyColors.stateAccentSolid
                          : hasValue
                          ? (active
                                ? DifyColors.componentsButtonSecondaryBorderHover
                                : DifyColors.componentsButtonSecondaryBorder)
                          : const Color(0x00000000),
                      width: focused ? 2 : Css.hairline,
                    ),
                    boxShadow: hasValue ? DifyShadows.xs : null,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    spacing: 4,
                    children: [
                      if (widget.showLeftIcon)
                        Padding(
                          padding: const EdgeInsets.all(2),
                          child:
                              widget.leftIcon ??
                              RemixIcon(
                                'filter-3-line',
                                size: 16,
                                color: hasValue ? DifyColors.textSecondary : DifyColors.textTertiary,
                              ),
                        ),
                      Flexible(
                        fit: widget.minWidth == null ? FlexFit.loose : FlexFit.tight,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Text(
                            trigger,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: difyTextStyle(
                              DifyType.systemSmRegular,
                              hasValue ? DifyColors.textSecondary : DifyColors.textTertiary,
                            ),
                          ),
                        ),
                      ),
                      if (!hasValue) RemixIcon('arrow-down-s-line', size: 16, color: DifyColors.textTertiary),
                    ],
                  ),
                );
                // `min-w-*`: at least that wide, else as wide as its content (not the whole row).
                return widget.minWidth == null ? chip : IntrinsicWidth(child: chip);
              },
            ),
          ),
          children: [
            DifyMenuRadioGroup<String>(
              value: widget.value,
              onValueChange: (v) {
                final item = widget.items.where((i) => i.value == v).firstOrNull;
                if (item != null) widget.onSelect(item);
              },
              children: [
                for (final item in widget.items)
                  DifyMenuRadioItem<String>(
                    key: ValueKey('chip-option-${item.value}'),
                    value: item.value,
                    closeOnClick: true,
                    child: Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
              ],
            ),
          ],
        ),
        if (hasValue)
          Positioned(
            right: 6,
            top: 0,
            bottom: 0,
            child: Center(
              child: DifyPressable(
                semanticLabel: clearLabel,
                onPressed: widget.onClear,
                builder: (context, hovered, focused) => SizedBox.square(
                  dimension: 20,
                  child: Center(
                    child: RemixIcon(
                      'close-circle-fill',
                      size: 14,
                      color: hovered ? DifyColors.textTertiary : DifyColors.textQuaternary,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// Sort (base/sort)
// ---------------------------------------------------------------------------------------------------------------------

/// base/sort: "Sort by: `name`" (a radio dropdown that keeps [order]) and the order button next to it (`sort-asc`
/// without an order, `sort-desc` with `-`), which flips the order.
class LogSort extends StatefulWidget {
  const LogSort({super.key, required this.order, required this.value, required this.items, required this.onSelect});

  /// `'-'` (descending) or `''`.
  final String order;
  final String value;
  final List<ChipItem> items;
  final ValueChanged<String> onSelect;

  @override
  State<LogSort> createState() => _LogSortState();
}

class _LogSortState extends State<LogSort> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final trigger = widget.items.where((i) => i.value == widget.value).firstOrNull?.name ?? '';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        DifyDropdownMenu(
          placement: DifyPlacement.bottomStart,
          width: 240,
          open: _open,
          onOpenChange: (v) => setState(() => _open = v),
          builder: (context, controller) => DifyPressable(
            semanticLabel: '${_l('filter.sortBy')} $trigger',
            onPressed: controller.toggle,
            builder: (context, hovered, focused) => Container(
              constraints: const BoxConstraints(minHeight: 32),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: hovered || _open ? DifyColors.stateBaseHoverAlt : DifyColors.componentsInputBgNormal,
                borderRadius: const BorderRadius.horizontal(left: Radius.circular(DifyRadius.lg)),
                border: focused ? Border.all(color: DifyColors.stateAccentSolid, width: 2) : null,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      spacing: 2,
                      children: [
                        Text(
                          _l('filter.sortBy'),
                          style: difyTextStyle(DifyType.systemSmRegular, DifyColors.textTertiary),
                        ),
                        Text(
                          trigger,
                          style: difyTextStyle(
                            DifyType.systemSmRegular,
                            widget.value.isNotEmpty ? DifyColors.textSecondary : DifyColors.textTertiary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  RemixIcon('arrow-down-s-line', size: 16, color: DifyColors.textTertiary),
                ],
              ),
            ),
          ),
          children: [
            DifyMenuRadioGroup<String>(
              value: widget.value,
              onValueChange: (v) => widget.onSelect('${widget.order}$v'),
              children: [
                for (final item in widget.items)
                  DifyMenuRadioItem<String>(
                    key: ValueKey('sort-option-${item.value}'),
                    value: item.value,
                    closeOnClick: true,
                    child: Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
              ],
            ),
          ],
        ),
        const SizedBox(width: 1),
        DifyPressable(
          semanticLabel: _l(widget.order.isNotEmpty ? 'filter.ascending' : 'filter.descending'),
          onPressed: () => widget.onSelect('${widget.order.isNotEmpty ? '' : '-'}${widget.value}'),
          builder: (context, hovered, focused) => Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: hovered ? DifyColors.componentsButtonTertiaryBgHover : DifyColors.componentsButtonTertiaryBg,
              borderRadius: const BorderRadius.horizontal(right: Radius.circular(DifyRadius.lg)),
              border: focused ? Border.all(color: DifyColors.stateAccentSolid, width: 2) : null,
            ),
            child: RemixIcon(
              widget.order.isNotEmpty ? 'sort-desc' : 'sort-asc',
              size: 16,
              color: DifyColors.componentsButtonTertiaryText,
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// Pagination (dify-ui)
// ---------------------------------------------------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------------------------------------------------
// Status cells, unread dot, loading
// ---------------------------------------------------------------------------------------------------------------------

/// An uppercase status label with its dot (`inline-flex items-center gap-1 system-xs-semibold-uppercase`).
class LogStatusLabel extends StatelessWidget {
  const LogStatusLabel({super.key, required this.dot, required this.text, required this.color});
  final StatusDotKind dot;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    spacing: 4,
    children: [
      StatusDot(status: dot),
      Flexible(
        child: Text(
          difyTransform(DifyType.systemXsSemiboldUppercase, text),
          style: difyTextStyle(DifyType.systemXsSemiboldUppercase, color),
        ),
      ),
    ],
  );
}

/// The unread mark (`size-1.5 rounded-sm bg-util-colors-blue-blue-500` in `p-3 pr-0.5`).
class LogUnreadDot extends StatelessWidget {
  const LogUnreadDot({super.key});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 12, 2, 12),
    child: Container(
      key: const ValueKey('log-unread-dot'),
      width: 6,
      height: 6,
      decoration: BoxDecoration(
        color: DifyColors.utilColorsBlueBlue500,
        borderRadius: BorderRadius.circular(2),
      ),
    ),
  );
}

/// base/loading (`type="app"`: centred in the remaining height).
class LogLoading extends StatelessWidget {
  const LogLoading({super.key});

  @override
  Widget build(BuildContext context) => Center(
    key: const ValueKey('logs-loading'),
    child: DifySpinner(color: DifyColors.utilColorsBlueBrandBlueBrand600, size: 24),
  );
}

// ---------------------------------------------------------------------------------------------------------------------
// Table
// ---------------------------------------------------------------------------------------------------------------------

/// A table column: its header (null: the empty unread column), its width (null: flexible with [flex]) and whether the
/// header row's corner is rounded there.
typedef LogColumn = ({Widget? header, double? width, int flex});

/// The logs' `<table>`: the header row (`system-xs-medium-uppercase text-text-tertiary` on `bg-background-section-burn`,
/// `rounded-lg` ends, `py-1.5 pl-3`), and rows with a bottom divider that highlight on hover and while selected.
class LogTable extends StatelessWidget {
  const LogTable({super.key, required this.columns, required this.rows, this.minWidth = 440});

  final List<LogColumn> columns;
  final List<LogTableRow> rows;
  final double minWidth;

  static Widget cellsRow(List<LogColumn> columns, List<Widget> cells, {EdgeInsets? padding}) => Row(
    crossAxisAlignment: CrossAxisAlignment.center,
    children: [
      for (final (i, c) in columns.indexed)
        if (c.width != null) SizedBox(width: c.width, child: cells[i]) else Expanded(flex: c.flex, child: cells[i]),
    ],
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth < minWidth ? minWidth : constraints.maxWidth;
      final table = SizedBox(
        width: width,
        child: Semantics(
          container: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                container: true,
                child: Container(
                  key: const ValueKey('log-table-header'),
                  decoration: BoxDecoration(
                    color: DifyColors.backgroundSectionBurn,
                    borderRadius: BorderRadius.circular(DifyRadius.lg),
                  ),
                  child: DefaultTextStyle.merge(
                    style: difyTextStyle(DifyType.systemXsMediumUppercase, DifyColors.textTertiary),
                    child: cellsRow(columns, [
                      for (final c in columns)
                        c.header == null
                            ? const SizedBox(height: 28)
                            : Padding(padding: const EdgeInsets.fromLTRB(12, 6, 0, 6), child: c.header),
                    ]),
                  ),
                ),
              ),
              ...rows,
            ],
          ),
        ),
      );
      if (width == constraints.maxWidth) return table;
      return SingleChildScrollView(scrollDirection: Axis.horizontal, child: table);
    },
  );
}

/// A table row: hover and [selected] backgrounds (`hover:bg-background-default-hover`), the bottom divider, a click
/// anywhere that is not a button opens the row ([onTap]).
class LogTableRow extends StatefulWidget {
  const LogTableRow({
    super.key,
    required this.columns,
    required this.cells,
    required this.onTap,
    this.selected = false,
  });

  final List<LogColumn> columns;
  final List<Widget> cells;
  final VoidCallback onTap;
  final bool selected;

  @override
  State<LogTableRow> createState() => _LogTableRowState();
}

class _LogTableRowState extends State<LogTableRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    selected: widget.selected,
    child: MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          decoration: BoxDecoration(
            color: _hover || widget.selected ? DifyColors.backgroundDefaultHover : null,
            border: Border(bottom: BorderSide(color: DifyColors.dividerSubtle)),
          ),
          child: DefaultTextStyle.merge(
            style: difyTextStyle(DifyType.systemSmRegular, DifyColors.textSecondary),
            child: LogTable.cellsRow(widget.columns, widget.cells),
          ),
        ),
      ),
    ),
  );
}

/// A cell's `p-3 pr-2`.
Widget logCell(Widget child) => Padding(
  padding: const EdgeInsets.fromLTRB(12, 12, 8, 12),
  child: Align(alignment: AlignmentDirectional.centerStart, child: child),
);

/// The drawer trigger in a row (`DrawerTrigger`: a full-width text button, focusable, Enter opens).
class LogDrawerTrigger extends StatelessWidget {
  const LogDrawerTrigger({super.key, required this.text, required this.onPressed, this.focusNode});
  final String text;
  final VoidCallback onPressed;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) => DifyPressable(
    semanticLabel: text,
    focusNode: focusNode,
    onPressed: onPressed,
    builder: (context, hovered, focused) => DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(DifyRadius.sm),
        border: focused ? Border.all(color: DifyColors.stateAccentSolid, width: 2) : null,
      ),
      child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis),
    ),
  );
}

// ---------------------------------------------------------------------------------------------------------------------
// Drawer
// ---------------------------------------------------------------------------------------------------------------------

/// dify-ui's Drawer from the right as the logs open it: modal, no backdrop colour on desktop, the popup
/// `top-16 right-2 bottom-3` (`bottom-4` for conversations), at most [maxWidth] wide, `rounded-xl` with a panel border.
/// Escape and a click outside close it; [builder] gets the close callback. Resolves when it is closed.
Future<void> showLogDrawer(
  BuildContext context, {
  required Widget Function(BuildContext context, VoidCallback close) builder,
  double maxWidth = 600,
  double bottom = 12,
  bool bordered = true,
}) => showGeneralDialog<void>(
  context: context,
  barrierDismissible: true,
  barrierLabel: _c('operation.close'),
  barrierColor: const Color(0x00000000),
  transitionDuration: const Duration(milliseconds: 200),
  transitionBuilder: (context, animation, _, child) => SlideTransition(
    position: Tween(
      begin: const Offset(1, 0),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
    child: child,
  ),
  pageBuilder: (dialogContext, _, _) => SafeArea(
    child: Padding(
      padding: EdgeInsets.fromLTRB(8, 64, 8, bottom),
      child: Align(
        alignment: Alignment.centerRight,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Semantics(
            key: const ValueKey('log-drawer'),
            role: SemanticsRole.dialog,
            scopesRoute: true,
            explicitChildNodes: true,
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: DifyColors.componentsPanelBg,
                borderRadius: BorderRadius.circular(DifyRadius.xl),
                border: bordered ? Border.all(color: DifyColors.componentsPanelBorder) : null,
                boxShadow: DifyShadows.xl,
              ),
              clipBehavior: Clip.antiAlias,
              child: DefaultTextStyle(
                style: difyTextStyle(DifyType.systemSmRegular, DifyColors.textSecondary),
                child: builder(dialogContext, () => Navigator.of(dialogContext).maybePop()),
              ),
            ),
          ),
        ),
      ),
    ),
  ),
);

// ---------------------------------------------------------------------------------------------------------------------
// EmptyElement
// ---------------------------------------------------------------------------------------------------------------------

/// log/empty-element.tsx `getWebAppType`: chat for every conversational mode, else the mode.
String webAppTypeOf(String mode) => mode != AppModes.completion && mode != AppModes.workflow ? AppModes.chat : mode;

/// log/empty-element.tsx: "Is anyone there?" (with the three-dots mark) in a `w-140 rounded-2xl` burn card, and the
/// text with its two links: [shareUrl] (the web app, `${app_base_url}/${type}/${access_token}`, a new tab) and
/// [testPath] (Dify's `getRedirectionPath`, opened with [onTest]).
class LogEmptyElement extends StatelessWidget {
  const LogEmptyElement({super.key, required this.shareUrl, required this.testPath, this.onShare, this.onTest});

  final String? shareUrl;
  final String testPath;

  /// Opens the share link (default: [openExternalUrl] of [shareUrl]).
  final VoidCallback? onShare;
  final VoidCallback? onTest;

  /// The share link's URL for an app's [site] (`app_base_url`, `access_token`) and [mode]; null without a site.
  static String? shareUrlOf(Map<String, Object?>? site, String mode) {
    if (site == null) return null;
    return '${site['app_base_url'] ?? ''}/${webAppTypeOf(mode)}/${site['access_token'] ?? ''}';
  }

  @override
  Widget build(BuildContext context) {
    final raw = _l('table.empty.element.content');
    final linkStyle = difyTextStyle(DifyType.systemSmRegular, DifyColors.utilColorsBlueBlue600);
    final spans = <InlineSpan>[];
    final tags = RegExp(r'<(shareLink|testLink)>(.*?)</\1>');
    var last = 0;
    for (final m in tags.allMatches(raw)) {
      spans.add(TextSpan(text: raw.substring(last, m.start)));
      final share = m.group(1) == 'shareLink';
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: _InlineLink(
            key: ValueKey(share ? 'log-empty-share-link' : 'log-empty-test-link'),
            text: m.group(2)!,
            url: share ? shareUrl : testPath,
            style: linkStyle,
            onTap: share ? (onShare ?? (shareUrl == null ? null : () => openExternalUrl(shareUrl!))) : onTest,
          ),
        ),
      );
      last = m.end;
    }
    spans.add(TextSpan(text: raw.substring(last)));
    final hasTags = last > 0;
    return Center(
      child: Container(
        key: const ValueKey('log-empty-element'),
        width: 560,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        decoration: BoxDecoration(
          color: DifyColors.backgroundSectionBurn,
          borderRadius: BorderRadius.circular(DifyRadius.xxl),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _l('table.empty.element.title'),
                  style: difyTextStyle(DifyType.systemMdSemibold, DifyColors.textSecondary),
                ),
                Transform.translate(
                  offset: const Offset(-6, -12),
                  child: SvgPicture.string(
                    _threeDotsSvg,
                    width: 16,
                    height: 16,
                    colorFilter: ColorFilter.mode(DifyColors.textSecondary, BlendMode.srcIn),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text.rich(
              TextSpan(children: hasTags ? spans : [TextSpan(text: raw)]),
              style: difyTextStyle(DifyType.systemSmRegular, DifyColors.textTertiary),
            ),
          ],
        ),
      ),
    );
  }
}

const _threeDotsSvg =
    '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg"><path d="M5 6.5V5M8.93934 '
    '7.56066L10 6.5M10.0103 11.5H11.5103" stroke="currentColor" stroke-width="2" stroke-linecap="round" '
    'stroke-linejoin="round"/></svg>';

class _InlineLink extends StatelessWidget {
  const _InlineLink({super.key, required this.text, required this.url, required this.style, this.onTap});
  final String text;
  final String? url;
  final TextStyle style;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => LogLink(
    url: url,
    label: text,
    onTap: onTap,
    builder: (hovered) => Text(text, style: style),
  );
}

/// A link (an anchor): its accessible name, its URL, a click and hover.
class LogLink extends StatefulWidget {
  const LogLink({super.key, required this.url, required this.label, required this.builder, this.onTap});
  final String? url;
  final String label;
  final VoidCallback? onTap;
  final Widget Function(bool hovered) builder;

  @override
  State<LogLink> createState() => _LogLinkState();
}

class _LogLinkState extends State<LogLink> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    link: true,
    linkUrl: widget.url == null ? null : Uri.tryParse(widget.url!),
    label: widget.label,
    onTap: widget.onTap,
    excludeSemantics: true,
    child: MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(onTap: widget.onTap, child: widget.builder(_hover)),
    ),
  );
}

// ---------------------------------------------------------------------------------------------------------------------
// VarPanel
// ---------------------------------------------------------------------------------------------------------------------

/// log/var-panel.tsx: a collapsible "Variables" card (`rounded-[10px] border border-divider-subtle bg-chat-bubble-bg`)
/// with a `{{label}} value` row per variable and the uploaded images (click to preview).
class LogVarPanel extends StatefulWidget {
  const LogVarPanel({super.key, required this.varList, this.messageFiles = const []});

  final List<({String label, String value})> varList;
  final List<String> messageFiles;

  @override
  State<LogVarPanel> createState() => _LogVarPanelState();
}

class _LogVarPanelState extends State<LogVarPanel> {
  bool _collapsed = false;

  void _preview(String url) => showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: _c('operation.close'),
    barrierColor: DifyColors.backgroundOverlay,
    pageBuilder: (ctx, _, _) => Stack(
      key: const ValueKey('var-panel-image-preview'),
      children: [
        Center(child: Image.network(url, errorBuilder: (_, _, _) => const SizedBox(width: 64, height: 64))),
        Positioned(
          top: 24,
          right: 24,
          child: DifyIconButton(
            label: _c('operation.close'),
            icon: RemixIcon('close-line', size: 16, color: DifyColors.textPrimaryOnSurface),
            onPressed: () => Navigator.of(ctx).pop(),
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      gradient: DifyGradients.chatBubbleBg,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: DifyColors.dividerSubtle),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DifyPressable(
          semanticLabel: _l('detail.variables'),
          onPressed: () => setState(() => _collapsed = !_collapsed),
          builder: (context, hovered, focused) => Container(
            padding: EdgeInsets.fromLTRB(12, 10, 12, _collapsed ? 10 : 8),
            decoration: BoxDecoration(
              border: _collapsed ? null : Border(bottom: BorderSide(color: DifyColors.dividerSubtle)),
            ),
            child: Row(
              spacing: 4,
              children: [
                DifyIcon('vender/solid/development/variable-02', size: 16, color: DifyColors.textSecondary),
                Expanded(
                  child: Text(
                    _l('detail.variables'),
                    style: difyTextStyle(DifyType.systemMdMedium, DifyColors.textSecondary),
                  ),
                ),
                RemixIcon(
                  _collapsed ? 'arrow-right-s-line' : 'arrow-down-s-line',
                  key: ValueKey(_collapsed ? 'var-panel-collapsed' : 'var-panel-expanded'),
                  size: 16,
                  color: DifyColors.textSecondary,
                ),
              ],
            ),
          ),
        ),
        if (!_collapsed)
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 500),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 8,
                children: [
                  for (final v in widget.varList)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 128,
                            child: DefaultTextStyle.merge(
                              style: difyTextStyle(DifyType.systemXsMedium, DifyColors.textAccent),
                              child: Row(
                                children: [
                                  const Opacity(opacity: 0.6, child: Text('{{')),
                                  Flexible(child: Text(v.label, maxLines: 1, overflow: TextOverflow.ellipsis)),
                                  const Opacity(opacity: 0.6, child: Text('}}')),
                                ],
                              ),
                            ),
                          ),
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.only(left: 10),
                              child: Text(
                                v.value,
                                style: difyTextStyle(DifyType.systemXsMedium, DifyColors.textSecondary),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (widget.messageFiles.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4, bottom: 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 128,
                            child: Text(
                              _l('detail.uploadImages'),
                              style: difyTextStyle(DifyType.systemXsMedium, DifyColors.textTertiary),
                            ),
                          ),
                          Wrap(
                            spacing: 8,
                            children: [
                              for (final (i, url) in widget.messageFiles.indexed)
                                GestureDetector(
                                  key: ValueKey('var-panel-image-$i'),
                                  onTap: () => _preview(url),
                                  child: Container(
                                    margin: const EdgeInsets.only(left: 10),
                                    width: 64,
                                    height: 64,
                                    clipBehavior: Clip.antiAlias,
                                    decoration: BoxDecoration(borderRadius: BorderRadius.circular(DifyRadius.lg)),
                                    child: Image.network(
                                      url,
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, _, _) => ColoredBox(color: DifyColors.backgroundSectionBurn),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ],
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
