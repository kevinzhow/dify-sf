/// "Customize AI web app" (Dify 1.17.1 app/overview/customize): fork Dify's open-source web app template, deploy it
/// on Vercel with the app's id, key and API URL, or build a front end on the API.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../design/css_metrics.dart';
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';
import 'access_point_card.dart' show ExternalLinkButton;
import 'access_point_utils.dart';

String _t(String key, [Map<String, Object?> params = const {}]) =>
    DifyI18n.tr('appOverview', 'overview.appInfo.customize.$key', params);

/// Shows [CustomizeModal].
Future<void> showCustomizeModal(
  BuildContext context, {
  required String appId,
  required String apiBaseUrl,
  required String mode,
}) => showDifyDialog<void>(
  context,
  builder: (context) => CustomizeModal(appId: appId, apiBaseUrl: apiBaseUrl, mode: mode),
);

/// CustomizeModal (`w-160`): the title, the explanation and close; "Way 1" (fork `webapp-conversation` for chat apps,
/// else `webapp-text-generator`; deploy on Vercel; set the environment variables shown) and "Way 2" (the API
/// documentation).
class CustomizeModal extends StatelessWidget {
  const CustomizeModal({super.key, required this.appId, required this.apiBaseUrl, this.mode, this.onOpen});

  final String appId, apiBaseUrl;
  final String? mode;
  final void Function(String url)? onOpen;

  bool get _isChatApp => mode == 'chat' || mode == 'advanced-chat';

  /// The template repository on GitHub.
  String get repository => _isChatApp ? 'webapp-conversation' : 'webapp-text-generator';

  static Widget _stepNum(String n) => Container(
    width: 28,
    height: 28,
    margin: const EdgeInsets.only(right: 12),
    alignment: Alignment.center,
    decoration: BoxDecoration(color: DifyColors.utilColorsBlueBlue50, borderRadius: BorderRadius.circular(16)),
    child: DifyTextLine(
      n,
      style: difyTextStyle(DifyType.systemMdRegular, DifyColors.textAccent),
    ),
  );

  Widget _badge(String text) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
    decoration: BoxDecoration(
      color: DifyColors.componentsBadgeBgDimm,
      borderRadius: BorderRadius.circular(5),
      border: Border.all(color: DifyColors.textAccentSecondary),
    ),
    child: DifyTextLine(
      difyTransform(DifyType.system2xsMediumUppercase, text),
      semanticsLabel: text,
      style: difyTextStyle(DifyType.system2xsMediumUppercase, DifyColors.textAccentSecondary),
    ),
  );

  Widget _step(String n, {required String title, required String tip, required Widget child, bool last = false}) {
    final body = difyTextStyle(DifyType.systemMdRegular, DifyColors.textPrimary); // inherited 14/20
    final small = difyTextStyle(DifyType.systemXsRegular, DifyColors.textTertiary); // `text-xs`
    return Padding(
      padding: EdgeInsets.only(top: 16, bottom: last ? 16 : (n == '2' ? 0 : 16)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _stepNum(n),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DifyTextLine(title, style: body),
                Padding(
                  padding: const EdgeInsets.only(top: 4, bottom: 8),
                  child: DifyTextLine(tip, style: small),
                ),
                child,
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final box = BoxDecoration(
      borderRadius: BorderRadius.circular(DifyRadius.lg),
      border: Border.all(color: DifyColors.componentsPanelBorder, width: Css.hairline),
    );
    final env =
        "NEXT_PUBLIC_APP_ID='$appId' \nNEXT_PUBLIC_APP_KEY='<Web API Key From Dify>' \nNEXT_PUBLIC_API_URL='$apiBaseUrl'";
    return DifyDialogSurface(
      label: _t('title'),
      width: 640,
      bordered: true,
      maxHeight: MediaQuery.sizeOf(context).height - 32,
      padding: const EdgeInsets.all(24),
      child: Stack(
        children: [
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DifyTextLine(_t('title'), style: difyTextStyle(DifyType.title2xlSemiBold, DifyColors.textPrimary)),
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: DifyTextLine(
                  _t('explanation'),
                  style: difyTextStyle(DifyType.bodyMdRegular, DifyColors.textSecondary),
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.only(top: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
                        decoration: box,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _badge('${_t('way')} 1'),
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: DifyTextLine(
                                _t('way1.name'),
                                style: difyTextStyle(DifyType.systemSmMedium, DifyColors.textSecondary),
                              ),
                            ),
                            _step(
                              '1',
                              title: _t('way1.step1'),
                              tip: _t('way1.step1Tip'),
                              child: ExternalLinkButton(
                                key: const ValueKey('customize-github'),
                                url: 'https://github.com/langgenius/$repository',
                                onOpen: onOpen,
                                leading: SvgPicture.asset('assets/embedded/github.svg', width: 18, height: 18),
                                child: DifyTextLine(_t('way1.step1Operation')),
                              ),
                            ),
                            _step(
                              '2',
                              title: _t('way1.step2'),
                              tip: _t('way1.step2Tip'),
                              child: ExternalLinkButton(
                                key: const ValueKey('customize-vercel'),
                                url: 'https://vercel.com/docs/concepts/deployments/git/vercel-for-github',
                                onOpen: onOpen,
                                leading: CustomPaint(
                                  size: const Size(14, 12),
                                  painter: _TrianglePainter(DifyColors.textPrimary),
                                ),
                                child: DifyTextLine(_t('way1.step2Operation')),
                              ),
                            ),
                            _step(
                              '3',
                              title: _t('way1.step3'),
                              tip: _t('way1.step3Tip'),
                              last: true,
                              child: Container(
                                width: double.infinity,
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                decoration: box.copyWith(color: DifyColors.backgroundSection),
                                child: SingleChildScrollView(
                                  scrollDirection: Axis.horizontal,
                                  child: DifySelectableText(
                                    env,
                                    // `text-xs font-medium text-text-secondary`
                                    style: difyTextStyle(DifyType.systemXsMedium, DifyColors.textSecondary),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        margin: const EdgeInsets.only(top: 16),
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
                        decoration: box,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _badge('${_t('way')} 2'),
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: DifyTextLine(
                                _t('way2.name'),
                                style: difyTextStyle(DifyType.systemSmMedium, DifyColors.textSecondary),
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: ExternalLinkButton(
                                key: const ValueKey('customize-api-docs'),
                                url: difyDocLink('/api-reference/guides/get-started'),
                                onOpen: onOpen,
                                trailing: HeroIcon(
                                  'arrow-top-right-on-square',
                                  size: 16,
                                  color: DifyColors.textSecondary,
                                ),
                                child: DifyTextLine(_t('way2.operation')),
                              ),
                            ),
                          ],
                        ),
                      ),
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
}

/// Vercel's triangle (`border-b-12 border-x-[7px] border-text-primary`, transparent sides).
class _TrianglePainter extends CustomPainter {
  _TrianglePainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawPath(
      Path()
        ..moveTo(size.width / 2, 0)
        ..lineTo(size.width, size.height)
        ..lineTo(0, size.height)
        ..close(),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_TrianglePainter old) => old.color != color;
}

/// Opens the GitHub template (for tests and callers that need the URL).
String customizeTemplateUrl(String? mode) =>
    'https://github.com/langgenius/${CustomizeModal(appId: '', apiBaseUrl: '', mode: mode).repository}';
