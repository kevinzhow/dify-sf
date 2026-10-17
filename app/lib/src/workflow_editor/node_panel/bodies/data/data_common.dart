/// What the data-node panels (http-request, tool, document-extractor, list-operator, iteration, loop, loop-end,
/// human-input) share: Dify's `setInputs` of `useNodeCrud` as small ops, the variables a node may reference
/// (`useAvailableVarList`), what the host hands in ([DataPanelHost]), text drafts committed with their base version,
/// and `input-support-select-var` ([VarInput]).
library;

import 'package:collab_client/collab_client.dart';
import 'package:flutter/material.dart';

import '../../../../design/dify_icon.dart';
import '../../../../design/dify_tokens.g.dart';
import '../../../../design/widgets/widgets.dart';
import '../../../../i18n/dify_i18n.dart';
import '../../../../workflow/dify_json.dart';
import '../../../../workflow/var_types.dart';
import '../../../header/checklist/use_checklist.dart' show difyGraphOf, getBeforeNodesInSameBranchIncludeParent;
import '../../../panel_fields/panel_fields.dart';
import '../../../prompt_editor/prompt_editor.dart';
import '../../../prompt_editor/prompt_editor_panel.dart' show workflowNodesMapOf;
import '../../node_panel_bodies.dart';

/// `t(key, { ns: 'workflow', ...params })`.
String wf(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('workflow', key, params);

/// `t(key, { ns: 'common', ...params })`.
String cm(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('common', key, params);

// ---- setInputs ----------------------------------------------------------------------------------------------------

/// Keys of Dify's `data` that are not settings: the shell or React Flow owns them.
const _notSettings = {'type', 'title', 'selected', '_dify_node'};

/// Dify's `setInputs(next)` (useNodeCrud): writes the top-level keys of [next] that differ from the node's data now,
/// one op each; a key [next] lacks or sets to null is cleared. Unchanged references and keyed-list item ids are kept;
/// a keyed list (VItems) is edited item by item so concurrent edits of other items merge. [base] goes with the ops
/// (typed text: the version its draft began on).
void setInputs(NodePanelProps props, Map<String, Object?> next, {int? base}) {
  final node = props.node;
  final doc = props.controller.doc;
  final keys = {...node.config.keys, ...next.keys}.where((k) => !_notSettings.contains(k) && !k.startsWith('_'));
  for (final key in keys) {
    final orig = node.config[key];
    final plain = next[key];
    if (jsonEquals(plainOf(orig), plain)) continue;
    if (plain == null) {
      if (orig != null && orig is! VNull) props.setData(key, null, base: base);
      continue;
    }
    if (orig is VItems && plain is List) {
      _editItems(props, [key], orig, plain, doc, base);
      continue;
    }
    props.setData(key, mergeValue(orig, plain, doc), base: base);
  }
}

/// `setInputs({...data, ...patch})`: [setInputs] of the node's data with [patch]'s keys replaced.
void patchInputs(NodePanelProps props, Map<String, Object?> patch, {int? base}) =>
    setInputs(props, {...props.data, ...patch}, base: base);

/// [plain] as a config [Value] over [orig]: unchanged parts keep their form (references, keyed-list ids), new
/// two-part selectors to an existing node's output become references (see [selectorValue]).
Value mergeValue(Value? orig, Object? plain, Document doc) {
  switch ((orig, plain)) {
    case (VRef(:final ref) || VBroken(:final ref), final List l)
        when l.length == 2 && l[0] == ref.node && l[1] == ref.output:
      return orig!;
    case (VItems(:final items), final List l) when l.length == items.length:
      return VItems([for (final (i, item) in items.indexed) Item(item.id, mergeValue(item.value, l[i], doc))]);
    case (VList(:final items), final List l) when l.length == items.length:
      return VList([for (final (i, item) in items.indexed) mergeValue(item, l[i], doc)]);
    case (VMap(:final entries), final Map m):
      return VMap({
        for (final e in m.entries)
          if (e.value != null || entries.containsKey(e.key)) '${e.key}': mergeValue(entries['${e.key}'], e.value, doc),
      });
  }
  if (plain is List && plain.length == 2 && plain.every((e) => e is String)) {
    return selectorValue([for (final e in plain) e as String], doc);
  }
  if (plain is List) return VList([for (final e in plain) mergeValue(null, e, doc)]);
  if (plain is Map) {
    return VMap({
      for (final e in plain.entries)
        if (e.value != null) '${e.key}': mergeValue(null, e.value, doc),
    });
  }
  return Value.of(plain);
}

/// A value selector as the document stores it: a reference when it names an output of a node in [doc] (any output
/// when the node declares none), else the plain list (sys / env / conversation / rag variables, deeper paths).
Value selectorValue(List<String> selector, Document doc) {
  if (selector.length == 2) {
    final target = doc.nodes[selector[0]];
    final outs = target == null ? null : Document.declaredOutputs(target);
    if (target != null && (outs == null || outs.contains(selector[1]))) {
      return VRef(OutputRef(selector[0], selector[1]));
    }
  }
  return VList([for (final s in selector) VString(s)]);
}

/// Edits the keyed list at [path] from [orig] to [next] with item ops: items equal on both sides stay, a removed or
/// inserted item is found by looking one ahead, everything else is an update in place.
void _editItems(NodePanelProps props, List<String> path, VItems orig, List<Object?> next, Document doc, int? base) {
  final c = props.controller;
  final items = orig.items;
  var i = 0;
  String? last; // the item new ones go after (null: the front)
  final pending = <Value>[];
  void flush() {
    for (final v in pending.reversed) {
      c.insertItem(props.id, path, v, after: last);
    }
    pending.clear();
  }

  for (var j = 0; j < next.length; j++) {
    final want = next[j];
    bool same(int k, Object? v) => k < items.length && jsonEquals(plainOf(items[k].value), v);
    if (same(i, want)) {
      flush();
      last = items[i++].id;
    } else if (same(i + 1, want)) {
      flush();
      c.removeItem(props.id, path, items[i].id);
      last = items[i + 1].id;
      i += 2;
    } else if (i < items.length && !(j + 1 < next.length && same(i, next[j + 1]))) {
      flush();
      c.updateItem(props.id, path, items[i].id, mergeValue(items[i].value, want, doc), base: base);
      last = items[i++].id;
    } else {
      pending.add(mergeValue(null, want, doc));
    }
  }
  flush();
  for (; i < items.length; i++) {
    c.removeItem(props.id, path, items[i].id);
  }
}

// ---- the variables a node may reference ---------------------------------------------------------------------------

/// The container a node sits in (React Flow's `parentId`), or null.
String? parentIdOf(Node node) {
  final parent = jsStr(jsGet(plainOf(node.config['_dify_node']), 'parentId'));
  return parent == null || parent.isEmpty ? null : parent;
}

/// The nodes inside the container [containerId] (not its start node).
List<Node> childrenOf(Document doc, String containerId) => [
  for (final n in doc.nodes.values)
    if (parentIdOf(n) == containerId && n.type != 'iteration-start' && n.type != 'loop-start') n,
];

final _scopes = Expando<VarScope>('data panel scope');

/// `useAvailableVarList(nodeId)` without a filter: the variables of the nodes before [props]' node in its branch
/// (and of its container), the container's item / index, environment and (in a chatflow) conversation variables.
/// Computed once per [props] (the shell makes new props on each build).
VarScope availableScope(NodePanelProps props) => _scopes[props] ??= _scopeOf(props, props.controller.doc);

VarScope _scopeOf(NodePanelProps props, Document doc) {
  final g = difyGraphOf(doc);
  final before = getBeforeNodesInSameBranchIncludeParent(props.id, g.nodes, g.edges);
  final parentId = parentIdOf(props.node);
  final parent = parentId == null ? null : doc.nodes[parentId];
  return scopeOfNodes(props, [for (final b in before) ?b.node], parent: parent);
}

/// The scope over [nodes] (Dify's `passedInAvailableNodes` / `toNodeOutputVars(nodes, …)`) seen from inside [parent].
VarScope scopeOfNodes(NodePanelProps props, List<Node> nodes, {Node? parent, bool env = true, bool chat = true}) {
  final store = props.actions.store;
  try {
    return VarScope.of(
      beforeNodes: nodes,
      parent: parent,
      chatMode: props.chatMode,
      environmentVariables: env ? DeclaredVar.listOf(store.environmentVariables.value) : const [],
      conversationVariables: chat && props.chatMode ? DeclaredVar.listOf(store.conversationVariables.value) : const [],
      currentIterationTitle: wf('nodes.iteration.currentIteration'),
    );
  } on StateError {
    return const VarScope();
  }
}

/// `useAvailableVarList(nodeId, { filterVar })`: [availableScope] narrowed by [filter].
VarScope filteredScope(NodePanelProps props, VarFilter filter) => availableScope(props).filtered(filter);

/// A filter keeping variables whose type is one of [types].
VarFilter typeIn(Set<String> types) =>
    (v, _) => types.contains(v.type);

/// The nodes a scope's variables come from, as the prompt editor's `workflowNodesMap` (`availableNodesWithParent`).
Map<String, WorkflowNodeInfo> nodesMapOf(NodePanelProps props) {
  final doc = props.controller.doc;
  final g = difyGraphOf(doc);
  final before = getBeforeNodesInSameBranchIncludeParent(props.id, g.nodes, g.edges);
  return workflowNodesMapOf([for (final b in before) ?b.node]);
}

// ---- what the host provides ---------------------------------------------------------------------------------------

/// dify-ui's toast types.
enum DataToastType { success, error, warning, info }

/// Shows a toast.
typedef DataToast = void Function(DataToastType type, String message);

/// What the data-node panels get from the app around them (services dify-sf does not have yet come in here; every
/// field has an empty default). Node types with more needs add their own host widget next to this one.
class DataPanelHost extends InheritedWidget {
  const DataPanelHost({super.key, this.toast, this.openUrl, this.isCloud = false, required super.child});

  /// dify-ui's `toast.*`; none: toasts are dropped.
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
    this.idleBorder = DifyColors.componentsInputBorderHover,
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
  final Color idleBorder;
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
        // py-1.5 around Dify's 18 px line; the editor's line is 24 px (see the report), so 3 px.
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
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
                child: const DifyIcon(
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
