/// The inline blocks of the prompt editor (the `component.tsx` of each prompt-editor plugin).
library;

import 'package:flutter/material.dart' show Colors;
import 'package:flutter/widgets.dart';

import '../../cards/variable_label.dart';
import '../../design/css_metrics.dart';
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';
import '../../workflow/var_types.dart' show VarType;
import '../panel_fields/var_reference_vars.dart' show VarFullPathPanel;
import 'prompt_editor_types.dart';

// The legacy palette some blocks still use (dify-ui styles.css).
const _gray50 = Color(0xFFF9FAFB), _gray100 = Color(0xFFF2F4F7), _gray500 = Color(0xFF667085);
const _gray700 = Color(0xFF475467), _gray800 = Color(0xFF1D2939), _primary600 = Color(0xFF155EEF);
const _indigo600 = Color(0xFF444CE7);

TextStyle _xsMedium(Color c) => difyTextStyle(DifyType.systemXsMedium, c);

/// Hover state for a block (`hover:` utilities).
class _Hover extends StatefulWidget {
  const _Hover({required this.builder});
  final Widget Function(BuildContext context, bool hovered) builder;

  @override
  State<_Hover> createState() => _HoverState();
}

class _HoverState extends State<_Hover> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => setState(() => _hovered = true),
    onExit: (_) => setState(() => _hovered = false),
    child: widget.builder(context, _hovered),
  );
}

/// The block's tap: Dify's `useSelectOrDelete` click selects the node; the click stops there (`stopPropagation`).
Widget _tappable(VoidCallback? onTap, Widget child) =>
    GestureDetector(behavior: HitTestBehavior.opaque, onTap: onTap ?? () {}, child: child);

// ---- workflow-variable-block/component.tsx ------------------------------------------------------------------------

bool _isSpecialVar(String prefix) => const ['sys', 'env', 'conversation', 'rag'].contains(prefix);

/// `hasErrorHandleNode` (workflow/utils/workflow.ts).
bool hasErrorHandleNode(String? type) =>
    const {'llm', 'tool', 'http-request', 'code', 'agent', 'agent-v2'}.contains(type);

/// `isExceptionVariable` (workflow/utils/variable.ts).
bool isExceptionVariable(String variable, String? nodeType) =>
    (variable == 'error_message' || variable == 'error_type') && hasErrorHandleNode(nodeType);

/// `useLlmModelPluginInstalled`: false only for an LLM node whose model provider's plugin is not installed.
bool llmModelPluginInstalled(
  String nodeId,
  Map<String, WorkflowNodeInfo>? workflowNodesMap,
  bool Function(String pluginId)? isInstalled,
) {
  final node = workflowNodesMap?[nodeId];
  final provider = node?.type == 'llm' ? node?.modelProvider : null;
  if (provider == null || provider.isEmpty) return true;
  return isInstalled?.call(extractPluginId(provider)) ?? true;
}

/// WorkflowVariableBlockComponent's checks for [variables]: the node it shows, whether only the last segment is
/// shown, the exception colour and the error message (invalid reference, model plugin missing).
({WorkflowNodeInfo? node, bool showAPart, bool isException, String? errorMsg}) workflowVariableState(
  List<String> variables,
  WorkflowVariableBlockConfig config,
) {
  final isRag = isRagVariableVar(variables);
  final showAPart = variables.length > 2 && !isRag;
  final sourceId = variables.length > (isRag ? 1 : 0) ? variables[isRag ? 1 : 0] : null;
  final node = sourceId == null ? null : config.workflowNodesMap[sourceId];
  final name = variables.isEmpty ? 'undefined' : '${isSystemVar(variables) ? 'sys.' : ''}${variables.last}';
  final valid = () {
    if (_isSpecialVar(variables.firstOrNull ?? '')) return true;
    if (variables.length < 2 || variables[1].isEmpty) return false;
    final source = config.variables.where((v) => v.nodeId == variables[0]).firstOrNull;
    return source != null && source.vars.any((v) => v.variable == variables[1]);
  }();
  final installed =
      sourceId == null || llmModelPluginInstalled(sourceId, config.workflowNodesMap, config.isModelPluginInstalled);
  return (
    node: node,
    showAPart: showAPart,
    isException: isExceptionVariable(name, node?.type),
    errorMsg: !valid
        ? DifyI18n.tr('workflow', 'errorMsg.invalidVariable')
        : !installed
        ? DifyI18n.tr('workflow', 'errorMsg.modelPluginNotInstalled')
        : null,
  );
}

/// The workflow variable block: VariableLabelInEditor, with the full path on hover for paths over two segments.
class WorkflowVariableChip extends StatelessWidget {
  const WorkflowVariableChip({
    super.key,
    required this.variables,
    required this.config,
    this.selected = false,
    this.onTap,
  });

  final List<String> variables;
  final WorkflowVariableBlockConfig config;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final s = workflowVariableState(variables, config);
    final node = s.node;
    final label = VariableLabel(
      variant: VarLabelStyle.inEditor,
      variables: variables,
      nodeType: node?.type,
      nodeTitle: node?.title,
      isExceptionVariable: s.isException,
      errorMsg: s.errorMsg,
      isSelected: selected,
      notShowFullPath: s.showAPart,
      onTap: () {
        onTap?.call();
        final id = variables.isEmpty ? null : variables[isRagVariableVar(variables) ? 1 : 0];
        if (node != null && id != null) config.onJumpToNode?.call(id);
      },
    );
    if (node == null || !s.showAPart) return label;
    return DifyTooltip(
      surface: false,
      placement: DifyPlacement.bottom,
      sideOffset: 8,
      content: VarFullPathPanel(
        nodeName: node.title,
        nodeType: node.type,
        path: variables.sublist(1),
        varType: config.getVarType?.call(variables[0], variables) ?? VarType.string,
      ),
      child: label,
    );
  }
}

// ---- context-block/component.tsx ----------------------------------------------------------------------------------

/// The context block: "Context" with the number of knowledge bases, which opens their list.
class ContextChip extends StatefulWidget {
  const ContextChip({super.key, required this.config, this.selected = false, this.onTap});
  final ContextBlockConfig config;
  final bool selected;
  final VoidCallback? onTap;

  @override
  State<ContextChip> createState() => _ContextChipState();
}

class _ContextChipState extends State<ContextChip> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.config;
    final title = DifyI18n.tr('common', 'promptEditor.context.item.title');
    return _Hover(
      builder: (context, hovered) => _tappable(
        widget.onTap,
        Container(
          height: 24,
          padding: const EdgeInsets.only(left: 4, right: 2),
          decoration: BoxDecoration(
            color: hovered || _open ? const Color(0xFFEBE9FE) : const Color(0xFFF4F3FF),
            borderRadius: BorderRadius.circular(5),
            border: Border.all(color: widget.selected ? const Color(0xFF9B8AFB) : const Color(0x00000000)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const DifyIcon(
                'vender/solid/files/file-05',
                key: Key('file-icon'),
                size: 14,
                color: Color(0xFF6938EF),
              ),
              const SizedBox(width: 4),
              Text(title, style: _xsMedium(const Color(0xFF6938EF))),
              const SizedBox(width: 4),
              if (!c.canNotAddContext)
                DifyPopover(
                  open: _open,
                  onOpenChange: (v) => setState(() => _open = v),
                  placement: DifyPlacement.bottomEnd,
                  sideOffset: 3,
                  alignOffset: -147,
                  surface: false,
                  builder: (context, _) => Semantics(
                    button: true,
                    label: title,
                    child: GestureDetector(
                      onTap: () => setState(() => _open = !_open),
                      child: Container(
                        width: 18,
                        height: 18,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: _open
                              ? const Color(0xFF6938EF)
                              : hovered
                              ? Colors.white
                              : Colors.white.withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(DifyRadius.sm),
                          boxShadow: hovered && !_open ? DifyShadows.xs : null,
                        ),
                        child: Text(
                          '${c.datasets.length}',
                          style: TextStyle(
                            fontSize: 11,
                            height: 1,
                            fontWeight: FontWeight.w600,
                            color: _open ? Colors.white : const Color(0xFF6938EF),
                          ),
                        ),
                      ),
                    ),
                  ),
                  content: _ContextModal(datasets: c.datasets, onAddContext: c.onAddContext),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ContextModal extends StatelessWidget {
  const _ContextModal({required this.datasets, this.onAddContext});
  final List<PromptDataset> datasets;
  final VoidCallback? onAddContext;

  @override
  Widget build(BuildContext context) {
    Widget box(Widget child, {Color? bg, Color border = _gray100}) => Container(
      width: 24,
      height: 24,
      margin: const EdgeInsets.only(right: 8),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(DifyRadius.md),
        border: Border.all(color: border, width: Css.hairline),
      ),
      child: Center(child: child),
    );
    return Container(
      width: 360,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(DifyRadius.xl),
        boxShadow: DifyShadows.lg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    DifyI18n.tr('common', 'promptEditor.context.modal.title', {'num': datasets.length}),
                    style: _xsMedium(_gray500),
                  ),
                ),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 270),
                  child: SingleChildScrollView(
                    child: Column(
                      children: [
                        for (final d in datasets)
                          SizedBox(
                            height: 32,
                            child: Row(
                              children: [
                                box(
                                  const DifyIcon(
                                    'vender/solid/files/folder',
                                    key: Key('folder-icon'),
                                    size: 16,
                                    color: _indigo600,
                                  ),
                                  bg: const Color(0xFFF5F8FF),
                                  border: const Color(0xFFEAECF5),
                                ),
                                Expanded(
                                  child: Text(
                                    d.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 14, height: 20 / 14, color: _gray800),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                DifyPressable(
                  onPressed: onAddContext,
                  semanticLabel: DifyI18n.tr('common', 'promptEditor.context.modal.add'),
                  builder: (context, hovered, focused) => SizedBox(
                    height: 32,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        box(const RemixIcon('add-line', size: 14, color: _primary600)),
                        Flexible(
                          child: Text(
                            DifyI18n.tr('common', 'promptEditor.context.modal.add'),
                            softWrap: false,
                            overflow: TextOverflow.visible,
                            style: const TextStyle(
                              fontSize: 13,
                              height: 18 / 13,
                              fontWeight: FontWeight.w500,
                              color: _primary600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: _gray50,
              border: Border(
                top: BorderSide(color: _gray50, width: Css.hairline),
              ),
              borderRadius: BorderRadius.vertical(bottom: Radius.circular(DifyRadius.xl)),
            ),
            child: Text(
              DifyI18n.tr('common', 'promptEditor.context.modal.footer'),
              style: const TextStyle(fontSize: 12, height: 16 / 12, color: _gray500),
            ),
          ),
        ],
      ),
    );
  }
}

// ---- history-block/component.tsx ----------------------------------------------------------------------------------

/// The history block: "Conversation History" and a "…" button that shows the role names.
class HistoryChip extends StatefulWidget {
  const HistoryChip({super.key, required this.config, this.selected = false, this.onTap});
  final HistoryBlockConfig config;
  final bool selected;
  final VoidCallback? onTap;

  @override
  State<HistoryChip> createState() => _HistoryChipState();
}

class _HistoryChipState extends State<HistoryChip> {
  bool _open = false;
  static const _pink = Color(0xFFDD2590);

  @override
  Widget build(BuildContext context) {
    final role = widget.config.history;
    // No truncate in Dify: long names and labels run on.
    Widget roleRow(String name, String key) => Row(
      children: [
        Container(
          width: 80,
          margin: const EdgeInsets.only(right: 4),
          child: Text(
            name,
            softWrap: false,
            overflow: TextOverflow.visible,
            style: const TextStyle(fontSize: 12, height: 16 / 12, fontWeight: FontWeight.w600, color: _gray700),
          ),
        ),
        Flexible(
          child: Text(
            DifyI18n.tr('common', key),
            softWrap: false,
            overflow: TextOverflow.visible,
            style: const TextStyle(fontSize: 14, height: 20 / 14, color: _gray700),
          ),
        ),
      ],
    );
    return _Hover(
      builder: (context, hovered) => _tappable(
        widget.onTap,
        Container(
          height: 24,
          padding: const EdgeInsets.only(left: 4, right: 2),
          decoration: BoxDecoration(
            color: hovered || _open ? const Color(0xFFFCE7F6) : const Color(0xFFFDF2FA),
            borderRadius: BorderRadius.circular(5),
            border: Border.all(color: widget.selected ? const Color(0xFFF670C7) : const Color(0x00000000)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const DifyIcon('vender/solid/general/message-clock-circle', size: 14, color: _pink),
              const SizedBox(width: 4),
              Text(DifyI18n.tr('common', 'promptEditor.history.item.title'), style: _xsMedium(_pink)),
              const SizedBox(width: 4),
              DifyPopover(
                open: _open,
                onOpenChange: (v) => setState(() => _open = v),
                placement: DifyPlacement.topEnd,
                sideOffset: 4,
                alignOffset: -148,
                surface: false,
                builder: (context, _) => GestureDetector(
                  onTap: () => setState(() => _open = !_open),
                  child: Container(
                    key: const Key('history-trigger'),
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      color: _open
                          ? _pink
                          : hovered
                          ? Colors.white
                          : Colors.white.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(DifyRadius.sm),
                      boxShadow: hovered && !_open ? DifyShadows.xs : null,
                    ),
                    child: Center(child: RemixIcon('more-fill', size: 12, color: _open ? Colors.white : _pink)),
                  ),
                ),
                content: Container(
                  width: 360,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(DifyRadius.xl),
                    boxShadow: DifyShadows.lg,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Text(
                                DifyI18n.tr('common', 'promptEditor.history.modal.title'),
                                style: _xsMedium(_gray500),
                              ),
                            ),
                            roleRow(role.user, 'promptEditor.history.modal.user'),
                            roleRow(role.assistant, 'promptEditor.history.modal.assistant'),
                          ],
                        ),
                      ),
                      GestureDetector(
                        onTap: widget.config.onEditRole,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          decoration: const BoxDecoration(
                            border: Border(top: BorderSide(color: Color(0x0D000000))),
                          ),
                          child: Text(
                            DifyI18n.tr('common', 'promptEditor.history.modal.edit'),
                            style: const TextStyle(fontSize: 12, height: 16 / 12, color: _primary600),
                          ),
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
}

// ---- query-block/component.tsx ------------------------------------------------------------------------------------

/// The query block: `{{` Query `}}` in orange.
class QueryChip extends StatelessWidget {
  const QueryChip({super.key, this.selected = false, this.onTap});
  final bool selected;
  final VoidCallback? onTap;

  static const _text = Color(0xFFEC4A0A);

  @override
  Widget build(BuildContext context) {
    final faint = _xsMedium(_text.withValues(alpha: 0.6));
    return _Hover(
      builder: (context, hovered) => _tappable(
        onTap,
        Container(
          height: 24,
          padding: const EdgeInsets.only(left: 4, right: 2),
          decoration: BoxDecoration(
            color: hovered ? const Color(0xFFFFEAD5) : const Color(0xFFFFF6ED),
            borderRadius: BorderRadius.circular(5),
            border: Border.all(color: selected ? const Color(0xFFFD853A) : const Color(0x00000000)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const DifyIcon('vender/solid/users/user-edit-02', size: 14, color: Color(0xFFFD853A)),
              const SizedBox(width: 4),
              Text('{{', style: faint),
              Text(DifyI18n.tr('common', 'promptEditor.query.item.title'), style: _xsMedium(_text)),
              Text('}}', style: faint),
            ],
          ),
        ),
      ),
    );
  }
}

// ---- current / error-message / last-run / request-url blocks ------------------------------------------------------

/// The small badge blocks: `mx-0.5 flex h-4.5 items-center rounded-[5px] border pr-0.75 pl-0.5`, accent border and
/// background when hovered or selected.
class _BadgeChip extends StatelessWidget {
  const _BadgeChip({
    required this.icon,
    required this.label,
    required this.color,
    this.selected = false,
    this.onTap,
    this.hoverBorder = DifyColors.stateAccentSolid,
    this.hoverBackground = true,
    this.padding = const EdgeInsets.only(left: 2, right: 3),
  });

  final Widget icon;
  final String label;
  final Color color;
  final bool selected;
  final VoidCallback? onTap;
  final Color hoverBorder;
  final bool hoverBackground;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => _Hover(
    builder: (context, hovered) {
      final accent = selected || hovered;
      return _tappable(
        onTap,
        Container(
          height: 18,
          margin: const EdgeInsets.symmetric(horizontal: 2),
          padding: padding,
          decoration: BoxDecoration(
            color: accent && hoverBackground ? DifyColors.stateAccentHover : DifyColors.componentsBadgeWhiteToDark,
            borderRadius: BorderRadius.circular(5),
            border: Border.all(color: accent ? hoverBorder : DifyColors.componentsPanelBorderSubtle),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              icon,
              const SizedBox(width: 2),
              Text(label, style: _xsMedium(color)),
            ],
          ),
        ),
      );
    },
  );
}

/// current-block: `current_prompt` / `current_code`.
class CurrentChip extends StatelessWidget {
  const CurrentChip({super.key, required this.generatorType, this.selected = false, this.onTap});
  final PromptGeneratorType generatorType;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final prompt = generatorType == PromptGeneratorType.prompt;
    const color = DifyColors.utilColorsVioletViolet600;
    return _BadgeChip(
      icon: DifyIcon(
        prompt ? 'vender/line/general/magic-edit' : 'vender/line/general/code-assistant',
        size: 14,
        color: color,
      ),
      label: prompt ? 'current_prompt' : 'current_code',
      color: color,
      selected: selected,
      onTap: onTap,
    );
  }
}

/// error-message-block: `error_message`.
class ErrorMessageChip extends StatelessWidget {
  const ErrorMessageChip({super.key, this.selected = false, this.onTap});
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => _BadgeChip(
    icon: const DifyIcon(
      'vender/solid/development/variable-02',
      size: 14,
      color: DifyColors.utilColorsOrangeDarkOrangeDark600,
    ),
    label: 'error_message',
    color: DifyColors.utilColorsOrangeDarkOrangeDark600,
    selected: selected,
    onTap: onTap,
  );
}

/// last-run-block: `last_run`.
class LastRunChip extends StatelessWidget {
  const LastRunChip({super.key, this.selected = false, this.onTap});
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => _BadgeChip(
    icon: const DifyIcon('vender/solid/development/variable-02', size: 14, color: DifyColors.textAccent),
    label: 'last_run',
    color: DifyColors.textAccent,
    selected: selected,
    onTap: onTap,
  );
}

/// request-url-block: the globe and "Request URL", with a violet border when hovered or selected.
class RequestUrlChip extends StatelessWidget {
  const RequestUrlChip({super.key, this.selected = false, this.onTap});
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => _BadgeChip(
    icon: const RemixIcon('global-line', size: 14, color: DifyColors.utilColorsVioletViolet600),
    label: DifyI18n.tr('common', 'promptEditor.requestURL.item.title'),
    color: DifyColors.utilColorsVioletViolet600,
    selected: selected,
    onTap: onTap,
    hoverBorder: const Color(0xFF7839EE),
    hoverBackground: false,
    padding: const EdgeInsets.symmetric(horizontal: 4),
  );
}
