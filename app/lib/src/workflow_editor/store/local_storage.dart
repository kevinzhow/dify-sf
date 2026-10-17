/// Dify's workflow preferences in localStorage (persistence/local-storage-options.ts) and the bridge that loads them
/// into the workflow store (persistence/local-storage-bridge.tsx). Stored with shared_preferences like the app's
/// settings, under Dify's keys and as Dify's strings (numbers as JavaScript's `String(n)`).
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../canvas/canvas_input.dart';
import 'workflow_store.dart';

const workflowNodePanelWidthKey = 'workflow-node-panel-width';
const workflowPreviewPanelWidthKey = 'debug-and-preview-panel-width';

/// Dify's key, typo included.
const workflowVariableInspectPanelHeightKey = 'workflow-variable-inpsect-panel-height';
const workflowOperationModeKey = 'workflow-operation-mode';

/// note-node/constants.ts.
const noteShowAuthorStorageKey = 'workflow-note-show-author';

/// local-storage-options.ts `isControlMode`.
ControlMode? controlModeOf(String? value) => switch (value) {
  'pointer' => ControlMode.pointer,
  'hand' => ControlMode.hand,
  'comment' => ControlMode.comment,
  _ => null,
};

/// JavaScript's `Number(s)` for what a stored width can be: trimmed, '' is 0, anything unparsable NaN.
double jsNumber(String s) {
  final t = s.trim();
  return t.isEmpty ? 0 : double.tryParse(t) ?? double.nan;
}

/// JavaScript's `String(n)`: integers without a fraction.
String jsNumberString(double n) => n.isFinite && n == n.truncateToDouble() ? n.toInt().toString() : n.toString();

/// One stored preference (foxact's createLocalStorageState): null until loaded or when absent (Dify's undefined);
/// setting [value] stores it and notifies listeners, as a same-tab localStorage write does.
class StoredPreference<T> extends ValueNotifier<T> {
  StoredPreference._(this.key, this._fallback, this._decode, this._encode, this._prefs) : super(_fallback);

  final String key;
  final T _fallback;
  final T Function(String) _decode;
  final String Function(T) _encode;
  final Future<SharedPreferences?> _prefs;

  bool _written = false;

  @override
  set value(T v) {
    _written = true;
    super.value = v;
    _prefs.then((p) async => p?.setString(key, _encode(v)));
  }

  /// A value written before the load finished wins over the stored one.
  void _load(SharedPreferences p) {
    if (_written) return;
    final raw = p.get(key);
    super.value = raw == null ? _fallback : _decode('$raw');
  }
}

/// The workflow editor's localStorage values. Loads in the background; listeners hear the loaded values.
class WorkflowPreferences {
  WorkflowPreferences({Future<SharedPreferences>? preferences})
    : _prefs = (preferences ?? SharedPreferences.getInstance())
          .then<SharedPreferences?>((p) => p)
          .catchError(
            // Like foxact without localStorage: the defaults stay and writes go nowhere.
            (Object _) => null,
          ) {
    loaded = _prefs.then((p) {
      if (p == null || _disposed) return;
      for (final s in _all) {
        s._load(p);
      }
    });
  }

  final Future<SharedPreferences?> _prefs;
  bool _disposed = false;

  /// Completes once the stored values are in.
  late final Future<void> loaded;

  late final workflowNodePanelWidth = _number(workflowNodePanelWidthKey);
  late final debugPreviewPanelWidth = _number(workflowPreviewPanelWidthKey);
  late final workflowVariableInspectPanelHeight = _number(workflowVariableInspectPanelHeightKey);

  /// The raw stored control mode (validated by the bridge).
  late final workflowOperationMode = StoredPreference<String?>._(
    workflowOperationModeKey,
    null,
    (s) => s,
    (s) => s ?? '',
    _prefs,
  );

  /// 'true' unless set; the note node reads it as a string, as Dify does.
  late final workflowNoteShowAuthor = StoredPreference<String>._(
    noteShowAuthorStorageKey,
    'true',
    (s) => s,
    (s) => s,
    _prefs,
  );

  late final List<StoredPreference<Object?>> _all = [
    workflowNodePanelWidth,
    debugPreviewPanelWidth,
    workflowVariableInspectPanelHeight,
    workflowOperationMode,
    workflowNoteShowAuthor,
  ];

  StoredPreference<double?> _number(String key) =>
      StoredPreference<double?>._(key, null, jsNumber, (n) => jsNumberString(n!), _prefs);

  void dispose() {
    _disposed = true;
    for (final s in _all) {
      s.dispose();
    }
  }
}

/// local-storage-bridge.tsx: puts the stored panel sizes and control mode into the store whenever they load or
/// change (a stored node panel width sets both `nodePanelWidth` and `panelWidth`; non-finite numbers and unknown
/// modes are ignored), and stores every change of the store's control mode.
class WorkflowLocalStorageBridge {
  WorkflowLocalStorageBridge(this.store, this.preferences) {
    for (final (stored, apply) in _bindings) {
      stored.addListener(apply);
      apply();
    }
    store.controlMode.addListener(_storeControlMode);
  }

  final WorkflowStore store;
  final WorkflowPreferences preferences;

  late final List<(Listenable, VoidCallback)> _bindings = [
    (preferences.workflowNodePanelWidth, _applyNodePanelWidth),
    (preferences.debugPreviewPanelWidth, _applyPreviewPanelWidth),
    (preferences.workflowVariableInspectPanelHeight, _applyVariableInspectPanelHeight),
    (preferences.workflowOperationMode, _applyControlMode),
  ];

  static bool _finite(double? v) => v != null && v.isFinite;

  void _applyNodePanelWidth() {
    final v = preferences.workflowNodePanelWidth.value;
    if (!_finite(v)) return;
    store.setNodePanelWidth(v!);
    store.setPanelWidth(v);
  }

  void _applyPreviewPanelWidth() {
    final v = preferences.debugPreviewPanelWidth.value;
    if (_finite(v)) store.setPreviewPanelWidth(v!);
  }

  void _applyVariableInspectPanelHeight() {
    final v = preferences.workflowVariableInspectPanelHeight.value;
    if (_finite(v)) store.setVariableInspectPanelHeight(v!);
  }

  void _applyControlMode() {
    final mode = controlModeOf(preferences.workflowOperationMode.value);
    if (mode != null) store.setControlMode(mode);
  }

  void _storeControlMode() {
    final name = store.controlMode.value.name;
    if (preferences.workflowOperationMode.value != name) preferences.workflowOperationMode.value = name;
  }

  void dispose() {
    for (final (stored, apply) in _bindings) {
      stored.removeListener(apply);
    }
    store.controlMode.removeListener(_storeControlMode);
  }
}
