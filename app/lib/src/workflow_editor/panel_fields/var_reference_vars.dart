/// The variable list of the reference picker (nodes/_base/components/variable/var-reference-vars.tsx,
/// var-reference-popup.tsx, manage-input-field.tsx, object-child-tree-panel/picker/, var-full-path-panel.tsx).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../canvas/node_card.dart' show blockColor;
import '../../cards/card_kit.dart';
import '../../design/css_metrics.dart';
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';
import '../../workflow/var_types.dart';
import 'field.dart';
import 'var_picker_model.dart';

/// Dify's `onChange(valueSelector, varDetail)`.
typedef VarSelected = void Function(List<String> selector, PickerVar item);

/// useVarIcon / useVarColor with a variable category (`loop`, `rag`, `environment`, `conversation`).
(String, Color) varIconAndColor(List<String> v, {String? category, bool isException = false}) {
  final icon = switch (category) {
    'loop' => 'vender/workflow/loop',
    'rag' => 'vender/pipeline/input-field',
    'environment' => 'vender/line/others/env',
    'conversation' => 'vender/line/others/bubble-x',
    _ => varIcon(v),
  };
  final color = isException
      ? DifyColors.textWarning
      : switch (category) {
          'loop' => DifyColors.utilColorsCyanCyan500,
          'environment' => DifyColors.utilColorsVioletViolet600,
          'conversation' => DifyColors.utilColorsTealTeal700,
          _ => varColor(v),
        };
  return (icon, color);
}

/// VariableIconWithColor with a category.
class CategoryVarIcon extends StatelessWidget {
  const CategoryVarIcon({super.key, required this.variables, this.category, this.isException = false, this.size = 14});
  final List<String> variables;
  final String? category;
  final bool isException;
  final double size;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = varIconAndColor(variables, category: category, isException: isException);
    return DifyIcon(icon, size: size, color: color);
  }
}

/// BlockIcon (block-icon.tsx) in the `xs` (16 px) and `sm` (20 px) sizes: the type's colour with its white glyph.
class SmallBlockIcon extends StatelessWidget {
  const SmallBlockIcon({super.key, required this.type, this.size = 20});
  final String type;
  final double size;

  @override
  Widget build(BuildContext context) {
    final xs = size <= 16;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: blockColor(type),
        borderRadius: BorderRadius.circular(xs ? 5 : DifyRadius.md),
        border: Border.all(color: const Color(0x05FFFFFF), width: 0.5),
        boxShadow: DifyShadows.xs,
      ),
      child: Center(
        child: DifyIcon(
          type == 'start' ? 'vender/workflow/user-input' : blockGlyph(type),
          size: xs ? 12 : 14,
          color: const Color(0xFFFFFFFF),
        ),
      ),
    );
  }
}

/// The search field of the list: an InputGroup with `i-ri-search-line` in front and, with text, a clear button.
class _SearchBox extends StatelessWidget {
  const _SearchBox({required this.value, required this.onChanged, required this.focusNode, required this.onKey});
  final String value;
  final ValueChanged<String> onChanged;
  final FocusNode focusNode;
  final FocusOnKeyEventCallback onKey;

  @override
  Widget build(BuildContext context) {
    final label = DifyI18n.tr('workflow', 'common.searchVar');
    return DifyInput(
      focusInteractiveAddons: false,
      value: value,
      onChanged: onChanged,
      placeholder: label,
      semanticLabel: label,
      focusNode: focusNode,
      onKeyEvent: onKey,
      leading: Padding(
        padding: EdgeInsets.only(left: 8, right: 4),
        child: RemixIcon('search-line', size: 16, color: DifyColors.componentsInputTextPlaceholder),
      ),
      trailing: value.isEmpty
          ? null
          : Padding(
              padding: const EdgeInsets.only(left: 2, right: 8),
              child: DifyIconButton(
                label: DifyI18n.tr('common', 'operation.clear'),
                size: DifyIconButtonSize.xs,
                onPressed: () {
                  onChanged('');
                  focusNode.requestFocus();
                },
                icon: RemixIcon('close-circle-fill', size: 14, color: DifyColors.textQuaternary),
              ),
            ),
    );
  }
}

/// VarReferenceVars: an optional search box, then the variables grouped by node (group titles in
/// `system-xs-medium-uppercase`), "No variable" when nothing matches, and the RAG "manage input field" row.
/// The first item is selected; ArrowUp / ArrowDown move the selection, Enter chooses it and Escape calls [onClose]
/// (from the search box, or from anywhere with [hideSearch], as the prompt editor's slash menu). Object and file
/// variables open their members to the left on hover (or a tap on the chevron).
class VarReferenceVars extends StatefulWidget {
  const VarReferenceVars({
    super.key,
    required this.vars,
    required this.onChange,
    this.hideSearch = false,
    this.searchText,
    this.isSupportFileVar = false,
    this.maxHeight,
    this.onClose,
    this.onBlur,
    this.isInCodeGeneratorInstructionEditor = false,
    this.showManageInputField = false,
    this.onManageInputField,
    this.searchFocusNode,
    this.preferSchemaType = false,
    this.tapRegionGroup,
  });

  final List<VarGroup> vars;
  final VarSelected onChange;
  final bool hideSearch;

  /// Search text controlled from outside (the prompt editor's typed query).
  final String? searchText;
  final bool isSupportFileVar;
  final double? maxHeight;
  final VoidCallback? onClose;

  /// The search box lost focus.
  final VoidCallback? onBlur;
  final bool isInCodeGeneratorInstructionEditor;
  final bool showManageInputField;
  final VoidCallback? onManageInputField;
  final FocusNode? searchFocusNode;
  final bool preferSchemaType;

  /// The enclosing popup's tap region group, so member panels count as inside it.
  final Object? tapRegionGroup;

  @override
  State<VarReferenceVars> createState() => _VarReferenceVarsState();
}

class _VarReferenceVarsState extends State<VarReferenceVars> {
  String _search = '';
  int _selected = -1;
  FocusNode? _ownFocus;
  final _selectedKey = GlobalKey();

  FocusNode get _focus => widget.searchFocusNode ?? (_ownFocus ??= FocusNode(debugLabel: 'var search'));

  String get _query => widget.searchText ?? _search;

  late List<VarGroup> _filtered = filterReferenceVars(widget.vars, _query);

  List<(String, bool, PickerVar)> get _items => [
    for (final g in _filtered)
      for (final v in g.vars) (g.nodeId, g.isFlat, v),
  ];

  int get _effective {
    final n = _items.length;
    return n == 0 ? -1 : _selected.clamp(0, n - 1);
  }

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocus);
    if (widget.hideSearch) HardwareKeyboard.instance.addHandler(_onGlobalKey);
  }

  @override
  void didUpdateWidget(VarReferenceVars old) {
    super.didUpdateWidget(old);
    if (old.vars != widget.vars || old.searchText != widget.searchText) {
      _filtered = filterReferenceVars(widget.vars, _query);
    }
    if (old.hideSearch != widget.hideSearch) {
      widget.hideSearch
          ? HardwareKeyboard.instance.addHandler(_onGlobalKey)
          : HardwareKeyboard.instance.removeHandler(_onGlobalKey);
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onGlobalKey);
    _focus.removeListener(_onFocus);
    _ownFocus?.dispose();
    super.dispose();
  }

  void _onFocus() {
    if (!_focus.hasFocus) widget.onBlur?.call();
  }

  void _setSearch(String s) => setState(() {
    _search = s;
    _filtered = filterReferenceVars(widget.vars, _query);
  });

  void _choose(int index) {
    final items = _items;
    if (index < 0 || index >= items.length) return;
    final (nodeId, isFlat, item) = items[index];
    final selector = resolveValueSelector(
      item,
      isFlat: isFlat,
      isSupportFileVar: widget.isSupportFileVar,
      nodeId: nodeId,
    );
    if (selector != null) widget.onChange(selector, item);
  }

  /// handleKeyboardEvent: true when the key was used.
  bool _key(LogicalKeyboardKey k) {
    if (k == LogicalKeyboardKey.escape) {
      widget.onClose?.call();
      return true;
    }
    final n = _items.length;
    if (n == 0) return false;
    if (k == LogicalKeyboardKey.arrowDown || k == LogicalKeyboardKey.arrowUp) {
      final e = _effective;
      setState(() => _selected = k == LogicalKeyboardKey.arrowDown ? (e + 1).clamp(0, n - 1) : (e - 1).clamp(0, n - 1));
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final c = _selectedKey.currentContext;
        if (c != null && c.mounted) {
          Scrollable.ensureVisible(c, alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd);
        }
      });
      return true;
    }
    if (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter) {
      _choose(_effective);
      return true;
    }
    return false;
  }

  KeyEventResult _onSearchKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    return _key(e.logicalKey) ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  bool _onGlobalKey(KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return false;
    final kb = HardwareKeyboard.instance;
    if (kb.isAltPressed || kb.isControlPressed || kb.isMetaPressed) return false;
    final keys = {
      LogicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.arrowUp,
      LogicalKeyboardKey.enter,
      LogicalKeyboardKey.numpadEnter,
      LogicalKeyboardKey.escape,
    };
    if (!keys.contains(e.logicalKey)) return false;
    return _key(e.logicalKey);
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final groups = _filtered;
    final selected = _effective;
    final hasNonFlat = groups.any((g) => !g.isFlat);
    var index = 0;
    final children = <Widget>[];
    for (final (i, g) in groups.indexed) {
      children.add(
        Padding(
          padding: EdgeInsets.only(top: !g.isFlat ? 12 : (i == 0 ? 8 : 0)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!g.isFlat)
                Container(
                  height: 22,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  alignment: Alignment.centerLeft,
                  child: DifyText(g.title, DifyType.systemXsMediumUppercase, color: DifyColors.textTertiary),
                ),
              for (final v in g.vars)
                () {
                  final at = index++;
                  return VarReferenceItem(
                    key: at == selected ? _selectedKey : null,
                    nodeId: g.nodeId,
                    title: g.title,
                    item: v,
                    onChange: w.onChange,
                    isSupportFileVar: w.isSupportFileVar,
                    isException: v.isException,
                    isLoopVar: g.isLoop,
                    isFlat: g.isFlat,
                    isInCodeGeneratorInstructionEditor: w.isInCodeGeneratorInstructionEditor,
                    preferSchemaType: w.preferSchemaType,
                    isSelected: at == selected,
                    onActivate: () => setState(() => _selected = at),
                    tapRegionGroup: w.tapRegionGroup,
                  );
                }(),
              if (g.isFlat && !(i + 1 < groups.length && groups[i + 1].isFlat) && hasNonFlat) const _LastOutputRule(),
            ],
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!w.hideSearch) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
            child: _SearchBox(value: _search, onChanged: _setSearch, focusNode: _focus, onKey: _onSearchKey),
          ),
          // `relative -left-1 h-[0.5px] bg-black/5` as wide as the popup's padding box.
          LayoutBuilder(
            builder: (context, c) => SizedBox(
              height: 0.5,
              child: OverflowBox(
                minWidth: c.maxWidth + 8,
                maxWidth: c.maxWidth + 8,
                child: const ColoredBox(color: Color(0x0D000000)),
              ),
            ),
          ),
        ],
        if (groups.isNotEmpty)
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: w.maxHeight ?? MediaQuery.sizeOf(context).height * 0.85),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: children,
              ),
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.only(top: 8, left: 12),
            child: Text(
              DifyI18n.tr('workflow', 'common.noVar').toUpperCase(),
              style: TextStyle(
                fontSize: 12,
                height: 18 / 12,
                fontWeight: FontWeight.w500,
                color: DifyColors.utilColorsGrayGray500,
              ),
            ),
          ),
        if (w.showManageInputField) ManageInputField(onManage: w.onManageInputField ?? () {}),
      ],
    );
  }
}

/// The "LAST OUTPUT" rule after the flat variables (code generator).
class _LastOutputRule extends StatelessWidget {
  const _LastOutputRule();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 14),
    child: Row(
      spacing: 4,
      children: [
        Container(width: 12, height: 2, color: DifyColors.dividerSubtle),
        DifyText(
          DifyI18n.tr('workflow', 'debug.lastOutput'),
          DifyType.system2xsSemiboldUppercase,
          color: DifyColors.textTertiary,
        ),
        Expanded(child: Container(height: 2, color: DifyColors.dividerSubtle)),
      ],
    ),
  );
}

/// ManageInputField (RAG pipelines): "+ Create user input field" | "Manage".
class ManageInputField extends StatelessWidget {
  const ManageInputField({super.key, required this.onManage});
  final VoidCallback onManage;

  @override
  Widget build(BuildContext context) {
    Widget tap(Widget child) => GestureDetector(behavior: HitTestBehavior.opaque, onTap: onManage, child: child);
    return Container(
      padding: const EdgeInsets.only(top: 4),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: DifyColors.dividerSubtle)),
      ),
      child: Row(
        children: [
          Expanded(
            child: tap(
              Container(
                height: 32,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    RemixIcon('add-line', size: 16, color: DifyColors.textTertiary),
                    const SizedBox(width: 4),
                    Flexible(
                      child: DifyText(
                        DifyI18n.tr('pipeline', 'inputField.create'),
                        DifyType.systemXsMedium,
                        color: DifyColors.textTertiary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Container(
            width: 1,
            height: 12,
            margin: const EdgeInsets.symmetric(horizontal: 4),
            color: DifyColors.dividerRegular,
          ),
          tap(
            Container(
              height: 32,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              alignment: Alignment.center,
              child: DifyText(
                DifyI18n.tr('pipeline', 'inputField.manage'),
                DifyType.systemXsMedium,
                color: DifyColors.textTertiary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One variable row (the `Item` of var-reference-vars.tsx): `h-6 rounded-md pl-3`, the variable icon, its name
/// (`system-sm-medium text-text-secondary`), its type (capitalised, tertiary) and for objects a chevron; hovered or
/// selected it takes `bg-state-base-hover` (objects: `bg-components-panel-on-panel-item-bg-hover`).
class VarReferenceItem extends StatefulWidget {
  const VarReferenceItem({
    super.key,
    required this.nodeId,
    required this.title,
    required this.item,
    required this.onChange,
    this.objPath = const [],
    this.isSupportFileVar = false,
    this.isException = false,
    this.isLoopVar = false,
    this.isFlat = false,
    this.isInCodeGeneratorInstructionEditor = false,
    this.preferSchemaType = false,
    this.isSelected = false,
    this.onActivate,
    this.tapRegionGroup,
  });

  final String nodeId, title;
  final PickerVar item;
  final VarSelected onChange;
  final List<String> objPath;
  final bool isSupportFileVar, isException, isLoopVar, isFlat, isInCodeGeneratorInstructionEditor;
  final bool preferSchemaType, isSelected;
  final VoidCallback? onActivate;
  final Object? tapRegionGroup;

  @override
  State<VarReferenceItem> createState() => _VarReferenceItemState();
}

class _VarReferenceItemState extends State<VarReferenceItem> {
  bool _itemHover = false, _childHover = false, _pinned = false;
  Timer? _leave;

  @override
  void dispose() {
    _leave?.cancel();
    super.dispose();
  }

  PickerVar get _v => widget.item;
  bool get _isStructured => _v.type == VarType.object && _v.schemaProperties != null;
  bool get _isObj => (_v.type == VarType.object || _v.type == VarType.file) && _v.childVars.isNotEmpty;
  bool get _hasPanel => _isObj || _isStructured;

  /// The members as a structured output (objPath children typed with varTypeToStructType).
  Map<String, Object?> get _schema => _isStructured
      ? (_v.children! as Map)['schema'] as Map<String, Object?>
      : {
          'type': 'object',
          'properties': {
            for (final c in _v.childVars) c.variable: {'type': varTypeToStructType(c.type)},
          },
        };

  void _hover(bool on) {
    _leave?.cancel();
    if (on) {
      setState(() => _itemHover = true);
      widget.onActivate?.call();
    } else if (_hasPanel) {
      _leave = Timer(const Duration(milliseconds: 100), () {
        if (mounted) setState(() => _itemHover = false);
      });
    } else {
      setState(() => _itemHover = false);
    }
  }

  void _choose() {
    final selector = resolveValueSelector(
      _v,
      isFlat: widget.isFlat,
      isSupportFileVar: widget.isSupportFileVar,
      nodeId: widget.nodeId,
      objPath: widget.objPath,
    );
    if (selector != null) widget.onChange(selector, _v);
  }

  Widget _icon() {
    if (!widget.isFlat) {
      return CategoryVarIcon(
        variables: _v.variable.split('.'),
        category: varsVariableCategory(
          isEnv: _v.variable.startsWith('env.'),
          isChatVar: _v.variable.startsWith('conversation.'),
          isLoopVar: widget.isLoopVar,
          isRagVariable: _v.isRagVariable,
        ),
        isException: widget.isException,
      );
    }
    return switch (_v.variable) {
      'current' => DifyIcon(
        widget.isInCodeGeneratorInstructionEditor
            ? 'vender/line/general/code-assistant'
            : 'vender/line/general/magic-edit',
        size: 14,
        color: DifyColors.utilColorsVioletViolet600,
      ),
      'error_message' => DifyIcon(
        'vender/solid/development/variable-02',
        size: 14,
        color: DifyColors.utilColorsOrangeDarkOrangeDark600,
      ),
      _ => DifyIcon('vender/solid/development/variable-02', size: 14, color: DifyColors.textAccent),
    };
  }

  String get _name {
    final v = _v.variable;
    if (v.startsWith('env.')) return v.substring(4);
    if (v.startsWith('conversation.')) return v.substring(13);
    if (_v.isRagVariable) return v.split('.').last;
    return varsDisplayName(
      v,
      widget.isFlat,
      isInCodeGeneratorInstructionEditor: widget.isInCodeGeneratorInstructionEditor,
    );
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final hovering = _itemHover || _childHover || _pinned;
    final type = w.preferSchemaType && _v.schemaType != null ? _v.schemaType : _v.type;
    final row = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => _hover(true),
      onExit: (_) => _hover(false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _choose,
        child: Container(
          height: 24,
          padding: EdgeInsets.only(left: 12, right: _hasPanel ? 4 : 18),
          decoration: BoxDecoration(
            color: hovering || w.isSelected
                ? (_hasPanel ? DifyColors.componentsPanelOnPanelItemBgHover : DifyColors.stateBaseHover)
                : null,
            borderRadius: BorderRadius.circular(DifyRadius.md),
          ),
          child: Row(
            children: [
              _icon(),
              const SizedBox(width: 4),
              Expanded(child: DifyText(_name, DifyType.systemSmMedium, color: DifyColors.textSecondary)),
              const SizedBox(width: 4),
              Text(
                cssCapitalize(type ?? ''),
                style: TextStyle(fontSize: 12, height: 16 / 12, color: DifyColors.textTertiary),
              ),
              if (_hasPanel)
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => setState(() => _pinned = !_pinned),
                  child: Padding(
                    padding: const EdgeInsets.only(left: 2),
                    child: DifyIcon(
                      'vender/line/arrows/chevron-right',
                      size: 12,
                      color: hovering ? DifyColors.textTertiary : DifyColors.textQuaternary,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    final item = Semantics(selected: w.isSelected, button: true, child: row);
    if (!_hasPanel) return item;
    return DifyFloating(
      open: hovering,
      placement: DifyPlacement.leftStart,
      dismissible: false,
      focusPopup: false,
      tapRegionGroup: w.tapRegionGroup,
      builder: (context, _) => item,
      popupBuilder: (context) => PickerStructurePanel(
        nodeId: w.nodeId,
        nodeName: w.title,
        attrName: _v.variable,
        attrAlias: _v.schemaType,
        schema: _schema,
        onHovering: (h) {
          _leave?.cancel();
          if (h) {
            setState(() => _childHover = true);
          } else {
            _leave = Timer(const Duration(milliseconds: 100), () {
              if (mounted) setState(() => _childHover = false);
            });
          }
        },
        onSelect: (sel) {
          setState(() => _pinned = false);
          w.onChange(sel, _v);
        },
      ),
    );
  }
}

/// PickerPanel (object-child-tree-panel/picker): `w-74 rounded-xl border-[0.5px] bg-components-panel-bg-blur p-1
/// shadow-lg backdrop-blur-[5px]` with the root (`node.attr` and its type) over the member tree.
class PickerStructurePanel extends StatelessWidget {
  const PickerStructurePanel({
    super.key,
    this.nodeId,
    this.nodeName,
    required this.attrName,
    this.attrAlias,
    required this.schema,
    this.readonly = false,
    this.onSelect,
    this.onHovering,
    this.bare = false,
  });

  final String? nodeId, nodeName;
  final String attrName;
  final String? attrAlias;

  /// The structured output's `schema` (`{type: object, properties}`).
  final Map<String, Object?> schema;
  final bool readonly;
  final ValueChanged<List<String>>? onSelect;
  final ValueChanged<bool>? onHovering;

  /// PickerPanelMain alone (no surface).
  final bool bare;

  @override
  Widget build(BuildContext context) {
    final props = (schema['properties'] as Map<String, Object?>?) ?? const {};
    Widget main = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              if (nodeName != null) ...[
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 100),
                  child: DifyText(nodeName!, DifyType.systemSmMedium, color: DifyColors.textTertiary),
                ),
                DifyText('.', DifyType.systemSmMedium, color: DifyColors.textTertiary),
              ],
              DifyText(attrName, DifyType.systemSmMedium, color: DifyColors.textSecondary),
              const SizedBox(width: 8),
              const Spacer(),
              Flexible(
                child: DifyText(attrAlias ?? 'object', DifyType.systemXsRegular, color: DifyColors.textTertiary),
              ),
            ],
          ),
        ),
        for (final e in props.entries)
          _StructField(
            name: e.key,
            field: e.value is Map<String, Object?> ? e.value as Map<String, Object?> : const {},
            selector: [nodeId ?? '', attrName],
            readonly: readonly,
            onSelect: onSelect,
          ),
      ],
    );
    if (onHovering != null) {
      main = MouseRegion(onEnter: (_) => onHovering!(true), onExit: (_) => onHovering!(false), child: main);
    }
    if (bare) return main;
    return DifyBlurredBox(
      blur: 5,
      borderRadius: BorderRadius.circular(DifyRadius.xl),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: DifyColors.componentsPanelBgBlur,
        borderRadius: BorderRadius.circular(DifyRadius.xl),
        border: Border.all(color: DifyColors.componentsPanelBorder, width: Css.hairline),
        boxShadow: DifyShadows.lg,
      ),
      child: SizedBox(width: 296 - 8, child: main),
    );
  }
}

/// One member row of the tree (picker/field.tsx): indent lines per depth, the name and its type; past depth 10 a
/// "…" with the "more" tooltip. Pressing a row selects its path (unless [readonly], which highlights leaves).
class _StructField extends StatefulWidget {
  const _StructField({
    required this.name,
    required this.field,
    required this.selector,
    this.depth = 1,
    this.readonly = false,
    this.onSelect,
  });
  final String name;
  final Map<String, Object?> field;
  final List<String> selector;
  final int depth;
  final bool readonly;
  final ValueChanged<List<String>>? onSelect;

  static const maxDepth = 10;

  @override
  State<_StructField> createState() => _StructFieldState();
}

class _StructFieldState extends State<_StructField> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final w = widget;
    if (w.depth > _StructField.maxDepth + 1) return const SizedBox.shrink();
    final props = w.field['type'] == 'object' ? w.field['properties'] as Map<String, Object?>? : null;
    final more = w.depth == _StructField.maxDepth + 1;
    final highlight = w.readonly && props == null;
    Widget row = Container(
      height: 24,
      padding: const EdgeInsets.only(right: 8),
      decoration: BoxDecoration(
        color: _hovered && !w.readonly ? DifyColors.stateBaseHover : null,
        borderRadius: BorderRadius.circular(DifyRadius.md),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TreeIndentLine(depth: w.depth),
          if (more)
            Center(child: RemixIcon('more-fill', size: 12, color: DifyColors.textTertiary))
          else
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: DifyText(
                  w.name,
                  DifyType.systemSmMedium,
                  color: highlight ? DifyColors.textAccent : DifyColors.textSecondary,
                ),
              ),
            ),
          if (!more) ...[
            const SizedBox(width: 8),
            Center(child: DifyText(fieldTypeOf(w.field), DifyType.systemXsRegular, color: DifyColors.textTertiary)),
          ],
        ],
      ),
    );
    row = MouseRegion(
      cursor: more ? SystemMouseCursors.basic : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: w.readonly ? null : (_) => w.onSelect?.call([...w.selector, w.name]),
        child: row,
      ),
    );
    if (more) row = DifyTooltip(content: Text(DifyI18n.tr('app', 'structOutput.moreFillTip')), child: row);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        row,
        if (w.depth <= _StructField.maxDepth && props != null)
          for (final e in props.entries)
            _StructField(
              name: e.key,
              field: e.value is Map<String, Object?> ? e.value as Map<String, Object?> : const {},
              selector: [...w.selector, w.name],
              depth: w.depth + 1,
              readonly: w.readonly,
              onSelect: w.onSelect,
            ),
      ],
    );
  }
}

/// VarFullPathPanel: the hover card of a nested selection: `w-70 rounded-xl` blur surface with the node (xs block
/// icon and title) over the path as a read-only tree, the last segment typed [varType].
class VarFullPathPanel extends StatelessWidget {
  const VarFullPathPanel({super.key, required this.nodeName, required this.path, required this.varType, this.nodeType});
  final String nodeName;

  /// The selector without its node.
  final List<String> path;
  final String varType;
  final String? nodeType;

  @override
  Widget build(BuildContext context) {
    final root = <String, Object?>{'type': 'object', 'properties': <String, Object?>{}};
    var current = root;
    for (var i = 1; i < path.length; i++) {
      final last = i == path.length - 1;
      final next = <String, Object?>{'type': last ? varType : 'object', 'properties': <String, Object?>{}};
      (current['properties'] as Map<String, Object?>)[path[i]] = next;
      current = next;
    }
    return DifyBlurredBox(
      blur: 5,
      borderRadius: BorderRadius.circular(DifyRadius.xl),
      decoration: BoxDecoration(
        color: DifyColors.componentsPanelBgBlur,
        borderRadius: BorderRadius.circular(DifyRadius.xl),
        border: Border.all(color: DifyColors.componentsPanelBorder, width: Css.hairline),
        boxShadow: DifyShadows.lg,
      ),
      child: SizedBox(
        width: 280,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: DifyColors.dividerSubtle, width: 0.5)),
              ),
              child: Row(
                spacing: 4,
                children: [
                  SmallBlockIcon(type: nodeType ?? 'llm', size: 16),
                  Expanded(child: DifyText(nodeName, DifyType.systemXsMedium, color: DifyColors.textSecondary)),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 12),
              child: PickerStructurePanel(
                attrName: path.isEmpty ? '' : path.first,
                schema: root,
                readonly: true,
                bare: true,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// VarReferencePopup: the picker's popup box (`space-y-1 rounded-lg border bg-components-panel-bg p-1 shadow-lg`,
/// [itemWidth] wide, 228 by default) around [VarReferenceVars], or for an assigner ([popupFor]) with no variables
/// the matching empty state.
class VarReferencePopup extends StatelessWidget {
  const VarReferencePopup({
    super.key,
    required this.vars,
    required this.onChange,
    this.popupFor,
    this.itemWidth,
    this.isSupportFileVar = true,
    this.preferSchemaType = false,
    this.searchFocusNode,
    this.showManageInputField = false,
    this.onManageInputField,
    this.onClose,
    this.tapRegionGroup,
  });

  final List<VarGroup> vars;
  final VarSelected onChange;

  /// `assigned` / `toAssigned` (variable assigner).
  final String? popupFor;
  final double? itemWidth;
  final bool isSupportFileVar, preferSchemaType;
  final FocusNode? searchFocusNode;
  final bool showManageInputField;
  final VoidCallback? onManageInputField;
  final VoidCallback? onClose;
  final Object? tapRegionGroup;

  @override
  Widget build(BuildContext context) {
    final empty = vars.isEmpty && popupFor != null;
    final toAssigned = popupFor == 'toAssigned';
    return Container(
      width: itemWidth ?? 228,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: DifyColors.componentsPanelBg,
        borderRadius: BorderRadius.circular(DifyRadius.lg),
        border: Border.all(color: DifyColors.componentsPanelBorder),
        boxShadow: DifyShadows.lg,
      ),
      child: empty
          ? _ListEmpty(
              title: DifyI18n.tr(
                'workflow',
                toAssigned ? 'variableReference.noAvailableVars' : 'variableReference.noAssignedVars',
              ),
              description: DifyI18n.tr(
                'workflow',
                toAssigned ? 'variableReference.noVarsForOperation' : 'variableReference.assignedVarsDescription',
              ),
            )
          : VarReferenceVars(
              vars: vars,
              onChange: onChange,
              isSupportFileVar: isSupportFileVar,
              preferSchemaType: preferSchemaType,
              searchFocusNode: searchFocusNode,
              showManageInputField: showManageInputField,
              onManageInputField: onManageInputField,
              onClose: onClose,
              tapRegionGroup: tapRegionGroup,
            ),
    );
  }
}

/// ListEmpty (base/list-empty): the variable icon tile, title and description.
class _ListEmpty extends StatelessWidget {
  const _ListEmpty({required this.title, required this.description});
  final String title, description;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: DifyColors.backgroundSectionBurn,
      borderRadius: BorderRadius.circular(DifyRadius.lg),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      spacing: 4,
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: DifyColors.componentsCardBg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: DifyColors.componentsCardBorder, width: Css.hairline),
            boxShadow: DifyShadows.lg,
          ),
          child: Center(
            child: DifyIcon('vender/solid/development/variable-02', size: 20, color: DifyColors.textAccent),
          ),
        ),
        const SizedBox(height: 4),
        DifyText(title, DifyType.systemSmMedium, color: DifyColors.textSecondary, maxLines: null),
        DifyText(description, DifyType.systemXsRegular, color: DifyColors.textTertiary, maxLines: null),
      ],
    ),
  );
}
