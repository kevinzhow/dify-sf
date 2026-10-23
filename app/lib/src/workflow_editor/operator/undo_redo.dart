import 'package:flutter/widgets.dart';

import '../../design/dify_icon.dart';
import '../../design/widgets/widgets.dart';
import '../../editor/undo_manager.dart';
import '../store/store.dart';
import 'action_bar.dart';
import 'actions.dart';
import 'view_workflow_history.dart';

/// header/undo-redo.tsx: undo, redo and the change history button, in one bar. The buttons are disabled when there
/// is nothing to undo / redo or the nodes are read-only.
class UndoRedo extends StatelessWidget {
  const UndoRedo({super.key, required this.history, required this.onUndo, required this.onRedo});

  final UndoManager history;
  final VoidCallback onUndo;
  final VoidCallback onRedo;

  @override
  Widget build(BuildContext context) {
    final store = WorkflowStoreScope.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([history, store.readOnlyChanges]),
      builder: (context, _) {
        final readOnly = store.nodesReadOnly;
        Widget button(String key, String icon, String shortcut, bool can, VoidCallback onPressed) => Padding(
          padding: const EdgeInsets.only(right: 2), // space-x-0.5
          child: DifyTipPopup(
            title: tw(key),
            shortcut: shortcut,
            child: OperatorButton(
              label: tw(key),
              icon: RemixIcon(icon),
              disabled: readOnly || !can,
              onPressed: onPressed,
            ),
          ),
        );
        return ActionBar(
          blur: true,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              button('common.undo', 'arrow-go-back-line', 'workflow.undo', history.canUndo, onUndo),
              button('common.redo', 'arrow-go-forward-fill', 'workflow.redo', history.canRedo, onRedo),
              const DifyDivider.vertical(margin: EdgeInsets.symmetric(horizontal: 2), length: 14),
              ViewWorkflowHistory(history: history, disabled: readOnly),
            ],
          ),
        );
      },
    );
  }
}
