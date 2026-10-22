/// Selection plumbing with Dify controls instead of the platform Material menu.
library;

import 'package:flutter/material.dart';

import '../dify_tokens.g.dart';
import 'widgets.dart';

Widget difySelectionToolbar(BuildContext context, EditableTextState state) => DifySelectionMenu(
  anchors: state.contextMenuAnchors,
  buttonItems: state.contextMenuButtonItems,
);

class DifySelectionMenu extends StatelessWidget {
  const DifySelectionMenu({super.key, required this.anchors, required this.buttonItems});
  final TextSelectionToolbarAnchors anchors;
  final List<ContextMenuButtonItem> buttonItems;
  @override
  Widget build(BuildContext context) => buttonItems.isEmpty
      ? const SizedBox.shrink()
      : TextSelectionToolbar(
          anchorAbove: anchors.primaryAnchor,
          anchorBelow: anchors.secondaryAnchor ?? anchors.primaryAnchor,
          toolbarBuilder: (context, child) => Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: DifyColors.componentsPanelBg,
              borderRadius: BorderRadius.circular(DifyRadius.lg),
              boxShadow: DifyShadows.lg,
            ),
            child: child,
          ),
          children: [
            for (final item in buttonItems)
              DifyButton(
                size: DifyButtonSize.small,
                variant: DifyButtonVariant.ghost,
                onPressed: item.onPressed,
                child: Text(
                  item.label ??
                      switch (item.type) {
                        ContextMenuButtonType.cut => MaterialLocalizations.of(context).cutButtonLabel,
                        ContextMenuButtonType.copy => MaterialLocalizations.of(context).copyButtonLabel,
                        ContextMenuButtonType.paste => MaterialLocalizations.of(context).pasteButtonLabel,
                        ContextMenuButtonType.selectAll => MaterialLocalizations.of(context).selectAllButtonLabel,
                        _ => '',
                      },
                ),
              ),
          ],
        );
}

class DifySelectableText extends StatelessWidget {
  const DifySelectableText(this.data, {super.key, this.style});
  final String data;
  final TextStyle? style;
  @override
  Widget build(BuildContext context) => SelectableText(
    data,
    style: style ?? difyTextStyle(DifyType.systemSmRegular, DifyColors.textSecondary),
    cursorColor: DifyColors.primary600,
    contextMenuBuilder: difySelectionToolbar,
  );
}
