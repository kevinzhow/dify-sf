/// dify-sf only: an owner's or admin's one-time password reset link for a member, for servers without mail (Dify's
/// community edition resets passwords from its command line). Drawn like the InvitedModal: the link to copy and pass on.
library;

import 'package:flutter/widgets.dart';

import '../../auth/auth_api.dart';
import '../../design/css_metrics.dart';
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../settings_kit.dart';
import 'invited_modal.dart';

/// Shows the ResetLinkModal for [member]'s [link].
Future<void> showResetLinkModal(BuildContext context, Member member, PasswordResetLink link, {String? origin}) =>
    showSettingsDialog<void>(context, (context) => ResetLinkModal(member: member, link: link, origin: origin));

/// The InvitedModal's frame (`w-120 p-8`, close button, the key in a `size-12 rounded-xl` box): "Password reset link",
/// what the link does, the link with its copy button (relative links completed with [origin]) and OK.
class ResetLinkModal extends StatelessWidget {
  const ResetLinkModal({super.key, required this.member, required this.link, this.origin, this.copy});

  final Member member;
  final PasswordResetLink link;

  /// See [InvitationLink.origin].
  final String? origin;

  /// See [InvitationLink.copy].
  final Future<void> Function(String text)? copy;

  static const title = 'Password reset link';

  /// The validity of the link in words ("24 hours" for the server's default).
  static String validity(PasswordResetLink link, DateTime now) {
    final at = link.expiresAt;
    if (at == null) return 'a limited time';
    final hours = (at.difference(now).inMinutes / 60).round();
    return hours <= 1 ? 'one hour' : '$hours hours';
  }

  @override
  Widget build(BuildContext context) {
    void close() => Navigator.of(context).maybePop();
    final who = member.name.isEmpty ? member.email : member.name;
    const tertiary = TextStyle(fontSize: 14, height: 20 / 14, color: DifyColors.textTertiary);
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
                    child: const RemixIcon('lock-password-line', size: 22, color: DifyColors.textAccent),
                  ),
                ),
              ),
              const Padding(
                padding: EdgeInsets.only(bottom: 4),
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
                child: Text(
                  'Send this link to $who (${member.email}). It sets a new password once and expires in '
                  '${validity(link, DateTime.now())}; setting the password signs $who out everywhere. Nobody else '
                  'sees the new password.',
                  key: const ValueKey('reset-link-description'),
                  style: tertiary,
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 36),
                child: InvitationLink(
                  key: const ValueKey('reset-link'),
                  value: InvitationResult(email: member.email, status: 'success', url: link.url),
                  origin: origin,
                  copy: copy,
                ),
              ),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: SizedBox(
                  width: 96,
                  child: DifyButton(
                    key: const ValueKey('reset-link-ok'),
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
