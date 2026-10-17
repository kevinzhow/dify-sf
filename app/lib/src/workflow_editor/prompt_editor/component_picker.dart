/// The prompt editor's `{` / `/` menu (base/prompt-editor/plugins/component-picker-block: index.tsx, hooks.tsx,
/// prompt-option.tsx, variable-option.tsx): the workflow variables, then the special blocks and app variables.
library;

import 'package:flutter/material.dart' show Tooltip;
import 'package:flutter/widgets.dart';

import '../../design/css_metrics.dart';
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';
import '../../workflow/var_types.dart' show VarType;
import '../panel_fields/var_picker_model.dart';
import 'prompt_blocks.dart';
import 'prompt_editor_types.dart';

/// One option below the variable list (`PickerBlockMenuOption`).
class PickerOption {
  const PickerOption({required this.key, required this.build, this.group, this.onSelect});

  final String key;
  final String? group;

  /// Builds the row (`render`): highlighted or not, the typed query, and the tap / hover callbacks.
  final Widget Function(bool isSelected, String? query, VoidCallback onSelect, VoidCallback onHighlight) build;

  /// What choosing the option does (`onSelectMenuOption`), after the typed trigger is removed.
  final VoidCallback? onSelect;
}

/// `new RegExp(query, 'i')`, or null where JavaScript would reject the pattern.
RegExp? queryRegExp(String query) {
  try {
    return RegExp(query, caseSensitive: false);
  } on FormatException {
    return null;
  }
}

/// PromptMenuItem: a 24 px row with an icon and the title, faded and inert when [disabled].
class PromptMenuItem extends StatefulWidget {
  const PromptMenuItem({
    super.key,
    required this.icon,
    required this.title,
    required this.isSelected,
    required this.onClick,
    required this.onMouseEnter,
    this.disabled = false,
  });

  final Widget icon;
  final String title;
  final bool disabled;
  final bool isSelected;
  final VoidCallback onClick;
  final VoidCallback onMouseEnter;

  @override
  State<PromptMenuItem> createState() => _PromptMenuItemState();
}

class _PromptMenuItemState extends State<PromptMenuItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final w = widget;
    Widget row = Container(
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: _hovered || (w.isSelected && !w.disabled) ? DifyColors.stateBaseHover : null,
        borderRadius: BorderRadius.circular(DifyRadius.md),
      ),
      child: Row(
        children: [
          w.icon,
          const SizedBox(width: 4),
          // No truncate in Dify: a long title runs past the row.
          Flexible(
            child: Text(
              w.title,
              softWrap: false,
              overflow: TextOverflow.visible,
              style: const TextStyle(fontSize: 13, height: 18 / 13, color: DifyColors.textSecondary),
            ),
          ),
        ],
      ),
    );
    if (w.disabled) row = Opacity(opacity: 0.3, child: row);
    return MouseRegion(
      cursor: w.disabled ? SystemMouseCursors.forbidden : SystemMouseCursors.click,
      onEnter: (_) {
        setState(() => _hovered = true);
        if (!w.disabled) w.onMouseEnter();
      },
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: w.disabled ? null : w.onClick,
        child: Semantics(button: true, enabled: !w.disabled, label: w.title, excludeSemantics: true, child: row),
      ),
    );
  }
}

/// VariableMenuItem: icon, the title with the query's first match in text-accent, and an optional trailing part.
class VariableMenuItem extends StatefulWidget {
  const VariableMenuItem({
    super.key,
    required this.title,
    required this.isSelected,
    required this.queryString,
    required this.onClick,
    required this.onMouseEnter,
    this.icon,
    this.extraElement,
  });

  final String title;
  final Widget? icon;
  final Widget? extraElement;
  final bool isSelected;
  final String? queryString;
  final VoidCallback onClick;
  final VoidCallback onMouseEnter;

  @override
  State<VariableMenuItem> createState() => _VariableMenuItemState();
}

class _VariableMenuItemState extends State<VariableMenuItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final w = widget;
    var before = w.title, middle = '', after = '';
    final q = w.queryString;
    if (q != null && q.isNotEmpty) {
      final m = queryRegExp(q)?.firstMatch(w.title);
      if (m != null) {
        before = w.title.substring(0, m.start);
        middle = m[0]!;
        after = w.title.substring(m.end);
      }
    }
    const style = TextStyle(fontSize: 13, height: 18 / 13, color: DifyColors.textSecondary);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) {
        setState(() => _hovered = true);
        w.onMouseEnter();
      },
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: w.onClick,
        child: Container(
          height: 24,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: _hovered || w.isSelected ? DifyColors.stateBaseHover : null,
            borderRadius: BorderRadius.circular(DifyRadius.md),
          ),
          child: Row(
            children: [
              if (w.icon != null) Padding(padding: const EdgeInsets.only(right: 8), child: w.icon),
              Expanded(
                // `title={title}`: the full name on hover.
                child: Tooltip(
                  message: w.title,
                  waitDuration: const Duration(milliseconds: 600),
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(text: before),
                        TextSpan(
                          text: middle,
                          style: const TextStyle(color: DifyColors.textAccent),
                        ),
                        TextSpan(text: after),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: style,
                  ),
                ),
              ),
              ?w.extraElement,
            ],
          ),
        ),
      ),
    );
  }
}

/// The menu box: `w-65 rounded-lg border-[0.5px] border-components-panel-border bg-components-panel-bg-blur p-1
/// shadow-lg` holding the variable list ([variables], in `p-1`), a divider, then the [options] with a divider
/// between groups.
class ComponentPickerMenu extends StatelessWidget {
  const ComponentPickerMenu({
    super.key,
    required this.options,
    required this.selectedIndex,
    required this.onSelect,
    required this.onHighlight,
    this.variables,
    this.queryString,
  });

  final Widget? variables;
  final List<PickerOption> options;

  /// The highlighted option, or null when highlights are hidden (the workflow variable list is shown).
  final int? selectedIndex;
  final String? queryString;
  final void Function(PickerOption option) onSelect;
  final void Function(int index) onHighlight;

  Widget _divider() => Transform.translate(
    offset: const Offset(-4, 0),
    child: Container(height: 1, margin: const EdgeInsets.symmetric(vertical: 4), color: DifyColors.dividerSubtle),
  );

  @override
  Widget build(BuildContext context) => Container(
    width: 260,
    padding: const EdgeInsets.all(4),
    decoration: BoxDecoration(
      color: DifyColors.componentsPanelBgBlur,
      border: Border.all(color: DifyColors.componentsPanelBorder, width: Css.hairline),
      borderRadius: BorderRadius.circular(DifyRadius.lg),
      boxShadow: DifyShadows.lg,
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (variables != null) Padding(padding: const EdgeInsets.all(4), child: variables),
        if (variables != null && options.isNotEmpty) _divider(),
        for (final (i, o) in options.indexed) ...[
          if (i > 0 && options[i - 1].group != o.group) _divider(),
          o.build(selectedIndex == i, queryString, () => onSelect(o), () => onHighlight(i)),
        ],
      ],
    ),
  );
}

/// The icons of the special-block options.
abstract final class PickerIcons {
  static const context = DifyIcon('vender/solid/files/file-05', size: 16, color: Color(0xFF6938EF));
  static const query = DifyIcon('vender/solid/users/user-edit-02', size: 16, color: Color(0xFFFD853A));
  static const requestUrl = RemixIcon('global-line', size: 16, color: DifyColors.utilColorsVioletViolet600);
  static const history = DifyIcon('vender/solid/general/message-clock-circle', size: 16, color: Color(0xFFDD2590));
  static const variable = DifyIcon('vender/line/development/brackets-x', size: 14, color: DifyColors.textAccent);
  static const tool = DifyIcon('vender/solid/general/tool-03', size: 14, color: DifyColors.textAccent);
  static const arrowUpRight = DifyIcon('vender/line/arrows/arrow-up-right', size: 12, color: DifyColors.textTertiary);
}

/// AppIcon at 14 px: the emoji on its background.
class PickerAppIcon extends StatelessWidget {
  const PickerAppIcon({super.key, this.icon, this.background});
  final String? icon;
  final String? background;

  @override
  Widget build(BuildContext context) {
    final bg = background;
    final color = bg != null && bg.startsWith('#') && (bg.length == 7)
        ? Color(0xFF000000 | int.parse(bg.substring(1), radix: 16))
        : const Color(0xFFFFEAD5);
    return Container(
      width: 14,
      height: 14,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(DifyRadius.sm)),
      child: Text(icon ?? '', style: const TextStyle(fontSize: 9, height: 1)),
    );
  }
}

/// The external tool option's trailing variable name.
Widget pickerExtraText(String text) =>
    Text(text, style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textTertiary).copyWith(height: 16 / 12));

/// `t('common', key)` shorthand for the picker's labels.
String pickerLabel(String key) => DifyI18n.tr('common', key);

/// What choosing an option does to the editor (Dify's INSERT_* commands).
class PickerActions {
  const PickerActions({required this.insertBlock, required this.insertText, required this.insertBraces});

  /// `INSERT_CONTEXT_BLOCK_COMMAND` and the like.
  final void Function(PromptBlockKind kind) insertBlock;

  /// `INSERT_VARIABLE_VALUE_BLOCK_COMMAND`: plain text.
  final void Function(String text) insertText;

  /// The add-variable option: `{{` and `}}` with the caret between.
  final void Function() insertBraces;
}

/// usePromptOptions: the context, query, request URL and history blocks that show, inert unless selectable.
List<PickerOption> promptOptions({
  required PickerActions actions,
  ContextBlockConfig? contextBlock,
  PromptBlockConfig? queryBlock,
  HistoryBlockConfig? historyBlock,
  PromptBlockConfig? requestUrlBlock,
}) {
  PickerOption option(PromptBlockConfig cfg, String key, String group, Widget icon, PromptBlockKind kind) =>
      PickerOption(
        key: key,
        group: group,
        build: (selected, _, onSelect, onHighlight) => PromptMenuItem(
          icon: icon,
          title: key,
          disabled: !cfg.selectable,
          isSelected: selected,
          onClick: onSelect,
          onMouseEnter: onHighlight,
        ),
        onSelect: () => cfg.selectable ? actions.insertBlock(kind) : null,
      );
  return [
    if (contextBlock case final c? when c.show)
      option(
        c,
        pickerLabel('promptEditor.context.item.title'),
        'prompt context',
        PickerIcons.context,
        PromptBlockKind.context,
      ),
    if (queryBlock case final c? when c.show)
      option(c, pickerLabel('promptEditor.query.item.title'), 'prompt query', PickerIcons.query, PromptBlockKind.query),
    if (requestUrlBlock case final c? when c.show)
      option(
        c,
        pickerLabel('promptEditor.requestURL.item.title'),
        'request URL',
        PickerIcons.requestUrl,
        PromptBlockKind.requestUrl,
      ),
    if (historyBlock case final c? when c.show)
      option(
        c,
        pickerLabel('promptEditor.history.item.title'),
        'prompt history',
        PickerIcons.history,
        PromptBlockKind.history,
      ),
  ];
}

PickerOption _variableOption(String key, String group, Widget icon, VoidCallback onSelect, {Widget? extra}) =>
    PickerOption(
      key: key,
      group: group,
      build: (selected, q, onTap, onHighlight) => VariableMenuItem(
        title: key,
        icon: icon,
        extraElement: extra,
        queryString: q,
        isSelected: selected,
        onClick: onTap,
        onMouseEnter: onHighlight,
      ),
      onSelect: onSelect,
    );

bool _matches(String? query, String key) =>
    query == null || query.isEmpty || (queryRegExp(query)?.hasMatch(key) ?? false);

/// useVariableOptions: the app variables matching [queryString] as `{{name}}`, then "Add new variable".
List<PickerOption> variableOptions(VariableBlockConfig? variableBlock, String? queryString, PickerActions actions) {
  if (variableBlock == null || !variableBlock.show) return const [];
  return [
    for (final o in variableBlock.variables ?? const <PromptOption>[])
      if (_matches(queryString, o.value))
        _variableOption(o.value, 'prompt variable', PickerIcons.variable, () => actions.insertText('{{${o.value}}}')),
    _variableOption(
      pickerLabel('promptEditor.variable.modal.add'),
      'prompt variable',
      PickerIcons.variable,
      actions.insertBraces,
    ),
  ];
}

/// useExternalToolOptions: the tools matching [queryString] as `{{variableName}}`, then "Add tool".
List<PickerOption> externalToolOptions(
  ExternalToolBlockConfig? externalToolBlock,
  String? queryString,
  PickerActions actions,
) {
  final tb = externalToolBlock;
  if (tb == null || !tb.show) return const [];
  return [
    for (final t in tb.externalTools ?? const <ExternalToolOption>[])
      if (_matches(queryString, t.name))
        _variableOption(
          t.name,
          'external tool',
          PickerAppIcon(icon: t.icon, background: t.iconBackground),
          () => actions.insertText('{{${t.variableName}}}'),
          extra: pickerExtraText(t.variableName),
        ),
    _variableOption(
      pickerLabel('promptEditor.variable.modal.addTool'),
      'external tool',
      PickerIcons.tool,
      () => tb.onAddExternalTool?.call(),
      extra: PickerIcons.arrowUpRight,
    ),
  ];
}

/// useOptions' `allFlattenOptions`: prompt blocks, app variables, external tools.
List<PickerOption> pickerOptions({
  required PickerActions actions,
  String? queryString,
  ContextBlockConfig? contextBlock,
  PromptBlockConfig? queryBlock,
  HistoryBlockConfig? historyBlock,
  PromptBlockConfig? requestUrlBlock,
  VariableBlockConfig? variableBlock,
  ExternalToolBlockConfig? externalToolBlock,
}) => [
  ...promptOptions(
    actions: actions,
    contextBlock: contextBlock,
    queryBlock: queryBlock,
    historyBlock: historyBlock,
    requestUrlBlock: requestUrlBlock,
  ),
  ...variableOptions(variableBlock, queryString, actions),
  ...externalToolOptions(externalToolBlock, queryString, actions),
];

/// useOptions' `workflowVariableOptions`: the workflow variables, led by flat entries for the current, last_run and
/// error_message blocks that show (in that order) unless the variables have them already.
List<VarGroup> workflowVariableOptions({
  WorkflowVariableBlockConfig? workflowVariableBlock,
  PromptBlockConfig? errorMessageBlock,
  PromptBlockConfig? lastRunBlock,
  CurrentBlockConfig? currentBlock,
}) {
  if (workflowVariableBlock == null || !workflowVariableBlock.show) return const [];
  final res = [...workflowVariableBlock.variables];
  bool has(String id) => res.any((g) => g.nodeId == id);
  if ((errorMessageBlock?.show ?? false) && !has('error_message')) {
    res.insert(
      0,
      const VarGroup(
        nodeId: 'error_message',
        title: 'error_message',
        isFlat: true,
        vars: [PickerVar('error_message', VarType.string)],
      ),
    );
  }
  if ((lastRunBlock?.show ?? false) && !has('last_run')) {
    res.insert(
      0,
      const VarGroup(
        nodeId: 'last_run',
        title: 'last_run',
        isFlat: true,
        vars: [PickerVar('last_run', VarType.object)],
      ),
    );
  }
  if (currentBlock case final cur? when cur.show && !has('current')) {
    res.insert(
      0,
      VarGroup(
        nodeId: 'current',
        title: cur.generatorType == PromptGeneratorType.prompt ? 'current_prompt' : 'current_code',
        isFlat: true,
        vars: const [PickerVar('current', VarType.string)],
      ),
    );
  }
  return res;
}
