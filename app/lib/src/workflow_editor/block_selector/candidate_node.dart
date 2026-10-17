/// The "place on click" flow (workflow/candidate-node.tsx, candidate-node-main.tsx): a node chosen from the toolbar's
/// Add Node (or the pane menu, or Add Note) waits in the store's `candidateNode`, follows the pointer at the canvas's
/// zoom, and is placed where the next click lands; a right click drops it.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import '../../canvas/canvas_controller.dart';
import '../../cards/bodies/note_body.dart' show NoteCardView, NoteData, customNoteNode;
import '../../cards/card_kit.dart' show DifyText;
import '../../design/dify_tokens.g.dart';
import '../store/workflow_store.dart';
import '../store/workflow_store_scope.dart';
import 'block_defaults.dart';
import 'selector_widgets.dart' show SelectorBlockIcon, SelectorIconSize;

/// The candidate a block chosen from the toolbar's Add Node becomes (operator/add-block.tsx handleSelect): a new
/// node (generateNewNode, `custom-simple` for Exit Loop) whose data is [newNodeData] flagged `_isCandidate`. Put it
/// in the store with `setCandidateNode`.
DifyJson candidateNodeOf(
  String type,
  DifyJson defaults, {
  DifyJson? toolDefaultValue,
  Iterable<DifyJson> existing = const [],
  String? id,
}) => generateNewNode(
  id: id,
  type: nodeCustomTypeOf(type),
  data: {
    ...newNodeData(type, defaults, toolDefaultValue: toolDefaultValue, existing: existing),
    '_isCandidate': true,
  },
  position: (x: 0, y: 0),
).node;

/// What placing a candidate does (candidate-node-main.tsx's click), for the app to apply to the document.
class CandidatePlacement {
  const CandidatePlacement({
    required this.node,
    this.startNode,
    required this.historyEvent,
    this.selectNode = false,
    this.deselectOthers = false,
    this.generateWebhookUrl = false,
    this.createInlineAgentBinding = false,
    this.syncDraft = false,
  });

  /// The node to add: the candidate at the clicked flow position, no longer `_isCandidate`.
  final DifyJson node;

  /// An iteration's or loop's start node (getIterationStartNode / getLoopStartNode), added after it.
  final DifyJson? startNode;

  /// `NodeAdd`, or `NoteAdd` for a note.
  final String historyEvent;

  /// Notes are selected once placed (handleNodeSelect).
  final bool selectNode;

  /// A start-from-scratch Agent v2 node is selected alone (every other node deselected), kept as a temp node while
  /// its inline agent binding is created ([createInlineAgentBinding]: then the store's
  /// `openInlineAgentPanelNodeId`, a forced draft sync, the binding and `_openInlineAgentPanel`; on failure the node
  /// is removed).
  final bool deselectOthers;
  final bool createInlineAgentBinding;

  /// A webhook trigger: sync the draft, then generate its URL (useAutoGenerateWebhookUrl).
  final bool generateWebhookUrl;

  /// An Agent v2 node with its binding: sync the draft right away.
  final bool syncDraft;
}

bool _isAgentV2(DifyJson data) =>
    (data['type'] == 'agent' || data['type'] == 'agent-v2') &&
    data['agent_node_kind'] == 'dify_agent' &&
    data['version'] == '2';

bool _needsInlineBinding(DifyJson data) {
  final b = data['agent_binding'];
  if (b is! Map || b['binding_type'] != 'inline_agent') return false;
  final id = b['agent_id'], snapshot = b['current_snapshot_id'];
  return !(id is String && id.isNotEmpty && snapshot is String && snapshot.isNotEmpty);
}

/// The candidate's click handler: [candidate] placed at [position] (flow coordinates).
CandidatePlacement placeCandidate(DifyJson candidate, Offset position) {
  final data = (candidate['data'] as Map?)?.cast<String, Object?>() ?? const {};
  final id = '${candidate['id']}';
  final inline = _isAgentV2(data) && _needsInlineBinding(data);
  final note = candidate['type'] == 'custom-note';
  final type = data['type'];
  return CandidatePlacement(
    node: {
      ...candidate,
      'data': {
        ...data,
        '_isCandidate': false,
        if (inline) '_isTempNode': true,
        if (inline) 'selected': true,
      },
      'position': {'x': position.dx, 'y': position.dy},
    },
    startNode: type == 'iteration'
        ? iterationStartNode(id)
        : type == 'loop'
        ? loopStartNode(id)
        : null,
    historyEvent: note ? 'NoteAdd' : 'NodeAdd',
    selectNode: note,
    deselectOthers: inline,
    createInlineAgentBinding: inline,
    generateWebhookUrl: type == 'trigger-webhook',
    syncDraft: _isAgentV2(data),
  );
}

/// CandidateNode: while the store holds a candidate, covers the canvas (put it over the canvas, the same size) and
/// draws the candidate's card with its top-left at the pointer, scaled by [canvas]'s zoom. A click (or tap) clears
/// the candidate and hands [onPlace] its [CandidatePlacement] at the clicked canvas point; a right click clears it.
/// [nodeBuilder] draws the card (default: the node's header as BaseNode draws it).
class CandidateNode extends StatelessWidget {
  const CandidateNode({super.key, required this.canvas, required this.onPlace, this.nodeBuilder});

  final CanvasController canvas;
  final void Function(CandidatePlacement placement) onPlace;
  final Widget Function(BuildContext context, DifyJson candidate)? nodeBuilder;

  @override
  Widget build(BuildContext context) {
    final store = WorkflowStoreScope.of(context);
    return ValueListenableBuilder(
      valueListenable: store.candidateNode,
      builder: (context, candidate, _) => candidate == null
          ? const SizedBox.shrink()
          : CandidateNodeMain(
              key: ValueKey(candidate['id']),
              candidate: candidate,
              canvas: canvas,
              onPlace: onPlace,
              nodeBuilder: nodeBuilder,
            ),
    );
  }
}

/// CandidateNodeMain: the overlay of one candidate.
class CandidateNodeMain extends StatefulWidget {
  const CandidateNodeMain({
    super.key,
    required this.candidate,
    required this.canvas,
    required this.onPlace,
    this.nodeBuilder,
  });

  final DifyJson candidate;
  final CanvasController canvas;
  final void Function(CandidatePlacement placement) onPlace;
  final Widget Function(BuildContext context, DifyJson candidate)? nodeBuilder;

  @override
  State<CandidateNodeMain> createState() => _CandidateNodeMainState();
}

class _CandidateNodeMainState extends State<CandidateNodeMain> {
  late final WorkflowStore _store = WorkflowStoreScope.of(context);

  void _track(PointerEvent e) => _store.setMousePosition((
    pageX: e.position.dx,
    pageY: e.position.dy,
    elementX: e.localPosition.dx,
    elementY: e.localPosition.dy,
  ));

  void _place(Offset local) {
    final placement = placeCandidate(widget.candidate, widget.canvas.view.toCanvas(local));
    _store.setCandidateNode();
    widget.onPlace(placement);
  }

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.opaque,
    onPointerHover: _track,
    onPointerMove: _track,
    onPointerDown: (e) {
      _track(e);
      if (e.buttons == kSecondaryMouseButton) _store.setCandidateNode();
    },
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (d) => _place(d.localPosition),
      child: ListenableBuilder(
        listenable: Listenable.merge([_store.mousePosition, widget.canvas.view]),
        builder: (context, _) {
          final m = _store.mousePosition.value;
          return Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: m.elementX,
                top: m.elementY,
                child: IgnorePointer(
                  child: Transform.scale(
                    scale: widget.canvas.view.scale,
                    alignment: Alignment.topLeft,
                    child:
                        widget.nodeBuilder?.call(context, widget.candidate) ??
                        _CandidateCard(candidate: widget.candidate),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    ),
  );
}

/// The default candidate card: BaseNode's `w-60 rounded-[15px] bg-workflow-block-bg shadow-xs` with its header
/// (BlockIcon md and the title in `system-sm-semibold-uppercase`); a note is the note card.
class _CandidateCard extends StatelessWidget {
  const _CandidateCard({required this.candidate});
  final DifyJson candidate;

  @override
  Widget build(BuildContext context) {
    final data = (candidate['data'] as Map?)?.cast<String, Object?>() ?? const {};
    // candidate-node-main.tsx renders the note itself (CustomNoteNode).
    if (candidate['type'] == customNoteNode) return NoteCardView(data: NoteData.fromJson(data));
    final type = '${data['type'] ?? ''}';
    final title = '${data['title'] ?? type}';
    return Container(
      width: 240,
      decoration: BoxDecoration(
        color: DifyColors.workflowBlockBg,
        borderRadius: BorderRadius.circular(DifyRadius.nodeCard),
        border: Border.all(color: const Color(0x00000000)),
        boxShadow: DifyShadows.xs,
      ),
      padding: const EdgeInsets.fromLTRB(13, 13, 13, 13),
      child: Row(
        children: [
          SelectorBlockIcon(type: type, size: SelectorIconSize.md, toolIcon: data['provider_icon']),
          const SizedBox(width: 8),
          Expanded(child: DifyText(title, DifyType.systemSmSemiboldUppercase, color: DifyColors.textPrimary)),
        ],
      ),
    );
  }
}
