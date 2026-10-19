/// The prompt field of the workflow panels (workflow/nodes/_base/components/prompt/editor.tsx): a title bar with
/// the character count, the Jinja switch, insert-variable, remove, copy and expand buttons over a
/// [DifyPromptEditor], or over the Jinja code editor in jinja2 mode.
library;

import 'package:collab_client/collab_client.dart';
import 'package:flutter/material.dart' show Colors;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../design/css_metrics.dart';
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';
import '../../workflow/var_types.dart' show plainOf;
import '../code_editor/code_editor.dart';
import '../node_panel/bodies/llm/group_host.dart' show LlmGroupScope, modelPluginInstalledIn;
import '../panel_fields/field.dart' show ToggleExpandBtn;
import '../panel_fields/var_picker_model.dart';
import 'prompt_editor.dart';

/// `EditionType`.
enum PromptEditionType { basic, jinja2 }

/// `hasSetBlockStatus`: which of the special blocks the prompt already has (the picker then can't add another).
typedef BlockStatus = ({bool context, bool history, bool query});

/// The Jinja editor's inputs (CodeEditor in editor-support-vars.tsx).
typedef JinjaEditorArgs = ({
  String value,
  ValueChanged<String> onChange,
  bool readOnly,
  bool isExpand,
  List<VarGroup> availableVars,
});

/// The workflow nodes map the variable blocks show (Editor's `availableNodes.reduce`): each node's title and type,
/// an LLM's model provider, and `sys` as the Start node.
Map<String, WorkflowNodeInfo> workflowNodesMapOf(Iterable<Node> nodes) {
  final map = <String, WorkflowNodeInfo>{};
  for (final n in nodes) {
    final model = n.type == 'llm' ? plainOf(n.config['model']) : null;
    final provider = model is Map ? model['provider'] : null;
    map[n.id] = WorkflowNodeInfo(title: n.title, type: n.type, modelProvider: provider is String ? provider : null);
    if (n.type == 'start') map['sys'] = WorkflowNodeInfo(title: DifyI18n.tr('workflow', 'blocks.start'), type: 'start');
  }
  return map;
}

/// Editor (prompt/editor.tsx). [title] and [titleTooltip] are strings or widgets. [nodesOutputVars] are the
/// variables on offer, [availableNodes] the nodes they come from. The context block shows with [isShowContext], the
/// history block for completion models in chat apps; [justVar] shows neither. [headerExtra] stands for the prompt
/// generator button. [expandedWidth] is the panel width less one (Wrap's `panelWidth - 1`). [jinjaEditorBuilder]
/// builds the jinja2 editor; by default the code editor in Python mode (Monaco's highlighting), without
/// editor-support-vars' `{` / `/` variable popup.
class DifyPromptEditorPanel extends StatefulWidget {
  const DifyPromptEditorPanel({
    super.key,
    required this.title,
    required this.value,
    required this.onChange,
    this.readOnly = false,
    this.showRemove = false,
    this.onRemove,
    this.justVar = false,
    this.isChatModel = false,
    this.isChatApp = false,
    this.isShowContext = false,
    this.hasSetBlockStatus = (context: false, history: false, query: false),
    this.nodesOutputVars = const [],
    this.availableNodes = const {},
    this.isSupportFileVar = false,
    this.isSupportJinja = false,
    this.editionType = PromptEditionType.basic,
    this.onEditionTypeChange,
    this.gradientBorder = true,
    this.titleTooltip,
    this.placeholder,
    this.required = false,
    this.headerExtra,
    this.getVarType,
    this.onJumpToNode,
    this.isModelPluginInstalled,
    this.showManageInputField = false,
    this.onManageInputField,
    this.expandedWidth = 419,
    this.onOpenUrl,
    this.jinjaEditorBuilder,
    this.controller,
    this.focusNode,
  });

  final Object title;
  final String value;
  final ValueChanged<String> onChange;
  final bool readOnly;
  final bool showRemove;
  final VoidCallback? onRemove;
  final bool justVar;
  final bool isChatModel;
  final bool isChatApp;
  final bool isShowContext;
  final BlockStatus hasSetBlockStatus;
  final List<VarGroup> nodesOutputVars;
  final Map<String, WorkflowNodeInfo> availableNodes;
  final bool isSupportFileVar;
  final bool isSupportJinja;
  final PromptEditionType editionType;
  final ValueChanged<PromptEditionType>? onEditionTypeChange;
  final bool gradientBorder;
  final Object? titleTooltip;
  final String? placeholder;
  final bool required;
  final Widget? headerExtra;
  final PromptGetVarType? getVarType;
  final void Function(String nodeId)? onJumpToNode;
  final bool Function(String pluginId)? isModelPluginInstalled;
  final bool showManageInputField;
  final VoidCallback? onManageInputField;
  final double expandedWidth;
  final void Function(String url)? onOpenUrl;
  final Widget Function(BuildContext context, JinjaEditorArgs args)? jinjaEditorBuilder;
  final PromptEditorController? controller;
  final FocusNode? focusNode;

  @override
  State<DifyPromptEditorPanel> createState() => _DifyPromptEditorPanelState();
}

class _DifyPromptEditorPanelState extends State<DifyPromptEditorPanel> {
  final _portal = OverlayPortalController();
  final _contentKey = GlobalKey();
  PromptEditorController? _ownController;
  FocusNode? _ownFocus;
  PromptEditorController get _controller => widget.controller ?? (_ownController ??= PromptEditorController());
  FocusNode get _focusNode => widget.focusNode ?? (_ownFocus ??= FocusNode(debugLabel: 'prompt panel'));
  bool _isFocus = false;
  bool _isExpand = false;
  bool _isCopied = false;

  @override
  void dispose() {
    _ownController?.dispose();
    _ownFocus?.dispose();
    super.dispose();
  }

  bool get _jinja => widget.isSupportJinja && widget.editionType == PromptEditionType.jinja2;

  void _setExpand(bool v) {
    setState(() => _isExpand = v);
    v ? _portal.show() : _portal.hide();
  }

  /// handleInsertVariable: focus the editor and type `/` at the caret (PROMPT_EDITOR_INSERT_QUICKLY).
  void _insertVariable() {
    setState(() => _isFocus = true);
    _focusNode.requestFocus();
    final c = _controller;
    if (!c.selection.isValid) c.selection = TextSelection.collapsed(offset: c.text.length);
    c.insertText('/');
  }

  Widget _titleText(Object t) => t is Widget
      ? t
      : Text('$t'.toUpperCase(), style: difyTextStyle(DifyType.systemXsSemiboldUppercase, DifyColors.textSecondary));

  Widget _header() {
    final w = widget;
    final tip = w.titleTooltip;
    return Padding(
      padding: const EdgeInsets.only(top: 4, right: 8, left: 12),
      child: Row(
        children: [
          Expanded(
            child: Row(
              spacing: 8,
              children: [
                Flexible(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(child: _titleText(w.title)),
                      if (w.required) ...[
                        Text(' ', style: difyTextStyle(DifyType.systemXsSemibold, DifyColors.textSecondary)),
                        Text('*', style: difyTextStyle(DifyType.systemXsSemibold, DifyColors.textDestructive)),
                      ],
                    ],
                  ),
                ),
                if (tip != null) _HoverPopover(label: tip is String ? tip : '${w.title}', content: tip, maxWidth: 300),
              ],
            ),
          ),
          Text(
            '${w.value.length}',
            style: TextStyle(
              fontSize: 12,
              height: 18 / 12,
              fontWeight: FontWeight.w500,
              color: DifyColors.textTertiary,
            ),
          ),
          // `<div className="ml-1.25">` around the inline button: the div's text line ends below it.
          if (w.headerExtra != null)
            Padding(
              padding: EdgeInsets.only(left: 5, bottom: Css.inlineButtonLineGap),
              child: w.headerExtra,
            ),
          Container(
            width: 1,
            height: 12,
            margin: const EdgeInsets.symmetric(horizontal: 8),
            color: DifyColors.dividerRegular,
          ),
          Row(
            spacing: 2,
            children: [
              if (w.isSupportJinja) _jinjaSwitch(),
              if (!w.readOnly)
                DifyTooltip(
                  content: Text(DifyI18n.tr('workflow', 'common.insertVarTip')),
                  child: DifyIconButton(
                    label: DifyI18n.tr('workflow', 'common.insertVarTip'),
                    onPressed: _insertVariable,
                    icon: const DifyIcon('vender/solid/development/variable-02', size: 16),
                  ),
                ),
              if (w.showRemove)
                DifyIconButton(
                  label: DifyI18n.tr('common', 'operation.remove'),
                  onPressed: w.onRemove,
                  icon: const RemixIcon('delete-bin-line', size: 16),
                ),
              DifyIconButton(
                label: DifyI18n.tr('common', 'operation.copy'),
                onPressed: _isCopied
                    ? null
                    : () {
                        Clipboard.setData(ClipboardData(text: w.value));
                        setState(() => _isCopied = true);
                      },
                icon: DifyIcon(_isCopied ? 'vender/line/files/copy-check' : 'vender/line/files/copy', size: 16),
              ),
              ToggleExpandBtn(isExpand: _isExpand, onExpandChange: _setExpand),
            ],
          ),
        ],
      ),
    );
  }

  Widget _jinjaSwitch() {
    final on = widget.editionType == PromptEditionType.jinja2;
    final label = DifyI18n.tr('workflow', 'common.enableJinja');
    return _Hover(
      builder: (context, hovered) => Container(
        height: 22,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(
          color: on ? DifyColors.componentsButtonGhostBgHover : null,
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: on || hovered ? DifyColors.componentsButtonGhostBgHover : const Color(0x00000000)),
        ),
        child: Row(
          spacing: 2,
          mainAxisSize: MainAxisSize.min,
          children: [
            _HoverPopover(
              label: label,
              trigger: SizedBox(
                width: 28,
                height: 16,
                child: Center(child: DifyIcon('vender/workflow/jinja', size: 24, color: DifyColors.textQuaternary)),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label),
                  GestureDetector(
                    onTap: () => widget.onOpenUrl?.call('https://jinja.palletsprojects.com/en/2.10.x/'),
                    child: Text(
                      DifyI18n.tr('workflow', 'common.learnMore'),
                      style: TextStyle(color: DifyColors.textAccent),
                    ),
                  ),
                ],
              ),
            ),
            DifySwitch(
              size: DifySwitchSize.sm,
              checked: on,
              semanticLabel: label,
              onCheckedChange: (v) =>
                  widget.onEditionTypeChange?.call(v ? PromptEditionType.jinja2 : PromptEditionType.basic),
            ),
          ],
        ),
      ),
    );
  }

  Widget _prompt(double? height) {
    final w = widget;
    final showHistory = !w.isChatModel && w.isChatApp;
    return DifyPromptEditor(
      controller: _controller,
      focusNode: _focusNode,
      placeholder: w.placeholder,
      compact: true,
      minHeight: 56,
      height: height,
      value: w.value,
      contextBlock: ContextBlockConfig(
        show: !w.justVar && w.isShowContext,
        selectable: !w.hasSetBlockStatus.context,
        canNotAddContext: true,
      ),
      historyBlock: HistoryBlockConfig(
        show: !w.justVar && showHistory,
        selectable: !w.hasSetBlockStatus.history,
        history: (user: 'Human', assistant: 'Assistant'),
      ),
      queryBlock: const PromptBlockConfig(), // [sys.query] stands in for the query block
      workflowVariableBlock: WorkflowVariableBlockConfig(
        show: true,
        variables: w.nodesOutputVars,
        getVarType: w.getVarType,
        workflowNodesMap: w.availableNodes,
        showManageInputField: w.showManageInputField,
        onManageInputField: w.onManageInputField,
        onJumpToNode: w.onJumpToNode,
        isModelPluginInstalled: w.isModelPluginInstalled ?? modelPluginInstalledIn(LlmGroupScope.of(context).models),
      ),
      onChange: w.onChange,
      onBlur: () => setState(() => _isFocus = false),
      onFocus: () => setState(() => _isFocus = true),
      editable: !w.readOnly,
      isSupportFileVar: w.isSupportFileVar,
    );
  }

  Widget _jinjaEditor() {
    final w = widget;
    final args = (
      value: w.value,
      onChange: w.onChange,
      readOnly: w.readOnly,
      isExpand: _isExpand,
      availableVars: w.nodesOutputVars,
    );
    if (w.jinjaEditorBuilder != null) return w.jinjaEditorBuilder!(context, args);
    // editor-support-vars.tsx: the bare (noWrapper) Monaco editor in Python mode, sized from its content.
    return DifyCodeEditor(
      value: w.value,
      language: CodeLanguage.python3,
      onChange: w.onChange,
      readOnly: w.readOnly,
      noWrapper: true,
      isInNode: true,
      isExpand: _isExpand,
      placeholder: DifyI18n.tr('workflow', 'common.jinjaEditorPlaceholder'),
    );
  }

  /// The gradient frame, the title bar and the editor (Wrap's child). Expanded, the editor fills the frame.
  Widget _content({bool expand = false}) {
    final w = widget;
    final focus = _isFocus;
    Widget body(double? height) {
      Widget b = Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: _jinja ? _jinjaEditor() : _prompt(height),
      );
      b = expand
          ? b
          : ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 56, maxHeight: 536),
              child: SingleChildScrollView(child: b),
            );
      return w.readOnly ? AbsorbPointer(child: b) : b;
    }

    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(9),
        gradient: focus && w.gradientBorder
            ? LinearGradient(
                colors: [DifyColors.componentsInputBorderActivePrompt1, DifyColors.componentsInputBorderActivePrompt2],
              )
            : null,
      ),
      child: Container(
        decoration: BoxDecoration(
          color: focus ? DifyColors.backgroundDefault : DifyColors.componentsInputBgNormal,
          borderRadius: BorderRadius.circular(DifyRadius.lg),
        ),
        child: Column(
          mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(),
            if (expand)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: LayoutBuilder(builder: (context, c) => body(c.maxHeight)),
                ),
              )
            else
              Padding(padding: const EdgeInsets.only(bottom: 8), child: body(null)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => OverlayPortal(
    controller: _portal,
    overlayChildBuilder: (context) => Positioned(
      right: 9,
      top: 166,
      bottom: 8,
      width: widget.expandedWidth,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: DifyColors.componentsPanelBg,
          borderRadius: BorderRadius.circular(DifyRadius.xl),
          boxShadow: const [
            BoxShadow(offset: Offset(0, 0), blurRadius: 12, spreadRadius: -4, color: Color(0x0D101828)),
            BoxShadow(offset: Offset(0, -3), blurRadius: 6, spreadRadius: -2, color: Color(0x08101828)),
          ],
        ),
        child: KeyedSubtree(key: _contentKey, child: _content(expand: true)),
      ),
    ),
    // Expanded, the editor is `fixed` over the panel and leaves its place empty.
    child: _isExpand ? const SizedBox.shrink() : KeyedSubtree(key: _contentKey, child: _content()),
  );
}

/// Hover state.
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

/// A Popover whose trigger opens it on hover (`openOnHover`): the title tooltip's question mark (16 px, the icon
/// quaternary, tertiary on hover) or [trigger]; the content in `px-3 py-2 system-xs-regular text-text-tertiary`.
class _HoverPopover extends StatelessWidget {
  const _HoverPopover({required this.label, required this.content, this.trigger, this.maxWidth});
  final String label;
  final Object content;
  final Widget? trigger;
  final double? maxWidth;

  @override
  Widget build(BuildContext context) => DifyTooltip(
    placement: DifyPlacement.bottom,
    surface: false,
    content: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth ?? double.infinity),
      child: DifyPopoverSurface(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: DefaultTextStyle.merge(
          style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textTertiary),
          child: content is Widget ? content as Widget : Text('$content'),
        ),
      ),
    ),
    child: Semantics(
      button: true,
      label: label,
      child:
          trigger ??
          _Hover(
            builder: (context, hovered) => Container(
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                color: hovered ? DifyColors.stateBaseHover : Colors.transparent,
                borderRadius: BorderRadius.circular(DifyRadius.sm),
              ),
              child: Center(
                child: RemixIcon(
                  'question-line',
                  size: 14,
                  color: hovered ? DifyColors.textTertiary : DifyColors.textQuaternary,
                ),
              ),
            ),
          ),
    ),
  );
}
