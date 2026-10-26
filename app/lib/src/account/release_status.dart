/// dify-sf extension: visible client/server identities and advertised capability.
library;

import 'package:collab_client/collab_client.dart';
import 'package:flutter/widgets.dart';

import '../design/dify_tokens.g.dart';
import '../design/widgets/widgets.dart';
import '../i18n/dify_i18n.dart';

const clientBuildRevision = String.fromEnvironment('DIFY_BUILD_REVISION', defaultValue: 'development');

class ReleaseStatus extends StatelessWidget {
  const ReleaseStatus({super.key, required this.features});
  final SystemFeatures features;
  @override
  Widget build(BuildContext context) {
    String tr(String key) => DifyI18n.tr('common', 'release.$key');
    final build = features.build;
    final revision = RegExp(r'^[a-f0-9]{40}$').hasMatch(clientBuildRevision) ? clientBuildRevision : 'development';
    String advertised(bool enabled) => tr(enabled ? 'enabled' : 'disabled');
    Widget row(String label, String value) => Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(
        spacing: 12,
        runSpacing: 4,
        children: [
          DifyTextLine(label, style: difyTextStyle(DifyType.systemSmMedium, DifyColors.textSecondary)),
          DifyTextLine(value, style: difyTextStyle(DifyType.systemSmRegular, DifyColors.textTertiary)),
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 32),
      child: Column(
        key: const ValueKey('release-status'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DifyTextLine(
            'dify-sf · ${tr('title')}',
            style: difyTextStyle(DifyType.systemMdMedium, DifyColors.textPrimary),
          ),
          row(tr('client'), revision),
          row(tr('server'), build?.revision ?? tr('unknown')),
          row(tr('workflow'), build?.workflowProtocol.isNotEmpty == true ? build!.workflowProtocol : tr('unknown')),
          row(tr('agentProtocol'), build?.agentProtocol.isNotEmpty == true ? build!.agentProtocol : tr('unknown')),
          row(tr('agent'), advertised(features.inlineAgent)),
          row(tr('shell'), advertised(features.inlineAgentShell)),
          row(tr('mail'), advertised(features.isEmailSetup)),
        ],
      ),
    );
  }
}
