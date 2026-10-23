/// run/hooks.ts `useLogs`: which detail view the tracing panel shows over its list (a node's retries, an iteration's
/// or loop's runs, an agent's or tool's log stack) and the data for it.
library;

import 'package:flutter/foundation.dart';

import '../../store/workflow_store.dart' show DifyJson;

typedef NodeTracingList = List<DifyJson>;

/// `IterationDurationMap` / `LoopDurationMap`: run key (index or parallel run id) → seconds.
typedef DurationMap = Map<String, Object?>;

class RunLogs extends ChangeNotifier {
  bool showRetryDetail = false;
  NodeTracingList retryResultList = const [];

  bool showIteratingDetail = false;
  List<NodeTracingList> iterationResultList = const [];
  DurationMap iterationResultDurationMap = const {};

  bool showLoopingDetail = false;
  List<NodeTracingList> loopResultList = const [];
  DurationMap loopResultDurationMap = const {};
  Map<String, Object?> loopResultVariableMap = const {};

  List<DifyJson> agentOrToolLogItemStack = const [];
  Map<String, List<DifyJson>> agentOrToolLogListMap = const {};

  bool get showSpecialResultPanel =>
      showRetryDetail || showIteratingDetail || showLoopingDetail || agentOrToolLogItemStack.isNotEmpty;

  void setShowRetryDetailTrue() => _set(() => showRetryDetail = true);
  void setShowRetryDetailFalse() => _set(() => showRetryDetail = false);
  void handleShowRetryResultList(NodeTracingList detail) => _set(() {
    showRetryDetail = true;
    retryResultList = detail;
  });

  void setShowIteratingDetailTrue() => _set(() => showIteratingDetail = true);
  void setShowIteratingDetailFalse() => _set(() => showIteratingDetail = false);
  void handleShowIterationResultList(List<NodeTracingList> detail, DurationMap iterDurationMap) => _set(() {
    showIteratingDetail = true;
    iterationResultList = detail;
    iterationResultDurationMap = iterDurationMap;
  });

  void setShowLoopingDetailTrue() => _set(() => showLoopingDetail = true);
  void setShowLoopingDetailFalse() => _set(() => showLoopingDetail = false);
  void handleShowLoopResultList(
    List<NodeTracingList> detail,
    DurationMap loopDurationMap,
    Map<String, Object?> loopVariableMap,
  ) => _set(() {
    showLoopingDetail = true;
    loopResultList = detail;
    loopResultDurationMap = loopDurationMap;
    loopResultVariableMap = loopVariableMap;
  });

  /// Shows [detail]'s children (pushing it, or going back to it when it is on the stack); null clears the stack.
  void handleShowAgentOrToolLog([DifyJson? detail]) => _set(() {
    if (detail == null) {
      agentOrToolLogItemStack = const [];
      return;
    }
    final id = detail['message_id'];
    final i = agentOrToolLogItemStack.indexWhere((l) => l['message_id'] == id);
    agentOrToolLogItemStack = i > -1 ? agentOrToolLogItemStack.sublist(0, i + 1) : [...agentOrToolLogItemStack, detail];
    final children = detail['children'];
    if (children is List) {
      agentOrToolLogListMap = {...agentOrToolLogListMap, '$id': children.cast<DifyJson>()};
    }
  });

  void _set(VoidCallback change) {
    change();
    notifyListeners();
  }
}

/// `Object.keys(o)` in JavaScript's order: integer-like keys first (ascending), then the others in insertion order.
List<String> jsObjectKeys(Map<Object?, Object?>? o) {
  if (o == null) return const [];
  final ints = <String>[], others = <String>[];
  for (final k in o.keys) {
    final s = '$k';
    final n = int.tryParse(s);
    (n != null && n >= 0 && '$n' == s ? ints : others).add(s);
  }
  ints.sort((a, b) => int.parse(a).compareTo(int.parse(b)));
  return [...ints, ...others];
}
