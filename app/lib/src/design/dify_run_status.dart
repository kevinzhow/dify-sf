import 'package:flutter/painting.dart';

/// workflow/run/status-container.tsx outer shadows; the custom painter handles its inset shadows.
abstract final class DifyRunStatusShadows {
  static List<BoxShadow> get dark => const [
    BoxShadow(offset: Offset(0, 1), blurRadius: 1.7321, color: Color(0x1A000000)),
    BoxShadow(spreadRadius: 1, color: Color(0xF218181B)),
  ];
  static List<BoxShadow> get light => const [
    BoxShadow(offset: Offset(0, 1), blurRadius: 1.7321, color: Color(0x0D09090B)),
    BoxShadow(spreadRadius: 1, color: Color(0x0D000000)),
  ];
}
