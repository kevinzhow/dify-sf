/// What the canvas shows of a run: Dify 1.17.1's run fields of React Flow's node and edge `data` (nodes/_base/
/// node.tsx, node-sections.tsx, retry-on-node.tsx, custom-edge.tsx, utils/edge.ts), as immutable values the
/// renderers and cards read. Local view state: never part of the document.
library;

import 'dart:ui';

import 'package:flutter/foundation.dart';

import '../design/dify_tokens.g.dart';

/// A node's run fields: `_runningStatus`, `_waitingRun`, `_singleRunningStatus`, `_iterationIndex`,
/// `_iterationLength`, `_loopIndex`, `_retryIndex`, and whether the node has inspect variables (`hasNodeInspectVars`).
@immutable
class NodeRunView {
  const NodeRunView({
    this.runningStatus,
    this.waiting = false,
    this.singleRunningStatus,
    this.hasVarValue = false,
    this.iterationIndex,
    this.iterationLength,
    this.loopIndex,
    this.retryIndex,
  });

  static const idle = NodeRunView();

  /// From Dify's run fields (the store's `nodeRunData` entry of the node).
  factory NodeRunView.fromRunData(Map<String, Object?> data, {bool hasVarValue = false}) {
    int? n(String key) => switch (data[key]) {
      final num v => v.toInt(),
      _ => null,
    };
    String? s(String key) => switch (data[key]) {
      final String v when v.isNotEmpty => v,
      _ => null,
    };
    return NodeRunView(
      runningStatus: s('_runningStatus'),
      waiting: data['_waitingRun'] == true,
      singleRunningStatus: s('_singleRunningStatus'),
      hasVarValue: hasVarValue,
      iterationIndex: n('_iterationIndex'),
      iterationLength: n('_iterationLength'),
      loopIndex: n('_loopIndex'),
      retryIndex: n('_retryIndex'),
    );
  }

  /// `data._runningStatus` (any NodeRunningStatus, or null).
  final String? runningStatus;

  /// `data._waitingRun`: the node is drawn at 70 % opacity (`opacity-70`).
  final bool waiting;

  /// The whole node, including live layers, frames and handle markers.
  double get opacity => waiting ? 0.7 : 1.0;

  Color tint(Color color) => color.withValues(alpha: color.a * opacity);

  /// `data._singleRunningStatus` (the node's single-step run).
  final String? singleRunningStatus;

  /// `hasNodeInspectVars(id)`: without a running status the node shows the success border and icon.
  final bool hasVarValue;
  final int? iterationIndex;
  final int? iterationLength;
  final int? loopIndex;
  final int? retryIndex;

  /// The status the card's border and header icon show (getNodeStatusBorders / NodeHeaderMeta): `running`,
  /// `paused`, `succeeded` (also with inspect variables and no running status), `failed`, `exception`, or `idle`.
  String get status => switch (runningStatus) {
    'running' || 'paused' || 'succeeded' || 'failed' || 'exception' => runningStatus!,
    null => hasVarValue ? 'succeeded' : 'idle',
    _ => 'idle',
  };

  /// node.tsx `isLoading`: the header shows the spinner.
  bool get isLoading => runningStatus == 'running' || singleRunningStatus == 'running';

  /// What the card itself draws (everything but the dimming, which the renderer applies to the whole node).
  NodeRunView get forCard => waiting ? copyWith(waiting: false) : this;

  NodeRunView copyWith({bool? waiting}) => NodeRunView(
    runningStatus: runningStatus,
    waiting: waiting ?? this.waiting,
    singleRunningStatus: singleRunningStatus,
    hasVarValue: hasVarValue,
    iterationIndex: iterationIndex,
    iterationLength: iterationLength,
    loopIndex: loopIndex,
    retryIndex: retryIndex,
  );

  @override
  bool operator ==(Object other) =>
      other is NodeRunView &&
      other.runningStatus == runningStatus &&
      other.waiting == waiting &&
      other.singleRunningStatus == singleRunningStatus &&
      other.hasVarValue == hasVarValue &&
      other.iterationIndex == iterationIndex &&
      other.iterationLength == iterationLength &&
      other.loopIndex == loopIndex &&
      other.retryIndex == retryIndex;

  @override
  int get hashCode => Object.hash(
    runningStatus,
    waiting,
    singleRunningStatus,
    hasVarValue,
    iterationIndex,
    iterationLength,
    loopIndex,
    retryIndex,
  );

  @override
  String toString() => 'NodeRunView($status${waiting ? ', waiting' : ''})';
}

/// An edge's run fields: `_sourceRunningStatus`, `_targetRunningStatus`, `_waitingRun`.
@immutable
class EdgeRunView {
  const EdgeRunView({this.sourceStatus, this.targetStatus, this.waiting = false});

  static const idle = EdgeRunView();

  factory EdgeRunView.fromRunData(Map<String, Object?> data) => EdgeRunView(
    sourceStatus: data['_sourceRunningStatus'] as String?,
    targetStatus: data['_targetRunningStatus'] as String?,
    waiting: data['_waitingRun'] == true,
  );

  final String? sourceStatus;
  final String? targetStatus;
  final bool waiting;

  @override
  bool operator ==(Object other) =>
      other is EdgeRunView &&
      other.sourceStatus == sourceStatus &&
      other.targetStatus == targetStatus &&
      other.waiting == waiting;

  @override
  int get hashCode => Object.hash(sourceStatus, targetStatus, waiting);
}

/// The card border in a run status colour (getNodeStatusBorders: running and paused share the accent), null for
/// none.
Color? statusBorderColor(String status) => switch (status) {
  'running' || 'paused' => DifyColors.stateAccentSolid,
  'succeeded' => DifyColors.stateSuccessSolid,
  'failed' => DifyColors.stateDestructiveSolid,
  'exception' => DifyColors.stateWarningSolid,
  _ => null,
};

/// utils/edge.ts `getEdgeColor`.
Color getEdgeColor([String? nodeRunningStatus, bool isFailBranch = false]) => switch (nodeRunningStatus) {
  'succeeded' => DifyColors.workflowLinkLineSuccessHandle,
  'failed' => DifyColors.workflowLinkLineErrorHandle,
  'exception' => DifyColors.workflowLinkLineFailureHandle,
  'running' => isFailBranch ? DifyColors.workflowLinkLineFailureHandle : DifyColors.workflowLinkLineHandle,
  _ => DifyColors.workflowLinkLineNormal,
};

/// How custom-edge.tsx strokes an edge: one colour, or (`url(#id)`) a linear gradient from [start] at the source
/// handle to [end] at the target handle; [opacity] (`_dimmed` 0.3, `_waitingRun` 0.7); dashed (`_isTemp`, 8 8).
@immutable
class EdgeStroke {
  const EdgeStroke(this.start, [Color? end, this.opacity = 1, this.dashed = false]) : end = end ?? start;

  final Color start;
  final Color end;
  final double opacity;
  final bool dashed;

  /// Two colours (a gradient whose ends match draws as one colour).
  bool get isGradient => start != end;

  /// The stroke's colour at [t] (0 at the source handle, 1 at the target handle) with its opacity.
  Color at(double t) {
    final c = Color.lerp(start, end, t.clamp(0.0, 1.0))!;
    return opacity == 1 ? c : c.withValues(alpha: c.a * opacity);
  }

  @override
  bool operator ==(Object other) =>
      other is EdgeStroke &&
      other.start == start &&
      other.end == end &&
      other.opacity == opacity &&
      other.dashed == dashed;

  @override
  int get hashCode => Object.hash(start, end, opacity, dashed);

  @override
  String toString() => 'EdgeStroke($start → $end, $opacity${dashed ? ', dashed' : ''})';
}

/// custom-edge.tsx `linearGradientId`: the edge gets the gradient when its source finished and its target finished or
/// runs.
bool hasEdgeGradient(EdgeRunView run) =>
    const {'succeeded', 'failed', 'exception'}.contains(run.sourceStatus) &&
    const {'succeeded', 'failed', 'exception', 'running'}.contains(run.targetStatus);

/// custom-edge.tsx's `stroke` and style: selected → the running colour; the run gradient; a hovered connected node →
/// the running colour (the fail branch's when the edge leaves one); otherwise the normal colour.
EdgeStroke customEdgeStroke(
  EdgeRunView run, {
  bool selected = false,
  bool connectedNodeIsHovering = false,
  bool isFailBranch = false,
  bool dimmed = false,
  bool isTemp = false,
}) {
  final opacity = dimmed ? 0.3 : (run.waiting ? 0.7 : 1.0);
  if (selected) return EdgeStroke(getEdgeColor('running'), null, opacity, isTemp);
  if (hasEdgeGradient(run)) {
    return EdgeStroke(getEdgeColor(run.sourceStatus), getEdgeColor(run.targetStatus), opacity, isTemp);
  }
  if (connectedNodeIsHovering) return EdgeStroke(getEdgeColor('running', isFailBranch), null, opacity, isTemp);
  return EdgeStroke(getEdgeColor(), null, opacity, isTemp);
}

/// The loader's spin (`animate-spin`: one turn a second, linear).
const spinPeriod = Duration(seconds: 1);
