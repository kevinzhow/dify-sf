/// The data source's authorization in the panel's tab row (plugins/plugin-auth/plugin-auth-in-datasource-node.tsx,
/// authorized-in-data-source-node.tsx, as workflow-panel/index.tsx places them).
library;

import 'package:flutter/widgets.dart';

import '../../../../../design/dify_icon.dart';
import '../../../../../design/dify_tokens.g.dart';
import '../../../../../design/widgets/widgets.dart';
import '../../../../../i18n/dify_i18n.dart';
import '../../../node_panel_bodies.dart';
import 'data_source_default.dart';
import 'data_source_host.dart';

/// The tab row of a data source's panel, null when Dify shows the plain row (a local file, or a data source not in
/// the host's list): not authorized, a full-width primary "Connect" instead of the tabs; authorized, [tabs] with the
/// "Authorizations" button on the right. The shell uses this for `datasource` nodes.
Widget? dataSourceTabsRow(BuildContext context, NodePanelProps props, Widget tabs) {
  final data = props.data;
  if (data['provider_type'] == localFileProviderType) return null;
  final host = DataSourceHost.maybeOf(context);
  final ds = findDataSource(host?.dataSourceList, data);
  if (ds == null) return null;
  return PluginAuthInDataSourceNode(
    isAuthorized: ds['is_authorized'] == true,
    onJumpToDataSourcePage: host?.onJumpToDataSourcePage,
    child: Padding(
      padding: const EdgeInsets.only(left: 16, right: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(child: tabs),
          AuthorizedInDataSourceNode(authorizationsNum: 3, onJumpToDataSourcePage: host?.onJumpToDataSourcePage),
        ],
      ),
    ),
  );
}

/// PluginAuthInDataSourceNode: [child] when authorized, else the "Connect" button (`px-4 pb-2`).
class PluginAuthInDataSourceNode extends StatelessWidget {
  const PluginAuthInDataSourceNode({
    super.key,
    required this.isAuthorized,
    required this.child,
    this.onJumpToDataSourcePage,
  });
  final bool isAuthorized;
  final Widget child;
  final VoidCallback? onJumpToDataSourcePage;

  @override
  Widget build(BuildContext context) {
    if (isAuthorized) return child;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: DifyButton(
        variant: DifyButtonVariant.primary,
        onPressed: onJumpToDataSourcePage,
        leading: const RemixIcon('add-line', size: 16),
        child: Text(DifyI18n.tr('common', 'integrations.connect')),
      ),
    );
  }
}

/// AuthorizedInDataSourceNode: a small button with a success dot, "Authorization(s)" and the equalizer icon.
class AuthorizedInDataSourceNode extends StatelessWidget {
  const AuthorizedInDataSourceNode({super.key, required this.authorizationsNum, this.onJumpToDataSourcePage});
  final int authorizationsNum;
  final VoidCallback? onJumpToDataSourcePage;

  @override
  Widget build(BuildContext context) => DifyButton(
    size: DifyButtonSize.small,
    onPressed: onJumpToDataSourcePage,
    leading: Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        color: DifyColors.componentsBadgeStatusLightSuccessBg,
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: DifyColors.componentsBadgeStatusLightSuccessBorderInner),
        boxShadow: [
          BoxShadow(color: DifyColors.componentsBadgeStatusLightSuccessHalo, offset: Offset(0, 2), blurRadius: 6),
          BoxShadow(color: DifyColors.componentsBadgeStatusLightBorderOuter, spreadRadius: 1),
        ],
      ),
    ),
    trailing: RemixIcon('equalizer-2-line', size: 14, color: DifyColors.componentsButtonGhostText),
    child: Text(DifyI18n.tr('plugin', authorizationsNum > 1 ? 'auth.authorizations' : 'auth.authorization')),
  );
}
