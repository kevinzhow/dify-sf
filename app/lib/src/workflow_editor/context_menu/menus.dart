import 'package:collab_client/collab_client.dart';
import 'package:flutter/widgets.dart';

import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';
import '../../workflow/dify_json.dart' show difyDataOf;
import '../hooks/use_nodes_meta_data.dart';
import 'node_meta.dart';
import 'workflow_actions.dart';

String _tw(String key) => DifyI18n.tr('workflow', key);
String _tc(String key) => DifyI18n.tr('common', key);

/// Menu widths (`w-50`, node-actions-menu/shared.tsx `w-[240px]`, `w-60`).
const panelMenuWidth = 200.0, nodeMenuWidth = 240.0, selectionMenuWidth = 240.0;

/// A menu item with a label and, at the end, a shortcut: `px-3` items are 4 px wider inside than the menu's
/// `px-2`, `gap-4` puts 16 px before the shortcut.
Widget _item(
  String label, {
  VoidCallback? onSelect,
  String? shortcut,
  String? hotkey,
  bool px3 = false,
  bool gap4 = true,
  bool disabled = false,
  bool closeOnClick = true,
  bool destructive = false,
  bool destructiveHighlight = false,
  Widget? leading,
}) {
  final pad = px3 ? 4.0 : 0.0;
  Widget text = Padding(
    padding: EdgeInsets.only(left: leading == null ? pad : 0),
    child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
  );
  Widget? trailing = shortcut == null && hotkey == null
      ? (pad == 0 ? null : SizedBox(width: pad))
      : Padding(
          padding: EdgeInsets.only(left: gap4 ? 12 : 0, right: pad),
          child: DifyShortcutKbd(shortcut: shortcut, hotkey: hotkey),
        );
  if (destructiveHighlight) text = _DestructiveWhenHighlighted(child: text);
  return DifyMenuItem(
    onSelect: onSelect,
    disabled: disabled,
    closeOnClick: closeOnClick,
    leading: leading,
    trailing: trailing,
    variant: destructive || destructiveHighlight ? DifyMenuItemVariant.destructive : DifyMenuItemVariant.normal,
    child: text,
  );
}

/// `text-text-secondary data-highlighted:text-text-destructive` (with the destructive variant's highlight): the
/// item's row highlights by taking focus, so the text follows the nearest focus node.
class _DestructiveWhenHighlighted extends StatelessWidget {
  const _DestructiveWhenHighlighted({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => DefaultTextStyle.merge(
    style: TextStyle(
      color: Focus.maybeOf(context)?.hasFocus ?? false ? DifyColors.textDestructive : DifyColors.textSecondary,
    ),
    child: child,
  );
}

/// Separators only between groups that have items.
List<Widget> _groups(List<List<Widget>> groups) => [
  for (final g in groups.where((g) => g.isNotEmpty)) ...[
    if (g != groups.firstWhere((g) => g.isNotEmpty)) const DifyMenuSeparator(),
    ...g,
  ],
];

/// panel-contextmenu.tsx: add a node or note, comment, run, paste, export and import. [at] is where the menu opened
/// (canvas coordinates).
List<Widget> panelMenuItems(WorkflowActions a, {required Offset at}) {
  final o = a.options, store = a.store;
  final readOnly = a.workflowOperationReadOnly;
  final canEdit = o.canEdit && !readOnly;
  return _groups([
    [
      if (canEdit && o.onAddBlock != null) _item(_tw('common.addBlock'), px3: true, onSelect: () => o.onAddBlock!(at)),
      if (canEdit) _item(_tw('nodes.note.addNote'), px3: true, onSelect: o.onAddNote),
      if (!readOnly && o.commentModeAvailable)
        ValueListenableBuilder(
          valueListenable: store.pendingComment,
          builder: (context, pending, _) => _item(
            _tw('comments.actions.addComment'),
            px3: true,
            disabled: pending != null,
            onSelect: () => store
              ..setCommentQuickAdd(true)
              ..setCommentPlacing(true),
          ),
        ),
      if (o.canRun)
        o.isChatMode
            ? _item(_tw('common.debugAndPreview'), px3: true, onSelect: o.onRun)
            : _item(_tw('common.run'), px3: true, hotkey: 'Alt+R', onSelect: o.onRun),
    ],
    [
      if (canEdit)
        ValueListenableBuilder(
          valueListenable: store.clipboardElements,
          builder: (context, clip, _) => _item(
            _tw('common.pasteHere'),
            px3: true,
            shortcut: 'workflow.paste',
            disabled: clip.isEmpty,
            onSelect: a.pasteNodes,
          ),
        ),
    ],
    [
      if (o.canImportExportDsl) ...[
        _item(DifyI18n.tr('app', 'export'), px3: true, onSelect: o.onExportDsl),
        if (!o.isSnippetCanvas)
          _item(DifyI18n.tr('app', 'importApp'), px3: true, onSelect: () => store.setShowImportDSLModal(true)),
      ],
    ],
  ]);
}

/// node-actions-menu (context-menu-content.tsx and dropdown-content.tsx, use-node-actions-menu-model.ts): run or
/// stop, change, copy, duplicate, delete, open workflow, docs, and the block's about.
List<Widget> nodeActionsMenuItems(WorkflowActions a, Node node, {bool showHelpLink = true}) {
  final o = a.options;
  final meta = a.metaOf(node);
  final readOnly = a.nodesReadOnly;
  final isChild = parentIdOf(node) != null;
  final canRun = o.canRun && !readOnly && canRunBySingle(node.type, isChildNode: isChild);
  final canChangeBlock =
      !(meta?.isTypeFixed ?? false) && !(meta?.isUndeletable ?? false) && !readOnly && o.onChangeBlock != null;
  final sourceHandle = a.doc.edges.values.where((e) => e.target == node.id).firstOrNull?.sourceHandle ?? 'source';
  final appHref = o.workflowAppHref?.call(node);
  final helpLink = showHelpLink ? nodeHelpLink(node.type, chatMode: a.chatMode, product: o.docsProduct) : null;
  final about = nodeMetaDataIn(a.store, difyDataOf(node));
  final id = node.id;
  Widget link(String label, String url) => _item(label, gap4: false, onSelect: () => o.openUrl?.call(url));
  return [
    ..._groups([
      [
        if (canRun)
          _item(
            a.isSingleRunning(id) ? _tw('debug.variableInspect.trigger.stop') : _tw('panel.runThisStep'),
            gap4: false,
            onSelect: () => a.runStep(id),
          ),
        if (canChangeBlock)
          _item(_tw('panel.changeBlock'), gap4: false, onSelect: () => o.onChangeBlock!(id, sourceHandle)),
      ],
      if (!readOnly && !(meta?.isSingleton ?? false))
        [
          _item(_tw('common.copy'), shortcut: 'workflow.copy', onSelect: () => a.copyNodes(id)),
          _item(_tw('common.duplicate'), shortcut: 'workflow.duplicate', onSelect: () => a.duplicateNodes(id)),
        ],
      if (!readOnly && !(meta?.isUndeletable ?? false))
        [
          _item(
            _tc('operation.delete'),
            shortcut: 'workflow.delete',
            destructiveHighlight: true,
            onSelect: () => a.deleteNode(id),
          ),
        ],
      [if (appHref != null) link(_tw('panel.openWorkflow'), appHref)],
      [if (helpLink != null) link(_tw('panel.helpLink'), helpLink)],
    ]),
    const DifyMenuSeparator(),
    // useNodeMetaData: a tool's provider, else Dify.
    NodeActionsMenuAbout(
      title: _tw('panel.about'),
      description: about.description,
      author: '${_tw('panel.createdBy')} ${about.author ?? ''}',
    ),
  ];
}

/// shared.tsx NodeActionsMenuAbout: `px-3 py-2 text-xs text-text-tertiary`.
class NodeActionsMenuAbout extends StatelessWidget {
  const NodeActionsMenuAbout({super.key, required this.title, this.description, this.author});
  final String title;
  final String? description;
  final String? author;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    child: DefaultTextStyle.merge(
      style: const TextStyle(fontSize: 12, height: 18 / 12, color: DifyColors.textTertiary),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 22,
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text(
                title.toUpperCase(),
                style: const TextStyle(fontWeight: FontWeight.w500, height: 16 / 12),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(description ?? '', style: const TextStyle(color: DifyColors.textSecondary)),
          const SizedBox(height: 4),
          Text(author ?? ''),
        ],
      ),
    ),
  );
}

/// edge-contextmenu.tsx: Delete.
List<Widget> edgeMenuItems(WorkflowActions a, String edgeId) => [
  _item(
    _tc('operation.delete'),
    px3: true,
    shortcut: 'workflow.delete',
    destructive: true,
    onSelect: () {
      a.deleteEdge(edgeId);
    },
  ),
];

/// Block types a snippet can't hold (selection-contextmenu.tsx unsupportedSnippetNodeTypes).
const _noSnippetTypes = {'answer', 'end', 'start', 'human-input', 'knowledge-retrieval'};

/// selection-contextmenu.tsx: create snippet, copy, duplicate, delete, and alignment. Empty unless several nodes
/// are selected.
List<Widget> selectionMenuItems(WorkflowActions a) {
  final selected = a.selectedNodes;
  if (selected.length <= 1) return const [];
  final o = a.options;
  Widget align(AlignType t, String icon, String key, {bool rotate = false}) {
    Widget glyph = RemixIcon(icon, size: 16);
    if (rotate) glyph = RotatedBox(quarterTurns: 1, child: glyph);
    return _item(_tw('operator.$key'), gap4: false, leading: glyph, onSelect: () => a.alignNodes(t));
  }

  return [
    if (o.canCreateSnippet &&
        o.onCreateSnippet != null &&
        selected.every((n) => !_noSnippetTypes.contains(n.type))) ...[
      _item(
        _tw('snippet.createDialogTitle'),
        px3: true,
        gap4: false,
        onSelect: () => o.onCreateSnippet!([for (final n in selected) n.id]),
      ),
      const DifyMenuSeparator(),
    ],
    _item(_tw('common.copy'), px3: true, gap4: false, shortcut: 'workflow.copy', onSelect: a.copyNodes),
    _item(_tw('common.duplicate'), px3: true, gap4: false, shortcut: 'workflow.duplicate', onSelect: a.duplicateNodes),
    const DifyMenuSeparator(),
    _item(
      _tc('operation.delete'),
      px3: true,
      gap4: false,
      shortcut: 'workflow.delete',
      destructiveHighlight: true,
      onSelect: a.deleteSelection,
    ),
    const DifyMenuSeparator(),
    DifyMenuGroupLabel(_tw('operator.vertical')),
    align(AlignType.top, 'align-top', 'alignTop'),
    align(AlignType.middle, 'align-center', 'alignMiddle', rotate: true),
    align(AlignType.bottom, 'align-bottom', 'alignBottom'),
    align(AlignType.distributeVertical, 'align-justify', 'distributeVertical', rotate: true),
    const DifyMenuSeparator(),
    DifyMenuGroupLabel(_tw('operator.horizontal')),
    align(AlignType.left, 'align-left', 'alignLeft'),
    align(AlignType.center, 'align-center', 'alignCenter'),
    align(AlignType.right, 'align-right', 'alignRight'),
    align(AlignType.distributeHorizontal, 'align-justify', 'distributeHorizontal'),
  ];
}
