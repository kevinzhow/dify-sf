/// The access point building blocks (Dify 1.17.1 web/app/components/base/access-point: card.tsx, url.tsx, status.ts;
/// app/access-point/shared/use-access-point-status-label.ts): the card with its status and switch, the
/// endpoint row, the URL row with copy / QR code / regenerate / open, and the empty content.
library;

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

import 'package:flutter/widgets.dart';

import '../../design/css_metrics.dart';
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';
import '../../open_url.dart';

String _t(String ns, String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr(ns, key, params);

/// `AccessPointAvailability`.
enum AccessPointAvailability { available, loading, unavailable }

/// `AccessPointStatus`.
enum AccessPointStatus { disabled, inService, loading, unavailable, unsupported }

/// `getAccessPointStatus`.
AccessPointStatus accessPointStatusOf(AccessPointAvailability availability, bool enabled) => switch (availability) {
  AccessPointAvailability.loading => AccessPointStatus.loading,
  AccessPointAvailability.unavailable => AccessPointStatus.unavailable,
  AccessPointAvailability.available => enabled ? AccessPointStatus.inService : AccessPointStatus.disabled,
};

/// `useAccessPointStatusLabel`.
String accessPointStatusLabel(AccessPointStatus status) => switch (status) {
  AccessPointStatus.disabled => _t('appOverview', 'overview.status.disable'),
  AccessPointStatus.inService => _t('agent-v-2', 'agentDetail.access.status.inService'),
  AccessPointStatus.loading => _t('common', 'loading'),
  AccessPointStatus.unavailable => _t('deployments', 'health.ENVIRONMENT_STATUS_FAILED'),
  AccessPointStatus.unsupported => _t('deployments', 'studio.accessPoint.notSupported'),
};

/// AccessPointCard: a `min-h-68 rounded-xl bg-background-section-burn p-1` section (`ring-2 ring-state-accent-solid`
/// when [highlighted]) named [title]: the header (icon, title and description truncated with their full text as
/// tooltip, the status dot and label, the switch while the point is disabled or in service and changeable), then the
/// `rounded-[10px] bg-components-panel-on-panel-item-bg` body with [child] and the [actions] footer. [busy] is
/// `aria-busy` (loading).
class AccessPointCard extends StatelessWidget {
  const AccessPointCard({
    super.key,
    required this.title,
    required this.description,
    required this.icon,
    required this.status,
    required this.statusLabel,
    required this.child,
    this.actions,
    this.highlighted = false,
    this.onEnabledChange,
    this.showStatus = true,
    this.switchDisabled = false,
    this.switchDisabledReason,
    this.switchLabel,
    this.switchLoading = false,
  });

  final String title, description, statusLabel;

  /// A widget (the app icon), or a [String] icon drawn in Dify's `size-10 rounded-[10px]` tile.
  final Object icon;
  final AccessPointStatus status;
  final Widget child;
  final List<Widget>? actions;
  final bool highlighted, showStatus, switchDisabled, switchLoading;
  final ValueChanged<bool>? onEnabledChange;
  final String? switchDisabledReason, switchLabel;

  bool get busy => status == AccessPointStatus.loading;

  /// The switch shows while the point is disabled or in service and there is a handler.
  bool get showSwitch =>
      (status == AccessPointStatus.disabled || status == AccessPointStatus.inService) && onEnabledChange != null;

  Widget _icon() {
    final icon = this.icon;
    if (icon is Widget) return icon;
    return Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: DifyColors.componentsPanelOnPanelItemBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: DifyColors.dividerRegular, width: Css.hairline),
      ),
      child: '$icon'.startsWith('vender/')
          ? DifyIcon('$icon', size: 20, color: DifyColors.textSecondary)
          : RemixIcon('$icon', size: 20, color: DifyColors.textSecondary),
    );
  }

  @override
  Widget build(BuildContext context) {
    final enabled = status == AccessPointStatus.inService;
    final hasReason = switchDisabled && (switchDisabledReason?.isNotEmpty ?? false);
    Widget? switchControl;
    if (showSwitch) {
      switchControl = DifySwitch(
        key: const ValueKey('access-point-switch'),
        checked: enabled,
        disabled: switchDisabled,
        loading: switchLoading,
        semanticLabel: switchLabel ?? title,
        onCheckedChange: (v) {
          if (!switchDisabled) onEnabledChange?.call(v);
        },
      );
      // With a reason the disabled switch stays focusable (`aria-disabled`) and explains itself in a tooltip.
      if (hasReason) {
        switchControl = DifyTooltip(
          content: Text(switchDisabledReason!),
          child: Focus(key: const ValueKey('access-point-switch-focus'), child: switchControl),
        );
      }
    }
    final footer = actions;
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: title,
      child: Container(
        constraints: const BoxConstraints(minHeight: 272),
        padding: const EdgeInsets.all(4),
        decoration: DifyFocusDecoration(
          color: DifyColors.backgroundSectionBurn,
          borderRadius: BorderRadius.circular(DifyRadius.xl),
          boxShadow: difyFocusRing(highlighted),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 2,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 56),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 20, 8),
                child: Row(
                  spacing: 10,
                  children: [
                    _icon(),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Semantics(
                            header: true,
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: difyTextStyle(DifyType.systemMdSemibold, DifyColors.textPrimary),
                            ),
                          ),
                          Text(
                            description,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textTertiary),
                          ),
                        ],
                      ),
                    ),
                    if (showStatus) ...[
                      Semantics(
                        liveRegion: true,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          spacing: 4,
                          children: [
                            if (busy)
                              const DifyPulse(child: DifyStatusDotSkeleton())
                            else
                              DifyStatusDot(
                                status: enabled ? DifyStatusDotStatus.success : DifyStatusDotStatus.disabled,
                              ),
                            Text(
                              difyTransform(DifyType.systemXsSemiboldUppercase, statusLabel),
                              semanticsLabel: statusLabel,
                              style: difyTextStyle(
                                DifyType.systemXsSemiboldUppercase,
                                enabled ? DifyColors.textSuccess : DifyColors.textTertiary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      ?switchControl,
                    ],
                  ],
                ),
              ),
            ),
            Expanded(
              flex: 0,
              child: Container(
                constraints: const BoxConstraints(minHeight: 272 - 8 - 56 - 2),
                decoration: BoxDecoration(
                  color: DifyColors.componentsPanelOnPanelItemBg,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    child,
                    if (footer != null)
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          border: Border(
                            top: BorderSide(color: DifyColors.dividerSubtle, width: Css.hairline),
                          ),
                        ),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: footer,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// AccessPointEndpoint: `px-4 py-3` with the label (`h-6 system-xs-medium text-text-secondary`) over a `h-9
/// rounded-lg border-[0.5px] bg-components-input-bg-normal` row: the Unavailable badge, the value (quaternary when
/// [dimmed] or [unavailable]; a pulsing bar while [loading]) and [actions].
class AccessPointEndpoint extends StatelessWidget {
  const AccessPointEndpoint({
    super.key,
    required this.label,
    required this.value,
    required this.unavailableLabel,
    this.actions,
    this.dimmed = false,
    this.loading = false,
    this.unavailable = false,
  });

  final String label, value, unavailableLabel;
  final Widget? actions;
  final bool dimmed, loading, unavailable;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 4,
      children: [
        SizedBox(
          height: 24,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(label, style: difyTextStyle(DifyType.systemXsMedium, DifyColors.textSecondary)),
          ),
        ),
        Container(
          height: 36,
          padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
          decoration: BoxDecoration(
            color: DifyColors.componentsInputBgNormal,
            borderRadius: BorderRadius.circular(DifyRadius.lg),
            border: Border.all(color: DifyColors.dividerSubtle, width: Css.hairline),
          ),
          child: LayoutBuilder(
            builder: (context, box) => Row(
              spacing: 2,
              children: [
                if (unavailable && !loading)
                  Container(
                    // `shrink-0`; a translation too long for the row is cut instead of pushing the actions out.
                    constraints: BoxConstraints(maxWidth: box.maxWidth / 4),
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(5),
                      border: Border.all(color: DifyColors.dividerDeep),
                    ),
                    child: Text(
                      difyTransform(DifyType.system2xsMediumUppercase, unavailableLabel),
                      semanticsLabel: unavailableLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: difyTextStyle(DifyType.system2xsMediumUppercase, DifyColors.textTertiary),
                    ),
                  ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: loading
                        ? const DifySkeletonRectangle(
                            widthFactor: 0.42,
                            radius: 4,
                            margin: EdgeInsets.zero,
                            pulse: true,
                          )
                        : Text(
                            value,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: difyTextStyle(
                              DifyType.systemSmRegular,
                              dimmed || unavailable ? DifyColors.textQuaternary : DifyColors.textSecondary,
                            ),
                          ),
                  ),
                ),
                ?actions,
              ],
            ),
          ),
        ),
      ],
    ),
  );
}

/// An external link drawn as a secondary button (`<a target="_blank" rel="noopener noreferrer">`): opens [url] with
/// [openExternalUrl] (or [onOpen]); its semantics are a link to [url].
class ExternalLinkButton extends StatelessWidget {
  const ExternalLinkButton({
    super.key,
    required this.url,
    required this.child,
    this.leading,
    this.trailing,
    this.size = DifyButtonSize.medium,
    this.paddingX,
    this.onOpen,
  });

  final String url;
  final Widget child;
  final Widget? leading, trailing;
  final DifyButtonSize size;
  final double? paddingX;
  final void Function(String url)? onOpen;

  @override
  Widget build(BuildContext context) => MergeSemantics(
    child: Semantics(
      link: true,
      linkUrl: Uri.tryParse(url),
      child: DifyButton(
        size: size,
        paddingX: paddingX,
        leading: leading,
        trailing: trailing,
        onPressed: () => onOpen != null ? onOpen!(url) : unawaited(openExternalUrl(url)),
        child: child,
      ),
    ),
  );
}

/// A greyed `p-0.5` icon (`text-text-disabled`, not-allowed cursor) standing in for an unavailable action.
class _DisabledIcon extends StatelessWidget {
  const _DisabledIcon(this.icon);
  final String icon;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.forbidden,
    child: Padding(
      padding: const EdgeInsets.all(2),
      child: RemixIcon(icon, size: 16, color: DifyColors.textDisabled),
    ),
  );
}

/// AccessPointUrl: an [AccessPointEndpoint] whose actions are copy, the QR code ([showQrCode]), regenerate
/// ([showRegenerate]) and Open ([showOpen]: a link to [openUrl] while [enabled], else a disabled button explaining
/// [openDisabledReason]). While loading or unavailable the actions are greyed placeholders.
class AccessPointUrl extends StatelessWidget {
  const AccessPointUrl({
    super.key,
    required this.label,
    required this.value,
    required this.unavailableLabel,
    required this.enabled,
    this.copyDisabled = false,
    this.loading = false,
    this.unavailable = false,
    this.showOpen = false,
    this.showQrCode = false,
    this.showRegenerate = false,
    this.openUrl,
    this.onRegenerate,
    this.openDisabledReason,
    this.openLabel,
    this.regenerateLabel,
    this.regenerateDisabled = false,
    this.regenerating = false,
    this.onOpen,
    this.saveQrCode,
  });

  final String label, value, unavailableLabel;
  final bool enabled, copyDisabled, loading, unavailable, showOpen, showQrCode, showRegenerate;
  final bool regenerateDisabled, regenerating;
  final String? openUrl, openDisabledReason, openLabel, regenerateLabel;
  final VoidCallback? onRegenerate;

  /// Opens a URL (the app's external opener by default).
  final void Function(String url)? onOpen;

  /// Saves the QR code PNG ([ShareQrCode.save]).
  final SaveDownload? saveQrCode;

  bool get detailsAvailable => !loading && !unavailable;

  Widget _openDivider(Color color) =>
      Container(width: 1, height: 14, margin: const EdgeInsets.symmetric(horizontal: 4), color: color);

  Widget _disabledOpen() {
    final button = DifyButton(
      key: const ValueKey('access-point-open'),
      size: DifyButtonSize.small,
      paddingX: 6,
      disabled: true,
      focusableWhenDisabled: openDisabledReason != null,
      leading: const RemixIcon('external-link-line', size: 14),
      child: Text(openLabel ?? ''),
    );
    return openDisabledReason == null ? button : DifyTooltip(content: Text(openDisabledReason!), child: button);
  }

  @override
  Widget build(BuildContext context) {
    final Widget actions;
    if (!detailsAvailable) {
      actions = Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 2,
        children: [
          const _DisabledIcon('file-copy-line'),
          if (showQrCode) const _DisabledIcon('qr-code-line'),
          if (showRegenerate) const _DisabledIcon('loop-left-line'),
          if (showOpen) ...[_openDivider(DifyColors.dividerSubtle), _disabledOpen()],
        ],
      );
    } else {
      final url = openUrl;
      actions = Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 2,
        children: [
          if (copyDisabled) const _DisabledIcon('file-copy-line') else DifyCopyFeedback(content: value),
          if (showQrCode)
            if (copyDisabled) const _DisabledIcon('qr-code-line') else ShareQrCode(content: value, save: saveQrCode),
          if (showRegenerate)
            DifyIconButton(
              key: const ValueKey('access-point-regenerate'),
              label: regenerateLabel ?? _t('common', 'operation.regenerate'),
              disabled: regenerateDisabled || regenerating,
              icon: regenerating
                  ? DifySpinnerIcon(child: const RemixIcon('loop-left-line', size: 16))
                  : const RemixIcon('loop-left-line', size: 16),
              onPressed: onRegenerate,
            ),
          if (showOpen) ...[
            _openDivider(DifyColors.dividerRegular),
            if (enabled && url != null)
              ExternalLinkButton(
                key: const ValueKey('access-point-open'),
                url: url,
                size: DifyButtonSize.small,
                paddingX: 6,
                onOpen: onOpen,
                leading: const RemixIcon('external-link-line', size: 14),
                child: Text(openLabel ?? ''),
              )
            else
              _disabledOpen(),
          ],
        ],
      );
    }
    return AccessPointEndpoint(
      label: label,
      value: value,
      unavailableLabel: unavailableLabel,
      unavailable: unavailable,
      dimmed: !enabled,
      loading: loading,
      actions: actions,
    );
  }
}

/// AccessPointEmptyContent: centred `min-h-36 px-6 py-8 system-xs-regular text-text-tertiary` text.
class AccessPointEmptyContent extends StatelessWidget {
  const AccessPointEmptyContent({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(minHeight: 144),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      child: Center(
        child: DefaultTextStyle.merge(
          textAlign: TextAlign.center,
          style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textTertiary),
          child: child,
        ),
      ),
    ),
  );
}

/// Saves a downloaded file (Dify's `downloadUrl` / `downloadBlob`): [name] with [bytes] of [mimeType].
typedef SaveDownload = Future<void> Function(String name, Uint8List bytes, String mimeType);

/// The browser download on the web, a save dialog on desktop.
Future<void> saveDownload(String name, Uint8List bytes, String mimeType) async {
  final file = XFile.fromData(bytes, name: name, mimeType: mimeType);
  if (kIsWeb) return file.saveTo(name);
  final location = await getSaveLocation(suggestedName: name);
  if (location != null) await file.saveTo(location.path);
}

/// `canvas.toDataURL()` of [DifyQrCode]: a [size] px PNG, black on white.
Future<Uint8List> qrCodePng(String data, {double size = 160}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(Offset.zero & Size.square(size), Paint()..color = DifyColors.effectsImageFrame);
  qrPainterOf(data).paint(canvas, Size.square(size));
  final image = await recorder.endRecording().toImage(size.round(), size.round());
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return bytes!.buffer.asUint8List();
}

/// base/qrcode ShareQRCode: the `qr-code-line` icon button (tooltip and name "QR Code") toggling a `w-58 rounded-lg
/// bg-components-panel-bg p-4 shadow-xs` panel 32 px below with the 160 px code and Download ("Scan · Download" with
/// [scanLabel]). A click outside closes it; Download saves `qrcode.png`.
class ShareQrCode extends StatefulWidget {
  const ShareQrCode({
    super.key,
    required this.content,
    this.triggerLabel,
    this.scanLabel,
    this.downloadLabel,
    this.save,
  });

  final String content;
  final String? triggerLabel, scanLabel, downloadLabel;

  /// Where Download goes ([saveDownload] by default).
  final SaveDownload? save;

  @override
  State<ShareQrCode> createState() => ShareQrCodeState();
}

class ShareQrCodeState extends State<ShareQrCode> {
  final _floating = DifyFloatingController();
  bool get isShow => _floating.isOpen;

  void _toggle() => _floating.toggle();

  Future<void> _download() async {
    final png = await qrCodePng(widget.content);
    await (widget.save ?? saveDownload)('qrcode.png', png, 'image/png');
  }

  @override
  Widget build(BuildContext context) {
    final label = widget.triggerLabel ?? _t('appOverview', 'overview.appInfo.qrcode.title');
    final download = widget.downloadLabel ?? _t('appOverview', 'overview.appInfo.qrcode.download');
    final scan = widget.scanLabel;
    final small = difyTextStyle(DifyType.systemXsRegular, DifyColors.textTertiary);
    return DifyFloating(
      controller: _floating,
      placement: DifyPlacement.bottomEnd,
      sideOffset: 8,
      alignOffset: -32,
      focusPopup: false,
      builder: (context, controller) => DifyTooltip(
        content: Text(label),
        child: DifyIconButton(
          key: const ValueKey('qrcode-trigger'),
          label: label,
          icon: const RemixIcon('qr-code-line', size: 16),
          onPressed: _toggle,
        ),
      ),
      popupBuilder: (context) => DifySurface(
        child: Container(
          key: const ValueKey('qrcode-panel'),
          width: 232,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: DifyColors.componentsPanelBg,
            borderRadius: BorderRadius.circular(DifyRadius.lg),
            boxShadow: DifyShadows.xs,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: DifyQrCode(key: const ValueKey('qrcode-canvas'), data: widget.content),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (scan != null) ...[Flexible(child: Text(scan, style: small)), Text('·', style: small)],
                  Flexible(
                    child: DifyPressable(
                      key: const ValueKey('qrcode-download'),
                      semanticLabel: download,
                      onPressed: () => unawaited(_download()),
                      builder: (context, hovered, focused) => Text(
                        download,
                        style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textAccentSecondary),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
