/// The Jinja code editor with variable insertion (nodes/_base/components/editor/code-editor/editor-support-vars.tsx):
/// typing `/` or `{` opens the variable list by the caret; a pick writes `{{ name }}` in place of the typed character
/// and adds the variable to the node's inputs when it is not there yet.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../../../design/dify_tokens.g.dart';
import '../../../../workflow/dify_json.dart';
import '../../../code_editor/code_editor.dart';
import '../../../code_editor/editor_view.dart' show CodeEditorMetrics;
import '../../../panel_fields/panel_fields.dart';
import 'core_kit.dart';

/// `getUniqVarName`: [name], or with `_1`, `_2`, … when a variable of [varList] (Dify's `Variable[]`) has it.
String uniqVarName(String name, List<Object?> varList) {
  if (!varList.any((v) => jsGet(v, 'variable') == name)) return name;
  final m = RegExp(r'_(\d+)$').firstMatch(name);
  final index = m == null ? 1 : int.parse(m[1]!) + 1;
  return uniqVarName('${name.replaceFirst(RegExp(r'_(\d+)$'), '')}_$index', varList);
}

/// `getVarName`: the name of the input already taking [selector], else a free name after its last segment.
({String name, bool isExist}) varNameFor(List<String> selector, List<Object?> varList) {
  final key = selector.join('@@@');
  for (final v in varList) {
    final s = jsGet(v, 'value_selector');
    if (s is List && s.map(jsKey).join('@@@') == key) return (name: jsStr(jsGet(v, 'variable')) ?? '', isExist: true);
  }
  return (name: uniqVarName(selector.last, varList), isExist: false);
}

/// Where the user typed a `/` or `{` (with an auto-closed `}` after it) going from [before] to [after]: the
/// character's offset and whether it is a brace; null for any other edit. Stands for Monaco's cursor-position event.
({int offset, bool leftBrace})? insertedTrigger(String before, String after) {
  if (after.length <= before.length) return null;
  var p = 0;
  while (p < before.length && before.codeUnitAt(p) == after.codeUnitAt(p)) {
    p++;
  }
  var s = 0;
  while (s < before.length - p && before.codeUnitAt(before.length - 1 - s) == after.codeUnitAt(after.length - 1 - s)) {
    s++;
  }
  final inserted = after.substring(p, after.length - s);
  if (before.length - s != p) return null; // something was replaced
  return switch (inserted) {
    '/' => (offset: p, leftBrace: false),
    '{' || '{}' => (offset: p, leftBrace: true),
    _ => null,
  };
}

/// CodeEditor (editor-support-vars.tsx) over [value]: [availableVars] are listed (no search, file variables not
/// selectable), [varList] is the node's `variables` and [onAddVar] adds one.
class CodeEditorSupportVars extends StatefulWidget {
  const CodeEditorSupportVars({
    super.key,
    required this.value,
    required this.onChange,
    required this.availableVars,
    required this.varList,
    this.onAddVar,
    this.language = CodeLanguage.python3,
    this.readOnly = false,
    this.isInNode = false,
    this.titleWidget,
    this.headerRight,
  });

  final String value;
  final ValueChanged<String> onChange;
  final List<VarGroup> availableVars;
  final List<Object?> varList;
  final ValueChanged<Map<String, Object?>>? onAddVar;
  final CodeLanguage language;
  final bool readOnly, isInNode;
  final Widget? titleWidget, headerRight;

  @override
  State<CodeEditorSupportVars> createState() => _CodeEditorSupportVarsState();
}

class _CodeEditorSupportVarsState extends State<CodeEditorSupportVars> {
  final _portal = OverlayPortalController();
  final _link = LayerLink();
  final _group = Object();
  ({int offset, bool leftBrace})? _at;

  void _hide() {
    _at = null;
    if (_portal.isShowing) _portal.hide();
  }

  void _changed(String text) {
    final at = widget.readOnly ? null : insertedTrigger(widget.value, text);
    widget.onChange(text);
    if (at == null) return _hide();
    setState(() => _at = at);
    _portal.show();
  }

  void _select(List<String> selector, PickerVar _) {
    final at = _at;
    _hide();
    if (at == null) return;
    final (:name, :isExist) = varNameFor(selector, widget.varList);
    if (!isExist) widget.onAddVar?.call({'variable': name, 'value_selector': selector});
    final text = widget.value;
    if (at.offset >= text.length || !'/{'.contains(text[at.offset])) return;
    widget.onChange(
      text.replaceRange(at.offset, at.offset + 1, '{{ $name }${at.leftBrace ? '' : '}'}'),
    );
  }

  /// The popup's top left from the editor's: under the caret after the typed character (`+ 20`), the editor's lines
  /// unwrapped and unscrolled.
  Offset _caret() {
    final at = _at!;
    final text = widget.value;
    final before = text.substring(0, at.offset.clamp(0, text.length));
    final line = '\n'.allMatches(before).length;
    final column = at.offset - (before.lastIndexOf('\n') + 1) + 1;
    final m = CodeEditorMetrics.of(defaultTargetPlatform);
    final lines = '\n'.allMatches(text).length + 1;
    return Offset(8 + m.contentLeft(lines) + column * m.charWidth, 28 + line * m.lineHeight + 20);
  }

  @override
  Widget build(BuildContext context) => OverlayPortal(
    controller: _portal,
    overlayChildBuilder: (context) => _at == null
        ? const SizedBox.shrink()
        : CompositedTransformFollower(
            link: _link,
            showWhenUnlinked: false,
            offset: _caret(),
            child: Align(
              alignment: Alignment.topLeft,
              child: TapRegion(
                groupId: _group,
                onTapOutside: (_) => setState(_hide),
                child: Container(
                  width: 228,
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: DifyColors.componentsPanelBg,
                    borderRadius: BorderRadius.circular(DifyRadius.lg),
                    border: Border.all(color: DifyColors.componentsPanelBorder),
                    boxShadow: DifyShadows.lg,
                  ),
                  child: VarReferenceVars(
                    hideSearch: true,
                    vars: widget.availableVars,
                    onChange: _select,
                    onClose: () => setState(_hide),
                    tapRegionGroup: _group,
                  ),
                ),
              ),
            ),
          ),
    child: CompositedTransformTarget(
      link: _link,
      child: DifyCodeEditor(
        value: widget.value,
        language: widget.language,
        readOnly: widget.readOnly,
        isInNode: widget.isInNode,
        titleWidget: widget.titleWidget,
        headerRight: widget.headerRight,
        placeholder: tw('common.jinjaEditorPlaceholder'),
        onChange: _changed,
      ),
    ),
  );
}
