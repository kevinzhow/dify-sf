/// The node panel's Last Run tab (nodes/_base/components/workflow-panel/last-run/index.tsx, no-data.tsx).
library;

import 'package:flutter/widgets.dart';

import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';

/// LastRun: dify-sf has no single-run engine or run history yet, so there is never a last run to fetch and the tab
/// is Dify's no-data state: the 32 px clock-play icon, "The results of the last run will be displayed here" and, when
/// the node can run alone ([canSingleRun]), a small "Run this node" button calling [onSingleRun].
class LastRun extends StatelessWidget {
  const LastRun({super.key, required this.canSingleRun, required this.onSingleRun});

  final bool canSingleRun;
  final VoidCallback onSingleRun;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        DifyIcon('vender/line/time/clock-play', size: 32, color: DifyColors.textQuaternary),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: DifyText(
            DifyI18n.tr('workflow', 'debug.noData.description'),
            DifyType.systemXsRegular,
            color: DifyColors.textTertiary,
            align: TextAlign.center,
            maxLines: null,
          ),
        ),
        if (canSingleRun)
          DifyButton(
            size: DifyButtonSize.small,
            onPressed: onSingleRun,
            leading: const RemixIcon('play-line', size: 14),
            child: Text(DifyI18n.tr('workflow', 'debug.noData.runThisNode')),
          ),
      ],
    ),
  );
}
