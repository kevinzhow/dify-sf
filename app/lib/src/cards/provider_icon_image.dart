/// A model provider's icon (`icon_small` / `icon_small_dark` URLs of the console's responses), drawn like Dify's
/// `<img>`: the server answers SVG for most providers (which `Image` cannot decode) and PNG for some, so the bytes are
/// fetched once and drawn as SVG or as an image by their type.
library;

import 'dart:async';

import 'package:collab_client/collab_client.dart' show ModelProviderIcon;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Where icons come from: the workspace's models (relative URLs, fetched through the server's API) or, by default,
/// the network (absolute URLs). [peek] answers what is already loaded, so a rebuilt icon draws in its first frame.
abstract class ProviderIconSource {
  /// Whether the icon at [url] was loaded (successfully or not), and its icon.
  (bool, ModelProviderIcon?) peek(String url);

  /// Loads the icon at [url] (once); null when there is none.
  Future<ModelProviderIcon?> load(String url);
}

/// A [ProviderIconSource] over a loader, caching its answers.
class CachedProviderIconSource implements ProviderIconSource {
  CachedProviderIconSource(this._loader);

  final Future<ModelProviderIcon?> Function(String url) _loader;
  final _done = <String, ModelProviderIcon?>{};
  final _pending = <String, Future<ModelProviderIcon?>>{};

  @override
  (bool, ModelProviderIcon?) peek(String url) => (_done.containsKey(url), _done[url]);

  @override
  Future<ModelProviderIcon?> load(String url) => _pending[url] ??= () async {
    ModelProviderIcon? icon;
    try {
      icon = await _loader(url);
    } on Object {
      icon = null;
    }
    // A failure is not remembered: the next icon tries again.
    if (icon != null) _done[url] = icon;
    _pending.remove(url);
    return icon;
  }();
}

/// Hands the workspace's icon source to the icons below it. Without one, [fallback] (by default URLs are fetched from
/// the network as they are).
class ProviderIconScope extends InheritedWidget {
  const ProviderIconScope({super.key, required this.source, required super.child});

  final ProviderIconSource source;

  static ProviderIconSource of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ProviderIconScope>()?.source ?? fallback;

  /// The source of icons outside any scope (dialog routes opened from the editor): the open editor's workspace sets
  /// it; absolute URLs from the network otherwise.
  static ProviderIconSource fallback = networkProviderIcons;

  @override
  bool updateShouldNotify(ProviderIconScope oldWidget) => source != oldWidget.source;
}

/// Absolute icon URLs, fetched from the network.
final ProviderIconSource networkProviderIcons = CachedProviderIconSource((url) async {
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasScheme) return null;
  final data = await NetworkAssetBundle(uri).load(url);
  final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  return ModelProviderIcon(bytes: bytes, contentType: sniffIconType(bytes));
});

/// `image/svg+xml` for markup, else `image/png`.
String sniffIconType(List<int> bytes) {
  final head = String.fromCharCodes(bytes.take(256)).trimLeft();
  return head.startsWith('<') ? 'image/svg+xml' : 'image/png';
}

/// The icon at [url] in a [width] x [height] box (contained); nothing while loading or when it cannot be loaded.
class ProviderIconImage extends StatefulWidget {
  const ProviderIconImage(this.url, {super.key, required this.width, required this.height});

  final String url;
  final double width, height;

  @override
  State<ProviderIconImage> createState() => _ProviderIconImageState();
}

class _ProviderIconImageState extends State<ProviderIconImage> {
  ProviderIconSource? _source;
  String? _url;
  ModelProviderIcon? _icon;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _load();
  }

  @override
  void didUpdateWidget(ProviderIconImage old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) _load();
  }

  void _load() {
    final source = ProviderIconScope.of(context);
    final url = widget.url;
    if (identical(source, _source) && url == _url) return;
    _source = source;
    _url = url;
    final (loaded, icon) = source.peek(url);
    _icon = icon;
    if (loaded) return;
    unawaited(
      source.load(url).then((icon) {
        if (mounted && _url == url && identical(_source, source)) setState(() => _icon = icon);
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final icon = _icon;
    final size = Size(widget.width, widget.height);
    if (icon == null) return SizedBox.fromSize(size: size);
    final bytes = icon.bytes is Uint8List ? icon.bytes as Uint8List : Uint8List.fromList(icon.bytes);
    return SizedBox.fromSize(
      size: size,
      child: icon.isSvg
          ? SvgPicture.memory(bytes, fit: BoxFit.contain)
          : Image.memory(
              bytes,
              fit: BoxFit.contain,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => const SizedBox(),
            ),
    );
  }
}
