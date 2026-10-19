/// Pieces the settings share: translation lookups, dify-ui's Dialog / AlertDialog as the members page uses them,
/// base/workspace-avatar and the radio control.
library;

import 'dart:async';

import 'package:flutter/material.dart' show Material, MaterialType;
import 'package:flutter/widgets.dart';

import '../design/css_metrics.dart';
import '../design/dify_icon.dart';
import '../design/dify_tokens.g.dart';
import '../design/widgets/widgets.dart';
import '../i18n/app_locale.dart';
import '../i18n/dify_i18n.dart';
import '../workflow_editor/panel_fields/dialog.dart';

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

/// dify-ui's AlertDialog with a title, a description and Cancel / Confirm (destructive primary): `w-120 rounded-2xl
/// border-[0.5px] shadow-lg`; the text in `flex flex-col gap-2 px-6 pt-6 pb-4` (title `title-2xl-semi-bold`,
/// truncated; description `system-md-regular text-text-tertiary`, wrapping), actions `p-6 gap-2`. [onConfirm] runs
/// with Confirm disabled (and Cancel too with [lockCancelWhileBusy]); the dialog closes when it completes (true) and
/// stays open when it throws. An empty [description] is left out; [confirmLabel] defaults to "Confirm".
Future<bool> showSettingsAlert(
  BuildContext context, {
  required String title,
  String description = '',
  required Future<void> Function() onConfirm,
  String? confirmLabel,
  bool lockCancelWhileBusy = false,
}) async {
  final ok = await showGeneralDialog<bool>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Dismiss',
    barrierColor: DifyColors.backgroundOverlay,
    transitionDuration: difyTransitionDuration,
    transitionBuilder: (context, animation, _, child) {
      final a = CurvedAnimation(parent: animation, curve: difyTransitionCurve);
      return FadeTransition(
        opacity: a,
        child: ScaleTransition(scale: Tween(begin: 0.95, end: 1.0).animate(a), child: child),
      );
    },
    pageBuilder: (context, _, _) => _AlertDialog(
      title: title,
      description: description,
      onConfirm: onConfirm,
      confirmLabel: confirmLabel,
      lockCancelWhileBusy: lockCancelWhileBusy,
    ),
  );
  return ok ?? false;
}

class _AlertDialog extends StatefulWidget {
  const _AlertDialog({
    required this.title,
    required this.description,
    required this.onConfirm,
    this.confirmLabel,
    this.lockCancelWhileBusy = false,
  });
  final String title, description;
  final Future<void> Function() onConfirm;
  final String? confirmLabel;
  final bool lockCancelWhileBusy;

  @override
  State<_AlertDialog> createState() => _AlertDialogState();
}

class _AlertDialogState extends State<_AlertDialog> {
  bool _busy = false;

  Future<void> _confirm() async {
    setState(() => _busy = true);
    try {
      await widget.onConfirm();
      if (mounted) Navigator.of(context).pop(true);
    } on Object {
      // The caller reported it (Dify's request layer toasts the server's message).
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Material(
        type: MaterialType.transparency,
        child: Semantics(
          container: true,
          scopesRoute: true,
          namesRoute: true,
          explicitChildNodes: true,
          label: widget.title,
          child: Container(
            key: const ValueKey('alert-dialog'),
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
                        widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: difyTextStyle(DifyType.title2xlSemiBold, DifyColors.textPrimary),
                      ),
                      if (widget.description.isNotEmpty)
                        Text(
                          widget.description,
                          style: difyTextStyle(DifyType.systemMdRegular, DifyColors.textTertiary),
                        ),
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
                        key: const ValueKey('alert-cancel'),
                        disabled: widget.lockCancelWhileBusy && _busy,
                        onPressed: () => Navigator.of(context).pop(false),
                        child: Text(stc(context, 'operation.cancel')),
                      ),
                      DifyButton(
                        key: const ValueKey('alert-confirm'),
                        variant: DifyButtonVariant.primary,
                        tone: DifyButtonTone.destructive,
                        disabled: _busy,
                        onPressed: () => unawaited(_confirm()),
                        child: Text(widget.confirmLabel ?? stc(context, 'operation.confirm')),
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
  );
}

/// base/workspace-avatar sizes: the box, its radius and the initial's font size / line height.
enum WorkspaceAvatarSize {
  xs(20, DifyRadius.md, 10, 12),
  sm(24, DifyRadius.md, 13, 16),
  lg(36, DifyRadius.lg, 16, 20),
  xxl(48, DifyRadius.xl, 20, 28);

  const WorkspaceAvatarSize(this.box, this.radius, this.fontSize, this.lineHeight);
  final double box, radius, fontSize, lineHeight;
}

/// base/workspace-avatar: the workspace's upper-cased initial (`?` without a name) in white (`font-semibold
/// uppercase opacity-90`) on `bg-components-icon-bg-orange-dark-solid` under the avatar mask gradient, `border
/// border-divider-regular`, `shadow-xs`.
class WorkspaceAvatar extends StatelessWidget {
  const WorkspaceAvatar({super.key, this.name, this.size = WorkspaceAvatarSize.sm});

  final String? name;
  final WorkspaceAvatarSize size;

  @override
  Widget build(BuildContext context) {
    final n = name ?? '';
    final initial = n.isEmpty ? '?' : String.fromCharCode(n.runes.first).toUpperCase();
    final r = BorderRadius.circular(size.radius);
    // The colour under the mask gradient (CSS paints background-color below background-image).
    return ExcludeSemantics(
      child: Container(
        width: size.box,
        height: size.box,
        decoration: BoxDecoration(
          borderRadius: r,
          color: DifyColors.componentsIconBgOrangeDarkSolid,
          boxShadow: DifyShadows.xs,
        ),
        foregroundDecoration: BoxDecoration(
          borderRadius: r,
          border: Border.all(color: DifyColors.dividerRegular),
        ),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: r,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [DifyColors.componentsAvatarBgMaskStop0, DifyColors.componentsAvatarBgMaskStop100],
            ),
          ),
          alignment: Alignment.center,
          child: Opacity(
            opacity: 0.9,
            child: Text(
              initial,
              style: TextStyle(
                fontSize: size.fontSize,
                height: size.lineHeight / size.fontSize,
                fontWeight: FontWeight.w600,
                color: DifyColors.componentsAvatarShapeFillStop0,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// dify-ui's RadioControl: `size-4 rounded-full border border-components-radio-border shadow-xs`, checked a 5 px
/// `border-components-radio-border-checked` ring; hover darkens the border.
class SettingsRadioDot extends StatelessWidget {
  const SettingsRadioDot({super.key, required this.checked, this.hovered = false, this.disabled = false});

  final bool checked, hovered, disabled;

  @override
  Widget build(BuildContext context) {
    final Color border;
    if (disabled) {
      border = checked ? DifyColors.componentsRadioBorderCheckedDisabled : DifyColors.componentsRadioBorderDisabled;
    } else if (checked) {
      border = hovered ? DifyColors.componentsRadioBorderCheckedHover : DifyColors.componentsRadioBorderChecked;
    } else {
      border = hovered ? DifyColors.componentsRadioBorderHover : DifyColors.componentsRadioBorder;
    }
    return Container(
      width: 16,
      height: 16,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: disabled ? DifyColors.componentsRadioBgDisabled : DifyColors.componentsRadioBg,
        border: Border.all(color: border, width: checked ? 5 : 1),
        boxShadow: [for (final s in DifyShadows.xs) s.copyWith(color: DifyColors.shadowShadow3)],
      ),
    );
  }
}
