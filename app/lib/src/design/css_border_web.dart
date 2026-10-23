import 'package:web/web.dart' as web;

final _widths = <(double, double), double>{};

/// Ask the browser that hosts skwasm how it lays out a CSS border. In Chromium,
/// emulated DPR and physical browser zoom do not necessarily round subpixel
/// CSS borders alike. Reading the native computed length avoids assuming they do.
double? browserBorderWidth(double width) {
  final body = web.document.body;
  if (body == null) return null;
  final key = (width, web.window.devicePixelRatio);
  if (_widths[key] case final measured?) return measured;
  final probe = web.HTMLDivElement();
  probe.style
    ..position = 'absolute'
    ..visibility = 'hidden'
    ..pointerEvents = 'none'
    ..width = '0'
    ..height = '0'
    ..borderLeft = '${width}px solid transparent';
  try {
    body.appendChild(probe);
    final measured = double.tryParse(web.window.getComputedStyle(probe).borderLeftWidth.replaceAll('px', ''));
    if (measured != null) _widths[key] = measured;
    return measured;
  } finally {
    probe.remove();
  }
}
