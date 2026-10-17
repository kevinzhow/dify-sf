import 'package:flutter/widgets.dart';

import '../../canvas/canvas_controller.dart';
import '../../design/css_metrics.dart';
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../store/store.dart';
import 'action_bar.dart';
import 'actions.dart';

const _black5 = Color(0x0D000000); // bg-black/5

/// operator/zoom-in-out.tsx: zoom out, the zoom percentage (opens the zoom menu), zoom in.
class ZoomInOut extends StatefulWidget {
  const ZoomInOut({
    super.key,
    required this.canvas,
    this.options = const OperatorOptions(),
    this.showMiniMap = true,
    this.onToggleMiniMap,
    this.showUserCursors = true,
    this.onToggleUserCursors,
    this.showUserComments = true,
    this.onToggleUserComments,
    this.isCommentMode = false,
  });

  final CanvasController canvas;
  final OperatorOptions options;
  final bool showMiniMap;
  final VoidCallback? onToggleMiniMap;
  final bool showUserCursors;
  final VoidCallback? onToggleUserCursors;
  final bool showUserComments;
  final VoidCallback? onToggleUserComments;
  final bool isCommentMode;

  @override
  State<ZoomInOut> createState() => _ZoomInOutState();
}

class _ZoomInOutState extends State<ZoomInOut> {
  bool _hovered = false;
  bool _menuOpen = false;

  @override
  Widget build(BuildContext context) {
    final store = WorkflowStoreScope.of(context);
    final view = widget.canvas.view;
    return ListenableBuilder(
      listenable: Listenable.merge([view, store.readOnlyChanges]),
      builder: (context, _) {
        final readOnly = store.workflowReadOnly;
        final zoom = view.scale;
        Widget pill = MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: ActionBar(
            blur: true,
            color: _hovered ? DifyColors.stateBaseHover : DifyColors.componentsActionbarBg,
            child: SizedBox(
              // h-9 border-box; the inner h-8 row overflows it by the border, as in the browser.
              width: 98,
              height: 36 - 4 - 2 * Css.hairline,
              child: OverflowBox(
                alignment: Alignment.topCenter,
                maxHeight: 32,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _zoomButton('operator.zoomOut', 'zoom-out-line', 'workflow.zoom-out', zoom <= 0.25, () {
                      widget.canvas.zoomOut();
                    }),
                    _menu(store, readOnly, zoom),
                    _zoomButton('operator.zoomIn', 'zoom-in-line', 'workflow.zoom-in', zoom >= 2, () {
                      widget.canvas.zoomIn();
                    }),
                  ],
                ),
              ),
            ),
          ),
        );
        if (readOnly) pill = Opacity(opacity: 0.5, child: pill);
        return pill;
      },
    );
  }

  Widget _zoomButton(String key, String icon, String shortcut, bool disabled, VoidCallback onPressed) => DifyTipPopup(
    title: tw(key),
    shortcut: shortcut,
    child: DifyPressable(
      semanticLabel: tw(key),
      disabled: disabled,
      onPressed: onPressed,
      builder: (context, hovered, focused) => DifyButtonSurface(
        look: DifyButtonLook(
          foreground: hovered ? DifyColors.textSecondary : DifyColors.textTertiary,
          background: hovered && !disabled ? _black5 : null,
        ),
        radius: DifyRadius.lg,
        focused: focused,
        child: SizedBox.square(dimension: 32, child: Center(child: RemixIcon(icon))),
      ),
    ),
  );

  void _zoom(void Function() apply) {
    if (WorkflowStoreScope.of(context).workflowReadOnly) return;
    apply();
    widget.options.onSyncDraft?.call();
  }

  Widget _menu(WorkflowStore store, bool readOnly, double zoom) {
    final canvas = widget.canvas;
    const blank = SizedBox.square(dimension: 16);
    const check = RemixIcon('check-line', color: DifyColors.textAccent);
    Widget item(String text, VoidCallback onSelect, {Widget leading = blank, String? kbd, bool disabled = false}) =>
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4), // the group's p-1
          child: DifyMenuItem(
            disabled: disabled,
            onSelect: onSelect,
            // px-3 where the row has px-2, and gap-2 where it has gap-1.
            leading: Padding(padding: const EdgeInsets.only(left: 4), child: leading),
            trailing: kbd == null
                ? null
                : Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: DifyShortcutKbd(shortcut: kbd),
                  ),
            child: Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Text(text, style: difyTextStyle(DifyType.systemMdRegular, DifyColors.textSecondary)),
            ),
          ),
        );
    Widget toggle(String key, bool on, VoidCallback? onToggle, {bool disabled = false}) => item(
      tw(key),
      () {
        if (!readOnly && !disabled) onToggle?.call();
      },
      leading: on ? check : blank,
      disabled: disabled,
    );
    Widget zoomTo(String text, double z, [String? kbd]) => item(text, () => _zoom(() => canvas.zoomTo(z)), kbd: kbd);
    final collaboration = widget.options.collaborationEnabled;
    return DifyDropdownMenu(
      open: _menuOpen && !readOnly,
      onOpenChange: (open) => setState(() => _menuOpen = open && !store.workflowReadOnly),
      placement: DifyPlacement.topStart,
      sideOffset: 4,
      alignOffset: -2,
      width: 192 - 2 * Css.hairline,
      builder: (context, c) => DifyPressable(
        disabled: readOnly,
        onPressed: c.toggle,
        builder: (context, hovered, focused) {
          final lit = hovered || _menuOpen;
          return DifyButtonSurface(
            look: DifyButtonLook(
              foreground: lit ? DifyColors.textSecondary : DifyColors.textTertiary,
              background: lit ? _black5 : null,
            ),
            radius: DifyRadius.lg,
            focused: focused,
            child: SizedBox(
              width: 34,
              height: 32,
              child: Center(
                child: Text('${(zoom * 100).toStringAsFixed(0)}%', style: DifyType.systemSmMedium.style),
              ),
            ),
          );
        },
      ),
      children: [
        zoomTo('200%', 2),
        zoomTo('100%', 1, 'workflow.zoom-to-100'),
        zoomTo('75%', 0.75),
        zoomTo('50%', 0.5, 'workflow.zoom-to-50'),
        zoomTo('25%', 0.25),
        item(
          tw('operator.zoomToFit'),
          () => _zoom(canvas.fitView),
          leading: const RemixIcon('fullscreen-line', color: DifyColors.textTertiary),
          kbd: 'workflow.zoom-to-fit',
        ),
        const SizedBox(height: 4),
        Container(height: 1, color: DifyColors.dividerSubtle),
        const SizedBox(height: 4),
        if (collaboration) ...[
          toggle(
            'operator.showUserComments',
            widget.showUserComments,
            widget.onToggleUserComments,
            disabled: widget.isCommentMode,
          ),
          toggle('operator.showUserCursors', widget.showUserCursors, widget.onToggleUserCursors),
        ],
        toggle('operator.showMiniMap', widget.showMiniMap, widget.onToggleMiniMap),
      ],
    );
  }
}
