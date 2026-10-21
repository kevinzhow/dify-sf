/// The accounts API as the app uses it: collab_client's (protocol 1.8, docs/protocol.md "Accounts"), plus the app's own
/// helpers.
library;

import 'package:collab_client/collab_client.dart';

export 'package:collab_client/collab_client.dart'
    show
        Account,
        AccountRole,
        AuthApi,
        AuthResult,
        AuthSession,
        AuthTokens,
        HttpAuthApi,
        InvitationCheck,
        InvitationResult,
        Member,
        MemoryTokenStore,
        PasswordResetLink,
        ResetCodeCheck,
        SetupStatus,
        SystemFeatures,
        TokenStore,
        TransportException;

/// The server refused the credentials or the session is over (401).
bool isUnauthorized(Object e) => e is TransportException && e.statusCode == 401;

/// No server (the in-memory demo): every call fails as if the server were unreachable.
class OfflineAuthApi implements AuthApi {
  const OfflineAuthApi();

  static Never _offline() => throw const TransportException('no server');

  @override
  Future<String> setupStatus() async => _offline();

  @override
  Future<AuthResult> setup({
    required String email,
    required String name,
    required String password,
    String? language,
    String? timezone,
  }) async => _offline();

  @override
  Future<AuthResult> login({
    required String email,
    required String password,
    bool rememberMe = false,
    String? inviteToken,
  }) async => _offline();

  @override
  Future<AuthTokens> refresh(String refreshToken) async => _offline();

  @override
  Future<void> logout(String accessToken) async {}

  @override
  Future<Account> account(String accessToken) async => _offline();

  @override
  Future<Account> updateName(String accessToken, String name) async => _offline();

  @override
  Future<void> updatePassword(
    String accessToken, {
    required String password,
    required String newPassword,
    required String repeatNewPassword,
  }) async => _offline();

  @override
  Future<Account> updateProfile(
    String accessToken, {
    String? name,
    String? interfaceLanguage,
    String? timezone,
    String? avatar,
  }) async => _offline();

  @override
  Future<String> sendChangeEmailCode(
    String accessToken, {
    required String email,
    String? language,
    String? phase,
    String? token,
  }) async => _offline();

  @override
  Future<ResetCodeCheck> checkChangeEmailCode(
    String accessToken, {
    required String email,
    required String code,
    required String token,
  }) async => _offline();

  @override
  Future<Account> changeEmail(String accessToken, {required String newEmail, required String token}) async =>
      _offline();

  @override
  Future<void> checkEmailUnique(String accessToken, String email) async => _offline();

  @override
  Future<List<Member>> members(String accessToken) async => _offline();

  @override
  Future<List<InvitationResult>> invite(
    String accessToken, {
    required List<String> emails,
    required String role,
  }) async => _offline();

  @override
  Future<void> updateRole(String accessToken, String memberId, String role) async => _offline();

  @override
  Future<void> removeMember(String accessToken, String memberId) async => _offline();

  @override
  Future<InvitationCheck> checkInvitation(String token) async => _offline();

  @override
  Future<AuthResult> activate({
    required String token,
    required String name,
    required String password,
    String? interfaceLanguage,
    String? timezone,
  }) async => _offline();

  @override
  Future<SystemFeatures> systemFeatures() async => SystemFeatures.none;

  @override
  Future<String> sendResetCode({required String email, String? language}) async => _offline();

  @override
  Future<ResetCodeCheck> checkResetCode({required String email, required String code, required String token}) async =>
      _offline();

  @override
  Future<void> resetPassword({
    required String token,
    required String newPassword,
    required String passwordConfirm,
  }) async => _offline();

  @override
  Future<PasswordResetLink> resetPasswordLink(String accessToken, String memberId) async => _offline();
}
