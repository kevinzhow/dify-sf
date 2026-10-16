import 'package:collab_client/collab_client.dart';
import 'package:flutter/material.dart';

import 'editor_controller.dart';
import 'graph_info.dart';

/// "Insert variable": a menu of every other node's output variables. Picking one calls [onPick] with the
/// reference and the document version the menu was opened at (so a pick made on stale data can conflict).
class VariablePickerButton extends StatefulWidget {
  const VariablePickerButton({
    super.key,
    required this.controller,
    required this.selfNodeId,
    required this.onPick,
    this.tooltip = 'Insert variable',
    this.icon = Icons.data_object,
  });

  final EditorController controller;
  final String selfNodeId;
  final void Function(OutputRef ref, int baseSeq) onPick;
  final String tooltip;
  final IconData icon;

  @override
  State<VariablePickerButton> createState() => _VariablePickerButtonState();
}

class _VariablePickerButtonState extends State<VariablePickerButton> {
  int _openedAt = 0;

  @override
  Widget build(BuildContext context) {
    final doc = widget.controller.doc;
    final options = <PopupMenuEntry<OutputRef>>[];
    for (final id in doc.nodes.keys.toList()..sort()) {
      if (id == widget.selfNodeId) continue;
      final node = doc.nodes[id]!;
      final outputs = outputNames(node);
      if (outputs.isEmpty) continue;
      options.add(
        PopupMenuItem<OutputRef>(
          enabled: false,
          height: 28,
          child: Text(
            node.title.isEmpty ? node.id : node.title,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
          ),
        ),
      );
      for (final o in outputs) {
        options.add(
          PopupMenuItem<OutputRef>(
            key: ValueKey('var-${node.id}-$o'),
            value: OutputRef(node.id, o),
            height: 32,
            child: Row(
              children: [
                const SizedBox(width: 12),
                const Icon(Icons.subdirectory_arrow_right, size: 14),
                const SizedBox(width: 6),
                Text(o),
              ],
            ),
          ),
        );
      }
    }
    return PopupMenuButton<OutputRef>(
      tooltip: widget.tooltip,
      icon: Icon(widget.icon, size: 20),
      onOpened: () => _openedAt = widget.controller.seenVersion,
      onSelected: (ref) => widget.onPick(ref, _openedAt),
      itemBuilder: (_) => options.isEmpty
          ? [const PopupMenuItem<OutputRef>(enabled: false, child: Text('No variables available'))]
          : options,
    );
  }
}
