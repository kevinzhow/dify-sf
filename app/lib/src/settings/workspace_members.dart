/// The workspace's members as the settings use them (protocol 1.8 "Accounts": `GET /v1/workspace/members`,
/// `invite-email`, `update-role`, `DELETE`), and Dify 1.17.1's role model with enterprise RBAC off (the community
/// edition): every member has one built-in role, listed by `/workspaces/current/rbac/roles` as `{id: name, name}`
/// (controllers/console/workspace/rbac.py `_legacy_workspace_roles`).
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../auth/auth_api.dart';
import '../auth/auth_controller.dart';

/// One workspace role (models/access-control.ts `Role`, the fields the members page reads).
@immutable
class WorkspaceRole {
  const WorkspaceRole({
    required this.id,
    required this.name,
    this.description = '',
    this.isBuiltin = true,
    this.permissionKeys = const [],
    this.roleTag = '',
  });

  final String id;
  final String name;
  final String description;
  final bool isBuiltin;
  final List<String> permissionKeys;

  /// `owner` for the owner's role.
  final String roleTag;

  @override
  bool operator ==(Object other) => other is WorkspaceRole && other.id == id && other.name == name;

  @override
  int get hashCode => Object.hash(id, name);

  @override
  String toString() => 'WorkspaceRole($id)';
}

/// The Dify permission keys a role has in dify-sf. Dify projects its legacy roles onto its whole permission catalog
/// (apps, knowledge, plugins, ...); dify-sf enforces only these (docs/protocol.md "Accounts and roles", "Model
/// providers"), in Dify's order (rbac_service.py `_LEGACY_WORKSPACE_*_KEYS`): owners and admins manage members and the
/// model providers (credentials, model settings, default models), editors and normal members use the configured
/// credentials, editors and up edit workflows (and import them), everybody views them.
const _difySfPermissionKeys = <String, List<String>>{
  AccountRole.owner: [
    'workspace.member.manage',
    'plugin.plugin_preferences',
    'plugin.model_config',
    'credential.use',
    'credential.create',
    'credential.manage',
    'app.acl.view_layout',
    'app.acl.edit',
    'app.acl.import_export_dsl',
  ],
  AccountRole.admin: [
    'workspace.member.manage',
    'plugin.plugin_preferences',
    'plugin.model_config',
    'credential.use',
    'credential.create',
    'credential.manage',
    'app.acl.view_layout',
    'app.acl.edit',
    'app.acl.import_export_dsl',
  ],
  AccountRole.editor: ['credential.use', 'app.acl.view_layout', 'app.acl.edit', 'app.acl.import_export_dsl'],
  AccountRole.normal: ['credential.use', 'app.acl.view_layout'],
  AccountRole.datasetOperator: ['app.acl.view_layout'],
};

/// The permission keys of [role] (empty for an unknown role).
List<String> permissionKeysOf(String? role) => _difySfPermissionKeys[role] ?? const [];

/// utils/permission.ts `hasPermission`.
bool hasPermission(String? role, String key) => permissionKeysOf(role).contains(key);

/// A member's role in the RBAC shape (rbac_service.py `_legacy_member_roles_response`): id and name are the role,
/// `role_tag` is `owner` for the owner.
WorkspaceRole legacyRoleOf(String role) => WorkspaceRole(
  id: role,
  name: role,
  permissionKeys: permissionKeysOf(role),
  roleTag: role == AccountRole.owner ? 'owner' : role,
);

/// `_legacy_workspace_roles`: owner (only with [includeOwner]), admin, editor, normal and dataset_operator (only with
/// Dify's `DATASET_OPERATOR_ENABLED`, off by default, so not offered).
List<WorkspaceRole> legacyWorkspaceRoles({bool includeOwner = false, bool datasetOperatorEnabled = false}) => [
  for (final r in AccountRole.all)
    if ((includeOwner || r != AccountRole.owner) && (datasetOperatorEnabled || r != AccountRole.datasetOperator))
      WorkspaceRole(
        id: r,
        name: r,
        permissionKeys: permissionKeysOf(r),
        roleTag: r == AccountRole.owner ? 'owner' : '',
      ),
];

/// The `members.*Tip` key describing a legacy role, by its name or id (role-selector.tsx
/// `getLegacyRoleDescriptionKey`).
String? legacyRoleDescriptionKey(WorkspaceRole role) {
  const keys = {
    'admin': 'members.adminTip',
    'editor': 'members.editorTip',
    'normal': 'members.normalTip',
    'dataset_operator': 'members.datasetOperatorTip',
  };
  for (final c in [role.name, role.id]) {
    final k = keys[c.trim().toLowerCase()];
    if (k != null) return k;
  }
  return null;
}

/// The workspace's name: Dify names the install's workspace `"<owner name>'s Workspace"` (the server answers the same
/// in invitation checks).
String workspaceNameOf(String ownerName) => "$ownerName's Workspace";

/// The members of the signed-in workspace (Dify's `useMembers` query plus the member mutations), through the
/// session of [auth] (Bearer token, one refresh after a 401).
class WorkspaceMembers extends ChangeNotifier {
  WorkspaceMembers(this.auth);

  final AuthController auth;

  List<Member>? _members;
  Object? _error;
  int _seq = 0, _inflight = 0;
  bool _disposed = false;

  /// The members, owner first (empty until loaded).
  List<Member> get members => _members ?? const [];
  bool get loaded => _members != null;
  bool get loading => _inflight > 0;
  Object? get error => _error;

  /// The signed-in account.
  Account? get me => auth.account;

  /// The signed-in account's row, if loaded.
  Member? get meAsMember {
    final email = me?.email.toLowerCase();
    if (email == null) return null;
    for (final m in members) {
      if (m.email.toLowerCase() == email) return m;
    }
    return null;
  }

  /// The signed-in account's role: as the member list says (it may have changed since the sign-in), else the
  /// account's.
  String? get myRole => meAsMember?.role ?? me?.role;

  /// `hasPermission(workspacePermissionKeys, 'workspace.member.manage')`: owners and admins.
  bool get canManage => hasPermission(myRole, 'workspace.member.manage');

  bool get isOwner => myRole == AccountRole.owner;

  Member? get owner {
    for (final m in members) {
      if (m.role == AccountRole.owner) return m;
    }
    return null;
  }

  /// The workspace's name, once known: from the owner's name (the signed-in owner's, when the list cannot be read).
  String? get workspaceName {
    final o = owner;
    if (o != null) return workspaceNameOf(o.name);
    final a = me;
    if (_error != null && a != null && a.role == AccountRole.owner) return workspaceNameOf(a.name);
    return null;
  }

  /// `GET /v1/workspace/members`. Requests may overlap (a refresh after a change); the latest one's answer wins.
  Future<void> refresh() async {
    final n = ++_seq;
    // No notification yet: callers start refreshes while building (a page's initState).
    _inflight++;
    try {
      final list = await auth.session.members();
      if (n == _seq) {
        _members = list;
        _error = null;
      }
    } on Object catch (e) {
      if (n == _seq) _error = e;
    } finally {
      _inflight--;
      _notify();
    }
  }

  /// `POST /v1/workspace/members/invite-email`; refreshes the list.
  Future<List<InvitationResult>> invite({required List<String> emails, required String role}) async {
    final results = await auth.session.invite(emails: emails, role: role);
    unawaited(refresh());
    return results;
  }

  /// `PUT /v1/workspace/members/{id}/update-role`; refreshes the list.
  Future<void> updateRole(String memberId, String role) async {
    await auth.session.updateRole(memberId, role);
    await refresh();
  }

  /// `DELETE /v1/workspace/members/{id}`; refreshes the list.
  Future<void> remove(String memberId) async {
    await auth.session.removeMember(memberId);
    await refresh();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
