/// invited-modal/index.tsx and invitation-link.tsx: the result of sending invitations. dify-sf has no mail server, so
/// it shows what Dify's self-hosted editions show: the invitation links to copy and pass on, the addresses already in
/// the team, and the failed ones.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/rendering.dart' show OverflowBoxFit;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../auth/auth_api.dart';
import '../../design/css_metrics.dart';
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../settings_kit.dart';

/// Shows the InvitedModal for [results].
Future<void> showInvitedModal(BuildContext context, List<InvitationResult> results, {String? origin}) =>
    showSettingsDialog<void>(context, (context) => InvitedModal(invitationResults: results, origin: origin));

/// The web app's origin a relative invitation link is completed with (`window.location.origin`); null on desktop,
/// where the app has no URL (the link is copied as the server gave it; `--invite` takes it).
String? get defaultInvitationOrigin => kIsWeb ? Uri.base.origin : null;

/// InvitedModal: `DialogContent className="w-120 p-8"` with the close button (`absolute top-8 right-8`), the green
/// check in a `size-12 rounded-xl` box, the title "Invitation sent" (or "No new invitations sent" when every address
/// already belongs to the team), the tip, then the sections: invitation links, already in team, failed (each failed
/// address explains itself in a tooltip), and the OK button (`w-24`).
class InvitedModal extends StatelessWidget {
  const InvitedModal({super.key, required this.invitationResults, this.onCancel, this.origin});

  final List<InvitationResult> invitationResults;

  /// Defaults to closing the dialog.
  final VoidCallback? onCancel;

  /// See [InvitationLink.origin].
  final String? origin;

  @override
  Widget build(BuildContext context) {
    final success = invitationResults.where((r) => r.status == 'success').toList();
    final already = invitationResults.where((r) => r.status == 'already_member').toList();
    final failed = invitationResults.where((r) => r.status == 'failed').toList();
    final onlyAlreadyMembers = already.isNotEmpty && success.isEmpty && failed.isEmpty;
    final description = stc(context, onlyAlreadyMembers ? 'members.alreadyInTeamTip' : 'members.invitationSentTip');
    final title = stc(context, onlyAlreadyMembers ? 'members.noNewInvitationsSent' : 'members.invitationSent');
    void close() => onCancel != null ? onCancel!() : Navigator.of(context).maybePop();
    final sectionTitle = TextStyle(
      fontSize: 14,
      height: 20 / 14,
      fontWeight: FontWeight.w500,
      color: DifyColors.textPrimary,
    );
    final tertiary = TextStyle(fontSize: 14, height: 20 / 14, color: DifyColors.textTertiary);
    return SettingsDialogContent(
      label: title,
      padding: const EdgeInsets.all(32),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Container(
                    width: 48,
                    height: 48,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: DifyColors.backgroundSectionBurn,
                      borderRadius: BorderRadius.circular(DifyRadius.xl),
                      border: Border.all(color: DifyColors.componentsPanelBorder, width: Css.hairline),
                      boxShadow: DifyShadows.xl,
                    ),
                    child: const HeroIcon('check-circle-solid', size: 22, color: Color(0xFF039855)),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 20,
                    height: 28 / 20,
                    fontWeight: FontWeight.w600,
                    color: DifyColors.textPrimary,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 20),
                child: Text(description, style: tertiary),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 36),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 8,
                  children: [
                    if (success.isNotEmpty) ...[
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(stc(context, 'members.invitationLink'), style: sectionTitle),
                      ),
                      for (final r in success)
                        InvitationLink(key: ValueKey('link-${r.email}'), value: r, origin: origin),
                    ],
                    if (already.isNotEmpty) ...[
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(stc(context, 'members.alreadyInTeam'), style: sectionTitle),
                      ),
                      if (!onlyAlreadyMembers) Text(stc(context, 'members.alreadyInTeamTip'), style: tertiary),
                      Wrap(
                        alignment: WrapAlignment.spaceBetween,
                        runSpacing: 4,
                        children: [
                          for (final r in already)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 4),
                              decoration: BoxDecoration(
                                color: DifyColors.backgroundSectionBurn,
                                borderRadius: BorderRadius.circular(DifyRadius.md),
                                border: Border.all(color: DifyColors.componentsPanelBorder),
                              ),
                              child: Text(
                                r.email,
                                style: TextStyle(fontSize: 14, height: 20 / 14, color: DifyColors.textSecondary),
                              ),
                            ),
                        ],
                      ),
                    ],
                    if (failed.isNotEmpty) ...[
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(stc(context, 'members.failedInvitationEmails'), style: sectionTitle),
                      ),
                      Wrap(
                        alignment: WrapAlignment.spaceBetween,
                        runSpacing: 4,
                        children: [
                          for (final r in failed)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 4),
                              decoration: BoxDecoration(
                                color: const Color(0xFFFEF6EE), // orange-50
                                borderRadius: BorderRadius.circular(DifyRadius.md),
                                border: Border.all(color: const Color(0xFFFDA29B)), // red-300
                              ),
                              child: DifyTooltip(
                                content: Text(r.message ?? ''),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  spacing: 4,
                                  children: [
                                    Text(r.email, style: const TextStyle(fontSize: 14, height: 20 / 14)),
                                    const RemixIcon('question-line', size: 16, color: Color(0xFFFDA29B)),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: SizedBox(
                  width: 96,
                  child: DifyButton(
                    key: const ValueKey('invited-ok'),
                    variant: DifyButtonVariant.primary,
                    onPressed: close,
                    child: Text(stc(context, 'members.ok')),
                  ),
                ),
              ),
            ],
          ),
          PositionedDirectional(top: 0, end: 0, child: SettingsDialogCloseButton(onPressed: close)),
        ],
      ),
    );
  }
}

/// The text copied for an invitation link: a relative link completed with [origin] (absolute links as they are).
String invitationLinkText(String url, String? origin) =>
    !url.startsWith('http') && origin != null ? '$origin$url' : url;

/// InvitationLink: `flex items-center rounded-lg border border-components-input-border-active
/// bg-components-input-bg-normal py-2` (hover `bg-state-base-hover`): the link (`text-[13px]`, truncated, a button
/// that copies it), a divider and the copy button (`size-7.5 rounded-lg`, Dify's copy / copy-hover / copied
/// images); both explain themselves in a "Copy" / "Copied" tooltip, which says "Copied" for a second after a copy.
class InvitationLink extends StatefulWidget {
  const InvitationLink({super.key, required this.value, this.origin, this.copy});

  final InvitationResult value;

  /// The web app's origin for relative links ([defaultInvitationOrigin] when null is not wanted: see there).
  final String? origin;

  /// Copies the text (the clipboard by default; tests record it).
  final Future<void> Function(String text)? copy;

  @override
  State<InvitationLink> createState() => _InvitationLinkState();
}

class _InvitationLinkState extends State<InvitationLink> {
  bool _copied = false;
  bool _hovered = false;
  bool _copyHovered = false;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _copy() {
    final text = invitationLinkText(widget.value.url ?? '', widget.origin ?? defaultInvitationOrigin);
    unawaited((widget.copy ?? (t) => Clipboard.setData(ClipboardData(text: t)))(text));
    setState(() => _copied = true);
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 1), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final url = widget.value.url ?? '';
    final tip = Text(st(context, 'appApi', _copied ? 'copied' : 'copy'));
    final copyLabel = st(context, 'appApi', 'copy');
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: _hovered ? DifyColors.stateBaseHover : DifyColors.componentsInputBgNormal,
          borderRadius: BorderRadius.circular(DifyRadius.lg),
          border: Border.all(color: DifyColors.componentsInputBorderActive),
        ),
        child: SizedBox(
          height: 20,
          child: Row(
            children: [
              Expanded(
                child: DifyTooltip(
                  content: tip,
                  child: Semantics(
                    button: true,
                    label: url,
                    onTap: _copy,
                    excludeSemantics: true,
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(
                        key: const ValueKey('invitation-url'),
                        behavior: HitTestBehavior.opaque,
                        onTap: _copy,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Align(
                            alignment: AlignmentDirectional.centerStart,
                            child: Text(
                              url,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 13, height: 20 / 13, color: DifyColors.textPrimary),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Container(width: 2, height: 16, color: DifyColors.dividerRegular),
              // The 30 px button overflows the 20 px line into the padding, as in the browser.
              OverflowBox(
                minHeight: 0,
                maxHeight: 30,
                fit: OverflowBoxFit.deferToChild,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: DifyTooltip(
                    content: tip,
                    child: Semantics(
                      button: true,
                      label: copyLabel,
                      onTap: _copy,
                      excludeSemantics: true,
                      child: MouseRegion(
                        cursor: SystemMouseCursors.click,
                        onEnter: (_) => setState(() => _copyHovered = true),
                        onExit: (_) => setState(() => _copyHovered = false),
                        child: GestureDetector(
                          key: const ValueKey('invitation-copy'),
                          onTap: _copy,
                          child: Container(
                            width: 30,
                            height: 30,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: _copyHovered ? DifyColors.stateBaseHover : null,
                              borderRadius: BorderRadius.circular(DifyRadius.lg),
                            ),
                            child: SvgPicture.asset(
                              'assets/members/${_copied
                                  ? 'copied'
                                  : _copyHovered
                                  ? 'copy-hover'
                                  : 'copy'}.svg',
                              width: 16,
                              height: 16,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
