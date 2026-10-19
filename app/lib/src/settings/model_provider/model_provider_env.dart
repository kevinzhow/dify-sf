/// What the model provider settings (Dify's model-provider-page) read besides the provider in hand: the workspace's
/// models ([WorkspaceModels], Dify's react-query caches), the signed-in member's permission keys (Dify's
/// `workspacePermissionKeysAtom`, from the role as dify-sf's server enforces it), the system features the page looks
/// at, and the language texts are shown in.
library;

import 'package:flutter/widgets.dart';

import '../../design/widgets/toast.dart';
import '../../workflow/workspace_models.dart';
import '../workspace_members.dart' show permissionKeysOf;

/// See the library comment.
@immutable
class ModelProviderEnv {
  const ModelProviderEnv({
    required this.models,
    this.permissionKeys = const [],
    this.rbacEnabled = false,
    this.deploymentEdition = 'COMMUNITY',
    this.enableMarketplace = false,
  });

  /// The env of a member with [role].
  factory ModelProviderEnv.forRole(WorkspaceModels models, String? role) =>
      ModelProviderEnv(models: models, permissionKeys: permissionKeysOf(role));

  final WorkspaceModels models;
  final List<String> permissionKeys;

  /// System features: `rbac_enabled` (off: dify-sf has no RBAC), `deployment_edition` (dify-sf is self-hosted) and
  /// `enable_marketplace` (no plugins).
  final bool rbacEnabled;
  final String deploymentEdition;
  final bool enableMarketplace;

  bool has(String key) => permissionKeys.contains(key);

  /// usePluginSettingsAccess / `plugin.plugin_preferences`: model lists, enable / disable, default models.
  bool get canSetPluginPreferences => has('plugin.plugin_preferences');

  /// `plugin.model_config`: custom models and the system default models.
  bool get canConfigureModels => has('plugin.model_config');

  /// useCredentialPermissions.
  bool get canUseCredential => has('credential.use');
  bool get canCreateCredential => has('credential.create');
  bool get canManageCredential => has('credential.manage');

  String get language => models.language;

  @override
  bool operator ==(Object other) =>
      other is ModelProviderEnv &&
      other.models == models &&
      _sameKeys(other.permissionKeys, permissionKeys) &&
      other.rbacEnabled == rbacEnabled &&
      other.deploymentEdition == deploymentEdition &&
      other.enableMarketplace == enableMarketplace;

  static bool _sameKeys(List<String> a, List<String> b) =>
      a.length == b.length && [for (var i = 0; i < a.length; i++) a[i] == b[i]].every((x) => x);

  @override
  int get hashCode => Object.hash(models, Object.hashAll(permissionKeys), rbacEnabled, deploymentEdition);
}

/// Hands the [ModelProviderEnv] to the settings below it (dialogs are routes: they hand it on themselves).
class ModelProviderScope extends InheritedWidget {
  const ModelProviderScope({super.key, required this.env, required super.child});

  final ModelProviderEnv env;

  static ModelProviderEnv of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<ModelProviderScope>();
    assert(scope != null, 'No ModelProviderScope above this widget');
    return scope!.env;
  }

  static ModelProviderEnv? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ModelProviderScope>()?.env;

  @override
  bool updateShouldNotify(ModelProviderScope oldWidget) => env != oldWidget.env;
}

/// Runs a request the way Dify's service layer does: a failure toasts the server's message and is rethrown.
Future<T> withRequestToast<T>(Future<T> Function() request) async {
  try {
    return await request();
  } on Object catch (e) {
    toast.error(apiErrorMessage(e));
    rethrow;
  }
}
