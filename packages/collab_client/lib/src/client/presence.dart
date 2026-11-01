import 'dart:async';

import '../wire/messages.dart';
import 'transport.dart';

/// What changed in [SessionPresence.users] with one `event: presence` (protocol 1.22).
final class PresenceChange {
  const PresenceChange({this.joined = const [], this.left = const [], this.updated = const []});

  /// Accounts this client sees for the first time (they opened the document).
  final List<PresenceUser> joined;

  /// Accounts that are gone (as they were last seen).
  final List<PresenceUser> left;

  /// Accounts already present whose cursor, drag or panels changed.
  final List<PresenceUser> updated;
}

/// Presence of one [CollabSession](session.dart) (docs/protocol.md, "Presence (1.22)"): what this client reports (its
/// pointer and open panel, throttled like Dify's cursor service, plus a heartbeat) and who else has the document open.
/// Reporting starts with [enable] (the server advertises `collaboration_presence`); a `403` or `404` turns it off.
class SessionPresence {
  SessionPresence(this._transport, this._clientId, {DateTime Function()? now}) : _now = now ?? DateTime.now;

  /// Dify's cursor service: at most one pointer report per this interval.
  static const cursorInterval = Duration(milliseconds: 300);

  /// A report (at least a heartbeat) at least this often keeps the client present (the server forgets it after 30 s).
  static const heartbeat = Duration(seconds: 10);

  final CollabTransport _transport;
  final String Function() _clientId;
  final DateTime Function() _now;

  final _changes = StreamController<PresenceChange>.broadcast();
  final Map<String, PresenceUser> _users = {};
  bool _enabled = false;
  bool _closed = false;

  PresencePoint? _cursor;
  PresenceDrag? _drag;
  String? _panel;
  PresencePoint? _sentCursor;
  DateTime? _sentCursorAt;
  Timer? _trailing;
  Timer? _heartbeat;
  bool _inFlight = false;
  Future<void>? _draining;
  PresenceReport? _queued;

  /// Everyone present, by account id, this client's own account included (leave it out when drawing).
  Map<String, PresenceUser> get users => Map.unmodifiable(_users);

  /// One [PresenceChange] per `event: presence` that changed something. Broadcast.
  Stream<PresenceChange> get changes => _changes.stream;

  bool get enabled => _enabled;

  /// Starts reporting (the server supports presence).
  void enable() {
    if (_enabled || _closed) return;
    _enabled = true;
    _send(_everything());
    _heartbeat = Timer.periodic(heartbeat, (_) => _send(const PresenceReport.heartbeat()));
  }

  PresenceReport _everything() =>
      PresenceReport(setsCursor: true, cursor: _cursor, setsDrag: true, drag: _drag, setsPanel: true, panel: _panel);

  /// The pointer moved to [cursor] (flow coordinates; null = it left the canvas). Sent at most every [cursorInterval]
  /// and only after moving more than [minMove] (Dify: `10 / zoom`) on either axis; the last position is sent when the
  /// interval ends, so a resting pointer is shown where it stopped.
  void moveCursor(PresencePoint? cursor, {double minMove = 0}) {
    _cursor = cursor;
    if (!_enabled) return;
    final last = _sentCursor;
    if (cursor != null &&
        last != null &&
        (cursor.x - last.x).abs() <= minMove &&
        (cursor.y - last.y).abs() <= minMove) {
      return;
    }
    final at = _sentCursorAt;
    final wait = at == null ? Duration.zero : cursorInterval - _now().difference(at);
    if (wait <= Duration.zero || cursor == null) {
      _sendCursor();
    } else {
      _trailing ??= Timer(wait, _sendCursor);
    }
  }

  void _sendCursor() {
    _trailing?.cancel();
    _trailing = null;
    if (_sentCursor == _cursor && _sentCursorAt != null) return;
    _sentCursor = _cursor;
    _sentCursorAt = _now();
    _send(PresenceReport(setsCursor: true, cursor: _cursor));
  }

  /// This client began dragging nodes, the pointer holding [drag] (null: the drag ended). Sent at once with the pointer:
  /// while it is set the others draw the pointer on that node, which moves with the drag's positions (dify-sf; Dify's
  /// pointer trails the nodes it drags).
  void setDrag(PresenceDrag? drag) {
    if (drag == _drag) return;
    _drag = drag;
    _trailing?.cancel();
    _trailing = null;
    _sentCursor = _cursor;
    _sentCursorAt = _now();
    _send(PresenceReport(setsCursor: true, cursor: _cursor, setsDrag: true, drag: drag));
  }

  /// The configuration panel of [node] opened (null: it closed). Sent at once.
  void openPanel(String? node) {
    if (node == _panel) return;
    _panel = node;
    _send(PresenceReport(setsPanel: true, panel: node));
  }

  /// The event stream reached `ready` again: the server may have forgotten this client while it was away.
  void onReady() {
    _sentCursorAt = null;
    _send(_everything());
  }

  /// Applies `event: presence`.
  void apply(PresenceEvent e) {
    final joined = <PresenceUser>[], left = <PresenceUser>[], updated = <PresenceUser>[];
    if (e.full) {
      final now = {for (final u in e.users) u.account: u};
      for (final u in _users.values) {
        if (!now.containsKey(u.account)) left.add(u);
      }
      for (final u in e.users) {
        final before = _users[u.account];
        if (before == null) {
          joined.add(u);
        } else if (before != u) {
          updated.add(u);
        }
      }
      _users
        ..clear()
        ..addAll(now);
    } else {
      for (final u in e.users) {
        final before = _users[u.account];
        if (before == null) {
          joined.add(u);
        } else if (before != u) {
          updated.add(u);
        }
        _users[u.account] = u;
      }
      for (final a in e.left) {
        final gone = _users.remove(a);
        if (gone != null) left.add(gone);
      }
    }
    if (_closed || (joined.isEmpty && left.isEmpty && updated.isEmpty)) return;
    _changes.add(PresenceChange(joined: joined, left: left, updated: updated));
  }

  /// One request at a time; reports made meanwhile are merged into the next one.
  void _send(PresenceReport r) {
    if (!_enabled || _closed) return;
    final q = _queued;
    _queued = q == null ? r : _merge(q, r);
    if (!_inFlight) _draining = _drain();
  }

  /// [older] followed by [newer]: what [newer] sets wins.
  static PresenceReport _merge(PresenceReport older, PresenceReport newer) => PresenceReport(
    setsCursor: older.setsCursor || newer.setsCursor,
    cursor: newer.setsCursor ? newer.cursor : older.cursor,
    setsDrag: older.setsDrag || newer.setsDrag,
    drag: newer.setsDrag ? newer.drag : older.drag,
    setsPanel: older.setsPanel || newer.setsPanel,
    panel: newer.setsPanel ? newer.panel : older.panel,
  );

  Future<void> _drain() async {
    _inFlight = true;
    try {
      while (_queued != null && _enabled && !_closed) {
        final r = _queued!;
        _queued = null;
        final id = _clientId();
        if (id.isEmpty) return;
        try {
          await _transport.putPresence(id, r);
        } on TransportException catch (e) {
          // A server without presence (404 on an older server), or a role that may not report: stop reporting.
          if (e.statusCode == 404 || e.statusCode == 403) {
            _stopReporting();
            return;
          }
          // Anything else (a 503, a timeout): what it said goes with the next report or heartbeat, under anything
          // reported since; no retry loop while the server is away.
          final since = _queued;
          _queued = since == null ? r : _merge(r, since);
          return;
        }
      }
    } finally {
      _inFlight = false;
    }
  }

  void _stopReporting() {
    _enabled = false;
    _heartbeat?.cancel();
    _trailing?.cancel();
    _queued = null;
  }

  /// Says goodbye (best-effort) and stops: after a report still in flight (at most 1 s), so the goodbye arrives last.
  Future<void> close() async {
    if (_closed) return;
    final wasEnabled = _enabled;
    final inFlight = _inFlight ? _draining : null;
    _stopReporting();
    _closed = true;
    if (inFlight != null) {
      try {
        await inFlight.timeout(const Duration(seconds: 1));
      } on Object {
        // Gone or stalled: say goodbye anyway (the server ignores this client's later reports).
      }
    }
    final id = _clientId();
    if (wasEnabled && id.isNotEmpty) {
      try {
        await _transport.deletePresence(id).timeout(const Duration(seconds: 1));
      } on Object {
        // The server forgets it within 30 s anyway.
      }
    }
    await _changes.close();
  }
}
