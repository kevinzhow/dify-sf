/// invite-modal/email-recipients.ts and invite-error.ts: parsing the invitation form's recipients and reading the
/// server's invitation error codes.
library;

import 'package:flutter/foundation.dart';

import '../../auth/auth_api.dart' show TransportException;

/// One recipient: the normalised address and whether a browser's `<input type="email">` accepts it.
@immutable
class EmailRecipient {
  const EmailRecipient(this.value, {required this.isValid});

  final String value;
  final bool isValid;

  @override
  bool operator ==(Object other) => other is EmailRecipient && other.value == value && other.isValid == isValid;

  @override
  int get hashCode => Object.hash(value, isValid);

  @override
  String toString() => 'EmailRecipient($value, ${isValid ? 'valid' : 'invalid'})';
}

/// `EMAIL_DELIMITER_PATTERN`: commas, semicolons, line breaks and tabs (not spaces).
final emailDelimiterPattern = RegExp(r'[,;\r\n\t]+');

/// The HTML standard's valid e-mail address (what `input.validity.valid` checks for `type="email"`): no dotted domain
/// required.
final _htmlEmail = RegExp(
  r"^[a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$",
);

bool isEmailValid(String value) => _htmlEmail.hasMatch(value);

/// `createEmailRecipient`: trimmed, lower-cased.
EmailRecipient createEmailRecipient(String input) {
  final value = input.trim().toLowerCase();
  return EmailRecipient(value, isValid: value.isNotEmpty && isEmailValid(value));
}

/// `hasEmailDelimiter`: whether [value] is a batch (a paste that becomes several recipients).
bool hasEmailDelimiter(String value) => emailDelimiterPattern.hasMatch(value);

/// `mergeEmailRecipients`: [recipients] followed by the non-empty entries of [input] not already present, in order.
List<EmailRecipient> mergeEmailRecipients(List<EmailRecipient> recipients, String input) {
  final next = [...recipients];
  final existing = {for (final r in recipients) r.value};
  for (final part in input.split(emailDelimiterPattern)) {
    final r = createEmailRecipient(part);
    if (r.value.isEmpty || !existing.add(r.value)) continue;
    next.add(r);
  }
  return next;
}

/// The documented invitation error codes (`MemberInviteErrorResponse['code']`).
const inviteErrorCodes = {'invalid_param', 'invalid_role', 'limit_exceeded'};

/// `getInviteErrorCode`: the server's error code when it is a documented invitation error, else null.
String? inviteErrorCode(Object error) {
  final code = error is TransportException ? error.code : null;
  return code != null && inviteErrorCodes.contains(code) ? code : null;
}
