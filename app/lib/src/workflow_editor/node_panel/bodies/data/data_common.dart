/// What the data-node panels (http-request, tool, document-extractor, list-operator, iteration, loop, loop-end,
/// human-input) share: what the host hands in ([DataPanelHost]), text drafts committed with their base version, and
/// `input-support-select-var` ([VarInput]). Writes (`setInputs`) and the variable scope (`NodeVars`) are the shared
/// `node_panel/panel_edit.dart`'s.
library;

import 'package:collab_client/collab_client.dart';
import 'package:flutter/material.dart';

import '../../../../design/dify_icon.dart';
import '../../../../design/dify_tokens.g.dart';
import '../../../../design/widgets/widgets.dart';
import '../../../../i18n/dify_i18n.dart';
import '../../../context_menu/workflow_actions.dart' show parentIdOf;
import '../../../panel_fields/panel_fields.dart';
import '../../../prompt_editor/prompt_editor.dart';
import '../../node_panel_bodies.dart';

/// `t(key, { ns: 'workflow', ...params })`.
String wf(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('workflow', key, params);

/// `t(key, { ns: 'common', ...params })`.
String cm(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('common', key, params);

// ---- the variables a node may reference ---------------------------------------------------------------------------

/// The nodes inside the container [containerId] (not its start node).
List<Node> childrenOf(Document doc, String containerId) => [
  for (final n in doc.nodes.values)
    if (parentIdOf(n) == containerId && n.type != 'iteration-start' && n.type != 'loop-start') n,
];

/// A filter keeping variables whose type is one of [types].
VarFilter typeIn(Set<String> types) =>
    (v, _) => types.contains(v.type);

// ---- what the host provides ---------------------------------------------------------------------------------------

/// dify-ui's toast types.
typedef DataToastType = DifyToastType;

/// Shows a toast.
typedef DataToast = void Function(DataToastType type, String message);

/// What the data-node panels get from the app around them (services dify-sf does not have yet come in here; every
/// field has an empty default). Node types with more needs add their own host widget next to this one.
class DataPanelHost extends InheritedWidget {
  const DataPanelHost({super.key, this.toast = difyToast, this.openUrl, this.isCloud = false, required super.child});

  /// dify-ui's `toast.*`; the app's toast host by default (null: toasts are dropped).
  final DataToast? toast;

  /// Opens a link (docs, "Learn more"); none: [NodePanelProps.actions]' `openUrl`.
  final ValueChanged<String>? openUrl;

  /// `IS_CLOUD_EDITION` / `deployment_edition === 'CLOUD'`.
  final bool isCloud;

  static const _none = DataPanelHost(child: SizedBox.shrink());

  static DataPanelHost of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<DataPanelHost>() ?? _none;

  @override
  bool updateShouldNotify(DataPanelHost old) => toast != old.toast || openUrl != old.openUrl || isCloud != old.isCloud;
}

/// Shows [message] as a toast through the [DataPanelHost] above [context].
void showDataToast(BuildContext context, DataToastType type, String message) =>
    DataPanelHost.of(context).toast?.call(type, message);

// ---- text drafts --------------------------------------------------------------------------------------------------

/// Commits typed [text]; [base] is the document version the draft began on (null: no version known).
typedef TextCommit = void Function(String text, int? base);

/// The draft bookkeeping of a text control bound to a document value: the version at the first keystroke is kept
/// and handed to the commit (on blur, Enter or dispose), so a write that landed meanwhile makes the edit conflict
/// instead of being overwritten silently. While there is no draft the control shows the document's value.
class TextDraft {
  TextDraft([this.version]);

  /// The document version now (`EditorController.seenVersion`); null: drafts commit without a base.
  final int Function()? version;
  int? _base;
  bool _open = false;

  bool get isOpen => _open;

  /// A keystroke: opens the draft.
  void touch() {
    if (_open) return;
    _open = true;
    _base = version?.call();
  }

  /// Closes the draft: its base, or null when none was open (then there is nothing to commit).
  ({int? base})? take() {
    if (!_open) return null;
    _open = false;
    final b = _base;
    _base = null;
    return (base: b);
  }
}

/// The document version getter for drafts of [props]' node.
int Function() versionOf(NodePanelProps props) =>
    () => props.controller.seenVersion;

// ---- input-support-select-var -------------------------------------------------------------------------------------

/// input-support-select-var.tsx: a one-line prompt editor where `/` (and `{`) insert a variable from [vars]; while
/// focused a `Variable02` badge sits on the top right edge (left with [insertVarTipToLeft]). With [boxed] it has the
/// field look of Dify's call sites (`rounded-lg border px-3 py-1.5`, active border / bg / shadow while focused, else
/// [idleBorder]). Typed text is a draft committed on blur ([onChange] with its base); [value] shows otherwise.
class VarInput extends StatefulWidget {
  const VarInput({
    super.key,
    required this.value,
    required this.onChange,
    this.vars = const [],
    this.nodesMap = const {},
    this.readOnly = false,
    this.placeholder,
    this.boxed = true,
    this._idleBorder,
    this.insertVarTipToLeft = false,
    this.version,
    this.onFocusChange,
    this.onEdit,
    this.isSupportFileVar = false,
    this.semanticLabel,
  });

  final String value;
  final TextCommit onChange;
  final List<VarGroup> vars;
  final Map<String, WorkflowNodeInfo> nodesMap;
  final bool readOnly;
  final String? placeholder;
  final bool boxed;
  final Color? _idleBorder;
  Color get idleBorder => _idleBorder ?? DifyColors.componentsInputBorderHover;
  final bool insertVarTipToLeft;
  final int Function()? version;
  final ValueChanged<bool>? onFocusChange;

  /// Each edit as typed (before the commit), for parents that react to typing (KeyValue's auto-added row).
  final ValueChanged<String>? onEdit;
  final bool isSupportFileVar;
  final String? semanticLabel;

  @override
  State<VarInput> createState() => _VarInputState();
}

class _VarInputState extends State<VarInput> {
  late final _focus = FocusNode(debugLabel: 'VarInput')..addListener(_focusChanged);
  late final _draft = TextDraft(widget.version);
  late String _text = widget.value;
  bool _focused = false;

  @override
  void didUpdateWidget(VarInput old) {
    super.didUpdateWidget(old);
    if (!_draft.isOpen) _text = widget.value;
  }

  void _focusChanged() {
    if (_focus.hasFocus == _focused) return;
    setState(() => _focused = _focus.hasFocus);
    widget.onFocusChange?.call(_focused);
    if (!_focused) _commit();
  }

  void _commit() {
    final d = _draft.take();
    if (d != null && _text != widget.value) widget.onChange(_text, d.base);
  }

  @override
  void dispose() {
    _commit();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    Widget editor = DifyPromptEditor(
      value: _text,
      focusNode: _focus,
      editable: !w.readOnly,
      placeholder: w.placeholder ?? '',
      semanticLabel: w.semanticLabel,
      isSupportFileVar: w.isSupportFileVar,
      minHeight: 20,
      lineHeight: 18, // leading-4.5
      onChange: (v) {
        if (v == _text) return;
        _draft.touch();
        _text = v;
        w.onEdit?.call(v);
      },
      workflowVariableBlock: WorkflowVariableBlockConfig(show: true, variables: w.vars, workflowNodesMap: w.nodesMap),
    );
    if (w.boxed) {
      editor = Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: _focused ? DifyColors.componentsInputBgActive : DifyColors.componentsInputBgNormal,
          borderRadius: BorderRadius.circular(DifyRadius.lg),
          border: Border.all(color: _focused ? DifyColors.componentsInputBorderActive : w.idleBorder),
          boxShadow: _focused ? DifyShadows.xs : null,
        ),
        child: editor,
      );
    }
    return Stack(
      clipBehavior: Clip.none,
      children: [
        if (w.boxed) ConstrainedBox(constraints: const BoxConstraints(minHeight: 32), child: editor) else editor,
        if (_focused)
          Positioned(
            top: w.insertVarTipToLeft ? 6 : -9,
            left: w.insertVarTipToLeft ? -12 : null,
            right: w.insertVarTipToLeft ? null : 4,
            child: DifyTooltip(
              content: Text(wf('common.insertVarTip')),
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: DifyColors.componentsBadgeWhiteToDark,
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(color: DifyColors.dividerRegular, width: 0.5),
                  boxShadow: DifyShadows.lg,
                ),
                child: DifyIcon(
                  'vender/solid/development/variable-02',
                  size: 14,
                  color: DifyColors.componentsButtonSecondaryAccentText,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
