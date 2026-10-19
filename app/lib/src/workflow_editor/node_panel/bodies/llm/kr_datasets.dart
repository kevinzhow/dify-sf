/// The Knowledge Retrieval panel's knowledge bases (nodes/knowledge-retrieval/components/dataset-list.tsx,
/// dataset-item.tsx, add-dataset.tsx and app/configuration/dataset-config/select-dataset/index.tsx).
library;

import 'package:flutter/widgets.dart';

import '../../../../cards/card_kit.dart';
import '../../../../cards/model_chip.dart' show FeatureIcon;
import '../../../../design/css_metrics.dart';
import '../../../../design/dify_icon.dart';
import '../../../../design/dify_tokens.g.dart';
import '../../../../design/widgets/widgets.dart';
import '../../../../i18n/dify_i18n.dart';
import '../../../../workflow/dify_json.dart';
import '../../../../workflow/model_catalog.dart' show ModelFeatureEnum;
import '../../../panel_fields/panel_fields.dart';
import 'group_host.dart';
import 'kr_config.dart';
import 'llm_vars.dart' show jsMap;

String _w(String key) => DifyI18n.tr('workflow', key);
String _c(String key) => DifyI18n.tr('common', key);
String _d(String key) => DifyI18n.tr('dataset', key);
String _ad(String key) => DifyI18n.tr('app-debug', key);

Color _hex(Object? s, Color fallback) {
  final v = s is String && s.startsWith('#') ? s.substring(1) : null;
  if (v == null || (v.length != 6 && v.length != 8)) return fallback;
  final n = int.tryParse(v, radix: 16);
  if (n == null) return fallback;
  return Color(v.length == 6 ? 0xFF000000 | n : n);
}

/// AppIcon of a dataset's `icon_info` (emoji on its background, or the image), Dify's fallback 📙 on #FFF4ED.
class DatasetIcon extends StatelessWidget {
  const DatasetIcon({super.key, required this.iconInfo, this.size = 24});
  final Object? iconInfo;

  /// `tiny` 24 (`rounded-md text-base`), `xs` 16 (`rounded-sm text-xs`).
  final double size;

  @override
  Widget build(BuildContext context) {
    final info = iconInfo is Map
        ? jsMap(iconInfo)
        : const {'icon': '📙', 'icon_type': 'emoji', 'icon_background': '#FFF4ED'};
    final isImage = info['icon_type'] == 'image';
    final url = jsStr(info['icon_url']);
    final radius = size >= 24 ? DifyRadius.md : DifyRadius.sm;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: isImage ? null : _hex(info['icon_background'], const Color(0xFFFFEAD5)),
        borderRadius: BorderRadius.circular(radius),
      ),
      child: isImage && url != null && url.isNotEmpty
          ? Image.network(
              url,
              width: size,
              height: size,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => const SizedBox(),
            )
          : Text(jsStr(info['icon']) ?? '', style: TextStyle(fontSize: size >= 24 ? 16 : 12, height: 1)),
    );
  }
}

/// The badges a dataset shows (dataset-item.tsx, select-dataset): the vision icon for multimodal datasets, the
/// indexing technique and method, "External".
List<Widget> datasetBadges(Json d) => [
  if (d['is_multimodal'] == true)
    const Padding(padding: EdgeInsets.only(right: 4), child: FeatureIcon(ModelFeatureEnum.vision)),
  if (jsTruthy(d['indexing_technique']))
    DifyBadge(
      formatIndexingTechniqueAndMethod(_d, d['indexing_technique'], jsGet(d['retrieval_model_dict'], 'search_method')),
    ),
  if (d['provider'] == 'external') DifyBadge(_d('externalTag')),
];

/// DatasetItem: an `h-10 rounded-lg` row with the icon and name; hovering (or tapping, on touch) swaps the badges
/// for Edit (when [editable]) and the destructive Remove, whose hover turns the row destructive.
class DatasetItem extends StatefulWidget {
  const DatasetItem({
    super.key,
    required this.payload,
    required this.onRemove,
    required this.onChange,
    this.readonly = false,
    this.editable = true,
  });

  final Json payload;
  final VoidCallback onRemove;
  final ValueChanged<Json> onChange;
  final bool readonly, editable;

  @override
  State<DatasetItem> createState() => _DatasetItemState();
}

class _DatasetItemState extends State<DatasetItem> {
  bool _hovered = false, _deleteHovered = false;

  Future<void> _edit() async {
    final edit = LlmGroupScope.of(context).editDataset;
    if (edit == null) return;
    final next = await edit(widget.payload);
    if (next != null && mounted) widget.onChange(next);
  }

  @override
  Widget build(BuildContext context) {
    final w = widget, d = w.payload;
    final canEdit = w.editable && LlmGroupScope.of(context).editDataset != null;
    final showActions = _hovered && !w.readonly;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _hovered = !_hovered),
        child: Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: _deleteHovered
                ? DifyColors.stateDestructiveHover
                : _hovered
                ? DifyColors.componentsPanelOnPanelItemBgHover
                : DifyColors.componentsPanelOnPanelItemBg,
            borderRadius: BorderRadius.circular(DifyRadius.lg),
            border: Border.all(
              color: _deleteHovered ? DifyColors.stateDestructiveBorder : DifyColors.componentsPanelBorderSubtle,
              width: 0.5,
            ),
          ),
          child: Row(
            children: [
              DatasetIcon(iconInfo: d['icon_info']),
              const SizedBox(width: 6),
              Expanded(child: DifyText('${d['name'] ?? ''}', DifyType.systemSmMedium, color: DifyColors.textSecondary)),
              if (showActions)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Row(
                    spacing: 4,
                    children: [
                      if (canEdit)
                        DifyIconButton(
                          label: _c('operation.edit'),
                          icon: RemixIcon('edit-line', size: 16, color: DifyColors.textTertiary),
                          onPressed: _edit,
                        ),
                      MouseRegion(
                        onEnter: (_) => setState(() => _deleteHovered = true),
                        onExit: (_) => setState(() => _deleteHovered = false),
                        child: DifyIconButton(
                          label: _c('operation.remove'),
                          tone: DifyButtonTone.destructive,
                          icon: const RemixIcon('delete-bin-line', size: 16),
                          onPressed: w.onRemove,
                        ),
                      ),
                    ],
                  ),
                )
              else
                _Badges(badges: datasetBadges(d)),
            ],
          ),
        ),
      ),
    );
  }
}

/// DatasetList: the items (`space-y-1`), or "Click the “+” button to add knowledge".
class DatasetList extends StatelessWidget {
  const DatasetList({super.key, required this.list, required this.onChange, this.readonly = false});
  final List<Json> list;
  final ValueChanged<List<Json>> onChange;
  final bool readonly;

  @override
  Widget build(BuildContext context) {
    final canEdit = LlmGroupScope.of(context).canEditDataset;
    if (list.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(12),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: DifyColors.backgroundSection,
          borderRadius: BorderRadius.circular(DifyRadius.lg),
        ),
        child: DifyText(
          _ad('datasetConfig.knowledgeTip'),
          DifyType.systemXsRegular,
          color: DifyColors.textTertiary,
          align: TextAlign.center,
          maxLines: null,
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 4,
      children: [
        for (final (i, d) in list.indexed)
          DatasetItem(
            key: ValueKey('dataset-$i-${d['id']}'),
            payload: d,
            readonly: readonly,
            editable: canEdit?.call(d) ?? true,
            onRemove: () => onChange([...list]..removeAt(i)),
            onChange: (v) => onChange([...list]..[i] = v),
          ),
      ],
    );
  }
}

/// AddDataset: the `+` button ("Add Knowledge") opening the Select reference Knowledge dialog; Add hands the chosen
/// datasets on.
class AddDataset extends StatelessWidget {
  const AddDataset({super.key, required this.selectedIds, required this.onChange});
  final List<String> selectedIds;
  final ValueChanged<List<Json>> onChange;

  // The button alone in its `<div>`, on that block's text line (see Css.inlineButtonLineGap).
  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(bottom: Css.inlineButtonLineGap),
    child: DifyIconButton(
      label: '${_c('operation.add')} ${_w('nodes.knowledgeRetrieval.knowledge')}',
      icon: RemixIcon('add-line', size: 16, color: DifyColors.textTertiary),
      onPressed: () async {
        final picked = await showSelectDataset(context, selectedIds: selectedIds);
        if (picked != null) onChange(picked);
      },
    ),
  );
}

/// Opens SelectDataSet; resolves with the chosen datasets (Add) or null (closed).
Future<List<Json>?> showSelectDataset(BuildContext context, {required List<String> selectedIds}) {
  final services = LlmGroupScope.of(context);
  return showDifyDialog<List<Json>>(
    context,
    builder: (ctx) => LlmGroupScope(
      services: services,
      child: DifyDialogSurface(
        label: _ad('feature.dataSet.selectTitle'),
        width: 400,
        padding: const EdgeInsets.all(24),
        child: SelectDataset(
          selectedIds: selectedIds,
          onSelect: (d) => Navigator.of(ctx).pop(d),
          onClose: () => Navigator.of(ctx).pop(),
        ),
      ),
    ),
  );
}

/// SelectDataSet's content: the workspace's indexed or external knowledge bases, loaded a page at a time as the
/// list scrolls, toggled by tapping (unavailable ones disabled); "{n} Knowledge selected", Cancel and Add.
class SelectDataset extends StatefulWidget {
  const SelectDataset({super.key, required this.selectedIds, required this.onSelect, required this.onClose});
  final List<String> selectedIds;
  final ValueChanged<List<Json>> onSelect;
  final VoidCallback onClose;

  @override
  State<SelectDataset> createState() => _SelectDatasetState();
}

class _SelectDatasetState extends State<SelectDataset> {
  late List<String> _selected = [...widget.selectedIds];
  final _datasets = <Json>[];
  bool _loading = true, _fetchingNext = false, _hasMore = false;
  int _page = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_page == 0) _fetch();
  }

  Future<void> _fetch() async {
    final load = LlmGroupScope.of(context).fetchDatasetPage;
    if (load == null) {
      setState(() => _loading = false);
      return;
    }
    _page++;
    if (_page > 1) setState(() => _fetchingNext = true);
    try {
      final (:data, :hasMore) = await load(_page);
      if (!mounted) return;
      setState(() {
        _datasets.addAll(data.where((d) => jsTruthy(d['indexing_technique']) || d['provider'] == 'external'));
        _hasMore = hasMore;
      });
    } on Object {
      _hasMore = false;
    }
    if (mounted) setState(() => _loading = _fetchingNext = false);
  }

  void _toggle(Json d) {
    final id = '${d['id']}';
    setState(() => _selected.contains(id) ? _selected.remove(id) : _selected.add(id));
  }

  @override
  Widget build(BuildContext context) {
    final services = LlmGroupScope.of(context);
    final byId = {for (final d in _datasets) '${d['id']}': d};
    final hasNoData = !_loading && _datasets.isEmpty;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: DifyText(_ad('feature.dataSet.selectTitle'), DifyType.title2xlSemiBold, maxLines: null)),
            DifyIconButton(
              label: _c('operation.close'),
              size: DifyIconButtonSize.lg,
              icon: const RemixIcon('close-line', size: 16),
              onPressed: () {
                _selected = [...widget.selectedIds];
                widget.onClose();
              },
            ),
          ],
        ),
        if (_loading && _datasets.isEmpty)
          const SizedBox(height: 200, child: Center(child: _Spinner()))
        else if (hasNoData)
          Container(
            margin: const EdgeInsets.only(top: 24),
            height: 128,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: DifyColors.componentsPanelOnPanelItemBg,
              borderRadius: BorderRadius.circular(DifyRadius.lg),
              border: Border.all(color: DifyColors.dividerSubtle),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 4,
              children: [
                Text(
                  _ad('feature.dataSet.noDataSet'),
                  style: difyStyle(DifyType.systemSmRegular, DifyColors.textTertiary),
                ),
                if (services.canCreateDataset)
                  DifyPressable(
                    semanticLabel: _ad('feature.dataSet.toCreate'),
                    onPressed: services.openCreateDataset,
                    builder: (context, hovered, focused) => Text(
                      _ad('feature.dataSet.toCreate'),
                      style: difyStyle(DifyType.systemSmRegular, DifyColors.textAccent),
                    ),
                  ),
              ],
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.only(top: 28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 286),
              child: NotificationListener<ScrollNotification>(
                onNotification: (n) {
                  if (n.metrics.extentAfter < 40 && _hasMore && !_fetchingNext) _fetch();
                  return false;
                },
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final d in _datasets)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: _DatasetOption(
                          dataset: d,
                          selected: _selected.contains('${d['id']}'),
                          onTap: () => _toggle(d),
                        ),
                      ),
                    if (_fetchingNext) const Center(child: _Spinner()),
                  ],
                ),
              ),
            ),
          ),
        if (!_loading)
          Padding(
            padding: const EdgeInsets.only(top: 32),
            child: Row(
              children: [
                Expanded(
                  child: DifyText(
                    _selected.isEmpty ? '' : '${_selected.length} ${_ad('feature.dataSet.selected')}',
                    DifyType.systemSmMedium,
                    color: DifyColors.textSecondary,
                  ),
                ),
                Flexible(
                  child: DifyButton(
                    onPressed: () {
                      _selected = [...widget.selectedIds];
                      widget.onClose();
                    },
                    child: Text(_c('operation.cancel')),
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: DifyButton(
                    variant: DifyButtonVariant.primary,
                    disabled: hasNoData,
                    onPressed: () => widget.onSelect([
                      for (final id in _selected) byId[id] ?? {'id': id},
                    ]),
                    child: Text(_c('operation.add')),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// The badges, shrinking (ellipsis) rather than overflowing a narrow row.
class _Badges extends StatelessWidget {
  const _Badges({required this.badges});
  final List<Widget> badges;

  @override
  Widget build(BuildContext context) => Flexible(
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [for (final b in badges) Flexible(child: b)],
    ),
  );
}

class _DatasetOption extends StatelessWidget {
  const _DatasetOption({required this.dataset, required this.selected, required this.onTap});
  final Json dataset;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final d = dataset;
    final available = d['embedding_available'] != false;
    return DifyPressable(
      semanticLabel: '${d['name'] ?? ''}',
      disabled: !available,
      onPressed: onTap,
      builder: (context, hovered, focused) => Semantics(
        selected: selected,
        child: Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: selected
                ? DifyColors.stateAccentHover
                : hovered && available
                ? DifyColors.componentsPanelOnPanelItemBgHover
                : DifyColors.componentsPanelOnPanelItemBg,
            borderRadius: BorderRadius.circular(DifyRadius.lg),
            border: Border.all(
              color: selected
                  ? DifyColors.componentsOptionCardOptionSelectedBorder
                  : hovered && available
                  ? DifyColors.componentsPanelBorder
                  : DifyColors.componentsPanelBorderSubtle,
              width: selected ? 1.5 : 0.5,
            ),
            boxShadow: hovered && available && !selected ? DifyShadows.sm : DifyShadows.xs,
          ),
          child: Row(
            children: [
              Opacity(
                opacity: available ? 1 : 0.3,
                child: DatasetIcon(iconInfo: d['icon_info']),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: available ? 200 : 120),
                  child: Opacity(
                    opacity: available ? 1 : 0.3,
                    child: Text(
                      '${d['name'] ?? ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: DifyColors.textSecondary,
                      ),
                    ),
                  ),
                ),
              ),
              if (!available)
                Container(
                  margin: const EdgeInsets.only(left: 4),
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(DifyRadius.md),
                    border: Border.all(color: DifyColors.dividerDeep),
                  ),
                  child: DifyText(_d('unavailable'), DifyType.systemXsRegular, color: DifyColors.textTertiary),
                ),
              const Spacer(),
              _Badges(badges: datasetBadges(d)),
            ],
          ),
        ),
      ),
    );
  }
}

class _Spinner extends StatefulWidget {
  const _Spinner();

  @override
  State<_Spinner> createState() => _SpinnerState();
}

class _SpinnerState extends State<_Spinner> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(seconds: 1))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RotationTransition(
    turns: _c,
    child: RemixIcon('loader-2-line', size: 16, color: DifyColors.textTertiary),
  );
}
