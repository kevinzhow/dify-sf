import 'package:flutter/widgets.dart';

import '../../canvas/canvas_controller.dart';
import '../../canvas/canvas_input.dart' show ControlMode;
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../block_selector/block_selector.dart';
import '../store/store.dart';
import 'action_bar.dart';
import 'actions.dart';
import 'shortcuts.dart';

/// operator/control.tsx: the left bar (add node, add note, pointer / hand / comment mode, organize, more actions).
/// Mount it in [WorkflowEditor.control] (see `workflowControlBuilder`).
class WorkflowControl extends StatelessWidget {
  const WorkflowControl({super.key, required this.canvas, this.options = const OperatorOptions()});

  final CanvasController canvas;
  final OperatorOptions options;

  static const _divider = DifyDivider(margin: EdgeInsets.symmetric(vertical: 4), length: 14);

  @override
  Widget build(BuildContext context) {
    final store = WorkflowStoreScope.of(context);
    final a = OperatorActions(canvas, store, options: options);
    Widget tip(String key, Widget button, {String? shortcut, EdgeInsets margin = EdgeInsets.zero}) => Padding(
      padding: margin,
      child: DifyTipPopup(title: tw(key), shortcut: shortcut, child: button),
    );
    return OperatorShortcutsTarget(
      canvas: canvas,
      child: ListenableBuilder(
        listenable: Listenable.merge([store.readOnlyChanges, store.controlMode]),
        builder: (context, _) {
          final readOnly = store.nodesReadOnly;
          final mode = store.controlMode.value;
          return ActionBar(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AddBlock(disabled: readOnly),
                tip(
                  'nodes.note.addNote',
                  OperatorButton(
                    label: tw('nodes.note.addNote'),
                    icon: const RemixIcon('sticky-note-add-line'),
                    disabled: readOnly,
                    onPressed: options.onAddNote,
                  ),
                  margin: const EdgeInsets.only(left: 1),
                ),
                _divider,
                tip(
                  'common.pointerMode',
                  OperatorButton(
                    label: tw('common.pointerMode'),
                    icon: const RemixIcon('cursor-line'),
                    pressed: mode == ControlMode.pointer,
                    disabled: readOnly,
                    onPressed: a.modePointer,
                  ),
                  shortcut: 'workflow.pointer-mode',
                  margin: const EdgeInsets.only(right: 1),
                ),
                tip(
                  'common.handMode',
                  OperatorButton(
                    label: tw('common.handMode'),
                    icon: const RemixIcon('hand'),
                    pressed: mode == ControlMode.hand,
                    disabled: readOnly,
                    onPressed: a.modeHand,
                  ),
                  shortcut: 'workflow.hand-mode',
                ),
                if (options.collaborationEnabled)
                  tip(
                    'common.commentMode',
                    OperatorButton(
                      label: tw('common.commentMode'),
                      icon: const DifyIcon('public/other/comment'),
                      pressed: mode == ControlMode.comment,
                      disabled: !a.canUseCommentMode,
                      onPressed: a.modeComment,
                    ),
                    shortcut: 'workflow.comment-mode',
                    margin: const EdgeInsets.only(left: 1),
                  ),
                _divider,
                tip(
                  'panel.organizeBlocks',
                  OperatorButton(
                    label: tw('panel.organizeBlocks'),
                    icon: const RemixIcon('function-add-line'),
                    disabled: readOnly,
                    onPressed: a.organize,
                  ),
                  shortcut: 'workflow.organize',
                ),
                MoreActions(disabled: readOnly, onExportImage: options.onExportImage),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// operator/add-block.tsx: the Add Node button and its open state. The block selector is a later phase; the
/// popover shows a placeholder.
class AddBlock extends StatefulWidget {
  const AddBlock({super.key, this.disabled = false});

  final bool disabled;

  @override
  State<AddBlock> createState() => _AddBlockState();
}

class _AddBlockState extends State<AddBlock> {
  bool _open = false;

  void _openChange(bool open) {
    if (open && widget.disabled) return;
    setState(() => _open = open);
    // handlePaneContextmenuCancel
    if (!open) WorkflowStoreScope.of(context).setContextMenuTarget(null);
  }

  @override
  Widget build(BuildContext context) {
    final label = tw('common.addBlock');
    final data = BlockSelectorScope.of(context);
    final store = WorkflowStoreScope.of(context);
    final p = BlockSelectorPlacements.addBlock;
    // add-block.tsx: the blocks that may follow Start; the Start tab outside chatflows and RAG pipelines.
    final available = useAvailableBlocks(
      'start',
      availableTypes: availableNodeTypes(chatMode: data.chatMode, agentV2: data.agentV2),
    ).next;
    return BlockSelector(
      open: _open,
      onOpenChange: _openChange,
      placement: p.placement,
      sideOffset: p.sideOffset,
      alignOffset: p.alignOffset,
      popupMinWidth: 256,
      availableBlocksTypes: available,
      showStartTab: !data.chatMode && data.flow == BlockSelectorFlow.app,
      disabled: widget.disabled,
      // handleSelect: the chosen block becomes the candidate that follows the pointer until a click places it.
      onSelect: (type, defaults, {toolDefaultValue}) => store.setCandidateNode(
        candidateNodeOf(
          type,
          defaults,
          toolDefaultValue: toolDefaultValue,
          existing: [
            for (final n in data.nodes)
              {
                'id': n.id,
                'data': {'type': n.type},
              },
          ],
        ),
      ),
      trigger: (context, c) => DifyTipPopup(
        title: label,
        child: OperatorButton(
          label: label,
          icon: const RemixIcon('add-circle-fill'),
          active: _open,
          disabled: widget.disabled,
          onPressed: c.toggle,
        ),
      ),
    );
  }
}

/// operator/more-actions.tsx: the export image menu. The export itself is [onExportImage]'s.
class MoreActions extends StatefulWidget {
  const MoreActions({super.key, this.disabled = false, this.onExportImage});

  final bool disabled;
  final void Function(ExportImageFormat format, {required bool wholeWorkflow})? onExportImage;

  @override
  State<MoreActions> createState() => _MoreActionsState();
}

class _MoreActionsState extends State<MoreActions> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final label = tw('common.moreActions');
    final heading = difyTextStyle(DifyType.systemXsMedium, DifyColors.textTertiary);
    Widget group(String key) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: DifyTextLine(tw(key), style: heading),
    );
    Widget item(ExportImageFormat format, bool whole) => DifyMenuItem(
      onSelect: () {
        // handleExportImage: nothing while read-only.
        if (WorkflowStoreScope.of(context).nodesReadOnly) return;
        widget.onExportImage?.call(format, wholeWorkflow: whole);
      },
      child: DifyTextLine(
        tw(switch (format) {
          ExportImageFormat.png => 'common.exportPNG',
          ExportImageFormat.jpeg => 'common.exportJPEG',
          ExportImageFormat.svg => 'common.exportSVG',
        }),
        style: difyTextStyle(DifyType.systemMdRegular, DifyColors.textSecondary),
      ),
    );
    return DifyDropdownMenu(
      open: _open && !widget.disabled,
      onOpenChange: (open) => setState(() => _open = open && !widget.disabled),
      placement: DifyPlacement.rightEnd,
      builder: (context, c) => DifyTipPopup(
        title: label,
        child: OperatorButton(
          label: label,
          icon: const RemixIcon('more-fill'),
          disabled: widget.disabled,
          onPressed: c.toggle,
        ),
      ),
      children: [
        const SizedBox(width: 179), // min-w-45
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            spacing: 8,
            children: [
              RemixIcon('export-line', size: 12, color: DifyColors.textTertiary),
              DifyTextLine(tw('common.exportImage'), style: heading),
            ],
          ),
        ),
        group('common.currentView'),
        for (final f in ExportImageFormat.values) item(f, false),
        Container(
          height: 1,
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          color: DifyColors.dividerSubtle,
        ),
        group('common.currentWorkflow'),
        for (final f in ExportImageFormat.values) item(f, true),
      ],
    );
  }
}
