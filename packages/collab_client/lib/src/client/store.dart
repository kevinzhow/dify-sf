import 'durable.dart';

/// Where the client persists its outbox and counters (write-ahead journal).
abstract interface class DurableStore {
  /// The last durably saved state, or null for a brand-new client.
  Future<ClientDurable?> load();

  /// Durably replaces the saved state. When the returned future completes the data must survive a crash
  /// of the process (the driver sends ops to the network only after this completes).
  Future<void> save(ClientDurable state);
}

/// In-memory store: survives a simulated crash within one test process, nothing more. Optionally models a
/// slow disk and a crash racing a write.
class MemoryStore implements DurableStore {
  MemoryStore({this.latency});

  /// Time one `save` takes (a Timer, so it works in fake time). null = completes in a microtask.
  Duration Function()? latency;

  ClientDurable? _saved;
  int _epoch = 0;
  bool _landInFlight = false;
  int writes = 0;

  /// Simulates the process dying: writes that were in flight at this moment either land or vanish, as a
  /// real disk may do either.
  void crash({required bool landInFlight}) {
    _epoch++;
    _landInFlight = landInFlight;
  }

  @override
  Future<ClientDurable?> load() async => _saved;

  @override
  Future<void> save(ClientDurable state) async {
    // Round-trip through JSON so tests also cover (de)serialisation, like a real file would.
    final copy = ClientDurable.fromJson(state.toJson());
    final epoch = _epoch;
    final lat = latency?.call();
    if (lat != null) await Future<void>.delayed(lat);
    if (epoch != _epoch && !_landInFlight) return; // the process died before the bytes reached the disk
    _saved = copy;
    writes++;
  }
}
