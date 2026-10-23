/// web/app/activate (Dify 1.17.1): activate/page.tsx around activateForm.tsx. An invitation link checks its token and
/// goes on to the invitation's sign-in (email prefilled); an invalid or used link says so.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../design/dify_tokens.g.dart';
import '../design/widgets/widgets.dart';
import 'auth_api.dart';
import 'auth_controller.dart';
import 'widgets/auth_widgets.dart';

class ActivatePage extends StatelessWidget {
  const ActivatePage({super.key, required this.token});
  final String token;

  @override
  Widget build(BuildContext context) => AuthPageFrame(child: ActivateForm(token: token));
}

class ActivateForm extends StatefulWidget {
  const ActivateForm({super.key, required this.token});
  final String token;

  @override
  State<ActivateForm> createState() => _ActivateFormState();
}

class _ActivateFormState extends State<ActivateForm> {
  InvitationCheck? _check;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  Future<void> _run() async {
    final auth = AuthScope.read(context);
    if (auth == null) return;
    InvitationCheck r;
    try {
      r = await auth.checkInvitation(widget.token);
    } on Object {
      r = const InvitationCheck(isValid: false);
    }
    if (!mounted) return;
    setState(() => _check = r);
    if (r.isValid) auth.go(SignInRoute(inviteToken: widget.token, email: r.email));
  }

  @override
  Widget build(BuildContext context) {
    final c = _check;
    final title = c?.isValid == false ? tLogin(context, 'invalid') : tLogin(context, 'setYourAccount');
    final md = MediaQuery.sizeOf(context).width >= 768;
    return DifyDocumentTitle(
      title: title,
      // `flex w-full grow flex-col items-center justify-center px-6 md:px-27`.
      child: Center(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: md ? 108 : 24),
          child: c == null
              ? const DifyLoading()
              : c.isValid
              ? const SizedBox.shrink()
              : SizedBox(
                  width: md ? 400 : double.infinity,
                  child: InvalidInvitation(
                    large: true,
                    onExplore: () => AuthScope.read(context)?.go(const SignInRoute()),
                  ),
                ),
        ),
      ),
    );
  }
}

/// The expired link: the shrug in a card, "The link has expired" and the "Explore Dify" button (activateForm's
/// [large] variant: `h-20 w-20 rounded-[20px] text-[40px]`, an `h2` of 32 px bold; invite-settings': `size-14
/// rounded-2xl text-2xl`, `title-4xl-semi-bold`). Dify's button opens dify.ai; dify-sf's goes to the sign-in page.
class InvalidInvitation extends StatelessWidget {
  const InvalidInvitation({super.key, this.large = false, required this.onExplore});
  final bool large;
  final VoidCallback onExplore;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: Container(
          width: large ? 80 : 56,
          height: large ? 80 : 56,
          margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            color: large ? DifyColors.componentsOptionCardOptionBg : null,
            border: Border.all(color: large ? DifyColors.dividerRegular : DifyColors.componentsPanelBorderSubtle),
            borderRadius: BorderRadius.circular(large ? 20 : 16),
            boxShadow: DifyShadows.lg,
          ),
          alignment: Alignment.center,
          child: DifyTextLine(
            '🤷‍♂️',
            // `text-[40px] font-bold` / `text-2xl font-bold`
            style: (large ? DifyTw.text40Bold : DifyTw.text2xlBold).style,
          ),
        ),
      ),
      AuthHeading(
        tLogin(context, 'invalid'),
        style: large
            ? difyTextStyle(DifyTw.text32BoldLeading48, DifyColors.textPrimary)
            : difyTextStyle(DifyType.title4xlSemiBold, DifyColors.textPrimary),
      ),
      const SizedBox(height: 24),
      DifyButton(
        key: const ValueKey('explore-dify'),
        variant: DifyButtonVariant.primary,
        onPressed: onExplore,
        child: DifyTextLine(tLogin(context, 'explore'), style: DifyTw.textSm.style), // `text-sm!`
      ),
    ],
  );
}
