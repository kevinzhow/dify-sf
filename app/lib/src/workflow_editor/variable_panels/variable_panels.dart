/// The variable panels of the editor's right side (Dify mounts EnvPanel in panel/index.tsx and the conversation
/// and system variable panels in workflow-app's workflow-panel.tsx): whichever of them the store shows. They are
/// mutually exclusive with each other and the debug panel ([WorkflowStore.setShowEnvPanel] and its siblings).
library;

import 'package:flutter/widgets.dart';

import '../../editor/editor_controller.dart';
import '../store/store.dart';
import 'app_variables.dart';
import 'chat_variable_panel.dart';
import 'env_panel.dart';
import 'global_variable_panel.dart';

export 'app_variables.dart' show AppVariableList, StoreSecret;
export 'chat_variable_panel.dart' show ChatVariablePanel;
export 'env_panel.dart' show EnvPanel;
export 'global_variable_panel.dart' show GlobalVariablePanel;

/// The Environment Variables panel, the Conversation Variables panel (chatflows only, [isChatMode]) or the System
/// Variables panel, as the store's `showEnvPanel` / `showChatVariablePanel` / `showGlobalVariablePanel` say; nothing
/// when none is shown.
class VariablePanels extends StatelessWidget {
  const VariablePanels({super.key, required this.controller, required this.isChatMode, this.storeSecret});
  final EditorController controller;
  final bool isChatMode;
  final StoreSecret? storeSecret;

  @override
  Widget build(BuildContext context) {
    final store = WorkflowStoreScope.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([store.showEnvPanel, store.showChatVariablePanel, store.showGlobalVariablePanel]),
      builder: (context, _) {
        if (store.showEnvPanel.value) return EnvPanel(controller: controller, storeSecret: storeSecret);
        if (store.showChatVariablePanel.value && isChatMode) return ChatVariablePanel(controller: controller);
        if (store.showGlobalVariablePanel.value) return GlobalVariablePanel(isChatMode: isChatMode);
        return const SizedBox.shrink();
      },
    );
  }
}
