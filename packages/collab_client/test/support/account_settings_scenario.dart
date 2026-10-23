import 'package:collab_client/collab_client.dart';
import 'package:test/test.dart';

Matcher _code(String code, int status) =>
    isA<TransportException>().having((e) => e.code, 'code', code).having((e) => e.statusCode, 'statusCode', status);

/// What the account page and Preferences call must do, whoever answers them (the in-memory fake over HTTP or a real
/// server, protocol 1.12).
///
/// [me] is a member of its own (the scenario changes its profile and, with mail, its email); [other] another member.
/// [codeFor] reads the last code mailed to an address; null when the test cannot read mail (a real server): then the
/// change of email is checked as far as a server with or without mail goes without the codes. [unique] makes the new
/// address unique on a shared server.
Future<void> accountSettingsScenario({
  required AuthSession me,
  required AuthSession other,
  required String unique,
  String? Function(String to)? codeFor,
}) async {
  // ---- the profile (Preferences: language and time zone; the account page: the name) ----
  final tz = await me.updateProfile(timezone: 'Asia/Tokyo');
  expect((tz.timezone, me.currentAccount!.timezone), ('Asia/Tokyo', 'Asia/Tokyo'));
  final lang = await me.updateProfile(interfaceLanguage: 'zh-Hans');
  expect((lang.interfaceLanguage, lang.timezone), ('zh-Hans', 'Asia/Tokyo'));
  final both = await me.updateProfile(name: 'Renamed Member', timezone: 'Europe/Berlin');
  expect((both.name, both.timezone, both.interfaceLanguage), ('Renamed Member', 'Europe/Berlin', 'zh-Hans'));
  final again = await me.account();
  expect((again.name, again.timezone, again.interfaceLanguage), ('Renamed Member', 'Europe/Berlin', 'zh-Hans'));
  await expectLater(me.updateProfile(interfaceLanguage: 'en'), throwsA(_code('bad_request', 400)));
  await expectLater(me.updateProfile(timezone: 'Mars/Olympus'), throwsA(_code('bad_request', 400)));
  await expectLater(me.updateProfile(name: 'Ab'), throwsA(_code('bad_request', 400)));
  expect((await me.account()).timezone, 'Europe/Berlin');
  // Another member's profile is its own.
  expect((await other.account()).timezone, isNot('Europe/Berlin'));

  // ---- changing the email ----
  final mine = me.currentAccount!.email, theirs = other.currentAccount!.email;
  await expectLater(me.checkEmailUnique(theirs.toUpperCase()), throwsA(_code('email_already_in_use', 400)));
  final fresh = 'changed-$unique@example.com';
  await me.checkEmailUnique(fresh);
  final features = await me.api.systemFeatures();
  if (!features.enableChangeEmail) {
    await expectLater(me.sendChangeEmailCode(email: mine), throwsA(_code('mail_not_configured', 400)));
    return;
  }
  await expectLater(me.sendChangeEmailCode(email: theirs), throwsA(_code('invalid_email', 400)));
  final first = await me.sendChangeEmailCode(email: mine.toUpperCase(), phase: 'old_email');
  expect(first, isNotEmpty);
  // Only the token of a right code for the old address opens the second step.
  await expectLater(
    me.sendChangeEmailCode(email: fresh, phase: 'new_email', token: first),
    throwsA(_code('invalid_token', 400)),
  );
  if (codeFor == null) return;
  final oldCode = codeFor(mine)!;
  await expectLater(
    me.checkChangeEmailCode(email: mine, code: oldCode == '000000' ? '111111' : '000000', token: first),
    throwsA(_code('email_code_error', 400)),
  );
  await expectLater(
    other.checkChangeEmailCode(email: mine, code: oldCode, token: first),
    throwsA(_code('invalid_token', 400)),
  );
  final verifiedOld = await me.checkChangeEmailCode(email: mine, code: oldCode, token: first);
  expect((verifiedOld.isValid, verifiedOld.email), (true, mine.toLowerCase()));
  final second = await me.sendChangeEmailCode(email: fresh, phase: 'new_email', token: verifiedOld.token);
  final verifiedNew = await me.checkChangeEmailCode(email: fresh, code: codeFor(fresh)!, token: second);
  await expectLater(me.changeEmail(newEmail: theirs, token: verifiedNew.token), throwsA(_code('invalid_token', 400)));
  final changed = await me.changeEmail(newEmail: fresh, token: verifiedNew.token);
  expect((changed.email, me.currentAccount!.email), (fresh, fresh));
  await expectLater(me.changeEmail(newEmail: fresh, token: verifiedNew.token), throwsA(_code('invalid_token', 400)));
  await expectLater(me.checkEmailUnique(fresh), throwsA(_code('email_already_in_use', 400)));
}
