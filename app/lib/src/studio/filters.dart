/// The Studio header's controls: apps/app-type-filter.tsx, app-sort-filter.tsx, creators-filter.tsx,
/// base/search-input and app/create-app-dropdown.tsx.
library;

import 'package:collab_client/collab_client.dart' show AppModes, AppSortBy, Member;
import 'package:flutter/material.dart' show Colors;
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../design/css_metrics.dart';
import '../design/dify_icon.dart';
import '../design/dify_tokens.g.dart';
import '../design/widgets/widgets.dart';
import '../i18n/dify_i18n.dart';
import 'app_list_controller.dart';

String _a(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('app', key, params);
String _c(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('common', key, params);

/// `text-[13px] leading-4`.
final _chipText = DifyTw.text13Leading16.style;

/// The filter chip (`chipClassName`: `flex h-8 items-center rounded-lg border-[0.5px] px-2 text-[13px] leading-4`):
/// [selected] = `border-components-button-secondary-border bg-components-button-secondary-bg shadow-xs
/// hover:bg-state-base-hover`, else `border-transparent bg-components-input-bg-normal text-text-tertiary
/// hover:bg-components-input-bg-hover`.
Widget _chip({
  required bool selected,
  required bool hovered,
  required bool focused,
  required Widget child,
  bool popupOpen = false,
  EdgeInsets padding = const EdgeInsets.symmetric(horizontal: 8),
  Color? hoverSelected,
}) => Container(
  height: 32,
  padding: padding,
  decoration: DifyFocusDecoration(
    color: selected
        ? (hovered || popupOpen ? hoverSelected ?? DifyColors.stateBaseHover : DifyColors.componentsButtonSecondaryBg)
        : (hovered || popupOpen ? DifyColors.componentsInputBgHover : DifyColors.componentsInputBgNormal),
    borderRadius: BorderRadius.circular(DifyRadius.lg),
    border: Border.all(
      color: selected ? DifyColors.componentsButtonSecondaryBorder : Colors.transparent,
      width: Css.hairline,
    ),
    boxShadow: [
      if (selected) ...DifyShadows.xs,
      if (focused) difyFocusRingShadow(),
    ],
  ),
  child: DefaultTextStyle.merge(
    style: _chipText.copyWith(color: DifyColors.textTertiary),
    child: DifyControlLabelScope(
      child: Row(mainAxisSize: MainAxisSize.min, children: [child]),
    ),
  ),
);

/// AppTypeFilter: a radio dropdown of [studioAppListCategories]; the trigger reads "Types" until a type is picked.
class AppTypeFilter extends StatefulWidget {
  const AppTypeFilter({super.key, required this.value, required this.onChange});

  final String value;
  final ValueChanged<String> onChange;

  /// `optionsByCategory`: the label and icon of each category (also those dify-sf does not offer).
  static (String text, String icon) option(String category) => switch (category) {
    AppModes.workflow => (_a('types.workflow'), 'exchange-2-line'),
    AppModes.advancedChat => (_a('types.advanced'), 'message-3-line'),
    AppModes.chat => (_a('types.chatbot'), 'message-3-line'),
    AppModes.agentChat => (_a('types.agent'), 'robot-3-line'),
    AppModes.completion => (_a('newApp.completeApp'), 'file-4-line'),
    _ => (_a('types.all'), 'apps-2-line'),
  };

  @override
  State<AppTypeFilter> createState() => _AppTypeFilterState();
}

class _AppTypeFilterState extends State<AppTypeFilter> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.value != AppModes.all;
    final label = selected ? AppTypeFilter.option(widget.value).$1 : _a('studio.filters.types');
    return DifyDropdownMenu(
      key: const ValueKey('studio-type-filter'),
      placement: DifyPlacement.bottomStart,
      width: 220,
      open: _open,
      onOpenChange: (v) => setState(() => _open = v),
      builder: (context, controller) => DifyPressable(
        semanticLabel: label,
        onPressed: controller.toggle,
        builder: (context, hovered, focused) => _chip(
          selected: selected,
          hovered: hovered,
          focused: focused,
          popupOpen: _open,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: DifyTextLine(label)),
              RemixIcon('arrow-down-s-line', size: 16, color: DifyColors.textTertiary),
            ],
          ),
        ),
      ),
      children: [
        DifyMenuRadioGroup<String>(
          value: widget.value,
          onValueChange: widget.onChange,
          children: [
            for (final c in studioAppListCategories)
              DifyMenuRadioItem<String>(
                key: ValueKey('studio-type-option-$c'),
                value: c,
                leading: RemixIcon(AppTypeFilter.option(c).$2, size: 16, color: DifyColors.textTertiary),
                child: DifyTextLine(AppTypeFilter.option(c).$1),
              ),
          ],
        ),
      ],
    );
  }
}

/// AppSortFilter: "Sort by <option>", a radio dropdown that closes on a choice.
class AppSortFilter extends StatefulWidget {
  const AppSortFilter({super.key, required this.value, required this.onChange});

  final String value;
  final ValueChanged<String> onChange;

  static String label(String sortBy) => switch (sortBy) {
    AppSortBy.recentlyCreated => _a('studio.sort.recentlyCreated'),
    AppSortBy.earliestCreated => _a('studio.sort.earliestCreated'),
    _ => _a('studio.sort.lastModified'),
  };

  @override
  State<AppSortFilter> createState() => _AppSortFilterState();
}

class _AppSortFilterState extends State<AppSortFilter> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final sortByLabel = _a('studio.sort.sortBy');
    final active = AppSortFilter.label(widget.value);
    return DifyDropdownMenu(
      key: const ValueKey('studio-sort-filter'),
      placement: DifyPlacement.bottomStart,
      width: 220,
      open: _open,
      onOpenChange: (v) => setState(() => _open = v),
      builder: (context, controller) => DifyPressable(
        semanticLabel: '$sortByLabel $active',
        onPressed: controller.toggle,
        builder: (context, hovered, focused) => Container(
          height: 32,
          padding: const EdgeInsets.fromLTRB(8, 4, 10, 4),
          decoration: DifyFocusDecoration(
            color: hovered || _open ? DifyColors.stateBaseHover : DifyColors.componentsInputBgNormal,
            borderRadius: BorderRadius.circular(DifyRadius.lg),
            boxShadow: focused ? [difyFocusRingShadow()] : null,
          ),
          child: DifyControlLabelScope(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.all(4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    spacing: 4, // app-sort-filter.tsx: gap-1, independent of glyph/locale.
                    children: [
                      DifyTextLine(sortByLabel, style: _chipText.copyWith(color: DifyColors.textTertiary)),
                      DifyTextLine(
                        active,
                        style: _chipText.copyWith(
                          color: DifyColors.textSecondary,
                          fontWeight: DifyTw.fontMedium.style.fontWeight,
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
      ),
      children: [
        DifyMenuRadioGroup<String>(
          value: widget.value,
          onValueChange: widget.onChange,
          children: [
            for (final s in AppSortBy.all)
              DifyMenuRadioItem<String>(
                key: ValueKey('studio-sort-option-$s'),
                value: s,
                closeOnClick: true,
                child: DifyTextLine(AppSortFilter.label(s), maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
          ],
        ),
      ],
    );
  }
}

/// A creator option (creators-filter.tsx `CreatorOption`).
typedef CreatorOption = ({String id, String name, String? avatarUrl, bool isYou});

/// `creatorOptions`: active members (not `pending`), the current user first, then by name.
List<CreatorOption> creatorOptionsOf(List<Member> members, String? currentUserId) {
  final list = [
    for (final m in members)
      if (m.status != 'pending') m,
  ];
  list.sort((l, r) {
    if (l.id == currentUserId) return -1;
    if (r.id == currentUserId) return 1;
    return l.name.compareTo(r.name);
  });
  return [for (final m in list) (id: m.id, name: m.name, avatarUrl: m.avatarUrl, isYou: m.id == currentUserId)];
}

/// CreatorsFilter: a multi-select of the workspace's members. The trigger shows up to three selected avatars and
/// `+<count>` (a reset button clears the selection); the popup has a search input and checkbox rows.
class CreatorsFilter extends StatefulWidget {
  const CreatorsFilter({
    super.key,
    required this.value,
    required this.onChange,
    required this.members,
    this.currentUserId,
  });

  final List<String> value;
  final ValueChanged<List<String>> onChange;
  final List<Member> members;
  final String? currentUserId;

  @override
  State<CreatorsFilter> createState() => _CreatorsFilterState();
}

class _CreatorsFilterState extends State<CreatorsFilter> {
  final _controller = DifyFloatingController();
  final _search = FocusNode(debugLabel: 'creators search');
  final _trigger = FocusNode(debugLabel: 'creators trigger');
  bool _open = false;
  String _keywords = '';

  /// The keyboard-highlighted option (Base UI's `autoHighlight`: the first match while searching); -1 = none.
  int _highlight = -1;

  @override
  void dispose() {
    _search.dispose();
    _trigger.dispose();
    super.dispose();
  }

  void _toggle(String id) {
    final next = widget.value.contains(id) ? [...widget.value.where((v) => v != id)] : [...widget.value, id];
    widget.onChange(next);
  }

  void _reset() {
    widget.onChange(const []);
    setState(() => _keywords = '');
    _trigger.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final options = creatorOptionsOf(widget.members, widget.currentUserId);
    final byId = {for (final o in options) o.id: o};
    final selected = [
      for (final id in widget.value) ?byId[id],
    ];
    final count = widget.value.length;
    final label = _a('studio.filters.creators');
    final q = _keywords.trim().toLowerCase();
    final visible = q.isEmpty
        ? options
        : [
            for (final o in options)
              if (o.name.toLowerCase().contains(q)) o,
          ];
    if (_highlight >= visible.length) _highlight = visible.isEmpty ? -1 : visible.length - 1;
    KeyEventResult onKey(FocusNode _, KeyEvent e) {
      if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
      if (visible.isEmpty) return KeyEventResult.ignored;
      if (e.logicalKey == LogicalKeyboardKey.arrowDown) {
        setState(() => _highlight = (_highlight + 1) % visible.length);
      } else if (e.logicalKey == LogicalKeyboardKey.arrowUp) {
        setState(() => _highlight = _highlight <= 0 ? visible.length - 1 : _highlight - 1);
      } else if (e.logicalKey == LogicalKeyboardKey.enter && _highlight >= 0) {
        _toggle(visible[_highlight].id);
      } else {
        return KeyEventResult.ignored;
      }
      return KeyEventResult.handled;
    }

    final textColor = _open ? DifyColors.textSecondary : DifyColors.textTertiary;
    return DifyFloating(
      key: const ValueKey('studio-creators-filter'),
      controller: _controller,
      open: _open,
      onOpenChange: (v) => setState(() {
        _open = v;
        _highlight = -1;
        if (!v) _keywords = '';
      }),
      placement: DifyPlacement.bottomStart,
      sideOffset: 4,
      collision: DifyCollision.dropdown,
      initialFocus: _search,
      builder: (context, controller) => Stack(
        alignment: AlignmentDirectional.centerEnd,
        children: [
          // The trigger is named by the label; the selected count is its (sr-only) value.
          Semantics(
            value: count > 0 ? _c('dynamicSelect.selected', {'count': count}) : null,
            child: DifyPressable(
              focusNode: _trigger,
              semanticLabel: label,
              onPressed: controller.toggle,
              builder: (context, hovered, focused) => _chip(
                selected: count > 0,
                hovered: hovered,
                focused: focused,
                popupOpen: _open,
                hoverSelected: DifyColors.stateBaseHoverAlt,
                padding: EdgeInsets.fromLTRB(8, 0, count > 0 ? 32 : 8, 0),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: DifyTextLine(label, style: TextStyle(color: textColor)),
                    ),
                    if (count > 0) ...[
                      Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (final (i, c) in selected.take(3).indexed)
                              Transform.translate(
                                offset: Offset(i * -4.0, 0),
                                child: Container(
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    border: Border.all(color: DifyColors.componentsPanelBg),
                                  ),
                                  child: DifyAvatar(name: c.name, url: c.avatarUrl, size: DifyAvatarSize.xs, box: 18),
                                ),
                              ),
                          ],
                        ),
                      ),
                      DifyTextLine(
                        '+$count',
                        style: difyTextStyle(DifyType.systemXsMedium, textColor), // `text-xs leading-4 font-medium`
                      ),
                    ] else
                      RemixIcon('arrow-down-s-line', size: 16, color: textColor),
                  ],
                ),
              ),
            ),
          ),
          if (count > 0)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: DifyIconButton(
                key: const ValueKey('studio-creators-reset'),
                label: _a('studio.filters.reset'),
                size: DifyIconButtonSize.sm,
                icon: RemixIcon('close-circle-fill', size: 14, color: textColor),
                onPressed: _reset,
              ),
            ),
        ],
      ),
      popupBuilder: (context) => Semantics(
        container: true,
        role: SemanticsRole.dialog,
        label: label,
        explicitChildNodes: true,
        child: DifyBlurredBox(
          blur: 5,
          borderRadius: BorderRadius.circular(DifyRadius.xl),
          decoration: DifyMenuPopup.decoration,
          child: DifySurface(
            child: SizedBox(
              width: 280,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
                    child: DifyInput(
                      key: const ValueKey('studio-creators-search'),
                      value: _keywords,
                      focusNode: _search,
                      height: 32,
                      placeholder: _a('studio.filters.searchCreators'),
                      semanticLabel: _a('studio.filters.searchCreators'),
                      onKeyEvent: onKey,
                      onChanged: (v) => setState(() {
                        _keywords = v;
                        _highlight = v.trim().isEmpty ? -1 : 0;
                      }),
                      leading: Padding(
                        padding: const EdgeInsets.only(left: 8, right: 6),
                        child: RemixIcon('search-line', size: 16, color: DifyColors.componentsInputTextPlaceholder),
                      ),
                      trailing: _keywords.isEmpty
                          ? null
                          : DifyIconButton(
                              key: const ValueKey('studio-creators-search-clear'),
                              label: _c('operation.clear'),
                              size: DifyIconButtonSize.sm,
                              icon: RemixIcon('close-circle-fill', size: 16, color: DifyColors.textQuaternary),
                              onPressed: () {
                                setState(() {
                                  _keywords = '';
                                  _highlight = -1;
                                });
                                _search.requestFocus();
                              },
                            ),
                    ),
                  ),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 240),
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final (i, o) in visible.indexed)
                            CreatorRow(
                              key: ValueKey('studio-creator-${o.id}'),
                              option: o,
                              highlighted: i == _highlight,
                              checked: widget.value.contains(o.id),
                              onTap: () => _toggle(o.id),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A creator option (`ComboboxItem`): checkbox, avatar, name and "You"; [highlighted] = Base UI's
/// `data-highlighted` (the keyboard's current option).
class CreatorRow extends StatelessWidget {
  const CreatorRow({
    super.key,
    required this.option,
    required this.checked,
    required this.onTap,
    this.highlighted = false,
  });

  final CreatorOption option;
  final bool checked, highlighted;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    selected: checked,
    checked: checked,
    child: DifyPressable(
      semanticLabel: option.name,
      onPressed: onTap,
      builder: (context, hovered, focused) => Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: hovered || focused || highlighted ? DifyColors.stateBaseHover : null,
          borderRadius: BorderRadius.circular(DifyRadius.md),
        ),
        child: Row(
          spacing: 4,
          children: [
            DifyCheckboxBox(checked: checked),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Row(
                  spacing: 8,
                  children: [
                    DifyAvatar(name: option.name, url: option.avatarUrl, size: DifyAvatarSize.xs),
                    Expanded(
                      child: DifyTextLine(
                        option.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: difyTextStyle(DifyType.systemMdRegular, DifyColors.textSecondary), // `text-sm`
                      ),
                    ),
                    if (option.isYou)
                      // `shrink-0` ("You" is short; the cap only guards long translations).
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 96),
                        child: DifyTextLine(
                          _a('studio.filters.you'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: difyTextStyle(DifyType.systemMdRegular, DifyColors.textQuaternary),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// base/search-input: a `w-50` input with the search icon in front and a clear button once it has text (which
/// empties it and keeps the focus).
class StudioSearchInput extends StatefulWidget {
  const StudioSearchInput({
    super.key,
    required this.value,
    required this.onChange,
    this.semanticLabel,
    this.width = 200,
  });

  final String value;
  final ValueChanged<String> onChange;
  final String? semanticLabel;
  final double width;

  @override
  State<StudioSearchInput> createState() => _StudioSearchInputState();
}

class _StudioSearchInputState extends State<StudioSearchInput> {
  @override
  Widget build(BuildContext context) => DifySearchInput(
    key: const ValueKey('studio-search'),
    value: widget.value,
    width: widget.width,
    semanticLabel: widget.semanticLabel,
    onValueChange: widget.onChange,
  );
}

/// CreateAppDropdown: the primary "Create" button and its menu: Create from Blank and Import DSL (dify-sf has no
/// templates, so "Create from Template" is left out).
class CreateAppDropdown extends StatelessWidget {
  const CreateAppDropdown({super.key, this.onCreateBlank, this.onImportDSL});

  final VoidCallback? onCreateBlank;
  final VoidCallback? onImportDSL;

  @override
  Widget build(BuildContext context) => DifyDropdownMenu(
    key: const ValueKey('studio-create'),
    placement: DifyPlacement.bottomEnd,
    width: 280,
    builder: (context, controller) => DifyButton(
      variant: DifyButtonVariant.primary,
      paddingX: 8,
      semanticLabel: _c('operation.create'),
      onPressed: controller.toggle,
      leading: const RemixIcon('add-line', size: 16),
      trailing: const RemixIcon('arrow-down-s-line', size: 16),
      child: DifyTextLine(_c('operation.create')),
    ),
    children: [
      if (onCreateBlank != null)
        DifyMenuItem(
          key: const ValueKey('studio-create-blank'),
          onSelect: onCreateBlank,
          leading: RemixIcon('sticky-note-add-line', size: 16, color: DifyColors.textSecondary),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: DifyTextLine(
              _a('newApp.startFromBlank'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: difyTextStyle(DifyType.systemMdRegular, DifyColors.textSecondary),
            ),
          ),
        ),
      if (onCreateBlank != null && onImportDSL != null) const DifyMenuSeparator(),
      if (onImportDSL != null)
        DifyMenuItem(
          key: const ValueKey('studio-create-dsl'),
          autoHeight: true,
          onSelect: onImportDSL,
          leading: RemixIcon('file-upload-line', size: 16, color: DifyColors.textSecondary),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 2,
              children: [
                DifyTextLine(_a('importDSL'), style: difyTextStyle(DifyType.systemMdRegular, DifyColors.textSecondary)),
                DifyTextLine(
                  _a('newApp.dropDSLToCreateApp'),
                  style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textTertiary),
                ),
              ],
            ),
          ),
        ),
    ],
  );
}
