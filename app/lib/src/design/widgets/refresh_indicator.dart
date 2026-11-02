/// dify-sf's phone pull to refresh (a dify-sf divergence: Dify's console refetches without a gesture). Built on the
/// widgets layer: no Material RefreshIndicator.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../dify_tokens.g.dart';
import 'loading.dart' show DifySpinner;

/// Pull to refresh around a vertical scroll view ([child]; give it `AlwaysScrollableScrollPhysics` so that a short
/// list can be pulled too). Dragging the list down past its top edge brings a [discSize] components-panel-bg disc
/// (`shadow-md`) with a text-accent spinner down from the top; released past [triggerDistance] it calls
/// [onRefresh] and the disc rests below the edge, spinning, until the returned future completes. Released earlier,
/// it goes back. The platform's overscroll glow or stretch is suppressed while pulling.
class DifyRefreshIndicator extends StatefulWidget {
  const DifyRefreshIndicator({
    super.key,
    required this.onRefresh,
    required this.child,
    this.triggerDistance = 72,
    this.restOffset = 16,
    this.semanticsLabel,
  });

  static const discSize = 40.0;

  final Future<void> Function() onRefresh;
  final Widget child;

  /// How far the list has to be pulled past its edge to refresh.
  final double triggerDistance;

  /// Where the disc rests below the top edge while refreshing.
  final double restOffset;

  /// Announced while refreshing.
  final String? semanticsLabel;

  @override
  State<DifyRefreshIndicator> createState() => DifyRefreshIndicatorState();
}

enum _Mode { idle, drag, armed, refreshing, done }

class DifyRefreshIndicatorState extends State<DifyRefreshIndicator> with SingleTickerProviderStateMixin {
  /// 0 = hidden, 1 = at [DifyRefreshIndicator.triggerDistance]; the disc follows the finger with resistance.
  late final _pull = AnimationController(vsync: this, upperBound: 1.5, duration: const Duration(milliseconds: 200));
  _Mode _mode = _Mode.idle;
  double _drag = 0;

  bool get refreshing => _mode == _Mode.refreshing;

  @override
  void dispose() {
    _pull.dispose();
    super.dispose();
  }

  /// Shows the indicator and runs [DifyRefreshIndicator.onRefresh], as a completed pull does.
  Future<void> show() => _start();

  bool _atTop(ScrollMetrics m) => m.extentBefore == 0 || m.pixels <= m.minScrollExtent;

  bool _onScroll(ScrollNotification n) {
    if (n.metrics.axis != Axis.vertical || n.depth != 0) return false;
    if (_mode == _Mode.refreshing || _mode == _Mode.done) return false;
    switch (n) {
      case ScrollStartNotification(dragDetails: _?) when _atTop(n.metrics):
        _mode = _Mode.drag;
        _drag = 0;
        _setPull(0);
      case ScrollUpdateNotification(:final dragDetails?) when _mode == _Mode.drag || _mode == _Mode.armed:
        // A bouncing list scrolls past its edge (pixels below the minimum); a clamping one reports overscroll.
        if (n.metrics.pixels < n.metrics.minScrollExtent) {
          _drag = n.metrics.minScrollExtent - n.metrics.pixels;
        } else if ((n.scrollDelta ?? 0) > 0) {
          _drag = math.max(0, _drag - n.scrollDelta!);
        }
        if (dragDetails.primaryDelta case final d? when d < 0 && _drag == 0) _cancel();
        _update();
      case OverscrollNotification(dragDetails: _?) when _mode == _Mode.drag || _mode == _Mode.armed:
        if (n.overscroll < 0) _drag -= n.overscroll;
        _update();
      case ScrollEndNotification() when _mode == _Mode.drag || _mode == _Mode.armed:
        _mode == _Mode.armed ? unawaited(_start()) : _cancel();
      default:
        break;
    }
    return false;
  }

  void _update() {
    if (_mode != _Mode.drag && _mode != _Mode.armed) return;
    final t = _drag / widget.triggerDistance;
    _mode = t >= 1 ? _Mode.armed : _Mode.drag;
    _setPull(t);
  }

  void _setPull(double t) {
    // Resistance past the trigger distance.
    final v = t <= 1 ? t : 1 + (1 - 1 / (1 + (t - 1)));
    _pull.value = v.clamp(0, 1.5);
    setState(() {});
  }

  void _cancel() {
    _mode = _Mode.idle;
    _drag = 0;
    unawaited(_pull.animateTo(0, curve: Curves.easeOut));
    setState(() {});
  }

  Future<void> _start() async {
    if (_mode == _Mode.refreshing) return;
    setState(() => _mode = _Mode.refreshing);
    unawaited(_pull.animateTo(1, curve: Curves.easeOut));
    try {
      await widget.onRefresh();
    } finally {
      if (mounted) {
        setState(() => _mode = _Mode.done);
        await _pull.animateTo(0, curve: Curves.easeIn);
        if (mounted) {
          setState(() {
            _mode = _Mode.idle;
            _drag = 0;
          });
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final indicator = AnimatedBuilder(
      animation: _pull,
      builder: (context, _) {
        final v = _pull.value;
        if (v <= 0 && _mode == _Mode.idle) return const SizedBox.shrink();
        final travel = widget.restOffset + DifyRefreshIndicator.discSize;
        final top = -DifyRefreshIndicator.discSize + travel * v;
        return Positioned(
          top: top,
          left: 0,
          right: 0,
          child: Center(
            child: Opacity(
              opacity: v.clamp(0, 1),
              child: Semantics(
                liveRegion: true,
                label: _mode == _Mode.refreshing ? widget.semanticsLabel : null,
                child: Container(
                  key: const ValueKey('dify-refresh-indicator'),
                  width: DifyRefreshIndicator.discSize,
                  height: DifyRefreshIndicator.discSize,
                  decoration: BoxDecoration(
                    color: DifyColors.componentsPanelBg,
                    shape: BoxShape.circle,
                    boxShadow: DifyShadows.md,
                  ),
                  alignment: Alignment.center,
                  child: _mode == _Mode.refreshing || _mode == _Mode.done
                      ? DifySpinner(color: DifyColors.textAccent, size: 20)
                      : Transform.rotate(
                          angle: v * math.pi * 1.5,
                          child: DifySpinner(color: DifyColors.textAccent, size: 20),
                        ),
                ),
              ),
            ),
          ),
        );
      },
    );
    return NotificationListener<OverscrollIndicatorNotification>(
      onNotification: (n) {
        if (n.depth == 0 && n.leading && _mode != _Mode.idle) n.disallowIndicator();
        return false;
      },
      child: NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        child: Stack(
          fit: StackFit.passthrough,
          clipBehavior: Clip.hardEdge,
          children: [widget.child, indicator],
        ),
      ),
    );
  }
}
