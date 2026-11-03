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
///
/// A phone (a compact window; the shared dialog's policy, see [showDifyDialog]): with [sheetOnCompact] (a form: the
/// annotation dialogs) the content is the dialog's sheet form in a [DifySheetPortal] (the portal keeps the page's
/// scopes, which the owners' content reads): [DifyDialogFrame] tells its parts, and the scrim and a drag down close it
/// only with [dismissible]. With [edgeToEdgeOnCompact] (the annotation drawers, pages on a phone as [showDifyDrawer]'s)
/// the content fills the window. Otherwise (a confirmation) the overlay stays centred. The form follows the live width.
///
/// At every width only the topmost overlay is read by assistive technology, as a modal route's ([DifyPortalSemantics]):
/// the page under it is hidden, and so is an overlay under a confirmation opened from it. (An overlay child's semantics
/// hang from its portal's place; a non-modal portal's empty place would drop the overlay from the platform's tree.)
///
/// Back (Android) calls [onBack] (by default [onClose]) while open, the newest overlay first, before the page under
/// it. [onBack] is for a dialog Dify does not close on Escape or a click outside, whose phone sheet Back still closes.
class ControlledOverlay extends StatefulWidget {
  const ControlledOverlay({
    super.key,
    required this.open,
    required this.builder,
    this.onClose,
    this.onBack,
    this.dismissible = true,
    this.backdrop = true,
    this.sheetOnCompact = false,
    this.edgeToEdgeOnCompact = false,
  });

  final bool open;
  final WidgetBuilder builder;
  final VoidCallback? onClose, onBack;
  final bool dismissible, backdrop, sheetOnCompact;

  /// On a phone the content fills the window, under the system bars (a drawer shown as a page keeps its content safe
  /// itself); elsewhere it stays inside the safe area.
  final bool edgeToEdgeOnCompact;

  @override
  State<ControlledOverlay> createState() => _ControlledOverlayState();
}

class _ControlledOverlayState extends State<ControlledOverlay> with SingleTickerProviderStateMixin {
  final _portal = OverlayPortalController();

  /// The content, and the part of it that is the same in both forms ([ControlledOverlay.bodyKeyOf]): one overlay shows
  /// either form, so a rotation moves them, with their state (a focused field, what was typed), to the other.
  final _content = GlobalKey(debugLabel: 'controlled overlay content');
  final _body = GlobalKey(debugLabel: 'controlled overlay body');

  /// The phone sheet's slide.
  late final _slide = AnimationController(vsync: this, duration: DifySheetRecipe.openDuration);
  late final _curved = CurvedAnimation(parent: _slide, curve: Curves.easeOutCubic);

  bool _phone = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The phone's forms are a question of width (a touch tablet keeps Dify's).
    _phone = DifyWindowClass.of(context) == DifyWindowClass.compact;
    _sync();
  }

  @override
  void didUpdateWidget(ControlledOverlay old) {
    super.didUpdateWidget(old);
    _sync();
  }

  @override
  void dispose() {
    _curved.dispose();
    _slide.dispose();
    super.dispose();
  }

  bool get _asSheet => widget.sheetOnCompact && _phone;

  /// Shows or hides the portal after this frame (the controller may not change while building).
  void _sync() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!mounted) return;
    final open = widget.open;
    if (open && !_portal.isShowing) {
      _portal.show();
      final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
      reduce ? _slide.value = 1 : _slide.forward(from: 0);
      setState(() {});
    } else if (!open && _portal.isShowing) {
      _portal.hide();
      setState(() {});
    }
  });

  @override
  Widget build(BuildContext context) {
    // Modal at every width: a wider window's drawer or dialog is as modal as Dify's (`aria-modal`), and the place a
    // non-modal portal gives its overlay is empty, which drops the overlay from the platform's tree.
    final modal = widget.open && _portal.isShowing;
    final back = widget.onBack ?? widget.onClose;
    return DifyBackDismiss(
      // Android back closes the newest open overlay before the page (these overlays are not routes).
      enabled: widget.open && back != null,
      onDismiss: () => back?.call(),
      child: DifyPortalSemantics(
        modal: modal,
        child: OverlayPortal(
          controller: _portal,
          overlayChildBuilder: (context) => _ControlledOverlayKeys(
            body: _body,
            child: _asSheet ? _sheet(context) : _centred(context),
          ),
          child: DifyPortalSemantics.place(modal: modal, child: const SizedBox.shrink()),
        ),
      ),
    );
  }

  Widget get _builder => KeyedSubtree(
    key: _content,
    child: Builder(builder: widget.builder),
  );

  /// A phone's form: the dialog's sheet form ([DifyDialogFrame]) on the shared portal sheet; the scrim and a drag down
  /// close it only when [ControlledOverlay.dismissible], Back and Escape always.
  Widget _sheet(BuildContext context) {
    // A rotation into this form shows the sheet where it is (no slide).
    if (!_slide.isAnimating && _slide.value == 0) _slide.value = 1;
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): () => widget.onClose?.call()},
      child: FocusScope(
        autofocus: true,
        child: DifyPortalSheetFrame(
          animation: _curved,
          isOpen: () => mounted && widget.open,
          onDismiss: widget.dismissible ? () => widget.onClose?.call() : null,
          child: DifyDialogFrame(
            form: DifyDialogForm.sheet,
            child: DifyModalLayer(child: _builder),
          ),
        ),
      ),
    );
  }

  // Inside the window's safe area, as when the app kept the whole navigator inside it (a phone's page form: the whole
  // window). A layer opened over the content (a confirmation) hides it from assistive technology.
  Widget _centred(BuildContext context) => _safe(
    context,
    Stack(
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
            child: DifySurface(child: DifyModalLayer(child: _builder)),
          ),
        ),
      ],
    ),
  );

  /// [DifyOverlaySafeArea], or the whole window on a phone with [ControlledOverlay.edgeToEdgeOnCompact]. One tree for
  /// both, so a rotation keeps the content's state.
  Widget _safe(BuildContext context, Widget child) {
    final edge = widget.edgeToEdgeOnCompact && _phone;
    return Padding(
      padding: edge ? EdgeInsets.zero : DifyWindowInsets.of(context),
      child: MediaQuery.removePadding(
        context: context,
        removeLeft: !edge,
        removeTop: !edge,
        removeRight: !edge,
        removeBottom: !edge,
        child: child,
      ),
    );
  }
}

/// The key of the part of a [ControlledOverlay]'s content that both forms show ([ControlledOverlay.bodyKeyOf]).
class _ControlledOverlayKeys extends InheritedWidget {
  const _ControlledOverlayKeys({required this.body, required super.child});

  final GlobalKey body;

  @override
  bool updateShouldNotify(_ControlledOverlayKeys oldWidget) => body != oldWidget.body;
}

/// [child] under the key its [ControlledOverlay] gives the content both of its forms show (a drawer's body, a dialog's
/// fields), so a rotation keeps its state.
Widget _keepAcrossForms(BuildContext context, Widget child) {
  final key = context.dependOnInheritedWidgetOfExactType<_ControlledOverlayKeys>()?.body;
  return key == null ? child : KeyedSubtree(key: key, child: child);
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
    this.onBack,
    this.width = 480,
    this.padding = const EdgeInsets.all(24),
    this.radius = DifyRadius.xxl,
    this.label,
    this.top,
  });

  final bool open;
  final Widget child;
  final VoidCallback? onClose;

  /// [ControlledOverlay.onBack].
  final VoidCallback? onBack;
  final double width;
  final EdgeInsets padding;
  final double radius;
  final String? label;
  final double? top;

  @override
  Widget build(BuildContext context) => ControlledOverlay(
    open: open,
    onClose: onClose,
    onBack: onBack,
    sheetOnCompact: true,
    builder: (context) => DifyDialogSurface(
      label: label,
      width: width,
      padding: padding,
      radius: radius,
      top: top,
      namesRoute: true,
      scrollable: true,
      child: _keepAcrossForms(context, child),
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
    edgeToEdgeOnCompact: true,
    onClose: onClose,
    builder: (context) => LayoutBuilder(
      builder: (context, c) {
        final phone = DifyWindowClass.of(context) == DifyWindowClass.compact;
        // The page form on a phone, and the inset drawer on a touch tablet, are touch-sized.
        final touch = phone || DifyTouch.compactOf(context);
        final popup = DifyDrawerPopup(
          key: const ValueKey('annotation-drawer'),
          label: label,
          scopesRoute: true,
          border: Border.all(color: DifyColors.dividerSubtle, width: Css.hairline),
          borderRadius: BorderRadius.circular(DifyRadius.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: EdgeInsets.symmetric(vertical: touch ? 6 : 16),
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: DifyColors.dividerSubtle)),
                ),
                child: Padding(
                  padding: const EdgeInsets.only(left: 24, right: 20),
                  child: SizedBox(
                    // A touch close button (44 px).
                    height: touch ? DifyTouch.controlHeight : 24,
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
              Expanded(child: SingleChildScrollView(child: _keepAcrossForms(context, body))),
              ?footer,
            ],
          ),
        );
        // A phone shows the drawer as a page (showDifyDrawer's compact form). One tree for both forms, so a rotation
        // keeps the fields' state and focus.
        return Stack(
          children: [
            Positioned(
              top: phone ? 0 : 64,
              left: phone ? 0 : null,
              right: phone ? 0 : 8,
              bottom: phone ? 0 : 12,
              width: phone ? null : width.clamp(0, c.maxWidth - 16).toDouble(),
              child: DifyDrawerPage(
                page: phone,
                child: DifyTouchSurface(enabled: touch, child: popup),
              ),
            ),
          ],
        );
      },
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
  Widget build(BuildContext context) {
    final decoration = BoxDecoration(
      color: DifyColors.backgroundSectionBurn,
      border: Border(top: BorderSide(color: DifyColors.dividerSubtle)),
    );
    final style = difyTextStyle(DifyType.systemSmMedium, DifyColors.textTertiary);
    // A phone's page (a touch surface): the parts share a row when they fit, else the trailing one goes to a second row
    // (the bar grows), so they keep their size and the touch targets stay 44 px; a part wider than the whole bar (a
    // very long translation) still shrinks.
    if (DifyTouchArea.appliesIn(context)) {
      return Container(
        constraints: const BoxConstraints(minHeight: 64),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        alignment: AlignmentDirectional.centerStart,
        decoration: decoration,
        child: DefaultTextStyle.merge(
          style: style,
          child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final part in [leading, ?trailing])
                FittedBox(fit: BoxFit.scaleDown, alignment: AlignmentDirectional.centerStart, child: part),
            ],
          ),
        ),
      );
    }
    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: decoration,
      child: DefaultTextStyle.merge(
        style: style,
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
}
