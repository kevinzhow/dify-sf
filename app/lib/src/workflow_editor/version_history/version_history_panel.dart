/// The version history panel (web/app/components/workflow/panel/version-history-panel: index.tsx,
/// version-history-item.tsx, action-menu/*, filter/*, restore-confirm-modal.tsx, delete-confirm-modal.tsx, empty.tsx,
/// loading/*), opened by the header's Version History button while the editor browses versions (`isRestoring`).
///
/// The versions and what is done to them come from the host ([VersionHistoryPanelData]): Dify's version list query
/// and its restore / delete / update requests. Without a version list the panel shows the current draft alone. Cloud
/// billing (the sandbox plan's upgrade prompts) is not part of dify-sf.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../design/css_metrics.dart';
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';
import '../../workflow/dify_json.dart';
import '../header/publisher/summary_section.dart' show PublishedWorkflowInfo;
import '../header/publisher/utils.dart' show getWorkflowVersionName;
import '../header/publisher/version_info_modal.dart' show showVersionInfoModal, VersionInfoUpdate;
import '../header/titles.dart' show workflowVersionDraft;
import '../store/store.dart';

String _w(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('workflow', key, params);
String _c(String key) => DifyI18n.tr('common', key);

Map<String, Object?> _map(Object? x) => x is Map<String, Object?> ? x : const {};

/// `WorkflowVersion.Latest`.
const workflowVersionLatest = 'latest';

/// `VersionHistoryContextMenuOptions`.
enum VersionHistoryAction { restore, edit, exportDsl, copyId, delete }

/// `WorkflowVersionFilterOptions`.
enum WorkflowVersionFilter { all, onlyYours }

/// One entry of the action menu (`{ key, name, description, disabled }`).
typedef VersionHistoryMenuOption = ({VersionHistoryAction key, String name, String? description, bool disabled});

/// A page of the version list (`{ items, has_more }`).
typedef VersionHistoryPage = ({List<DifyJson> items, bool hasMore});

/// `HISTORY_PER_PAGE`.
const versionHistoryPerPage = 10;

/// A version's display name (`getWorkflowVersionName(item, defaultName)`).
String versionHistoryName(DifyJson item) => getWorkflowVersionName(
  markedName: item['marked_name'] as String?,
  versionNumber: (item['version_number'] as num?)?.toInt(),
  defaultName: _w('versionHistory.defaultName'),
);

/// version-history-item `formatVersion`: `draft`, `latest` for [latestVersionId], else the version as
/// `YYYY-MM-DD HH:mm:ss` (UTC) when it is a date, else as it is.
String formatWorkflowVersion(DifyJson item, String latestVersionId) {
  final version = '${item['version'] ?? ''}';
  if (version == workflowVersionDraft) return workflowVersionDraft;
  if (item['id'] == latestVersionId) return workflowVersionLatest;
  final date = DateTime.tryParse(version);
  if (date == null) return version;
  return date.toUtc().toIso8601String().substring(0, 19).replaceFirst('T', ' ');
}

/// `dayjs.unix(time).format('YYYY-MM-DD HH:mm')` (local time).
String formatVersionTime(num seconds) {
  final d = DateTime.fromMillisecondsSinceEpoch((seconds * 1000).round());
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
}

/// `useActionMenu`: restore, edit (named "Edit version info" for a named version, else "Name this version"),
/// export (with the DSL permission, not for pipelines), copy id (the id as its description); and delete.
({VersionHistoryMenuOption deleteOperation, List<VersionHistoryMenuOption> options}) versionHistoryActionMenu({
  required String workflowId,
  required bool isNamedVersion,
  required bool canImportExportDsl,
  bool isPipeline = false,
}) => (
  deleteOperation: (key: VersionHistoryAction.delete, name: _c('operation.delete'), description: null, disabled: false),
  options: [
    (key: VersionHistoryAction.restore, name: _w('common.restore'), description: null, disabled: false),
    (
      key: VersionHistoryAction.edit,
      name: isNamedVersion ? _w('versionHistory.editVersionInfo') : _w('versionHistory.nameThisVersion'),
      description: null,
      disabled: false,
    ),
    if (canImportExportDsl && !isPipeline)
      (key: VersionHistoryAction.exportDsl, name: DifyI18n.tr('app', 'export'), description: null, disabled: false),
    (key: VersionHistoryAction.copyId, name: _w('versionHistory.copyId'), description: workflowId, disabled: false),
  ],
);

/// `useFilterOptions`.
List<({WorkflowVersionFilter key, String name})> versionHistoryFilterOptions() => [
  (key: WorkflowVersionFilter.all, name: _w('versionHistory.filter.all')),
  (key: WorkflowVersionFilter.onlyYours, name: _w('versionHistory.filter.onlyYours')),
];

// ---- filter ------------------------------------------------------------------------------------------------------

/// FilterItem: `rounded-lg px-2 py-1.5` with the name (`system-md-regular`) and, when selected, `check-line`.
class VersionHistoryFilterItem extends StatelessWidget {
  const VersionHistoryFilterItem({super.key, required this.item, this.isSelected = false, required this.onClick});
  final ({WorkflowVersionFilter key, String name}) item;
  final bool isSelected;
  final ValueChanged<WorkflowVersionFilter> onClick;

  @override
  Widget build(BuildContext context) => Semantics(
    selected: isSelected,
    child: DifyPressable(
      semanticLabel: item.name,
      onPressed: () => onClick(item.key),
      builder: (context, hovered, focused) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: hovered ? DifyColors.stateBaseHover : null,
          borderRadius: BorderRadius.circular(DifyRadius.lg),
          boxShadow: difyFocusRing(focused),
        ),
        child: Row(
          spacing: 4,
          children: [
            Expanded(child: DifyText(item.name, DifyType.systemMdRegular, color: DifyColors.textPrimary)),
            if (isSelected) RemixIcon('check-line', size: 16, color: DifyColors.textAccent),
          ],
        ),
      ),
    ),
  );
}

/// FilterSwitch: "Only show named versions" and a switch.
class VersionHistoryFilterSwitch extends StatelessWidget {
  const VersionHistoryFilterSwitch({super.key, required this.enabled, required this.handleSwitch});
  final bool enabled;
  final ValueChanged<bool> handleSwitch;

  @override
  Widget build(BuildContext context) {
    final label = _w('versionHistory.filter.onlyShowNamedVersions');
    return Padding(
      padding: const EdgeInsets.all(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          spacing: 4,
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: DifyText(label, DifyType.systemMdRegular, color: DifyColors.textSecondary),
              ),
            ),
            DifySwitch(checked: enabled, onCheckedChange: handleSwitch, semanticLabel: label),
          ],
        ),
      ),
    );
  }
}

/// Filter: the `filter-3-line` trigger (`size-6 rounded-md`, `bg-state-accent-active-alt` and an accent icon while a
/// filter is on) opening a `w-62` popover with the filter options and the named-only switch.
class VersionHistoryFilter extends StatefulWidget {
  const VersionHistoryFilter({
    super.key,
    required this.filterValue,
    required this.isOnlyShowNamedVersions,
    required this.onClickFilterItem,
    required this.handleSwitch,
  });
  final WorkflowVersionFilter filterValue;
  final bool isOnlyShowNamedVersions;
  final ValueChanged<WorkflowVersionFilter> onClickFilterItem;
  final ValueChanged<bool> handleSwitch;

  /// Whether a filter is on (the trigger's active look).
  bool get isFiltering => filterValue != WorkflowVersionFilter.all || isOnlyShowNamedVersions;

  @override
  State<VersionHistoryFilter> createState() => _VersionHistoryFilterState();
}

class _VersionHistoryFilterState extends State<VersionHistoryFilter> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final filtering = w.isFiltering;
    return DifyPopover(
      open: _open,
      onOpenChange: (v) => setState(() => _open = v),
      placement: DifyPlacement.bottomEnd,
      sideOffset: 4,
      alignOffset: 55,
      surface: false,
      builder: (context, c) => DifyPressable(
        key: const Key('version-history-filter'),
        semanticLabel: _w('versionHistory.filter.all'),
        onPressed: () => setState(() => _open = !_open),
        builder: (context, hovered, _) => Container(
          width: 24,
          height: 24,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: filtering ? DifyColors.stateAccentActiveAlt : (hovered ? DifyColors.stateBaseHover : null),
            borderRadius: BorderRadius.circular(DifyRadius.md),
          ),
          child: RemixIcon(
            'filter-3-line',
            size: 16,
            color: filtering ? DifyColors.textAccent : DifyColors.textTertiary,
          ),
        ),
      ),
      content: Container(
        width: 248,
        decoration: BoxDecoration(
          color: DifyColors.componentsPanelBgBlur,
          borderRadius: BorderRadius.circular(DifyRadius.xl),
          border: Border.all(color: DifyColors.componentsPanelBorder, width: Css.hairline),
          boxShadow: DifyShadows.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final o in versionHistoryFilterOptions())
                    VersionHistoryFilterItem(
                      item: o,
                      isSelected: w.filterValue == o.key,
                      onClick: w.onClickFilterItem,
                    ),
                ],
              ),
            ),
            SizedBox(height: 1, child: ColoredBox(color: DifyColors.dividerSubtle)),
            VersionHistoryFilterSwitch(enabled: w.isOnlyShowNamedVersions, handleSwitch: w.handleSwitch),
          ],
        ),
      ),
    );
  }
}

// ---- action menu -------------------------------------------------------------------------------------------------

/// ActionMenuItem: `justify-between gap-x-3 px-2 py-1.5` with the name (`system-md-regular`) and, for copy id, the id
/// under it (`system-2xs-regular text-text-tertiary`, `max-w-38` truncated); destructive in red.
class VersionHistoryActionMenuItem extends StatelessWidget {
  const VersionHistoryActionMenuItem({
    super.key,
    required this.item,
    required this.onClick,
    this.isDestructive = false,
  });
  final VersionHistoryMenuOption item;
  final ValueChanged<VersionHistoryAction> onClick;
  final bool isDestructive;

  @override
  Widget build(BuildContext context) {
    final description = item.description;
    return DifyMenuItem(
      semanticLabel: item.name,
      autoHeight: description != null,
      disabled: item.disabled,
      variant: isDestructive ? DifyMenuItemVariant.destructive : DifyMenuItemVariant.normal,
      onSelect: () => onClick(item.key),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: description == null
            ? Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis)
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 2,
                children: [
                  Text(
                    item.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: DifyColors.textSecondary),
                  ),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 152),
                    child: DifyText(description, DifyType.system2xsRegular, color: DifyColors.textTertiary),
                  ),
                ],
              ),
      ),
    );
  }
}

/// ActionMenu: the `more-fill` icon button (secondary, `md`) opening the options, then a separator and Delete (when
/// [isShowDelete]), `bottom-end` 4 px below.
class VersionHistoryActionMenu extends StatelessWidget {
  const VersionHistoryActionMenu({
    super.key,
    required this.workflowId,
    required this.isShowDelete,
    required this.isNamedVersion,
    required this.canImportExportDsl,
    required this.open,
    required this.setOpen,
    required this.handleClickActionMenuItem,
    this.isPipeline = false,
    this.focusNode,
  });

  final String workflowId;
  final bool isShowDelete, isNamedVersion, canImportExportDsl, open, isPipeline;
  final ValueChanged<bool> setOpen;
  final ValueChanged<VersionHistoryAction> handleClickActionMenuItem;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final menu = versionHistoryActionMenu(
      workflowId: workflowId,
      isNamedVersion: isNamedVersion,
      canImportExportDsl: canImportExportDsl,
      isPipeline: isPipeline,
    );
    return DifyDropdownMenu(
      open: open,
      onOpenChange: setOpen,
      placement: DifyPlacement.bottomEnd,
      sideOffset: 4,
      builder: (context, c) => DifyIconButton(
        label: _c('operation.more'),
        variant: DifyButtonVariant.secondary,
        focusNode: focusNode,
        onPressed: () => setOpen(!open),
        icon: RemixIcon('more-fill', size: 16, color: DifyColors.componentsButtonSecondaryText),
      ),
      children: [
        for (final o in menu.options) VersionHistoryActionMenuItem(item: o, onClick: handleClickActionMenuItem),
        if (isShowDelete) ...[
          const DifyMenuSeparator(),
          VersionHistoryActionMenuItem(
            item: menu.deleteOperation,
            isDestructive: true,
            onClick: (_) => handleClickActionMenuItem(VersionHistoryAction.delete),
          ),
        ],
      ],
    );
  }
}

// ---- item --------------------------------------------------------------------------------------------------------

/// VersionHistoryItem: a `rounded-lg p-2` row (selected `bg-state-accent-active`, else hover) over the timeline (a
/// dot, and a line down to the next item unless [isLast]): the name ("Current Draft" for the draft) with a Latest
/// badge, the release notes, "time · creator" and the environments it is deployed to; the action menu on hover, focus
/// or right-click (not for the draft). The draft selects itself once mounted.
class VersionHistoryItem extends StatefulWidget {
  const VersionHistoryItem({
    super.key,
    required this.item,
    required this.currentVersion,
    required this.latestVersionId,
    required this.onClick,
    required this.handleClickActionMenuItem,
    required this.canImportExportDsl,
    required this.isLast,
    this.hideActionMenu = false,
    this.isPipeline = false,
  });

  final DifyJson item;
  final DifyJson? currentVersion;
  final String latestVersionId;
  final ValueChanged<DifyJson> onClick;
  final ValueChanged<VersionHistoryAction> handleClickActionMenuItem;
  final bool canImportExportDsl, isLast, hideActionMenu, isPipeline;

  @override
  State<VersionHistoryItem> createState() => _VersionHistoryItemState();
}

class _VersionHistoryItemState extends State<VersionHistoryItem> {
  bool _open = false, _hovered = false, _focusWithin = false;

  String get _formatted => formatWorkflowVersion(widget.item, widget.latestVersionId);
  bool get _isDraft => _formatted == workflowVersionDraft;

  @override
  void initState() {
    super.initState();
    if (_isDraft) WidgetsBinding.instance.addPostFrameCallback((_) => mounted ? widget.onClick(widget.item) : null);
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final item = w.item;
    final isSelected = item['version'] == w.currentVersion?['version'];
    final isDraft = _isDraft;
    final isLatest = _formatted == workflowVersionLatest;
    final environments = [for (final e in jsList(item['environments'])) _map(e)];
    final title = isDraft ? _w('versionHistory.currentDraft') : versionHistoryName(item);
    final comment = '${item['marked_comment'] ?? ''}';
    final creator = '${_map(item['created_by'])['name'] ?? ''}';
    final showMenu = !w.hideActionMenu && !isDraft;
    final content = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 4,
      children: [
        SizedBox(
          width: 18,
          height: 20,
          child: Center(
            child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(DifyRadius.lg),
                border: Border.all(
                  color: isSelected ? DifyColors.textAccent : DifyColors.textQuaternary,
                  width: 2,
                ),
              ),
            ),
          ),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 2,
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 24),
                child: SizedBox(
                  height: 20,
                  child: Row(
                    spacing: 4,
                    children: [
                      Flexible(
                        child: DifyText(
                          title,
                          DifyType.systemSmSemibold,
                          color: isSelected ? DifyColors.textAccent : DifyColors.textSecondary,
                        ),
                      ),
                      if (isLatest)
                        Flexible(
                          child: Container(
                            height: 20,
                            padding: const EdgeInsets.symmetric(horizontal: 5),
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: DifyColors.componentsBadgeBgDimm,
                              borderRadius: BorderRadius.circular(DifyRadius.md),
                              border: Border.all(color: DifyColors.textAccentSecondary),
                            ),
                            child: DifyText(
                              _w('versionHistory.latest').toUpperCase(),
                              DifyType.system2xsMediumUppercase,
                              color: DifyColors.textAccentSecondary,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              if (!isDraft) ...[
                DifyText(comment, DifyType.systemXsRegular, color: DifyColors.textSecondary, maxLines: null),
                DifyText(
                  '${formatVersionTime((item['created_at'] as num?) ?? 0)} · $creator',
                  DifyType.systemXsRegular,
                  color: DifyColors.textTertiary,
                ),
                if (environments.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Wrap(
                      spacing: 4,
                      runSpacing: 8,
                      children: [
                        for (final e in environments)
                          Container(
                            height: 18,
                            constraints: const BoxConstraints(minWidth: 18),
                            padding: const EdgeInsets.symmetric(horizontal: 5),
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: DifyColors.componentsBadgeBgDimm,
                              borderRadius: BorderRadius.circular(5),
                              border: Border.all(color: DifyColors.dividerDeep),
                            ),
                            child: DifyText(
                              '${e['name'] ?? ''}',
                              DifyType.system2xsMedium,
                              color: DifyColors.textTertiary,
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ],
          ),
        ),
      ],
    );
    final row = Stack(
      children: [
        if (!w.isLast)
          Positioned(
            top: 24,
            left: 16 - 8,
            bottom: -12,
            width: 2,
            child: IgnorePointer(child: ColoredBox(color: DifyColors.dividerSubtle)),
          ),
        // The whole row is the version's button (`absolute inset-0`), named by its title.
        Positioned.fill(
          child: Semantics(
            label: title,
            button: true,
            selected: isSelected,
            child: DifyPressable(
              key: ValueKey('version-${item['id']}'),
              onPressed: () {
                if (isSelected) return;
                w.onClick(item);
              },
              builder: (context, hovered, focused) => Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(DifyRadius.lg),
                  boxShadow: difyFocusRing(focused),
                ),
              ),
            ),
          ),
        ),
        IgnorePointer(child: ExcludeSemantics(child: content)),
        if (showMenu && (_hovered || _focusWithin || _open))
          Positioned(
            top: 4 - 8,
            right: 4 - 8,
            child: VersionHistoryActionMenu(
              workflowId: '${item['id']}',
              isShowDelete: !isLatest,
              isNamedVersion: '${item['marked_name'] ?? ''}'.isNotEmpty,
              canImportExportDsl: w.canImportExportDsl,
              isPipeline: w.isPipeline,
              open: _open,
              setOpen: (v) => setState(() => _open = v),
              handleClickActionMenuItem: w.handleClickActionMenuItem,
            ),
          ),
      ],
    );
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() {
        _hovered = false;
        _open = false;
      }),
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onFocusChange: (f) => setState(() => _focusWithin = f),
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onSecondaryTap: showMenu ? () => setState(() => _open = true) : null,
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: isSelected ? DifyColors.stateAccentActive : (_hovered ? DifyColors.stateBaseHover : null),
              borderRadius: BorderRadius.circular(DifyRadius.lg),
            ),
            child: row,
          ),
        ),
      ),
    );
  }
}

// ---- confirm dialogs ---------------------------------------------------------------------------------------------

/// The alert dialog of a version action (`title-2xl-semi-bold` "`action` `name`", the tip, Cancel and the action).
class VersionConfirmDialog extends StatelessWidget {
  const VersionConfirmDialog({
    super.key,
    required this.title,
    required this.description,
    required this.confirmText,
    required this.onCancel,
    required this.onConfirm,
    this.destructive = false,
  });

  final String title, description, confirmText;
  final VoidCallback onCancel, onConfirm;
  final bool destructive;

  /// AlertDialogContent `border-none shadow-xl`, the title and description wrapping.
  @override
  Widget build(BuildContext context) => DifyAlertDialog(
    bordered: false,
    shadow: DifyShadows.xl,
    title: title,
    titleMaxLines: null,
    description: description,
    descriptionColor: DifyColors.textSecondary,
    cancelLabel: _c('operation.cancel'),
    confirmLabel: confirmText,
    confirmTone: destructive ? DifyButtonTone.destructive : DifyButtonTone.normal,
    onCancel: onCancel,
    onConfirm: onConfirm,
  );
}

/// RestoreConfirmModal: "Restore `name`" with the restoration tip; Restore hands [versionInfo] to [onRestore].
class RestoreConfirmModal extends StatelessWidget {
  const RestoreConfirmModal({super.key, required this.versionInfo, required this.onClose, required this.onRestore});
  final DifyJson versionInfo;
  final VoidCallback onClose;
  final ValueChanged<DifyJson> onRestore;

  @override
  Widget build(BuildContext context) => VersionConfirmDialog(
    title: '${_w('common.restore')} ${versionHistoryName(versionInfo)}',
    description: _w('versionHistory.restorationTip'),
    confirmText: _w('common.restore'),
    onCancel: onClose,
    onConfirm: () => onRestore(versionInfo),
  );
}

/// DeleteConfirmModal: "Delete `name`" with the deletion tip; Delete hands the version's id to [onDelete].
class DeleteConfirmModal extends StatelessWidget {
  const DeleteConfirmModal({super.key, required this.versionInfo, required this.onClose, required this.onDelete});
  final DifyJson versionInfo;
  final VoidCallback onClose;
  final ValueChanged<String> onDelete;

  @override
  Widget build(BuildContext context) => VersionConfirmDialog(
    title: '${_c('operation.delete')} ${versionHistoryName(versionInfo)}',
    description: _w('versionHistory.deletionTip'),
    confirmText: _c('operation.delete'),
    destructive: true,
    onCancel: onClose,
    onConfirm: () => onDelete('${versionInfo['id']}'),
  );
}

Future<void> _showDialog(BuildContext context, WidgetBuilder builder) =>
    showDifyAlertDialog<void>(context, dismissible: true, builder: builder);

// ---- empty and loading -------------------------------------------------------------------------------------------

/// Empty: `history-line` (40 px), "No versions" and Reset filter.
class VersionHistoryEmpty extends StatelessWidget {
  const VersionHistoryEmpty({super.key, required this.onResetFilter});
  final VoidCallback onResetFilter;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 48),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      spacing: 8,
      children: [
        RemixIcon('history-line', size: 40, color: DifyColors.textEmptyStateIcon),
        DifyText(_w('versionHistory.filter.empty'), DifyType.systemXsRegular, color: DifyColors.textTertiary),
        DifyButton(
          size: DifyButtonSize.small,
          onPressed: onResetFilter,
          child: Text(_w('versionHistory.filter.reset')),
        ),
      ],
    ),
  );
}

/// Loading: eight placeholder rows under a fading mask.
class VersionHistoryLoading extends StatelessWidget {
  const VersionHistoryLoading({super.key});

  @override
  Widget build(BuildContext context) {
    // `h-2 w-* rounded-xs bg-text-quaternary opacity-20` (SkeletonRectangle's look without its margin).
    Widget bar(double width, double height) =>
        DifySkeletonRectangle(widthFactor: width, height: height, margin: EdgeInsets.zero);
    return Column(
      key: const Key('version-history-loading'),
      children: [
        for (var i = 0; i < 8; i++)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 4,
              children: [
                SizedBox(
                  width: 18,
                  height: 20,
                  child: Center(
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(DifyRadius.lg),
                        border: Border.all(color: DifyColors.textQuaternary, width: 2),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: Column(
                    spacing: 2,
                    children: [
                      SizedBox(height: 14, child: Center(child: bar((i + 1).isEven ? 1 / 3 : 2 / 5, 8))),
                      if (i > 0) SizedBox(height: 12, child: Center(child: bar((i + 1).isEven ? 3 / 4 : 4 / 6, 6))),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

// ---- the panel ---------------------------------------------------------------------------------------------------

/// What the panel needs from the host: the version list (Dify's `useWorkflowVersionHistory`), the restore, delete and
/// update requests, the DSL export, and the editor's useWorkflowRun / refresh-draft / last-run hooks.
class VersionHistoryPanelData {
  const VersionHistoryPanelData({
    this.fetchVersions,
    this.restoreVersion,
    this.deleteVersion,
    this.updateVersion,
    this.exportDsl,
    this.handleRestoreFromPublishedWorkflow,
    this.handleLoadBackupDraft,
    this.handleRefreshWorkflowDraft,
    this.invalidAllLastRun,
    this.invalidateAppWorkflow,
    this.latestVersionId,
    this.currentUserId = '',
    this.canImportExportDsl = true,
    this.isPipeline = false,
    this.toast,
    this.copyText,
  });

  /// A page of versions (1-based [page], [limit] per page; [userId] for "only yours", [namedOnly]); null: the list is
  /// the current draft alone.
  final Future<VersionHistoryPage> Function({
    required int page,
    required int limit,
    required String userId,
    required bool namedOnly,
  })?
  fetchVersions;

  /// `restoreWorkflow(restoreVersionUrl(id))`, `deleteWorkflow(deleteVersionUrl(id))`,
  /// `updateWorkflow({ url: updateVersionUrl(id), title, releaseNotes })`; each throws when refused.
  final Future<void> Function(String versionId)? restoreVersion;
  final Future<void> Function(String versionId)? deleteVersion;
  final Future<void> Function(String versionId, {required String title, required String releaseNotes})? updateVersion;

  /// `handleExportDSL(false, versionId)`.
  final void Function(String versionId)? exportDsl;

  /// useWorkflowRun's handleRestoreFromPublishedWorkflow (show the version) and handleLoadBackupDraft (bring back the
  /// draft); useWorkflowRefreshDraft; useInvalidAllLastRun; useInvalidateAppWorkflow (after editing the latest
  /// version).
  final void Function(DifyJson version)? handleRestoreFromPublishedWorkflow;
  final VoidCallback? handleLoadBackupDraft;
  final VoidCallback? handleRefreshWorkflowDraft;
  final VoidCallback? invalidAllLastRun;
  final VoidCallback? invalidateAppWorkflow;

  /// The app's latest published version (its Latest badge, no Delete).
  final String? latestVersionId;

  /// The signed-in user (the "only yours" filter).
  final String currentUserId;
  final bool canImportExportDsl;

  /// A RAG pipeline (no per-version DSL export).
  final bool isPipeline;

  /// Shows a toast; the app's toast host by default.
  final void Function(DifyToastType type, String message)? toast;

  /// Copies a version id; the clipboard by default.
  final Future<void> Function(String text)? copyText;
}

/// VersionHistoryPanel: `w-67` (`rounded-l-2xl`, panel border and `shadow-xl`): "Version History" with the filter and
/// close, the versions (ten per page, "Load more" while there are more), and the restore / delete / version info
/// dialogs.
class VersionHistoryPanel extends StatefulWidget {
  const VersionHistoryPanel({super.key, this.data = const VersionHistoryPanelData()});
  final VersionHistoryPanelData data;

  @override
  State<VersionHistoryPanel> createState() => VersionHistoryPanelState();
}

class VersionHistoryPanelState extends State<VersionHistoryPanel> {
  WorkflowVersionFilter _filterValue = WorkflowVersionFilter.all;
  bool _onlyNamed = false;
  final _pages = <List<DifyJson>>[];
  bool _hasNextPage = false, _isFetching = false;
  int _query = 0;

  VersionHistoryPanelData get _data => widget.data;

  @override
  void initState() {
    super.initState();
    _reset();
  }

  void _toast(DifyToastType type, String message) => (_data.toast ?? difyToast)(type, message);

  /// `useResetWorkflowVersionHistory` / a new filter: the list from its first page.
  void _reset() {
    _pages.clear();
    _hasNextPage = false;
    _fetch(1);
  }

  Future<void> _fetch(int page) async {
    final fetch = _data.fetchVersions;
    if (fetch == null) {
      setStateIfMounted(() {
        _pages
          ..clear()
          ..add([
            {'id': workflowVersionDraft, 'version': workflowVersionDraft},
          ]);
      });
      return;
    }
    final query = ++_query;
    setStateIfMounted(() => _isFetching = true);
    try {
      final r = await fetch(
        page: page,
        limit: versionHistoryPerPage,
        userId: _filterValue == WorkflowVersionFilter.onlyYours ? _data.currentUserId : '',
        namedOnly: _onlyNamed,
      );
      if (query != _query || !mounted) return;
      setState(() {
        if (page == 1) _pages.clear();
        _pages.add(r.items);
        _hasNextPage = r.hasMore;
      });
    } catch (_) {
      // The query keeps what it had.
    } finally {
      if (query == _query) setStateIfMounted(() => _isFetching = false);
    }
  }

  void setStateIfMounted(VoidCallback fn) {
    if (mounted) setState(fn);
  }

  /// `handleVersionClick`.
  void _onVersionClick(DifyJson item) {
    final store = WorkflowStoreScope.of(context);
    if (item['id'] == store.currentVersion.value?['id']) return;
    store.setCurrentVersion(item);
    if (item['version'] == workflowVersionDraft) {
      _data.handleLoadBackupDraft?.call();
    } else {
      _data.handleRestoreFromPublishedWorkflow?.call(item);
    }
  }

  /// `handleNextPage`.
  void _nextPage() {
    if (_hasNextPage && !_isFetching) _fetch(_pages.length + 1);
  }

  /// `handleClose`.
  void _close() {
    final store = WorkflowStoreScope.of(context);
    _data.handleLoadBackupDraft?.call();
    store
      ..isRestoring.value = false
      ..setShowWorkflowVersionHistoryPanel(false);
  }

  void _setFilter(WorkflowVersionFilter v) {
    setState(() => _filterValue = v);
    _reset();
  }

  void _setOnlyNamed(bool v) {
    setState(() => _onlyNamed = v);
    _reset();
  }

  void _resetFilter() {
    setState(() {
      _filterValue = WorkflowVersionFilter.all;
      _onlyNamed = false;
    });
    _reset();
  }

  /// `handleClickActionMenuItem`.
  Future<void> _onAction(DifyJson item, VersionHistoryAction action) async {
    if (action == VersionHistoryAction.delete && jsList(item['environments']).isNotEmpty) {
      _toast(DifyToastType.error, _w('versionHistory.action.deleteDeployedVersionError'));
      return;
    }
    switch (action) {
      case VersionHistoryAction.restore:
        await _showDialog(
          context,
          (context) => RestoreConfirmModal(
            versionInfo: item,
            onClose: () => Navigator.of(context).pop(),
            onRestore: (v) {
              Navigator.of(context).pop();
              _restore(v);
            },
          ),
        );
      case VersionHistoryAction.edit:
        await showVersionInfoModal(
          context,
          versionInfo: PublishedWorkflowInfo.fromJson(item),
          onPublish: _updateVersion,
          onToast: _toast,
        );
      case VersionHistoryAction.delete:
        await _showDialog(
          context,
          (context) => DeleteConfirmModal(
            versionInfo: item,
            onClose: () => Navigator.of(context).pop(),
            onDelete: (id) {
              Navigator.of(context).pop();
              _delete(id);
            },
          ),
        );
      case VersionHistoryAction.copyId:
        final id = '${item['id']}';
        await (_data.copyText ?? (t) => Clipboard.setData(ClipboardData(text: t)))(id);
        _toast(DifyToastType.success, _w('versionHistory.action.copyIdSuccess'));
      case VersionHistoryAction.exportDsl:
        if (!_data.canImportExportDsl) return;
        _data.exportDsl?.call('${item['id']}');
    }
  }

  /// `handleRestore`: the panel closes; on success the version is current, browsing ends without a backup draft, the
  /// draft is reloaded; a failure keeps the browsing state.
  Future<void> _restore(DifyJson item) async {
    final store = WorkflowStoreScope.of(context);
    store.setShowWorkflowVersionHistoryPanel(false);
    try {
      await _data.restoreVersion?.call('${item['id']}');
      store
        ..setCurrentVersion(item)
        ..isRestoring.value = false
        ..backupDraft.value = null;
      _data.handleRefreshWorkflowDraft?.call();
      _toast(DifyToastType.success, _w('versionHistory.action.restoreSuccess'));
      store.deleteAllInspectVars();
      _data.invalidAllLastRun?.call();
    } catch (_) {
      _toast(DifyToastType.error, _w('versionHistory.action.restoreFailure'));
    } finally {
      if (mounted) _reset();
    }
  }

  /// `handleDelete`.
  Future<void> _delete(String id) async {
    final store = WorkflowStoreScope.of(context);
    try {
      await _data.deleteVersion?.call(id);
      _toast(DifyToastType.success, _w('versionHistory.action.deleteSuccess'));
      if (mounted) _reset();
      store.deleteAllInspectVars();
      _data.invalidAllLastRun?.call();
    } catch (_) {
      _toast(DifyToastType.error, _w('versionHistory.action.deleteFailure'));
    }
  }

  /// `handleUpdateWorkflow`: after editing the latest version the app's published workflow is refetched.
  Future<void> _updateVersion(VersionInfoUpdate u) async {
    final id = u.id ?? '';
    try {
      await _data.updateVersion?.call(id, title: u.title, releaseNotes: u.releaseNotes);
      _toast(DifyToastType.success, _w('versionHistory.action.updateSuccess'));
      if (id == _data.latestVersionId) _data.invalidateAppWorkflow?.call();
      if (mounted) _reset();
    } catch (_) {
      _toast(DifyToastType.error, _w('versionHistory.action.updateFailure'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = WorkflowStoreScope.of(context);
    final items = [for (final p in _pages) ...p];
    return Container(
      width: 268,
      decoration: BoxDecoration(
        color: DifyColors.componentsPanelBg,
        borderRadius: const BorderRadius.horizontal(left: Radius.circular(DifyRadius.xxl)),
        border: Border(
          top: BorderSide(color: DifyColors.componentsPanelBorder, width: Css.hairline),
          bottom: BorderSide(color: DifyColors.componentsPanelBorder, width: Css.hairline),
          left: BorderSide(color: DifyColors.componentsPanelBorder, width: Css.hairline),
        ),
        boxShadow: DifyShadows.xl,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Row(
              spacing: 8,
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: DifyText(
                      _w('versionHistory.title'),
                      DifyType.systemXlSemibold,
                      color: DifyColors.textPrimary,
                    ),
                  ),
                ),
                VersionHistoryFilter(
                  filterValue: _filterValue,
                  isOnlyShowNamedVersions: _onlyNamed,
                  onClickFilterItem: _setFilter,
                  handleSwitch: _setOnlyNamed,
                ),
                Container(
                  width: 1,
                  height: 14,
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  color: DifyColors.dividerRegular,
                ),
                DifyPressable(
                  semanticLabel: _c('operation.close'),
                  onPressed: _close,
                  builder: (context, hovered, focused) => Container(
                    width: 24,
                    height: 24,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: hovered ? DifyColors.stateBaseHover : null,
                      borderRadius: BorderRadius.circular(DifyRadius.sm),
                    ),
                    child: RemixIcon('close-line', size: 16, color: DifyColors.textTertiary),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ValueListenableBuilder(
              valueListenable: store.currentVersion,
              builder: (context, current, _) => ListView(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                children: [
                  if (_isFetching && _pages.isEmpty)
                    const VersionHistoryLoading()
                  else ...[
                    for (final (i, item) in items.indexed)
                      VersionHistoryItem(
                        key: ValueKey('${item['id']}'),
                        item: item,
                        currentVersion: current,
                        latestVersionId: _data.latestVersionId ?? '',
                        onClick: _onVersionClick,
                        handleClickActionMenuItem: (a) => _onAction(item, a),
                        canImportExportDsl: _data.canImportExportDsl,
                        isPipeline: _data.isPipeline,
                        isLast: i == items.length - 1,
                      ),
                    if (!_isFetching && items.isEmpty) VersionHistoryEmpty(onResetFilter: _resetFilter),
                  ],
                ],
              ),
            ),
          ),
          if (_hasNextPage)
            Padding(
              padding: const EdgeInsets.all(8),
              child: DifyPressable(
                semanticLabel: _w('common.loadMore'),
                disabled: _isFetching,
                onPressed: _nextPage,
                builder: (context, hovered, focused) => Container(
                  decoration: BoxDecoration(
                    color: hovered ? DifyColors.stateBaseHover : null,
                    borderRadius: BorderRadius.circular(DifyRadius.sm),
                  ),
                  child: Row(
                    spacing: 4,
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(2),
                        child: RemixIcon(
                          _isFetching ? 'loader-2-line' : 'arrow-down-double-line',
                          size: 14,
                          color: DifyColors.textAccent,
                        ),
                      ),
                      Flexible(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 1),
                          child: DifyText(
                            _w('common.loadMore').toUpperCase(),
                            DifyType.systemXsMediumUppercase,
                            color: DifyColors.textAccent,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The version history panel while the store says it is shown (`showWorkflowVersionHistoryPanel`).
class VersionHistoryPanelHost extends StatelessWidget {
  const VersionHistoryPanelHost({super.key, this.data = const VersionHistoryPanelData()});
  final VersionHistoryPanelData data;

  @override
  Widget build(BuildContext context) {
    final store = WorkflowStoreScope.of(context);
    return ValueListenableBuilder(
      valueListenable: store.showWorkflowVersionHistoryPanel,
      builder: (context, show, _) => show ? VersionHistoryPanel(data: data) : const SizedBox.shrink(),
    );
  }
}
