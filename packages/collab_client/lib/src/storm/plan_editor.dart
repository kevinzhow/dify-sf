import '../model/document.dart';
import '../model/ops.dart';
import '../wire/messages.dart';

/// The edits of one client in the build demo (`bin/build_demo.dart`), from a plan written by
/// `tool/demo/build_storm/make_plan.py`: a list of steps, each one of
///
/// * `{"op": <op>}`: send this op (dify-sf's wire format);
/// * `{"wait": [node ids]}`: no edit until every listed node is in the client's view (someone else adds it);
/// * `{"sleep_ms": n}`: no edit for n milliseconds;
/// * `{"presence": {"cursor": [x, y] | null, "drag": {"node", "x", "y"} | null, "panel": "<node id>" | null}}`: report
///   the pointer, the node it drags and/or the open panel (protocol 1.22) through [onPresence]; a missing key is
///   unchanged.
/// * `{"at_ms": n}`: no edit until n milliseconds after [epoch] (the convergence runs' "everyone writes the final
///   values now");
///
/// and an `op` step may also say `"deadline_ms": n` (skipped when it comes after n ms past [epoch]: a contested edit
/// that would be too late) and `"final": true` (one of the values the document must end with: [finals]).
///
/// After the last step the client makes no more edits.
class PlanEditor {
  PlanEditor(this.steps, {DateTime Function()? clock, this.onPresence, DateTime? epoch})
    : _clock = clock ?? DateTime.now,
      epoch = epoch ?? (clock ?? DateTime.now)();

  /// When the run started: `at_ms` and `deadline_ms` count from here.
  final DateTime epoch;

  /// The `final` ops this editor has sent: the runner re-applies them until they are confirmed.
  final Set<Op> finals = {};

  final List<Map<String, Object?>> steps;

  /// Reports a `presence` step: `setsCursor` / `setsDrag` / `setsPanel` say which the step names.
  final void Function({
    bool setsCursor,
    PresencePoint? cursor,
    bool setsDrag,
    PresenceDrag? drag,
    bool setsPanel,
    String? panel,
  })?
  onPresence;
  final DateTime Function() _clock;
  int _next = 0;
  DateTime? _sleepUntil;

  bool get done => _next >= steps.length;

  Op? next(Document view) {
    while (_next < steps.length) {
      final step = steps[_next];
      final sleep = step['sleep_ms'];
      if (sleep is int) {
        final until = _sleepUntil ??= _clock().add(Duration(milliseconds: sleep));
        if (_clock().isBefore(until)) return null;
        _sleepUntil = null;
        _next++;
        continue;
      }
      final presence = step['presence'];
      if (presence is Map) {
        final c = presence['cursor'], d = presence['drag'];
        onPresence?.call(
          setsCursor: presence.containsKey('cursor'),
          cursor: c is List && c.length == 2 ? PresencePoint((c[0] as num).toDouble(), (c[1] as num).toDouble()) : null,
          setsDrag: presence.containsKey('drag'),
          drag: d == null ? null : PresenceDrag.fromJson(d),
          setsPanel: presence.containsKey('panel'),
          panel: presence['panel'] as String?,
        );
        _next++;
        continue;
      }
      final at = step['at_ms'];
      if (at is int) {
        if (_clock().isBefore(epoch.add(Duration(milliseconds: at)))) return null;
        _next++;
        continue;
      }
      final wait = step['wait'];
      if (wait is List) {
        if (!wait.every((id) => view.nodes.containsKey(id))) return null;
        _next++;
        continue;
      }
      _next++;
      final deadline = step['deadline_ms'];
      if (deadline is int && _clock().isAfter(epoch.add(Duration(milliseconds: deadline)))) continue;
      final op = Op.fromJson(step['op']);
      if (step['final'] == true) finals.add(op);
      return op;
    }
    return null;
  }
}
