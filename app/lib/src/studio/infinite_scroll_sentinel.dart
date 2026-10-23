/// base/infinite-scroll-sentinel: a 1 px marker at the end of a scrolling list that asks for more ([onLoadMore])
/// whenever it comes within [preloadDistance] of the viewport's end while [canLoadMore] (Dify's IntersectionObserver
/// with `rootMargin: 0 0 <distance>px 0`: also once when it starts observing and the marker is already there).
library;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// The preload distance, from the scroll position (its viewport size), like Dify's `(scrollContainer) => number`.
typedef PreloadDistance = double Function(ScrollPosition position);

class InfiniteScrollSentinel extends StatefulWidget {
  const InfiniteScrollSentinel({
    super.key,
    required this.canLoadMore,
    required this.onLoadMore,
    required this.preloadDistance,
  });

  final bool canLoadMore;
  final VoidCallback onLoadMore;
  final PreloadDistance preloadDistance;

  /// A fixed distance.
  static PreloadDistance fixed(double distance) =>
      (_) => distance;

  @override
  State<InfiniteScrollSentinel> createState() => _InfiniteScrollSentinelState();
}

class _InfiniteScrollSentinelState extends State<InfiniteScrollSentinel> {
  ScrollPosition? _position;
  bool _inside = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final p = Scrollable.maybeOf(context)?.position;
    if (p == _position) return;
    _position?.removeListener(_check);
    _position = p?..addListener(_check);
    _inside = false;
  }

  @override
  void didUpdateWidget(InfiniteScrollSentinel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A new observer: it reports the current state once.
    if (!oldWidget.canLoadMore && widget.canLoadMore) _inside = false;
  }

  @override
  void dispose() {
    _position?.removeListener(_check);
    super.dispose();
  }

  /// Whether the marker is within the preload area below the viewport (or inside it).
  bool _intersecting() {
    final p = _position, ro = context.findRenderObject();
    if (p == null || ro == null || !ro.attached || !p.hasPixels || !p.hasViewportDimension) return false;
    final viewport = RenderAbstractViewport.maybeOf(ro);
    if (viewport == null) return false;
    final atEnd = viewport.getOffsetToReveal(ro, 1).offset;
    return p.pixels + widget.preloadDistance(p) >= atEnd;
  }

  void _check() {
    if (!mounted || !widget.canLoadMore) return;
    final inside = _intersecting();
    if (inside && !_inside) widget.onLoadMore();
    _inside = inside;
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
    return const SizedBox(height: 1, width: double.infinity);
  }
}
