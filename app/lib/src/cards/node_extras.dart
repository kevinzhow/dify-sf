import 'package:collab_client/collab_client.dart';
import 'package:flutter/material.dart' show Colors;
import 'package:flutter/widgets.dart';

import '../canvas/run_view.dart';
import '../i18n/dify_i18n.dart';
import '../design/css_metrics.dart';
import '../design/dify_icon.dart';
import '../design/dify_tokens.g.dart';
import 'card_spinner.dart';
import '../design/widgets/widgets.dart';

/// What retry-on-node.tsx shows for a run state: the "Retry n times" row ([idle]), the attempt while running, its
/// outcome, or nothing (a run state without a retry index).
enum RetryLook { idle, running, succeeded, failed }

/// The rows BaseNode adds under the body of nodes that can retry or handle errors (retry-on-node.tsx,
/// error-handle-on-node.tsx): "Retry n times on failure" (during a run: retrying / successful / failed with the
/// attempt) and "On Failure" with the strategy (the fail branch has its own source handle on that row).
abstract final class NodeExtras {
  static const failBranch = 'fail-branch';
  static bool hasRunPreview(Node n) =>
      (n.type == 'agent' || n.type == 'agent-v2') && n.config['version'] == const VString('2');
  static double progressHeight(Node n, NodeRunView run) => hasRunPreview(n) ? run.agentProgress?.height ?? 0 : 0;

  // utils/node.ts hasRetryNode, utils/workflow.ts hasErrorHandleNode.
  static const _retryTypes = {'llm', 'tool', 'http-request', 'code'};
  static const _errorTypes = {'llm', 'tool', 'http-request', 'code', 'agent', 'agent-v2'};

  /// Whether [n] shows a retry row in some run state (its card's size then depends on the run).
  static bool hasRetry(Node n) => _retries(n) != null;

  /// retry-on-node.tsx: null when the row is not shown. A selected node shows the idle row
  /// (`showSelectedBorder` turns the run states off).
  static RetryLook? retryLook(Node n, NodeRunView run, {bool selected = false}) {
    if (_retries(n) == null) return null;
    final status = selected ? null : run.runningStatus;
    final look = switch (status) {
      'running' => RetryLook.running,
      'succeeded' => RetryLook.succeeded,
      'failed' || 'exception' => RetryLook.failed,
      _ => RetryLook.idle,
    };
    if (look != RetryLook.idle && (run.retryIndex ?? 0) == 0) return null;
    return look;
  }

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

  static double height(Node n, [NodeRunView run = NodeRunView.idle, bool selected = false]) =>
      progressHeight(n, run) +
      (retryLook(n, run, selected: selected) != null ? _retryHeight : 0) +
      (_strategy(n) != null ? _errorHeight : 0);

  /// The fail branch row's middle, from the top of these rows; null without a fail branch.
  static double? failBranchY(Node n, [NodeRunView run = NodeRunView.idle, bool selected = false]) =>
      _strategy(n) == failBranch
      ? progressHeight(n, run) + (retryLook(n, run, selected: selected) != null ? _retryHeight : 0) + 4 + 12
      : null;

  /// The retry row's loader (a 14 px square), from the top-left of these rows; null when it does not spin.
  static Rect? retrySpinner(Node n, NodeRunView run, {bool selected = false}) =>
      retryLook(n, run, selected: selected) == RetryLook.running
      ? Rect.fromLTWH(12 + Css.hairline + 5, progressHeight(n, run) + Css.hairline + 4 + 1, 14, 14)
      : null;

  static Widget build(Node n, [NodeRunView run = NodeRunView.idle, bool selected = false]) {
    final retries = _retries(n), strategy = _strategy(n);
    final look = retryLook(n, run, selected: selected);
    final previewHeight = progressHeight(n, run);
    if (look == null && strategy == null && previewHeight == 0) return const SizedBox.shrink();
    final box = BoxDecoration(
      color: DifyColors.workflowBlockParmaBg,
      borderRadius: BorderRadius.circular(DifyRadius.md),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (previewHeight > 0) SizedBox(height: previewHeight),
        if (look != null) _retryRow(retries!, look, run.retryIndex ?? 0, box),
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

Widget _retryRow(int retries, RetryLook look, int retryIndex, BoxDecoration box) {
  final (border, bg, color) = switch (look) {
    RetryLook.idle => (Colors.transparent, DifyColors.workflowBlockParmaBg, DifyColors.textTertiary),
    RetryLook.running => (DifyColors.stateAccentActive, DifyColors.stateAccentHover, DifyColors.textAccent),
    RetryLook.succeeded => (DifyColors.stateSuccessActive, DifyColors.stateSuccessHover, DifyColors.textSuccess),
    RetryLook.failed => (DifyColors.stateWarningActive, DifyColors.stateWarningHover, DifyColors.textWarning),
  };
  String tr(String key, [Map<String, Object?> p = const {}]) => DifyI18n.tr('workflow', 'nodes.common.retry.$key', p);
  Widget label(String text) => DifyText(text, DifyType.systemXsMediumUppercase, color: color);
  return Padding(
    padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 4),
      decoration: box.copyWith(
        color: bg,
        border: Border.all(color: border, width: Css.hairline),
      ),
      child: Row(
        children: [
          ...switch (look) {
            RetryLook.idle => [
              Flexible(child: label(tr('retryTimes', {'times': retries}))),
            ],
            RetryLook.running => [
              CardSpinner(color: color, key: const Key('retry-spinner')),
              const SizedBox(width: 4),
              Flexible(child: label(tr('retrying'))),
            ],
            RetryLook.succeeded => [
              RemixIcon('checkbox-circle-fill', size: 14, color: color),
              const SizedBox(width: 4),
              Flexible(child: label(tr('retrySuccessful'))),
            ],
            RetryLook.failed => [
              RemixIcon('alert-fill', size: 14, color: color),
              const SizedBox(width: 4),
              Flexible(child: label(tr('retryFailed'))),
            ],
          },
          if (look != RetryLook.idle && retryIndex != 0) ...[
            const Spacer(),
            label('$retryIndex/$retries'),
          ],
        ],
      ),
    ),
  );
}
