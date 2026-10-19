import 'package:flutter/material.dart';

import '../../canvas/canvas_controller.dart';
import '../../canvas/card_controls.dart';
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../editor/editor_controller.dart';
import '../../i18n/dify_i18n.dart';
import '../../workflow/dify_json.dart';
import '../block_selector/block_selector.dart';
import '../context_menu/context_menu.dart';
import '../node_insertion/insert_block.dart';
import '../node_panel/bodies/core/variable_aggregator_panel.dart';
import '../node_panel/node_panel_bodies.dart';
import '../node_panel/panel_edit.dart';
import '../panel_fields/panel_fields.dart';
import '../store/store.dart';
import '../operator/actions.dart' show OperatorReadOnly;

NodePanelProps _props(BuildContext context, EditorController editor, CanvasController canvas, String id) =>
    NodePanelProps(
      node: editor.doc.nodes[id]!,
      controller: editor,
      actions: WorkflowActions(
        controller: editor,
        canvas: canvas,
        store: WorkflowStoreScope.of(context),
        options: WorkflowMenuOptions(isChatMode: BlockSelectorScope.of(context).chatMode),
      ),
    );

VariableAssignerHooks _hooks(EditorController editor, WorkflowStore store) => VariableAssignerHooks(
  getNodes: () => reactFlowGraphOf(editor.doc).nodes,
  setNodes: (_) {}, // Dify's two popup flags are local store state, never document edits.
  handleNodeDataUpdate: ({required id, required data}) {
    if (store.nodesReadOnly) return;
    final node = editor.doc.nodes[id];
    if (node != null) writeInputs(editor, id, {...difyDataOf(node), ...data}, shown: node);
  },
  setShowAssignVariablePopup: () => store.setShowAssignVariablePopup(null),
  setHoveringAssignVariableGroupId: store.setHoveringAssignVariableGroupId,
  connectingNodePayload: () => store.connectingNodePayload.value,
);

VarScope _scope(NodePanelProps props, String outputType, {String? source}) {
  final full = source == null
      ? NodeVars.of(props).scope
      : NodeVars.scopeOver(props, [?props.controller.doc.nodes[source]]);
  return aggregatorAddScope(full, filterVarByType(outputType.isEmpty ? 'any' : outputType));
}

/// variable-assigner/components/node-group-item: transient drag borders and the live add-variable button.
class AggregatorGroupControl extends StatelessWidget {
  const AggregatorGroupControl({super.key, required this.nodeId, required this.groupId, required this.type});
  final String nodeId, groupId, type;

  @override
  Widget build(BuildContext context) {
    final store = context.getInheritedWidgetOfExactType<WorkflowStoreScope>()?.store;
    if (store == null) return const SizedBox.shrink();
    final canvas = CanvasControlScope.of(context);
    final props = _props(context, canvas.editor, canvas.canvas, nodeId);
    final popup = DifyFloatingController();
    return ListenableBuilder(
      listenable: Listenable.merge([
        store.enteringNodePayload,
        store.hoveringAssignVariableGroupId,
        store.connectingNodePayload,
        store.canvasReadOnly,
      ]),
      builder: (context, _) {
        final entering = store.enteringNodePayload.value?.nodeId == nodeId;
        final selected = entering && (store.hoveringAssignVariableGroupId.value ?? 'target') == groupId;
        return Stack(
          children: [
            if (entering)
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    key: ValueKey('aggregator-entering-$nodeId-$groupId'),
                    painter: _GroupBorder(selected),
                  ),
                ),
              ),
            Positioned(
              top: 5.5,
              right: 7.5,
              width: 16,
              height: 16,
              child: DifyFloating(
                controller: popup,
                placement: DifyPlacement.right,
                sideOffset: 4,
                builder: (context, popup) => DifyPressable(
                  key: ValueKey('aggregator-add-$nodeId-$groupId'),
                  semanticLabel: DifyI18n.tr('common', 'operation.add'),
                  disabled: store.nodesReadOnly,
                  onPressed: store.nodesReadOnly ? null : popup.toggle,
                  builder: (context, hovered, focused) => Center(
                    child: DifyIcon('vender/line/general/plus-02', size: 10, color: DifyColors.textTertiary),
                  ),
                ),
                popupBuilder: (context) => _variablePopup(
                  vars: _scope(props, type).vars,
                  popupFor: 'assigned',
                  onChange: (value, detail) {
                    _hooks(canvas.editor, store).handleAssignVariableValueChange(nodeId, value, detail, groupId);
                    popup.close();
                  },
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The post-connection picker, anchored at the drop point. The popup itself is the existing variable picker.
class AggregatorPopupHost extends StatelessWidget {
  const AggregatorPopupHost({super.key, required this.controller, required this.canvas});
  final EditorController controller;
  final CanvasController canvas;

  @override
  Widget build(BuildContext context) {
    final store = WorkflowStoreScope.of(context);
    return ValueListenableBuilder(
      valueListenable: store.showAssignVariablePopup,
      builder: (context, payload, _) {
        if (payload == null || store.nodesReadOnly) return const SizedBox.shrink();
        final target = controller.doc.nodes[payload.variableAssignerNodeId];
        final node = canvas.graph?[payload.variableAssignerNodeId];
        if (target == null || node == null) return const SizedBox.shrink();
        final props = _props(context, controller, canvas, target.id);
        final groupId = payload.variableAssignerNodeHandleId;
        final data = difyDataOf(target);
        var type = '${data['output_type'] ?? 'any'}';
        if (groupId != 'target') {
          final groups = ((data['advanced_settings'] as Map?)?['groups'] as List?) ?? [];
          final group = groups.whereType<Map>().where((g) => g['groupId'] == groupId).firstOrNull;
          type = '${group?['output_type'] ?? 'any'}';
        }
        final at = canvas.view.toScreen(Offset(node.x + payload.x, node.y + payload.y));
        return Stack(
          children: [
            Positioned(
              left: at.dx,
              top: at.dy,
              width: 1,
              height: 1,
              child: DifyFloating(
                open: true,
                placement: DifyPlacement.rightStart,
                sideOffset: 4,
                onOpenChange: (open) {
                  if (!open) store.setShowAssignVariablePopup(null);
                },
                builder: (context, _) => const SizedBox.shrink(),
                popupBuilder: (context) => _variablePopup(
                  vars: _scope(props, type, source: payload.nodeId).vars,
                  popupFor: 'assigned',
                  onChange: (value, detail) =>
                      _hooks(controller, store).handleAddVariableInAddVariablePopupWithPosition(
                        payload.nodeId,
                        target.id,
                        groupId,
                        value,
                        detail,
                      ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

Widget _variablePopup({required List<VarGroup> vars, required VarSelected onChange, String? popupFor}) => Material(
  type: MaterialType.transparency,
  child: VarReferencePopup(vars: vars, onChange: onChange, popupFor: popupFor),
);

class _GroupBorder extends CustomPainter {
  const _GroupBorder(this.selected);
  final bool selected;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = RRect.fromRectAndRadius((Offset.zero & size).deflate(0.75), const Radius.circular(8));
    canvas.drawRRect(
      rect,
      Paint()..color = selected ? DifyColors.utilColorsBlueBlue50.withValues(alpha: 0.3) : DifyColors.stateBaseHover,
    );
    final paint = Paint()
      ..color = (selected ? DifyColors.textAccent : DifyColors.dividerSubtle)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    if (selected) {
      canvas.drawRRect(rect, paint);
    } else {
      final path = Path()..addRRect(rect);
      for (final metric in path.computeMetrics()) {
        for (var offset = 0.0; offset < metric.length; offset += 8) {
          canvas.drawPath(metric.extractPath(offset, offset + 4), paint);
        }
      }
    }
  }

  @override
  bool shouldRepaint(_GroupBorder oldDelegate) => oldDelegate.selected != selected;
}
