// dify-spec: web/app/signin/__tests__/layout.spec.tsx
// dify-spec: web/app/signin/__tests__/page.spec.tsx
import 'package:dify_sf_app/src/auth/signin_page.dart';
import 'package:dify_sf_app/src/auth/widgets/auth_widgets.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/auth_fakes.dart';
import 'harness.dart';

void main() {
  group('SignInLayout landmarks', () {
    testWidgets('separates the site header, sign-in content, and copyright', (t) async {
      await renderAuth(
        t,
        await authOn(RecordingAuthApi()),
        const SignInLayout(child: AuthHeading('Sign in', style: TextStyle())),
      );
      final header = t.getRect(find.byType(SignInHeader));
      final heading = t.getRect(find.text('Sign in'));
      final footer = t.getRect(find.textContaining('LangGenius'));
      // The banner above the main content, the content-info below it; none inside another.
      expect(header.bottom, lessThanOrEqualTo(heading.top));
      expect(heading.bottom, lessThanOrEqualTo(footer.top));
      expect(find.descendant(of: find.byType(SignInHeader), matching: find.text('Sign in')), findsNothing);
      expect(find.descendant(of: find.byType(SignInHeader), matching: find.textContaining('LangGenius')), findsNothing);
    });
  });

  group('SignIn', () {
    testWidgets('renders the sign-in form by default', (t) async {
      await renderAuth(t, await authOn(RecordingAuthApi()), const SignInPage());
      expect(find.byType(NormalForm), findsOneWidget);
      expect(find.byType(MailAndPasswordAuth), findsOneWidget);
    });
  });
}
