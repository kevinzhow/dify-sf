import 'package:collab_client/collab_client.dart';
import 'package:flutter/widgets.dart';

import '../i18n/dify_i18n.dart';
import '../design/css_metrics.dart';
import '../design/dify_tokens.g.dart';
import 'card_kit.dart';

/// The rows BaseNode adds under the body of nodes that can retry or handle errors (retry-on-node.tsx,
/// error-handle-on-node.tsx): "Retry n times on failure" and "On Failure" with the strategy (the fail branch has
/// its own source handle on that row).
abstract final class NodeExtras {
  static const failBranch = 'fail-branch';

  // utils/node.ts hasRetryNode, utils/workflow.ts hasErrorHandleNode.
  static const _retryTypes = {'llm', 'tool', 'http-request', 'code'};
  static const _errorTypes = {'llm', 'tool', 'http-request', 'code', 'agent', 'agent-v2'};

  static int? _retries(Node n) {
    if (!_retryTypes.contains(n.type)) return null;
    final c = n.config['retry_config'];
    if (c is! VMap) return null;
    if (c.entries['retry_enabled'] is! VBool || !(c.entries['retry_enabled']! as VBool).value) {
      return null;
    }
    return switch (c.entries['max_retries']) {
      VInt(:final value) => value,
      VDouble(:final value) => value.round(),
      _ => 0,
    };
  }

  static String? _strategy(Node n) {
    if (!_errorTypes.contains(n.type)) return null;
    return switch (n.config['error_strategy']) {
      VString(:final value) when value == 'default-value' || value == failBranch => value,
      _ => null,
    };
  }

  // Retry: mb-1, py-1 around a 16 px line, 0.5 px border (as Chrome snaps it). Error handling: pt-1, a 24 px row, pb-2.
  static double get _retryHeight => 2 * Css.hairline + 4 + 16 + 4 + 4;
  static const _errorHeight = 4 + 24 + 8.0;

  static double height(Node n) => (_retries(n) != null ? _retryHeight : 0) + (_strategy(n) != null ? _errorHeight : 0);

  /// The fail branch row's middle, from the top of these rows; null without a fail branch.
  static double? failBranchY(Node n) =>
      _strategy(n) == failBranch ? (_retries(n) != null ? _retryHeight : 0) + 4 + 12 : null;

  static Widget build(Node n) {
    final retries = _retries(n), strategy = _strategy(n);
    if (retries == null && strategy == null) return const SizedBox.shrink();
    final box = BoxDecoration(
      color: DifyColors.workflowBlockParmaBg,
      borderRadius: BorderRadius.circular(DifyRadius.md),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (retries != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 4),
              decoration: box.copyWith(
                border: Border.all(color: const Color(0x00000000), width: Css.hairline),
              ),
              child: DifyText(
                DifyI18n.tr('workflow', 'nodes.common.retry.retryTimes', {'times': retries}),
                DifyType.systemXsMediumUppercase,
                color: DifyColors.textTertiary,
              ),
            ),
          ),
        if (strategy != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: Container(
              height: 24,
              padding: const EdgeInsets.symmetric(horizontal: 5),
              decoration: box,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  DifyText(
                    DifyI18n.tr('workflow', 'common.onFailure'),
                    DifyType.systemXsMediumUppercase,
                    color: DifyColors.textTertiary,
                  ),
                  DifyText(
                    DifyI18n.tr(
                      'workflow',
                      strategy == failBranch
                          ? 'nodes.common.errorHandle.failBranch.title'
                          : 'nodes.common.errorHandle.defaultValue.output',
                    ),
                    DifyType.systemXsMedium,
                    color: DifyColors.textSecondary,
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
