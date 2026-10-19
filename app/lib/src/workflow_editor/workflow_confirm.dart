/// components/workflow/index.tsx's AlertDialog over the store's `showConfirm` (deleting a container with children,
/// …): the title, the description, Cancel (clears `showConfirm`) and Confirm (its `onConfirm`). A click outside
/// cancels, as Escape does.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design/dify_tokens.g.dart';
import '../design/widgets/widgets.dart';
import 'store/store.dart';

class WorkflowConfirm extends StatelessWidget {
  const WorkflowConfirm({super.key});

  @override
  Widget build(BuildContext context) {
    final store = WorkflowStoreScope.of(context);
    return ValueListenableBuilder<ShowConfirm?>(
      valueListenable: store.showConfirm,
      builder: (context, confirm, _) {
        if (confirm == null) return const SizedBox.shrink();
        void cancel() => store.setShowConfirm(null);
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: cancel,
                child: ColoredBox(color: DifyColors.backgroundOverlay),
              ),
            ),
            CallbackShortcuts(
              bindings: {const SingleActivator(LogicalKeyboardKey.escape): cancel},
              child: FocusScope(
                autofocus: true,
                child: DifyAlertDialog(
                  surfaceKey: const ValueKey('workflow-confirm'),
                  title: confirm.title,
                  description: confirm.desc,
                  cancelKey: const ValueKey('workflow-confirm-cancel'),
                  confirmKey: const ValueKey('workflow-confirm-confirm'),
                  semanticButtonLabels: true,
                  onCancel: cancel,
                  onConfirm: confirm.onConfirm,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
