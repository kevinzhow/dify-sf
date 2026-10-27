/// The controlled overlays the Annotations page is built from, as Dify renders them while their `open` / `isShow` is
/// true: dify-ui's AlertDialog (title, Cancel and a destructive Confirm), Dialog (centred content) and Drawer (the
/// annotation drawers inset from the right edge). Each is drawn on the root overlay over the `bg-background-overlay`
/// backdrop; Escape asks to close, and so does a backdrop click unless pointer dismissal is off.
library;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../design/css_metrics.dart';
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';

String _c(String key) => DifyI18n.tr('common', key);

/// [builder]'s overlay on the root overlay while [open] (nothing otherwise): the backdrop, then the content. [onClose]
/// runs on Escape and, with [dismissible], on a backdrop click.
class ControlledOverlay extends StatefulWidget {
  const ControlledOverlay({
    super.key,
    required this.open,
    required this.builder,
    this.onClose,
    this.dismissible = true,
    this.backdrop = true,
  });

  final bool open;
  final WidgetBuilder builder;
  final VoidCallback? onClose;
  final bool dismissible, backdrop;

  @override
  State<ControlledOverlay> createState() => _ControlledOverlayState();
}

class _ControlledOverlayState extends State<ControlledOverlay> {
  final _portal = OverlayPortalController();

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(ControlledOverlay old) {
    super.didUpdateWidget(old);
    _sync();
  }

  /// Shows or hides the portal after this frame (the controller may not change while building).
  void _sync() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!mounted) return;
    if (widget.open && !_portal.isShowing) _portal.show();
    if (!widget.open && _portal.isShowing) _portal.hide();
  });

  @override
  Widget build(BuildContext context) => OverlayPortal(
    controller: _portal,
    overlayChildBuilder: (context) => Stack(
      fit: StackFit.expand,
      children: [
        if (widget.backdrop)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.dismissible ? widget.onClose : null,
              child: ColoredBox(color: DifyColors.backgroundOverlay),
            ),
          ),
        CallbackShortcuts(
          bindings: {const SingleActivator(LogicalKeyboardKey.escape): () => widget.onClose?.call()},
          child: FocusScope(
            autofocus: true,
            child: DifySurface(
              child: Builder(builder: widget.builder),
            ),
          ),
        ),
      ],
    ),
    child: const SizedBox.shrink(),
  );
}

/// dify-ui's AlertDialog with a title and Cancel / Confirm (`AlertDialogConfirmButton`: primary, destructive by
/// default): `w-120 rounded-2xl border-[0.5px] shadow-lg`; the title in `px-6 pt-6 pb-4` (`title-2xl-semi-bold`,
/// truncated), the actions in `p-6 gap-2`. Cancel and Escape call [onCancel]; a backdrop click too.
class AnnotationAlertDialog extends StatelessWidget {
  const AnnotationAlertDialog({
    super.key,
    required this.open,
    required this.title,
    required this.onCancel,
    required this.onConfirm,
    this.confirmLabel,
    this.loading = false,
  });

  final bool open;
  final String title;
  final VoidCallback onCancel, onConfirm;

  /// "Confirm" by default.
  final String? confirmLabel;

  /// AlertDialogConfirmButton `loading`.
  final bool loading;

  @override
  Widget build(BuildContext context) => ControlledOverlay(
    open: open,
    onClose: onCancel,
    builder: (context) => DifyAlertDialog(
      surfaceKey: const ValueKey('annotation-alert-dialog'),
      title: title,
      cancelLabel: _c('operation.cancel'),
      confirmLabel: confirmLabel ?? _c('operation.confirm'),
      confirmLoading: loading,
      onCancel: onCancel,
      onConfirm: onConfirm,
    ),
  );
}

/// dify-ui's Dialog (DialogContent): centred, [width] wide (at most the viewport less 2 rem), `rounded-2xl
/// bg-components-panel-bg shadow-xl` with [padding] (`p-6` by default), [top] below the viewport's top when given
/// (`mt-14`), named [label].
class AnnotationDialog extends StatelessWidget {
  const AnnotationDialog({
    super.key,
    required this.open,
    required this.child,
    this.onClose,
    this.width = 480,
    this.padding = const EdgeInsets.all(24),
    this.radius = DifyRadius.xxl,
    this.label,
    this.top,
  });

  final bool open;
  final Widget child;
  final VoidCallback? onClose;
  final double width;
  final EdgeInsets padding;
  final double radius;
  final String? label;
  final double? top;

  @override
  Widget build(BuildContext context) => ControlledOverlay(
    open: open,
    onClose: onClose,
    builder: (context) => DifyDialogSurface(
      label: label,
      width: width,
      padding: padding,
      radius: radius,
      top: top,
      namesRoute: true,
      scrollable: true,
      child: child,
    ),
  );
}

/// The annotation drawers (dify-ui's Drawer, `swipeDirection="right"`, `disablePointerDismissal`) as the Annotations
/// page places them: `top-16 right-2 bottom-3 w-120` (or [width]) `rounded-xl`, the panel border and `shadow-xl`, on
/// the backdrop; the header row (`border-b py-4`: [title] and the `size-6` close button), the scrolling body and
/// the [footer].
class AnnotationDrawer extends StatelessWidget {
  const AnnotationDrawer({
    super.key,
    required this.title,
    required this.body,
    required this.onClose,
    this.footer,
    this.width = 480,
    this.label,
  });

  final Widget title;
  final Widget body;
  final Widget? footer;
  final VoidCallback onClose;
  final double width;

  /// The drawer's accessible name.
  final String? label;

  @override
  Widget build(BuildContext context) => ControlledOverlay(
    open: true,
    dismissible: false,
    onClose: onClose,
    builder: (context) => LayoutBuilder(
      builder: (context, c) => Stack(
        children: [
          Positioned(
            top: 64,
            right: 8,
            bottom: 12,
            width: width.clamp(0, c.maxWidth - 16).toDouble(),
            child: DifyDrawerPopup(
              key: const ValueKey('annotation-drawer'),
              label: label,
              scopesRoute: true,
              border: Border.all(color: DifyColors.dividerSubtle, width: Css.hairline),
              borderRadius: BorderRadius.circular(DifyRadius.xl),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    decoration: BoxDecoration(
                      border: Border(bottom: BorderSide(color: DifyColors.dividerSubtle)),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.only(left: 24, right: 20),
                      child: SizedBox(
                        height: 24,
                        child: Row(
                          children: [
                            Expanded(child: title),
                            DifyIconButton(
                              label: _c('operation.close'),
                              size: DifyIconButtonSize.md,
                              icon: const RemixIcon('close-line', size: 16),
                              onPressed: onClose,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Expanded(child: SingleChildScrollView(child: body)),
                  ?footer,
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

/// The drawers' footer bar: `flex h-16 items-center justify-between rounded-b-xl border-t border-divider-subtle
/// bg-background-section-burn px-4 system-sm-medium text-text-tertiary`.
class AnnotationDrawerFooter extends StatelessWidget {
  const AnnotationDrawerFooter({super.key, required this.leading, this.trailing});

  final Widget leading;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Container(
    height: 64,
    padding: const EdgeInsets.symmetric(horizontal: 16),
    decoration: BoxDecoration(
      color: DifyColors.backgroundSectionBurn,
      border: Border(top: BorderSide(color: DifyColors.dividerSubtle)),
    ),
    child: DefaultTextStyle.merge(
      style: difyTextStyle(DifyType.systemSmMedium, DifyColors.textTertiary),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        spacing: 8,
        children: [
          // Long translations shrink rather than overflow (the drawer is at most 480 px wide).
          Flexible(
            child: FittedBox(fit: BoxFit.scaleDown, alignment: AlignmentDirectional.centerStart, child: leading),
          ),
          if (trailing case final t?)
            Flexible(
              child: FittedBox(fit: BoxFit.scaleDown, alignment: AlignmentDirectional.centerEnd, child: t),
            ),
        ],
      ),
    ),
  );
}
