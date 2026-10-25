/// Per-execution leases renewed by the Swift server. When a lease expires,
/// the execution's running operations are cancelled (`cancel_lost`).
library;

import 'dart:async';

class LeaseManager {
  LeaseManager({required this.onExpired});

  /// Called with the execution ID when its lease expires.
  final void Function(String executionId) onExpired;

  final Map<String, ({DateTime expiresAt, Timer timer})> _leases = {};

  /// Renews (or starts) the lease of [executionId] for [ttl].
  DateTime renew(String executionId, Duration ttl) {
    _leases.remove(executionId)?.timer.cancel();
    final expiresAt = DateTime.now().toUtc().add(ttl);
    final timer = Timer(ttl, () {
      _leases.remove(executionId);
      onExpired(executionId);
    });
    _leases[executionId] = (expiresAt: expiresAt, timer: timer);
    return expiresAt;
  }

  DateTime? expiresAt(String executionId) => _leases[executionId]?.expiresAt;

  void remove(String executionId) =>
      _leases.remove(executionId)?.timer.cancel();

  void close() {
    for (final l in _leases.values) {
      l.timer.cancel();
    }
    _leases.clear();
  }
}
