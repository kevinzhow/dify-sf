/// components/workflow/index.tsx's AlertDialog over the store's `showConfirm` (deleting a container with children,
/// …): the title, the description, Cancel (clears `showConfirm`) and Confirm (its `onConfirm`). A click outside
/// cancels, as Escape does.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design/css_metrics.dart';
import '../design/dify_tokens.g.dart';
import '../design/widgets/widgets.dart';
import '../i18n/dify_i18n.dart';
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
            Center(
              child: CallbackShortcuts(
                bindings: {const SingleActivator(LogicalKeyboardKey.escape): cancel},
                child: FocusScope(
                  autofocus: true,
                  child: Material(
                    type: MaterialType.transparency,
                    child: Semantics(
                      container: true,
                      scopesRoute: true,
                      namesRoute: true,
                      explicitChildNodes: true,
                      label: confirm.title,
                      child: Container(
                        key: const ValueKey('workflow-confirm'),
                        width: 480,
                        decoration: BoxDecoration(
                          color: DifyColors.componentsPanelBg,
                          borderRadius: BorderRadius.circular(DifyRadius.xxl),
                          border: Border.all(color: DifyColors.componentsPanelBorder, width: Css.hairline),
                          boxShadow: DifyShadows.lg,
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Padding(
                              padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                spacing: 8,
                                children: [
                                  Text(
                                    confirm.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: difyTextStyle(DifyType.title2xlSemiBold, DifyColors.textPrimary),
                                  ),
                                  if (confirm.desc case final desc? when desc.isNotEmpty)
                                    Text(desc, style: difyTextStyle(DifyType.systemMdRegular, DifyColors.textTertiary)),
                                ],
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.all(24),
                              child: Wrap(
                                alignment: WrapAlignment.end,
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  DifyButton(
                                    key: const ValueKey('workflow-confirm-cancel'),
                                    semanticLabel: DifyI18n.tr('common', 'operation.cancel'),
                                    onPressed: cancel,
                                    child: Text(DifyI18n.tr('common', 'operation.cancel')),
                                  ),
                                  DifyButton(
                                    key: const ValueKey('workflow-confirm-confirm'),
                                    variant: DifyButtonVariant.primary,
                                    tone: DifyButtonTone.destructive,
                                    semanticLabel: DifyI18n.tr('common', 'operation.confirm'),
                                    onPressed: confirm.onConfirm,
                                    child: Text(DifyI18n.tr('common', 'operation.confirm')),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
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
