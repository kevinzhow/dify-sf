/// dify-ui's Dialog for the node panels: a modal route over the `bg-background-overlay` backdrop, scaling from 0.95
/// and fading in (150 ms), with the `rounded-2xl bg-components-panel-bg shadow-xl` content box ([DifyDialogSurface]).
///
/// On a phone (a compact window, below 600 dp) the same dialog is a modal bottom sheet (a dify-sf divergence, as
/// raft-flutter's `RaftPresentationPolicy.form`): [DifyDialogFrame] tells the dialog's parts which form they are in,
/// and [DifyDialogSurface], [DifyDialogTitle] and [DifyAlertDialogActions] draw the sheet's surface, its header and
/// its pinned action row there. Confirmations ([showDifyAlertDialog]) stay centred at every width, as raft's
/// `RaftPresentationPolicy.confirm`.
library;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../css_metrics.dart';
import '../dify_tokens.g.dart';
import 'widgets.dart';

/// How a [showDifyDialog] route comes in and goes out.
enum DifyDialogTransition {
  /// dify-ui's `modalPopupAnimationClassName`: scale from 0.95 and fade ([difyTransitionCurve]).
  scaleFade,

  /// A fade on [difyTransitionCurve] (MenuDialog, the create-app shell).
  fade,

  /// A linear fade (Flutter's `showGeneralDialog` default).
  linearFade,

  /// No animation of the popup (the backdrop still fades in).
  none,
}

/// Material's `showDialog` barrier (`Colors.black54`), for the dev shell's dialogs (not Dify screens).
const materialDialogBarrierColor = Color(0x8A000000);

/// Which form a [showDifyDialog] dialog takes.
enum DifyDialogForm {
  /// Centred over the backdrop (Dify's dialog; every window from 600 dp, and confirmations everywhere).
  dialog,

  /// A modal bottom sheet (a compact window): the sheet's header, a scrolling body, the actions pinned at its bottom.
  sheet,
}

/// The form of the dialog around its parts (raft-flutter's `RaftFormFrame`): [showDifyDialog] provides it, and the
/// parts ([DifyDialogSurface], [DifyDialogTitle], [DifyAlertDialogActions], [DifyAlertDialogContent]) draw
/// themselves for it. Outside a frame (a test that builds a surface alone) they draw Dify's dialog.
class DifyDialogFrame extends InheritedWidget {
  const DifyDialogFrame({super.key, required this.form, required super.child});

  final DifyDialogForm form;

  /// The form of the enclosing dialog, or null outside one.
  static DifyDialogForm? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DifyDialogFrame>()?.form;

  /// Whether the enclosing dialog is a bottom sheet.
  static bool sheetOf(BuildContext context) => maybeOf(context) == DifyDialogForm.sheet;

  @override
  bool updateShouldNotify(DifyDialogFrame oldWidget) => form != oldWidget.form;
}

/// Shows [builder]'s dialog (usually a [DifyDialogSurface]); resolves with what it pops. Escape closes it (unless
/// [closeOnEscape] is false: the dialog handles Escape itself), and so does a backdrop click unless [dismissible] is
/// false (Dify's `disablePointerDismissal`). [barrierColor] defaults to dify-ui's `modalBackdropClassName`
/// (`bg-background-overlay`); [transition] and [transitionDuration] (150 ms) default to its popup animation.
///
/// In a compact window (below 600 dp) and with [sheetOnCompact] (the default; confirmations pass false and stay
/// centred) it is a modal bottom sheet instead ([showDifyBottomSheet], a route like the dialog's, so its content sees
/// what a dialog's sees): as tall as its content up to the window below the status bar, rising with the keyboard, its
/// content clear of the gesture bar. Its parts draw the sheet's form ([DifyDialogFrame]): the title row is the sheet's
/// header with a 44 px close, the actions a row of 44 px buttons pinned at the bottom. Back and Escape close it first
/// (before any sheet or layer under it); the scrim and a drag down close it unless [dismissible] is false. Only the
/// topmost layer is read by assistive technology: the page under the route, and the dialog's own content while a
/// picker sheet covers it ([DifyModalLayer]).
///
/// Such a dialog follows the live width (raft-flutter's `RaftPresentedRoute`): rotating a phone or resizing the window
/// across 600 dp while it is open re-presents it in place, a sheet when compact and the centred dialog when not, and
/// [builder]'s content keeps its state (it is built under one key in both forms).
Future<T?> showDifyDialog<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool dismissible = true,
  bool closeOnEscape = true,
  Color? barrierColor,
  String? barrierLabel,
  DifyDialogTransition transition = DifyDialogTransition.scaleFade,
  Duration transitionDuration = difyTransitionDuration,
  bool useRootNavigator = true,
  bool sheetOnCompact = true,
}) {
  if (!sheetOnCompact) {
    return _showCentred<T>(
      context,
      builder: builder,
      dismissible: dismissible,
      closeOnEscape: closeOnEscape,
      barrierColor: barrierColor,
      barrierLabel: barrierLabel,
      transition: transition,
      transitionDuration: transitionDuration,
      useRootNavigator: useRootNavigator,
    );
  }
  // The content, under one key in either form, so a switch moves it with its state.
  final content = GlobalKey(debugLabel: 'dify dialog content');
  Widget body(BuildContext context) => KeyedSubtree(key: content, child: Builder(builder: builder));
  return showDifyBottomSheet<T>(
    context,
    (context) => DifyDialogFrame(
      form: DifyDialogForm.sheet,
      // Layers opened from the dialog (a picker sheet) hide it from assistive technology, as the sheets' do.
      child: DifyModalLayer(
        child: FocusScope(autofocus: true, child: body(context)),
      ),
    ),
    dismissible: dismissible,
    backDismissible: true,
    closeOnEscape: closeOnEscape,
    barrierLabel: barrierLabel,
    useRootNavigator: useRootNavigator,
    wide: DifySheetWideForm(
      builder: (context) => _centredPage(context, closeOnEscape, body),
      barrierColor: barrierColor ?? DifyColors.backgroundOverlay,
      transitionsBuilder: (context, animation, _, child) => _transition(transition, animation, child),
      transitionDuration: transitionDuration,
    ),
  );
}

Widget _transition(DifyDialogTransition transition, Animation<double> animation, Widget child) => switch (transition) {
  DifyDialogTransition.scaleFade => () {
    final a = CurvedAnimation(parent: animation, curve: difyTransitionCurve);
    return FadeTransition(
      opacity: a,
      child: ScaleTransition(scale: Tween(begin: 0.95, end: 1.0).animate(a), child: child),
    );
  }(),
  DifyDialogTransition.fade => FadeTransition(
    opacity: CurvedAnimation(parent: animation, curve: difyTransitionCurve),
    child: child,
  ),
  DifyDialogTransition.linearFade => FadeTransition(opacity: animation, child: child),
  DifyDialogTransition.none => child,
};

/// The centred dialog's page: the backdrop covers the whole window; the dialog stays inside the safe area
/// (DifyApplication no longer consumes the system insets for the navigator).
Widget _centredPage(BuildContext context, bool closeOnEscape, WidgetBuilder builder) {
  final scope = FocusScope(
    autofocus: true,
    child: DifySelectionRegion(
      child: DifyDialogFrame(form: DifyDialogForm.dialog, child: builder(context)),
    ),
  );
  return SafeArea(
    child: !closeOnEscape
        ? scope
        : Shortcuts(
            shortcuts: const {SingleActivator(LogicalKeyboardKey.escape): DismissIntent()},
            child: Actions(
              actions: {
                DismissIntent: CallbackAction<DismissIntent>(
                  onInvoke: (_) {
                    Navigator.of(context).pop();
                    return null;
                  },
                ),
              },
              child: scope,
            ),
          ),
  );
}

Future<T?> _showCentred<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  required bool dismissible,
  required bool closeOnEscape,
  required Color? barrierColor,
  required String? barrierLabel,
  required DifyDialogTransition transition,
  required Duration transitionDuration,
  required bool useRootNavigator,
}) => showGeneralDialog<T>(
  context: context,
  barrierDismissible: dismissible,
  barrierLabel: barrierLabel ?? MaterialLocalizations.of(context).modalBarrierDismissLabel,
  barrierColor: barrierColor ?? DifyColors.backgroundOverlay,
  transitionDuration: transitionDuration,
  useRootNavigator: useRootNavigator,
  transitionBuilder: (context, animation, _, child) => _transition(transition, animation, child),
  pageBuilder: (context, _, _) => _centredPage(context, closeOnEscape, builder),
);

/// DialogContent: centred (or [top] below the viewport's top: `mt-*`), [width] wide (at most the viewport less 2 rem),
/// `rounded-2xl` ([radius]) `bg-components-panel-bg shadow-xl` with [padding]; [height] fixes the height, else it hugs
/// the content up to [maxHeight] (80 % of the viewport below [top] by default), scrolling when [scrollable]. Named
/// [label] (the dialog's title) for assistive technology; [namesRoute] also makes it the route's scope and name.
/// [bordered] adds dify-ui 1.17's `border-[0.5px] border-components-panel-border`.
///
/// In a sheet ([DifyDialogFrame]) the sheet is the surface: no box, no centring, no [width], [top] or [maxHeight]; the
/// content keeps its [padding] and [scrollable], takes the sheet's width and at most its height (a [Flexible] body
/// between the title and the actions scrolls while they stay), and [height] is its height when the window has it.
class DifyDialogSurface extends StatelessWidget {
  const DifyDialogSurface({
    super.key,
    required this.child,
    this.label,
    this.width = 480,
    this.height,
    this.maxHeight,
    this.padding = EdgeInsets.zero,
    this.scrollable = false,
    this.bordered = false,
    this.radius = DifyRadius.xxl,
    this.top,
    this.namesRoute = false,
  });

  final Widget child;
  final String? label;
  final double width;
  final double? height, maxHeight;
  final EdgeInsetsGeometry padding;
  final bool scrollable;
  final bool bordered;
  final double radius;
  final double? top;
  final bool namesRoute;

  @override
  Widget build(BuildContext context) {
    if (DifyDialogFrame.sheetOf(context)) return _sheet();
    final screen = MediaQuery.sizeOf(context);
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final available = (screen.height - keyboard - (top ?? 0) - 32).clamp(0.0, double.infinity);
    final box = ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: width,
        maxHeight: (height ?? maxHeight ?? (screen.height - (top ?? 0)) * 0.8).clamp(0.0, available),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Semantics(
          container: true,
          role: SemanticsRole.dialog,
          scopesRoute: namesRoute ? true : null,
          namesRoute: namesRoute ? true : null,
          explicitChildNodes: true,
          label: label,
          child: Container(
            width: width,
            height: height,
            clipBehavior: Clip.antiAlias,
            padding: padding,
            decoration: BoxDecoration(
              color: DifyColors.componentsPanelBg,
              borderRadius: BorderRadius.circular(radius),
              border: bordered ? Border.all(color: DifyColors.componentsPanelBorder, width: Css.hairline) : null,
              boxShadow: DifyShadows.xl,
            ),
            child: scrollable ? SingleChildScrollView(child: child) : child,
          ),
        ),
      ),
    );
    if (top case final t?) {
      return Align(
        alignment: Alignment.topCenter,
        child: Padding(padding: EdgeInsets.fromLTRB(16, t, 16, keyboard), child: box),
      );
    }
    return Center(
      child: Padding(padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + keyboard), child: box),
    );
  }

  Widget _sheet() {
    Widget content = Padding(padding: padding, child: scrollable ? SingleChildScrollView(child: child) : child);
    if (height case final h?) content = SizedBox(height: h, child: content);
    return Material(
      type: MaterialType.transparency,
      child: Semantics(
        container: true,
        role: SemanticsRole.dialog,
        scopesRoute: namesRoute ? true : null,
        namesRoute: namesRoute ? true : null,
        explicitChildNodes: true,
        label: label,
        child: content,
      ),
    );
  }
}

/// dify-ui's DialogTitle with its close button: the dialog's title row. In a dialog it is [child], the dialog's own
/// row as Dify draws it. In a sheet ([DifyDialogFrame]) it is the sheet's header ([DifySheetHeader]): [title] (one
/// line), [description] under it, and a 44 px close that calls [onClose] (by default it asks the route to close, as
/// Back does); no close when [closable] is false. Put it first in the dialog's column, above a [Flexible] body, so it
/// stays while the body scrolls.
class DifyDialogTitle extends StatelessWidget {
  const DifyDialogTitle({
    super.key,
    required this.title,
    this.description,
    this.onClose,
    this.closable = true,
    required this.child,
  });

  final String title;
  final String? description;
  final VoidCallback? onClose;
  final bool closable;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!DifyDialogFrame.sheetOf(context)) return child;
    return Padding(
      // The sheet's grab handle is above; a little air before the body.
      padding: const EdgeInsets.only(bottom: 4),
      child: DifySheetHeader(title: title, subtitle: description, onClose: onClose, showClose: closable),
    );
  }
}
