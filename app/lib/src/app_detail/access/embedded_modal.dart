/// "Embed on website" (Dify 1.17.1 app/overview/embedded): the iframe, script and Chrome extension snippets of a chat
/// Web App, with the hidden Start inputs as gzipped, base64-encoded search parameters.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../design/css_metrics.dart';
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';
import '../../open_url.dart';
import 'access_point_utils.dart';
import 'api_key_modal.dart' show monoFontFamily;
import 'workflow_launch_dialog.dart';

String _t(String key, [Map<String, Object?> params = const {}]) =>
    DifyI18n.tr('appOverview', 'overview.appInfo.embedded.$key', params);

/// The embed options, in Dify's order.
enum EmbeddedOption { iframe, scripts, chromePlugin }

/// The Chrome extension's store page.
const difyChromeExtensionUrl =
    'https://chrome.google.com/webstore/detail/dify-chatbot/ceehdapohffmjmkdcifjofadiaoeggaf';

/// Shows [EmbeddedModal].
Future<void> showEmbeddedModal(
  BuildContext context, {
  required String appBaseUrl,
  required String accessToken,
  String? chatColorTheme,
  List<Json> hiddenInputs = const [],
}) => showDifyDialog<void>(
  context,
  builder: (context) => EmbeddedModal(
    appBaseUrl: appBaseUrl,
    accessToken: accessToken,
    chatColorTheme: chatColorTheme,
    hiddenInputs: hiddenInputs,
  ),
);

/// Embedded (`w-160`): "Embed on website" and close, the explanation, the hidden inputs (collapsed by default), the
/// three option tiles (`188 x 128`, the active one `border-[1.5px] border-[#2970FF]`), the Chrome extension's install
/// button, and the snippet box with its copy button.
class EmbeddedModal extends StatefulWidget {
  const EmbeddedModal({
    super.key,
    required this.appBaseUrl,
    required this.accessToken,
    this.chatColorTheme,
    this.webAppRoute = 'chatbot',
    this.hiddenInputs = const [],
    this.isTestEnv = false,
    this.encode = compressAndEncodeBase64,
    this.copy,
    this.openUrl,
  });

  final String appBaseUrl, accessToken, webAppRoute;

  /// The site's `chat_color_theme` (the script's bubble colour).
  final String? chatColorTheme;
  final List<Json> hiddenInputs;

  /// The account's environment is `TESTING` or `DEVELOPMENT` (the script's `isDev`); dify-sf runs as production.
  final bool isTestEnv;

  /// A hidden input's value as a search parameter ([compressAndEncodeBase64]).
  final String Function(String value) encode;

  /// `copy-to-clipboard`; the clipboard by default.
  final void Function(String text)? copy;

  /// `window.open(url, '_blank', 'noopener,noreferrer')`; the app's external opener by default.
  final void Function(String url)? openUrl;

  @override
  State<EmbeddedModal> createState() => EmbeddedModalState();
}

class EmbeddedModalState extends State<EmbeddedModal> {
  late final _supported = widget.hiddenInputs.where(isWorkflowLaunchInputSupported).toList();
  late final Map<String, LaunchValue> _values = workflowLaunchInitialValues(_supported);
  EmbeddedOption option = EmbeddedOption.iframe;
  EmbeddedOption? _copied;
  bool _hiddenInputsCollapsed = true;

  String get _iframeUrl {
    final uri = Uri.parse('${widget.appBaseUrl}/${widget.webAppRoute}/${widget.accessToken}');
    if (_supported.isEmpty) return uri.toString();
    return uri
        .replace(
          queryParameters: {
            ...uri.queryParameters,
            for (final v in _supported) '${v['variable']}': widget.encode(_serialized(v)),
          },
        )
        .toString();
  }

  String _serialized(Json variable) {
    final raw = _values['${variable['variable']}'];
    if (variable['type'] == 'checkbox') return '${raw == true || (raw is String && raw.isNotEmpty)}';
    return raw == null ? '' : '$raw';
  }

  String get _scripts => embeddedScriptSnippet(
    url: widget.appBaseUrl,
    token: widget.accessToken,
    webAppRoute: widget.webAppRoute,
    primaryColor: chatPrimaryColor(widget.chatColorTheme),
    isTestEnv: widget.isTestEnv,
    inputValues: _values,
  );

  /// What the snippet box shows for [option].
  String get content => switch (option) {
    EmbeddedOption.scripts => _scripts,
    EmbeddedOption.chromePlugin => chromePluginContent(_iframeUrl),
    EmbeddedOption.iframe => embeddedIframeSnippet(_iframeUrl),
  };

  void _copy() {
    final url = _iframeUrl;
    final text = switch (option) {
      EmbeddedOption.chromePlugin => chromePluginContent(url).split(': ').skip(1).join(': '),
      EmbeddedOption.iframe => embeddedIframeSnippet(url),
      EmbeddedOption.scripts => _scripts,
    };
    if (text.isNotEmpty) {
      (widget.copy ?? (t) => unawaited(Clipboard.setData(ClipboardData(text: t))))(text);
    }
    setState(() => _copied = option);
  }

  Widget _optionTile(EmbeddedOption o) {
    final active = option == o;
    final asset = switch (o) {
      EmbeddedOption.iframe => 'iframe-option',
      EmbeddedOption.scripts => 'scripts-option',
      EmbeddedOption.chromePlugin => 'chromeplugin-option',
    };
    return DifyPressable(
      key: ValueKey('embedded-option-${o.name}'),
      semanticLabel: _t(o.name),
      onPressed: () => setState(() {
        option = o;
        _copied = null;
      }),
      builder: (context, hovered, focused) => Container(
        width: 188,
        height: 128,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(DifyRadius.md),
          border: active ? Border.all(color: DifyColors.primary500, width: 1.5) : null,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(DifyRadius.md),
          child: _themedImage(
            SvgPicture.asset('assets/embedded/$asset.svg', fit: BoxFit.none),
            darkFilter: _optionDarkFilter,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final title = _t('title');
    final copiedNow = _copied == option;
    final copyLabel = copiedNow ? _t('copied') : _t('copy');
    final screen = MediaQuery.sizeOf(context);
    return DifyDialogSurface(
      label: title,
      width: 640,
      bordered: true,
      maxHeight: screen.height - 32,
      padding: const EdgeInsets.all(24),
      child: Stack(
        children: [
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DifyTextLine(title, style: difyTextStyle(DifyType.title2xlSemiBold, DifyColors.textPrimary)),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 32, bottom: 16),
                        child: DifyTextLine(
                          _t('explanation'),
                          style: difyTextStyle(DifyType.systemSmMedium, DifyColors.textPrimary),
                        ),
                      ),
                      if (_supported.isNotEmpty) _hiddenInputs(),
                      Wrap(
                        alignment: WrapAlignment.spaceBetween,
                        runSpacing: 8,
                        children: [for (final o in EmbeddedOption.values) _optionTile(o)],
                      ),
                      if (option == EmbeddedOption.chromePlugin) _chromeInstall(),
                      _snippet(copyLabel, copiedNow),
                    ],
                  ),
                ),
              ),
            ],
          ),
          Positioned(
            top: 0,
            right: 0,
            child: DifyIconButton(
              key: const ValueKey('dialog-close'),
              label: DifyI18n.tr('common', 'operation.close'),
              size: DifyIconButtonSize.lg,
              icon: const RemixIcon('close-line', size: 16),
              onPressed: () => Navigator.of(context).maybePop(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _hiddenInputs() => Container(
    margin: const EdgeInsets.only(bottom: 24),
    decoration: BoxDecoration(
      color: DifyColors.backgroundSection,
      borderRadius: BorderRadius.circular(DifyRadius.xl),
      border: Border.all(color: DifyColors.componentsPanelBorder, width: Css.hairline),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DifyPressable(
          key: const ValueKey('embedded-hidden-inputs'),
          semanticLabel: _t('hiddenInputs.title'),
          onPressed: () => setState(() => _hiddenInputsCollapsed = !_hiddenInputsCollapsed),
          builder: (context, hovered, focused) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              spacing: 12,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      DifyTextLine(
                        _t('hiddenInputs.title'),
                        style: difyTextStyle(DifyType.systemSmMedium, DifyColors.textPrimary),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: DifyTextLine(
                          _t('hiddenInputs.description'),
                          style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textTertiary),
                        ),
                      ),
                    ],
                  ),
                ),
                RemixIcon(
                  _hiddenInputsCollapsed ? 'arrow-right-s-line' : 'arrow-down-s-line',
                  size: 16,
                  color: DifyColors.textTertiary,
                ),
              ],
            ),
          ),
        ),
        if (!_hiddenInputsCollapsed)
          Container(
            constraints: const BoxConstraints(maxHeight: 288),
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(color: DifyColors.dividerSubtle, width: Css.hairline),
              ),
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: WorkflowHiddenInputFields(
                hiddenVariables: _supported,
                values: _values,
                fieldIdPrefix: 'embedded-hidden-input',
                onValueChange: (k, v) => setState(() {
                  _values[k] = v;
                  _copied = null;
                }),
              ),
            ),
          ),
      ],
    ),
  );

  Widget _chromeInstall() => Padding(
    padding: const EdgeInsets.only(top: 24),
    child: DifyPressable(
      key: const ValueKey('embedded-chrome-install'),
      semanticLabel: _t('chromePlugin'),
      onPressed: () => (widget.openUrl ?? (u) => unawaited(openExternalUrl(u)))(difyChromeExtensionUrl),
      builder: (context, hovered, focused) => Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: hovered ? DifyColors.primary600.withValues(alpha: 0.75) : DifyColors.primary600,
          borderRadius: BorderRadius.circular(DifyRadius.lg),
          boxShadow: hovered ? DifyShadows.sm : null,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          spacing: 8,
          children: [
            SizedBox.square(
              dimension: 16,
              child: _themedImage(
                SvgPicture.asset('assets/embedded/chromeplugin-install.svg'),
                darkFilter: _invertMatrix(0.9),
              ),
            ),
            Flexible(
              child: DifyTextLine(
                _t('chromePlugin'),
                // `text-sm leading-tight font-medium text-white`
                style: difyTextStyle(DifyTw.textSmMediumLeadingTight, DifyTailwind.white),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _snippet(String copyLabel, bool copiedNow) => Container(
    margin: const EdgeInsets.only(top: 24),
    decoration: BoxDecoration(
      color: DifyColors.backgroundSection,
      borderRadius: BorderRadius.circular(DifyRadius.lg),
      border: Border.all(color: DifyColors.componentsPanelBorder, width: Css.hairline),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
          decoration: BoxDecoration(
            color: DifyColors.backgroundSectionBurn,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(DifyRadius.lg)),
          ),
          child: Row(
            spacing: 8,
            children: [
              Expanded(
                child: DifyTextLine(
                  _t(option.name),
                  style: difyTextStyle(DifyType.systemSmMedium, DifyColors.textSecondary),
                ),
              ),
              DifyTooltip(
                content: DifyTextLine(copyLabel),
                child: DifyIconButton(
                  key: const ValueKey('embedded-copy'),
                  label: copyLabel,
                  icon: RemixIcon(copiedNow ? 'clipboard-fill' : 'clipboard-line', size: 16),
                  onPressed: _copy,
                ),
              ),
            ],
          ),
        ),
        ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: (MediaQuery.sizeOf(context).height - 320).clamp(180.0, 360.0).toDouble(),
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DifySelectableText(
                content,
                key: const ValueKey('embedded-pre'),
                // `font-mono text-[13px] leading-tight text-text-secondary`
                style: difyTextStyle(
                  DifyTw.text13LeadingTight,
                  DifyColors.textSecondary,
                ).copyWith(fontFamily: monoFontFamily),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

/// [image], with [darkFilter] in the dark theme (the CSS `filter` Dify applies there).
Widget _themedImage(Widget image, {required List<double> darkFilter}) =>
    DifyColors.isDark ? ColorFiltered(colorFilter: ColorFilter.matrix(darkFilter), child: image) : image;

/// `filter: invert(0.86) hue-rotate(180deg) saturate(0.5) brightness(0.95)` (the option tiles in the dark theme).
final _optionDarkFilter = _compose([
  _invertMatrix(0.86),
  _hueRotateMatrix(math.pi),
  _saturateMatrix(0.5),
  _brightnessMatrix(0.95),
]);

/// CSS filter functions as 4x5 colour matrices (Filter Effects Level 1), in [ColorFilter.matrix]'s layout.
List<double> _invertMatrix(double a) => [
  1 - 2 * a, 0, 0, 0, 255 * a, //
  0, 1 - 2 * a, 0, 0, 255 * a,
  0, 0, 1 - 2 * a, 0, 255 * a,
  0, 0, 0, 1, 0,
];

List<double> _brightnessMatrix(double b) => [b, 0, 0, 0, 0, 0, b, 0, 0, 0, 0, 0, b, 0, 0, 0, 0, 0, 1, 0];

List<double> _saturateMatrix(double s) => [
  0.213 + 0.787 * s, 0.715 - 0.715 * s, 0.072 - 0.072 * s, 0, 0, //
  0.213 - 0.213 * s, 0.715 + 0.285 * s, 0.072 - 0.072 * s, 0, 0,
  0.213 - 0.213 * s, 0.715 - 0.715 * s, 0.072 + 0.928 * s, 0, 0,
  0, 0, 0, 1, 0,
];

List<double> _hueRotateMatrix(double angle) {
  final c = math.cos(angle), s = math.sin(angle);
  return [
    0.213 + c * 0.787 - s * 0.213, 0.715 - c * 0.715 - s * 0.715, 0.072 - c * 0.072 + s * 0.928, 0, 0, //
    0.213 - c * 0.213 + s * 0.143, 0.715 + c * 0.285 + s * 0.140, 0.072 - c * 0.072 - s * 0.283, 0, 0,
    0.213 - c * 0.213 - s * 0.787, 0.715 - c * 0.715 + s * 0.715, 0.072 + c * 0.928 + s * 0.072, 0, 0,
    0, 0, 0, 1, 0,
  ];
}

/// The matrix applying [ms] in order (the first one first).
List<double> _compose(List<List<double>> ms) => ms.reduce((acc, m) => _multiply(m, acc));

/// [a] after [b] (5x5 affine matrices with an implicit last row `0 0 0 0 1`).
List<double> _multiply(List<double> a, List<double> b) {
  double at(List<double> m, int r, int c) => r == 4 ? (c == 4 ? 1 : 0) : m[r * 5 + c];
  return [
    for (var r = 0; r < 4; r++)
      for (var c = 0; c < 5; c++) [for (var k = 0; k < 5; k++) at(a, r, k) * at(b, k, c)].reduce((x, y) => x + y),
  ];
}
