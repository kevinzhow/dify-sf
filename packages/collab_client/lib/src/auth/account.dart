/// Accounts (docs/protocol.md section 2 "Accounts", protocol 1.8): the wire models of Dify 1.17.1's community edition,
/// one workspace per server.
///
/// * [Account]: the signed-in user (`GET /v1/account`, and the `account` of every sign-in answer), with its [AccountRole].
/// * [Member]: one row of `GET /v1/workspace/members`.
/// * [AuthTokens]: an access token (60 minutes, sent as `Authorization: Bearer`) and a refresh token (30 days, rotates).
/// * [AuthResult]: what `setup`, `login` and `activate` answer: tokens plus the account.
/// * [InvitationResult], [InvitationCheck], [SetupStatus]: the invitation flow and the install state.
/// * [SystemFeatures], [ResetCodeCheck], [PasswordResetLink]: mail, forgot password and the admins' reset links.
/// * [MentionUser], [ClientIdentity]: the comments' mention candidates and the client directory (client id -> account).
library;

/// Dify's workspace roles (`TenantAccountRole`). `owner`, `admin` and `editor` may edit workflows; `owner` and `admin`
/// are privileged (members, secrets in exports); `normal` and `dataset_operator` only read (Dify's `nodesReadOnly`).
abstract final class AccountRole {
  static const owner = 'owner';
  static const admin = 'admin';
  static const editor = 'editor';
  static const normal = 'normal';
  static const datasetOperator = 'dataset_operator';

  static const all = [owner, admin, editor, normal, datasetOperator];

  /// The roles an invitation or a role change may give (everything but `owner`).
  static const assignable = [admin, editor, normal, datasetOperator];

  /// Dify's `has_edit_permission`: may write to workflows and their comments.
  static bool canEdit(String? role) => role == owner || role == admin || role == editor;

  /// Dify's `is_admin_or_owner`: may manage members and export secrets.
  static bool isPrivileged(String? role) => role == owner || role == admin;
}

/// The signed-in account (`{"id","email","name","avatar_url"?,"role","interface_language"?,"timezone"?,"created_at"}`).
final class Account {
  const Account({
    required this.id,
    required this.email,
    required this.name,
    this.avatarUrl,
    required this.role,
    this.interfaceLanguage,
    this.timezone,
    this.createdAt,
  });

  factory Account.fromJson(Object? json) {
    final m = _map(json, 'account');
    return Account(
      id: _str(m, 'id'),
      email: _str(m, 'email'),
      name: _str(m, 'name'),
      avatarUrl: m['avatar_url'] as String?,
      role: m['role'] as String? ?? AccountRole.normal,
      interfaceLanguage: m['interface_language'] as String?,
      timezone: m['timezone'] as String?,
      createdAt: _time(m['created_at']),
    );
  }

  final String id;
  final String email;
  final String name;
  final String? avatarUrl;

  /// One of [AccountRole.all].
  final String role;
  final String? interfaceLanguage;
  final String? timezone;
  final DateTime? createdAt;

  /// May edit workflows (Dify's `canEdit`; false = the editor is read-only).
  bool get canEdit => AccountRole.canEdit(role);

  /// May manage members and export secrets.
  bool get isPrivileged => AccountRole.isPrivileged(role);

  Map<String, Object?> toJson() => {
    'id': id,
    'email': email,
    'name': name,
    'avatar_url': ?avatarUrl,
    'role': role,
    'interface_language': ?interfaceLanguage,
    'timezone': ?timezone,
    'created_at': ?createdAt?.toUtc().toIso8601String(),
  };

  Account copyWith({String? name, String? role}) => Account(
    id: id,
    email: email,
    name: name ?? this.name,
    avatarUrl: avatarUrl,
    role: role ?? this.role,
    interfaceLanguage: interfaceLanguage,
    timezone: timezone,
    createdAt: createdAt,
  );

  @override
  bool operator ==(Object other) =>
      other is Account &&
      other.id == id &&
      other.email == email &&
      other.name == name &&
      other.avatarUrl == avatarUrl &&
      other.role == role &&
      other.interfaceLanguage == interfaceLanguage &&
      other.timezone == timezone;

  @override
  int get hashCode => Object.hash(id, email, name, avatarUrl, role, interfaceLanguage, timezone);

  @override
  String toString() => 'Account($email, $role)';
}

/// A workspace member (`GET /v1/workspace/members`). [status] is `active`, `pending` (invited, not activated) or `banned`.
final class Member {
  const Member({
    required this.id,
    required this.name,
    required this.email,
    this.avatarUrl,
    required this.role,
    required this.status,
    this.lastLoginAt,
    this.createdAt,
  });

  factory Member.fromJson(Object? json) {
    final m = _map(json, 'member');
    return Member(
      id: _str(m, 'id'),
      name: _str(m, 'name'),
      email: _str(m, 'email'),
      avatarUrl: m['avatar_url'] as String?,
      role: _str(m, 'role'),
      status: m['status'] as String? ?? 'active',
      lastLoginAt: _time(m['last_login_at']),
      createdAt: _time(m['created_at']),
    );
  }

  final String id;
  final String name;
  final String email;
  final String? avatarUrl;
  final String role;
  final String status;
  final DateTime? lastLoginAt;
  final DateTime? createdAt;

  bool get isPending => status == 'pending';
}

/// An access token and a refresh token.
final class AuthTokens {
  const AuthTokens({required this.accessToken, required this.refreshToken});

  factory AuthTokens.fromJson(Object? json) {
    final m = _map(json, 'token pair');
    return AuthTokens(accessToken: _str(m, 'access_token'), refreshToken: _str(m, 'refresh_token'));
  }

  final String accessToken;
  final String refreshToken;

  Map<String, Object?> toJson() => {'access_token': accessToken, 'refresh_token': refreshToken};

  @override
  bool operator ==(Object other) =>
      other is AuthTokens && other.accessToken == accessToken && other.refreshToken == refreshToken;

  @override
  int get hashCode => Object.hash(accessToken, refreshToken);

  @override
  String toString() => 'AuthTokens(...)'; // never print tokens
}

/// The answer of `setup`, `login` and `activate`.
final class AuthResult {
  const AuthResult({required this.tokens, required this.account});

  factory AuthResult.fromJson(Object? json) =>
      AuthResult(tokens: AuthTokens.fromJson(json), account: Account.fromJson(_map(json, 'sign-in')['account']));

  final AuthTokens tokens;
  final Account account;
}

/// The answers of `GET /v1/setup` (Dify's `step`): whether the workspace exists yet (Dify's install page shows while it
/// does not).
abstract final class SetupStatus {
  static const notStarted = 'not_started';
  static const finished = 'finished';
}

/// One entry of `POST /v1/workspace/members/invite-email`: [status] is `success` (with the activation [url], relative to the
/// web app: `/activate?email=...&token=...`), `already_member` or `failed` (with a [message]).
final class InvitationResult {
  const InvitationResult({required this.email, required this.status, this.url, this.message});

  factory InvitationResult.fromJson(Object? json) {
    final m = _map(json, 'invitation result');
    return InvitationResult(
      email: _str(m, 'email'),
      status: _str(m, 'status'),
      url: m['url'] as String?,
      message: m['message'] as String?,
    );
  }

  final String email;
  final String status;
  final String? url;
  final String? message;

  bool get succeeded => status == 'success';

  /// The activation token inside [url].
  String? get token {
    final u = url;
    if (u == null) return null;
    return Uri.tryParse(u)?.queryParameters['token'];
  }
}

/// `POST /v1/activate/check` (Dify's activation check: `{"is_valid", "data": {"email", "workspace_name", "account_status",
/// "requires_setup"}}`).
final class InvitationCheck {
  const InvitationCheck({
    required this.isValid,
    this.email,
    this.workspaceName,
    this.requiresSetup,
    this.accountStatus,
  });

  factory InvitationCheck.fromJson(Object? json) {
    final m = _map(json, 'activation check');
    final data = m['data'];
    final d = data is Map<String, Object?> ? data : const <String, Object?>{};
    return InvitationCheck(
      isValid: m['is_valid'] == true,
      email: d['email'] as String?,
      workspaceName: d['workspace_name'] as String?,
      requiresSetup: d['requires_setup'] as bool?,
      accountStatus: d['account_status'] as String?,
    );
  }

  final bool isValid;
  final String? email;
  final String? workspaceName;

  /// Dify's `requires_setup`: the account still needs its name and password (always true for a valid dify-sf link).
  final bool? requiresSetup;

  /// Dify's `account_status` (`pending` for a valid dify-sf link).
  final String? accountStatus;

  /// Dify's invite-settings rule: `requires_setup ?? account_status == 'pending'`.
  bool get needsSetup => requiresSetup ?? (accountStatus == null || accountStatus == 'pending');
}

/// The members of Dify's system features (`GET /v1/system-features`) the sign-in pages read. A server that does not know
/// the endpoint (older than the password reset) is [SystemFeatures.none]: no mail.
final class SystemFeatures {
  const SystemFeatures({
    this.isEmailSetup = false,
    this.enableEmailPasswordLogin = true,
    this.enableEmailCodeLogin = false,
    this.isAllowRegister = false,
  });

  factory SystemFeatures.fromJson(Object? json) {
    final m = _map(json, 'system features');
    return SystemFeatures(
      isEmailSetup: m['is_email_setup'] == true,
      enableEmailPasswordLogin: m['enable_email_password_login'] != false,
      enableEmailCodeLogin: m['enable_email_code_login'] == true,
      isAllowRegister: m['is_allow_register'] == true,
    );
  }

  static const none = SystemFeatures();

  /// Dify's `is_email_setup`: the server sends mail, so "Forgot your password?" works.
  final bool isEmailSetup;
  final bool enableEmailPasswordLogin;
  final bool enableEmailCodeLogin;
  final bool isAllowRegister;
}

/// `POST /v1/forgot-password/validity`'s answer to a right code: the token that resets the password.
final class ResetCodeCheck {
  const ResetCodeCheck({required this.isValid, required this.email, required this.token});

  factory ResetCodeCheck.fromJson(Object? json) {
    final m = _map(json, 'code check');
    return ResetCodeCheck(isValid: m['is_valid'] == true, email: _str(m, 'email'), token: _str(m, 'token'));
  }

  final bool isValid;
  final String email;
  final String token;
}

/// An admin's one-time reset link for a member (dify-sf only): [url] is relative to the web app
/// (`/reset-password/set-password?email=...&token=...`).
final class PasswordResetLink {
  const PasswordResetLink({required this.url, this.expiresAt});

  factory PasswordResetLink.fromJson(Object? json) {
    final m = _map(json, 'reset link');
    return PasswordResetLink(url: _str(m, 'url'), expiresAt: _time(m['expires_at']));
  }

  final String url;
  final DateTime? expiresAt;

  /// The link's token.
  String get token => Uri.parse(url).queryParameters['token'] ?? '';
}

/// A mention candidate (`GET /v1/docs/{doc}/comments/mention-users`): a workspace member.
final class MentionUser {
  const MentionUser({required this.id, required this.name, required this.email, this.avatarUrl, required this.role});

  factory MentionUser.fromJson(Object? json) {
    final m = _map(json, 'user');
    return MentionUser(
      id: _str(m, 'id'),
      name: _str(m, 'name'),
      email: m['email'] as String? ?? '',
      avatarUrl: m['avatar_url'] as String?,
      role: m['role'] as String? ?? '',
    );
  }

  final String id;
  final String name;
  final String email;
  final String? avatarUrl;
  final String role;
}

/// The account behind a client id (`GET /v1/docs/{doc}/clients`: `{"<client id>": {"account","name","avatar_url"?}}`).
/// Several client ids (tabs, devices) of one account are one user.
final class ClientIdentity {
  const ClientIdentity({required this.account, required this.name, this.avatarUrl});

  factory ClientIdentity.fromJson(Object? json) {
    final m = _map(json, 'client identity');
    return ClientIdentity(account: _str(m, 'account'), name: _str(m, 'name'), avatarUrl: m['avatar_url'] as String?);
  }

  final String account;
  final String name;
  final String? avatarUrl;

  Map<String, Object?> toJson() => {'account': account, 'name': name, 'avatar_url': ?avatarUrl};

  @override
  bool operator ==(Object other) =>
      other is ClientIdentity && other.account == account && other.name == name && other.avatarUrl == avatarUrl;

  @override
  int get hashCode => Object.hash(account, name, avatarUrl);
}

Map<String, Object?> _map(Object? json, String what) =>
    json is Map<String, Object?> ? json : throw FormatException('expected a $what object, got $json');

String _str(Map<String, Object?> m, String key) =>
    m[key] is String ? m[key]! as String : throw FormatException('missing or non-string "$key"');

DateTime? _time(Object? v) => v is String ? DateTime.tryParse(v)?.toUtc() : null;
