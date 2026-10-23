/// Pieces the settings share: translation lookups, dify-ui's Dialog / AlertDialog as the members page uses them,
/// and the radio control.
library;

import 'package:flutter/widgets.dart';

import '../design/dify_icon.dart';
import '../design/widgets/widgets.dart';
import '../i18n/app_locale.dart';
import '../i18n/dify_i18n.dart';

/// `t(key, { ns, ...params })`, rebuilding the caller when the language changes.
String st(BuildContext context, String ns, String key, [Map<String, Object?> params = const {}]) {
  AppLocaleScope.of(context);
  return DifyI18n.tr(ns, key, params);
}

/// `t(key, { ns: 'common', ...params })`.
String stc(BuildContext context, String key, [Map<String, Object?> params = const {}]) =>
    st(context, 'common', key, params);

/// Shows a dify-ui Dialog (the `bg-background-overlay` backdrop, Escape and backdrop clicks close it) built by
/// [builder]; resolves with what it pops.
Future<T?> showSettingsDialog<T>(BuildContext context, WidgetBuilder builder) =>
    showDifyDialog<T>(context, builder: builder);

/// DialogContent as dify-ui 1.17 draws it: `w-120 rounded-2xl border-[0.5px] border-components-panel-border
/// bg-components-panel-bg shadow-xl`, [padding] `p-6` by default; [label] names the dialog.
class SettingsDialogContent extends StatelessWidget {
  const SettingsDialogContent({
    super.key,
    required this.child,
    this.label,
    this.width = 480,
    this.height,
    this.padding = const EdgeInsets.all(24),
    this.scrollable = true,
  });

  final Widget child;
  final String? label;
  final double width;
  final double? height;
  final EdgeInsetsGeometry padding;
  final bool scrollable;

  @override
  Widget build(BuildContext context) => DifyDialogSurface(
    label: label,
    width: width,
    height: height,
    padding: padding,
    bordered: true,
    scrollable: scrollable,
    child: child,
  );
}

/// DialogClose rendering `IconButton size="lg"` with `i-ri-close-line size-4` and the accessible name "Close".
class SettingsDialogCloseButton extends StatelessWidget {
  const SettingsDialogCloseButton({super.key, this.onPressed});

  /// Defaults to popping the dialog.
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => DifyIconButton(
    key: const ValueKey('dialog-close'),
    label: stc(context, 'operation.close'),
    size: DifyIconButtonSize.lg,
    icon: const RemixIcon('close-line', size: 16),
    onPressed: onPressed ?? () => Navigator.of(context).maybePop(),
  );
}

/// dify-ui's AlertDialog with a title, a description and Cancel / Confirm (destructive primary) as the members page
/// uses it ([showDifyConfirm]; a click outside closes it too). [onConfirm] runs with Confirm disabled (and Cancel too
/// with [lockCancelWhileBusy]); the dialog closes when it completes (true) and stays open when it throws. An empty
/// [description] is left out; [confirmLabel] defaults to "Confirm".
Future<bool> showSettingsAlert(
  BuildContext context, {
  required String title,
  String description = '',
  required Future<void> Function() onConfirm,
  String? confirmLabel,
  bool lockCancelWhileBusy = false,
}) => showDifyConfirm(
  context,
  title: title,
  description: description,
  onConfirm: onConfirm,
  confirmLabel: confirmLabel,
  lockCancelWhileBusy: lockCancelWhileBusy,
  dismissible: true,
  surfaceKey: const ValueKey('alert-dialog'),
  cancelKey: const ValueKey('alert-cancel'),
  confirmKey: const ValueKey('alert-confirm'),
);
