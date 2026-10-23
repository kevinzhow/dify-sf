import 'durable.dart';

/// Where the client persists its outbox and counters (write-ahead journal).
abstract interface class DurableStore {
  /// The last durably saved state, or null for a brand-new client.
  Future<ClientDurable?> load();

  /// Durably replaces the saved state. When the returned future completes the data must survive a crash
  /// of the process (the driver sends ops to the network only after this completes).
  Future<void> save(ClientDurable state);
}

/// A journal owned by exactly one live client instance (process, window, tab). Protocol 1.1 requires that a
/// client id is used by one live process at a time, and the id lives in the journal: so a journal is claimed
/// before use and [release]d afterwards. A crash releases it implicitly (OS file lock, tab lifetime).
abstract interface class JournalSlot implements DurableStore {
  /// Human-readable location, for diagnostics.
  String get description;

  /// Gives the slot back so that another instance may claim its journal.
  Future<void> release();
}

/// In-memory store: survives a simulated crash within one test process, nothing more. Optionally models a
/// slow disk and a crash racing a write.
class MemoryStore implements DurableStore {
  MemoryStore({this.latency});

  /// Time one `save` takes (a Timer, so it works in fake time). null = completes in a microtask.
  Duration Function()? latency;

  ClientDurable? _saved;

  /// What a restart would find in the journal.
  ClientDurable? get saved => _saved;
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
    if (epoch != _epoch && !_landInFlight) {
      throw StateError('process died before the write reached the disk'); // nobody is left to see this
    }
    _saved = copy;
    writes++;
  }
}
