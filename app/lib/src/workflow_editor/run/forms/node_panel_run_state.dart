/// BasePanel's local pause state. A new run clears it; opening the input form while the previous run's status is
/// removed pauses its result view because the backend cannot pause a single-node request.
library;

class NodePanelRunState {
  bool isPaused = false;
  bool _wasRunning = false;

  bool update(Map<String, Object?> data) {
    final before = isPaused;
    if (data['_singleRunningStatus'] == 'running') {
      _wasRunning = true;
      isPaused = false;
    } else if (data['_isSingleRun'] == true && data['_singleRunningStatus'] == null && _wasRunning) {
      isPaused = true;
      _wasRunning = false;
    }
    return before != isPaused;
  }

  void tabChanged() => isPaused = false;
}
