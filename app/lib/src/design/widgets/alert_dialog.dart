/// dify-ui's AlertDialog (packages/dify-ui/src/alert-dialog): [DifyAlertDialogContent] (the popup),
/// [DifyAlertDialogActions] (the button row), the usual title / description / Cancel / Confirm composition
/// ([DifyAlertDialog]) and [showDifyAlertDialog], its modal route.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../css_metrics.dart';
import '../dify_tokens.g.dart';
import '../../i18n/dify_i18n.dart';
import 'widgets.dart';

/// AlertDialogContent: centred, [width] wide (`w-120`; at most the viewport less 2 rem) and at most the viewport less
/// 2 rem high (scrolling), `rounded-2xl border-[0.5px] border-components-panel-border bg-components-panel-bg
/// shadow-lg`; named [label] for assistive technology. The className overrides sites use: [bordered] false
/// (`border-none`), [shadow] (`shadow-xl`), [padding].
class DifyAlertDialogContent extends StatelessWidget {
  const DifyAlertDialogContent({
    super.key,
    required this.child,
    this.label,
    this.width = 480,
    this.bordered = true,
    this.shadow,
    this.padding = EdgeInsets.zero,
    this.surfaceKey,
  });

  final Widget child;
  final String? label;
  final double width;
  final bool bordered;

  /// `shadow-lg` by default.
  final List<BoxShadow>? shadow;
  final EdgeInsetsGeometry padding;

  /// A key on the popup box (tests find the dialog by it).
  final Key? surfaceKey;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: width, maxHeight: MediaQuery.sizeOf(context).height - 32),
        child: Material(
          type: MaterialType.transparency,
          child: Semantics(
            container: true,
            role: SemanticsRole.alertDialog,
            scopesRoute: true,
            namesRoute: true,
            explicitChildNodes: true,
            label: label,
            child: Container(
              key: surfaceKey,
              width: width,
              clipBehavior: Clip.antiAlias,
              padding: padding,
              decoration: BoxDecoration(
                color: DifyColors.componentsPanelBg,
                borderRadius: BorderRadius.circular(DifyRadius.xxl),
                border: bordered ? Border.all(color: DifyColors.componentsPanelBorder, width: Css.hairline) : null,
                boxShadow: shadow ?? DifyShadows.lg,
              ),
              child: SingleChildScrollView(child: child),
            ),
          ),
        ),
      ),
    ),
  );
}

/// AlertDialogActions: `flex items-start justify-end gap-2 self-stretch p-6`; long translations wrap to a new row
/// rather than overflow.
class DifyAlertDialogActions extends StatelessWidget {
  const DifyAlertDialogActions({super.key, required this.children, this.padding = const EdgeInsets.all(24)});

  final List<Widget> children;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => Padding(
    padding: padding,
    child: Wrap(alignment: WrapAlignment.end, spacing: 8, runSpacing: 8, children: children),
  );
}

/// The usual AlertDialog: [DifyAlertDialogContent] holding `flex flex-col gap-2 px-6 pt-6 pb-4` with the title
/// (`title-2xl-semi-bold text-text-primary`, truncated unless [titleMaxLines] is null), the [description]
/// (`system-md-regular text-text-tertiary`, wrapping; left out when empty) and [extra] below it, then
/// [DifyAlertDialogActions] with AlertDialogCancelButton (secondary) and AlertDialogConfirmButton (primary,
/// destructive by default). Cancel calls [onCancel], Confirm [onConfirm].
class DifyAlertDialog extends StatelessWidget {
  const DifyAlertDialog({
    super.key,
    required this.title,
    this.description,
    this.descriptionColor,
    this.titleMaxLines = 1,
    this.extra,
    required this.onCancel,
    required this.onConfirm,
    this.cancelLabel,
    this.confirmLabel,
    this.confirmTone = DifyButtonTone.destructive,
    this.confirmLoading = false,
    this.confirmDisabled = false,
    this.cancelDisabled = false,
    this.cancelKey,
    this.confirmKey,
    this.surfaceKey,
    this.semanticButtonLabels = false,
    this.label,
    this.bordered = true,
    this.shadow,
  });

  final String title;
  final String? description;

  /// `text-text-tertiary` by default.
  final Color? descriptionColor;
  final int? titleMaxLines;

  /// Below the description, inside the text column (an input, a list).
  final Widget? extra;
  final VoidCallback? onCancel, onConfirm;

  /// "Cancel" / "Confirm" by default.
  final String? cancelLabel, confirmLabel;
  final DifyButtonTone confirmTone;
  final bool confirmLoading, confirmDisabled, cancelDisabled;
  final Key? cancelKey, confirmKey, surfaceKey;

  /// Names the buttons by their labels for assistive technology.
  final bool semanticButtonLabels;

  /// The dialog's accessible name ([title] by default).
  final String? label;
  final bool bordered;
  final List<BoxShadow>? shadow;

  @override
  Widget build(BuildContext context) {
    final cancel = cancelLabel ?? DifyI18n.tr('common', 'operation.cancel');
    final confirm = confirmLabel ?? DifyI18n.tr('common', 'operation.confirm');
    final desc = description;
    return DifyAlertDialogContent(
      label: label ?? title,
      surfaceKey: surfaceKey,
      bordered: bordered,
      shadow: shadow,
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
                  title,
                  maxLines: titleMaxLines,
                  overflow: titleMaxLines == null ? null : TextOverflow.ellipsis,
                  style: difyTextStyle(DifyType.title2xlSemiBold, DifyColors.textPrimary),
                ),
                if (desc != null && desc.isNotEmpty)
                  Text(
                    desc,
                    style: difyTextStyle(DifyType.systemMdRegular, descriptionColor ?? DifyColors.textTertiary),
                  ),
                ?extra,
              ],
            ),
          ),
          DifyAlertDialogActions(
            children: [
              DifyButton(
                key: cancelKey,
                disabled: cancelDisabled,
                semanticLabel: semanticButtonLabels ? cancel : null,
                onPressed: onCancel,
                child: Text(cancel),
              ),
              DifyButton(
                key: confirmKey,
                variant: DifyButtonVariant.primary,
                tone: confirmTone,
                disabled: confirmDisabled,
                loading: confirmLoading,
                semanticLabel: semanticButtonLabels ? confirm : null,
                onPressed: onConfirm,
                child: Text(confirm),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Opens [builder]'s alert dialog (usually a [DifyAlertDialog]) as a modal route ([showDifyDialog]); Escape closes
/// it. dify-ui's AlertDialog stays open on an outside click: [dismissible] true is for the sites that close there.
Future<T?> showDifyAlertDialog<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool dismissible = false,
  bool closeOnEscape = true,
}) => showDifyDialog<T>(context, builder: builder, dismissible: dismissible, closeOnEscape: closeOnEscape);

/// The common case: [title], [description], Cancel and Confirm; true when confirmed. With [onConfirm], Confirm runs
/// it showing its loading state (and Cancel disabled with [lockCancelWhileBusy]); the dialog closes (true) when it
/// completes and stays open when it throws (the caller reported the error).
Future<bool> showDifyConfirm(
  BuildContext context, {
  required String title,
  String? description,
  Future<void> Function()? onConfirm,
  String? confirmLabel,
  String? cancelLabel,
  DifyButtonTone confirmTone = DifyButtonTone.destructive,
  bool lockCancelWhileBusy = false,
  bool dismissible = false,
  Key? surfaceKey,
  Key? cancelKey,
  Key? confirmKey,
  bool semanticButtonLabels = false,
}) async {
  final ok = await showDifyAlertDialog<bool>(
    context,
    dismissible: dismissible,
    builder: (context) => _BusyAlertDialog(
      title: title,
      description: description,
      onConfirm: onConfirm,
      confirmLabel: confirmLabel,
      cancelLabel: cancelLabel,
      confirmTone: confirmTone,
      lockCancelWhileBusy: lockCancelWhileBusy,
      surfaceKey: surfaceKey,
      cancelKey: cancelKey,
      confirmKey: confirmKey,
      semanticButtonLabels: semanticButtonLabels,
    ),
  );
  return ok ?? false;
}

class _BusyAlertDialog extends StatefulWidget {
  const _BusyAlertDialog({
    required this.title,
    this.description,
    this.onConfirm,
    this.confirmLabel,
    this.cancelLabel,
    required this.confirmTone,
    required this.lockCancelWhileBusy,
    this.surfaceKey,
    this.cancelKey,
    this.confirmKey,
    required this.semanticButtonLabels,
  });

  final String title;
  final String? description, confirmLabel, cancelLabel;
  final Future<void> Function()? onConfirm;
  final DifyButtonTone confirmTone;
  final bool lockCancelWhileBusy, semanticButtonLabels;
  final Key? surfaceKey, cancelKey, confirmKey;

  @override
  State<_BusyAlertDialog> createState() => _BusyAlertDialogState();
}

class _BusyAlertDialogState extends State<_BusyAlertDialog> {
  bool _busy = false;

  Future<void> _confirm() async {
    final run = widget.onConfirm;
    if (run == null) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() => _busy = true);
    try {
      await run();
      if (mounted) Navigator.of(context).pop(true);
    } on Object {
      // The caller reported it (Dify's request layer toasts the server's message).
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => DifyAlertDialog(
    title: widget.title,
    description: widget.description,
    confirmLabel: widget.confirmLabel,
    cancelLabel: widget.cancelLabel,
    confirmTone: widget.confirmTone,
    confirmDisabled: _busy,
    cancelDisabled: widget.lockCancelWhileBusy && _busy,
    surfaceKey: widget.surfaceKey,
    cancelKey: widget.cancelKey,
    confirmKey: widget.confirmKey,
    semanticButtonLabels: widget.semanticButtonLabels,
    onCancel: () => Navigator.of(context).pop(false),
    onConfirm: () => unawaited(_confirm()),
  );
}
