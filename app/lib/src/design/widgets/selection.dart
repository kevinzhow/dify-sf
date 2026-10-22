/// Selection plumbing with Dify controls instead of the platform Material menu.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SelectedContent, Selectable, MatrixUtils;

import '../dify_tokens.g.dart';
import 'widgets.dart';

/// One selection region per page/dialog, so ordinary Text and Markdown Text.rich
/// support cross-paragraph selection. EditableText keeps its own editing selection.
class DifySelectionRegion extends StatefulWidget {
  const DifySelectionRegion({super.key, required this.child, this.onSelectionChanged});
  final Widget child;
  final ValueChanged<SelectedContent?>? onSelectionChanged;

  @override
  State<DifySelectionRegion> createState() => _DifySelectionRegionState();
}

class _DifySelectionRegionState extends State<DifySelectionRegion> {
  final _blocks = _DifySelectionDelegate();
  @override
  void dispose() {
    _blocks.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SelectionArea(
    onSelectionChanged: widget.onSelectionChanged,
    contextMenuBuilder: (context, state) => DifySelectionMenu(
      anchors: state.contextMenuAnchors,
      buttonItems: state.contextMenuButtonItems,
    ),
    child: SelectionContainer(delegate: _blocks, child: widget.child),
  );
}

/// Flutter concatenates separate Text widgets without separators. Keep inline
/// fragments together, but preserve a line break between vertically distinct
/// selected blocks instead of copying "first paragraphsecond paragraph".
class _DifySelectionDelegate extends StaticSelectionContainerDelegate {
  Iterable<Selectable> _leaves(Iterable<Selectable> children) sync* {
    for (final child in children) {
      // Scrollable installs its own selection container. Preserve boundaries
      // within it too, using the public container/delegate API.
      if (child is State<SelectionContainer>) {
        final delegate = (child as State<SelectionContainer>).widget.delegate;
        if (delegate is MultiSelectableSelectionContainerDelegate && delegate != this) {
          yield* _leaves(delegate.selectables);
          continue;
        }
      }
      yield child;
    }
  }

  @override
  SelectedContent? getSelectedContent() {
    final result = StringBuffer();
    Rect? previous;
    var endsWithNewline = false;
    for (final child in _leaves(selectables)) {
      final text = child.getSelectedContent()?.plainText;
      if (text == null || text.isEmpty) continue;
      final rects = child.value.selectionRects;
      final transform = child.getTransformTo(null);
      final first = rects.isEmpty ? null : MatrixUtils.transformRect(transform, rects.first);
      if (previous != null &&
          first != null &&
          first.top >= previous.bottom - 0.5 &&
          !endsWithNewline &&
          !text.startsWith('\n')) {
        result.write('\n');
      }
      result.write(text);
      endsWithNewline = text.endsWith('\n');
      if (rects.isNotEmpty) previous = MatrixUtils.transformRect(transform, rects.last);
    }
    return result.isEmpty ? null : SelectedContent(plainText: result.toString());
  }
}

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
