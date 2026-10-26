/// Selection plumbing with Dify controls instead of the platform Material menu.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart' show SelectedContent, Selectable, MatrixUtils;

import '../dify_tokens.g.dart';
import '../../i18n/dify_i18n.dart';
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
  final _focus = FocusNode(debugLabel: 'DifySelectionRegion');
  @override
  void dispose() {
    _blocks.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SelectionArea(
    focusNode: _focus,
    onSelectionChanged: widget.onSelectionChanged,
    contextMenuBuilder: (context, state) => DifySelectionMenu(
      anchors: state.contextMenuAnchors,
      buttonItems: state.contextMenuButtonItems,
      focusParent: _focus,
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
  focusParent: state.widget.focusNode,
);

class DifySelectionMenu extends StatelessWidget {
  const DifySelectionMenu({super.key, required this.anchors, required this.buttonItems, this.focusParent});
  final TextSelectionToolbarAnchors anchors;
  final List<ContextMenuButtonItem> buttonItems;
  final FocusNode? focusParent;

  void _close() {
    ContextMenuController.removeAny();
    focusParent?.requestFocus();
  }

  void _activate(ContextMenuButtonItem item) {
    item.onPressed?.call();
    _close();
  }

  Map<ShortcutActivator, VoidCallback> get _shortcuts {
    const keys = {
      ContextMenuButtonType.copy: LogicalKeyboardKey.keyC,
      ContextMenuButtonType.cut: LogicalKeyboardKey.keyX,
      ContextMenuButtonType.paste: LogicalKeyboardKey.keyV,
      ContextMenuButtonType.selectAll: LogicalKeyboardKey.keyA,
    };
    return {
      const SingleActivator(LogicalKeyboardKey.escape): _close,
      for (final item in buttonItems)
        if (item.onPressed != null && keys.containsKey(item.type)) ...{
          SingleActivator(keys[item.type]!, control: true): () => _activate(item),
          SingleActivator(keys[item.type]!, meta: true): () => _activate(item),
        },
    };
  }

  String _label(ContextMenuButtonItem item) =>
      item.label ??
      switch (item.type) {
        ContextMenuButtonType.cut => DifyI18n.tr('common', 'operation.cut'),
        ContextMenuButtonType.copy => DifyI18n.tr('common', 'operation.copy'),
        ContextMenuButtonType.paste => DifyI18n.tr('common', 'operation.paste'),
        ContextMenuButtonType.selectAll => DifyI18n.tr('common', 'operation.selectAll'),
        ContextMenuButtonType.delete => DifyI18n.tr('common', 'operation.delete'),
        _ => '',
      };

  @override
  Widget build(BuildContext context) {
    if (buttonItems.isEmpty) return const SizedBox.shrink();
    final padding = MediaQuery.paddingOf(context);
    final inset = MediaQuery.viewInsetsOf(context);
    final origin = Offset(difyFloatingCollisionPadding, padding.top + difyFloatingCollisionPadding);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        origin.dx,
        origin.dy,
        difyFloatingCollisionPadding,
        inset.bottom + padding.bottom + difyFloatingCollisionPadding,
      ),
      child: CustomSingleChildLayout(
        delegate: _SelectionMenuLayout(
          anchorAbove: anchors.primaryAnchor - origin,
          anchorBelow: (anchors.secondaryAnchor ?? anchors.primaryAnchor) - origin,
        ),
        child: TextFieldTapRegion(
          child: Focus(
            parentNode: focusParent,
            child: CallbackShortcuts(
              bindings: _shortcuts,
              child: DefaultTextStyle(
                style: difyTextStyle(
                  DifyType.systemSmRegular,
                  DifyColors.textSecondary,
                ).copyWith(inherit: false, decoration: TextDecoration.none),
                child: DifyMenuPopup(
                  focusFirst: true,
                  children: [
                    for (final item in buttonItems)
                      DifyMenuItem(
                        disabled: item.onPressed == null,
                        onSelect: () => _activate(item),
                        child: DifyTextLine(_label(item)),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Reuse Flutter's selection anchor geometry, with the design system's collision
/// padding and the visible keyboard bounds. No Material toolbar is rendered.
class _SelectionMenuLayout extends TextSelectionToolbarLayoutDelegate {
  _SelectionMenuLayout({required super.anchorAbove, required super.anchorBelow});
  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final target = super.getPositionForChild(size, childSize);
    return Offset(
      target.dx.clamp(0, (size.width - childSize.width).clamp(0, size.width)),
      target.dy.clamp(0, (size.height - childSize.height).clamp(0, size.height)),
    );
  }
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
