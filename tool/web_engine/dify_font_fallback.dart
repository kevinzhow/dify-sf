// Copyright 2026 Dify SF contributors. BSD-3-Clause, as Flutter's engine.
part of dart._engine;

// This optional hook connects the existing missing-glyph detector to a host's
// font provider. It does not inspect widgets, modify text or change shaping.
@JS('window.difyFontFallback')
external JSFunction? get _difyFontFallback;
@JS('window.difyFontFamilies')
external JSArray<JSString>? get _difyFontFamilies;
@JS('window.difyFontIdle')
external set _difyFontIdle(JSFunction value);
@JS('window.difyFontStatus')
external set _difyFontStatus(JSFunction value);
@JS('window.difyFontFailure')
external JSFunction? get _difyFontFailure;
@JS('window.difyFontInvalidate')
external set _difyFontInvalidate(JSFunction value);

mixin DifyFontFallback on Object {
  final Set<int> _difyPending = <int>{};
  final Set<int> _difyHandled = <int>{};
  final Set<int> _difyFailed = <int>{};
  bool _difyBusy = false;
  bool _difyInstalled = false;
  int _difyEpoch = 0;

  void _applyDifyFamilies() {
    final FontFallbackManager manager = renderer.fontCollection.fontFallbackManager;
    manager.globalFontFallbacks.removeWhere((String name) => name.startsWith('Dify CJK '));
    final families = _difyFontFamilies;
    if (families != null) {
      // Regional application fonts precede broad Noto fallbacks already loaded
      // for unrelated scripts. A locale switch replaces only our own families.
      manager.globalFontFallbacks.insertAll(0, families.toDart.map((JSString name) => name.toDart));
    }
    manager.updateFallbackFontFamilies();
  }

  void _reportDifyFontFailure() {
    final service = this as FallbackFontService;
    _difyFontFailure?.callAsFunction(null,
      (_difyFailed.isNotEmpty || service._permanentlyUnavailableFonts.isNotEmpty).toJS);
  }

  bool _queueDifyFonts(List<int> points) {
    if (_difyFontFallback == null) return false;
    final service = this as FallbackFontService;
    if (!_difyInstalled) {
      _difyInstalled = true;
      _difyFontIdle = (() => service.waitForIdle().then((_) => true.toJS).toJS).toJS;
      _difyFontStatus = (() => <String, Object?>{
        'pending': _difyPending.length + service._unprocessedCodePoints.length,
        'busy': _difyBusy || service._pendingFonts.isNotEmpty,
        'failed': _difyFailed.length + service._permanentlyUnavailableFonts.length,
      }.jsify() as JSObject).toJS;
      _difyFontInvalidate = (() {
        _difyEpoch++;
        _difyHandled.clear();
        final retry = <int>{..._difyFailed, ...service._unsupportedCodePoints, ...service._unprocessedCodePoints}.toList();
        _difyFailed.clear();
        // Explicit user/online retry reopens failed upstream downloads while
        // retaining every successfully registered font and its coverage cache.
        service._unsupportedCodePoints.clear();
        service._permanentlyUnavailableFonts.clear();
        service._failedFontsPerComponent.clear();
        service._totalPermanentFailures = 0;
        service._isBroken = false;
        _applyDifyFamilies();
        service._notifyFontsChanged();
        _queueDifyFonts(retry);
      }).toJS;
    }
    for (final int cp in points) {
      if (!_difyHandled.contains(cp) && !_difyFailed.contains(cp)) _difyPending.add(cp);
    }
    if (_difyPending.isNotEmpty) {
      service._idleCompleter ??= Completer<void>();
      if (!_difyBusy) unawaited(_loadDifyFonts());
    }
    return true;
  }

  Future<void> _loadDifyFonts() async {
    _difyBusy = true;
    // Batch the existing paragraph requests of this frame before selecting shards.
    await Future<void>.delayed(Duration.zero);
    final points = _difyPending.toList();
    _difyPending.clear();
    final int epoch = _difyEpoch;
    final service = this as FallbackFontService;
    try {
      final result = _difyFontFallback!.callAsFunction(null, points.map((int cp) => cp.toJS).toList().toJS);
      final remaining = (await (result as JSPromise<JSArray<JSNumber>>).toDart).toDart.map((JSNumber cp) => cp.toDartInt).toList();
      if (epoch == _difyEpoch) {
        _difyHandled.addAll(points);
        _difyPending.removeAll(points);
        _applyDifyFamilies();
        service._notifyFontsChanged();
        // Preserve upstream fallback behavior for glyphs outside our real cmap.
        service._addStandardMissingCodePoints(remaining);
      } else {
        _difyPending.addAll(points);
      }
    } catch (_) {
      // App-owned error/retry UI keeps this recoverable. Do not substitute a
      // different CJK font, permanently blacklist it, or start a per-frame retry.
      if (epoch == _difyEpoch) { _difyFailed.addAll(points); }
      else { _difyPending.addAll(points); }
      printWarning('A self-hosted font shard is unavailable; retry after reconnecting.');
    } finally {
      _difyBusy = false;
      if (_difyPending.isNotEmpty) unawaited(_loadDifyFonts());
      service._checkIdle();
    }
  }
}
