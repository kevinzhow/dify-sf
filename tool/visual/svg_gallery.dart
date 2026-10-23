// Standalone Web rendering probe for svg_inventory.py. This is not part of the product's navigation.
import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;

@JS('__svgReady')
external set _ready(JSString value);

void main() => runApp(const Directionality(textDirection: TextDirection.ltr, child: _Gallery()));

class _Gallery extends StatefulWidget {
  const _Gallery();
  @override
  State<_Gallery> createState() => _GalleryState();
}

class _GalleryState extends State<_Gallery> {
  late final Future<List<dynamic>> _index = http
      .get(Uri.base.resolve('/index.json'))
      .then((r) => jsonDecode(r.body) as List);
  late final JSFunction _onHash = ((web.Event _) {
    unawaited(_load());
  }).toJS;
  PictureInfo? _picture;
  bool _dark = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    web.window.addEventListener('hashchange', _onHash);
    _load();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    final hash = web.window.location.hash;
    if (hash.isEmpty) return;
    final id = hash.substring(1);
    try {
      final index = await _index;
      final row = index.cast<Map<String, dynamic>>().singleWhere((row) => row['id'] == id);
      final dark = row['dark'] == true;
      final response = await http.get(Uri.base.resolve('/svg/$id.svg'));
      if (response.statusCode != 200) throw StateError('SVG response ${response.statusCode}');
      final loader = SvgStringLoader(
        response.body,
        theme: SvgTheme(currentColor: dark ? const ui.Color(0xfff9fafb) : const ui.Color(0xff101828)),
      );
      var info = await vg.loadPicture(loader, null);
      final scale = 80 / math.max(info.size.width, info.size.height);
      if (info.requiresRasterResolution && scale != 1) {
        info.picture.dispose();
        info = await vg.loadPicture(loader, null, filterRasterScale: scale);
      }
      if (!mounted || generation != _generation) {
        info.picture.dispose();
        return;
      }
      final old = _picture;
      setState(() {
        _picture = info;
        _dark = dark;
      });
      old?.picture.dispose();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (generation == _generation) _ready = id.toJS;
      });
    } catch (error) {
      _ready = 'ERROR $id $error'.toJS;
    }
  }

  @override
  void dispose() {
    web.window.removeEventListener('hashchange', _onHash);
    _picture?.picture.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topLeft,
    child: SizedBox(width: 40, height: 40, child: CustomPaint(painter: _Icon(_picture, _dark))),
  );
}

class _Icon extends CustomPainter {
  const _Icon(this.info, this.dark);
  final PictureInfo? info;
  final bool dark;
  @override
  void paint(ui.Canvas canvas, ui.Size size) {
    canvas.drawColor(dark ? const ui.Color(0xff101828) : const ui.Color(0xffffffff), ui.BlendMode.src);
    final picture = info;
    if (picture == null) return;
    final scale = math.min(size.width / picture.size.width, size.height / picture.size.height);
    canvas.save();
    canvas.translate((size.width - picture.size.width * scale) / 2, (size.height - picture.size.height * scale) / 2);
    canvas.scale(scale);
    canvas.drawPicture(picture.picture);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_Icon old) => info != old.info || dark != old.dark;
}
