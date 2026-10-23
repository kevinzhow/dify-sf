import 'package:flutter/widgets.dart';

import '../../canvas/card_controls.dart';
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/button.dart';
import '../../i18n/dify_i18n.dart';
import '../context_menu/context_menu.dart';
import '../node_insertion/insert_block.dart';
import '../store/store.dart';
import '../../design/widgets/text_line.dart';

/// iteration/add-block.tsx, rendered as a live control over either canvas renderer.
class IterationAddBlock extends StatelessWidget {
  const IterationAddBlock({super.key, required this.startNodeId});
  final String startNodeId;

  @override
  Widget build(BuildContext context) {
    final scope = CanvasControlScope.of(context);
    return IterationAddBlockVisual(
      buttonKey: ValueKey('iteration-add-$startNodeId'),
      disabled: scope.canvas.isReadOnly(),
      onPressed: () => WorkflowActions(
        controller: scope.editor,
        canvas: scope.canvas,
        store: WorkflowStoreScope.of(context),
        options: const WorkflowMenuOptions(),
      ).showInsertBlockSelector(context, InsertAfter(startNodeId), popupWidth: 256, showStartTab: false),
    );
  }
}

/// The same line and button painted in a detached export, without attaching editing callbacks or a session.
class IterationAddBlockVisual extends StatelessWidget {
  const IterationAddBlockVisual({super.key, this.buttonKey, this.disabled = false, this.onPressed});
  final Key? buttonKey;
  final bool disabled;
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 64,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Container(height: 2, color: DifyColors.dividerRegular),
              Positioned(right: 0, top: -3, child: Container(width: 2, height: 8, color: DifyColors.textAccent)),
            ],
          ),
        ),
        Flexible(
          child: DifyButton(
            key: buttonKey,
            disabled: disabled,
            leading: const RemixIcon('add-line', size: 16),
            onPressed: onPressed,
            child: DifyTextLine(DifyI18n.tr('workflow', 'common.addBlock')),
          ),
        ),
      ],
    );
  }
}
