/// Dify's form rules (web/config/index.ts) and helpers of the sign-in pages.
library;

/// `emailRegex` (`/^[\w.!#$%&'*+\-/=?^{|}~]+@([\w-]+\.)+[\w-]{2,}$/m`).
final emailRegex = RegExp(r"^[\w.!#$%&'*+\-/=?^{|}~]+@([\w-]+\.)+[\w-]{2,}$", multiLine: true);

/// `validPassword` (`/^(?=.*[a-z])(?=.*\d)\S{8,}$/i`): a letter, a digit, at least 8 characters, no whitespace.
final validPassword = RegExp(r'^(?=.*[a-z])(?=.*\d)\S{8,}$', caseSensitive: false);

/// signin/utils/invitation-account.ts: the invitation is for the signed-in account (emails compared
/// trimmed and case-insensitively; false when either is missing).
bool isInvitationForAccount(String? invitationEmail, String? accountEmail) {
  if (invitationEmail == null || invitationEmail.isEmpty || accountEmail == null || accountEmail.isEmpty) return false;
  return invitationEmail.trim().toLowerCase() == accountEmail.trim().toLowerCase();
}

/// zod 4's `z.email()` (the install form's email check).
final zodEmailRegex = RegExp(
  r"^(?!\.)(?!.*\.\.)([A-Za-z0-9_'+\-\.]*)[A-Za-z0-9_+-]@([A-Za-z0-9][A-Za-z0-9\-]*\.)+[A-Za-z]{2,}$",
);

/// constants/link.ts `LICENSE_LINK`.
const difyLicenseLink = 'https://github.com/langgenius/dify?tab=License-1-ov-file#readme';
