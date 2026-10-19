/// The System Variables panel (panel/global-variable-panel: index.tsx, item.tsx): the read-only `sys.` variables.
library;

import 'package:flutter/material.dart';

import '../../cards/card_kit.dart';
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../store/store.dart';
import 'panel_kit.dart';

/// The system variables of a chatflow ([isChatMode]) or a workflow (`timestamp` only on the workflow page).
List<({String name, String valueType, String description})> globalVariableList({
  required bool isChatMode,
  required bool isWorkflowPage,
}) {
  String d(String key) => tw('globalVar.fieldsDescription.$key');
  return [
    if (isChatMode) ...[
      (name: 'conversation_id', valueType: 'string', description: d('conversationId')),
      (name: 'dialog_count', valueType: 'number', description: d('dialogCount')),
    ],
    (name: 'user_id', valueType: 'string', description: d('userId')),
    (name: 'app_id', valueType: 'string', description: d('appId')),
    (name: 'workflow_id', valueType: 'string', description: d('workflowId')),
    (name: 'workflow_run_id', valueType: 'string', description: d('workflowRunId')),
    if (isWorkflowPage && !isChatMode) (name: 'timestamp', valueType: 'number', description: d('triggerTimestamp')),
  ];
}

/// Panel: the title, the description and a card per system variable (orange icon, `sys.` + name, type,
/// description).
class GlobalVariablePanel extends StatelessWidget {
  const GlobalVariablePanel({super.key, required this.isChatMode, this.isWorkflowPage = true});
  final bool isChatMode;

  /// `isInWorkflowPage()`: the app's workflow editor (not a RAG pipeline).
  final bool isWorkflowPage;

  @override
  Widget build(BuildContext context) {
    final store = WorkflowStoreScope.of(context);
    return VariablePanelShell(
      title: tw('globalVar.title'),
      actions: [PanelCloseButton(onPressed: () => store.setShowGlobalVariablePanel(false))],
      children: [
        PanelDescription(tw('globalVar.description')),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            children: [
              for (final v in globalVariableList(isChatMode: isChatMode, isWorkflowPage: isWorkflowPage))
                VariableItemCard(
                  key: ValueKey(v.name),
                  icon: DifyIcon(
                    'vender/line/others/global-variable',
                    size: 16,
                    color: DifyColors.utilColorsOrangeOrange600,
                  ),
                  name: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: 'sys.',
                          style: TextStyle(color: DifyColors.textTertiary),
                        ),
                        TextSpan(text: v.name),
                      ],
                    ),
                    style: difyStyle(DifyType.systemSmMedium, DifyColors.textPrimary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  type: capitalize(v.valueType),
                  body: Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: DifyText(v.description, DifyType.systemXsRegular, color: DifyColors.textTertiary),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
