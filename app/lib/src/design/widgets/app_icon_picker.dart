/// Dify's app-icon-picker and emoji-picker/Inner. Reuses its pinned Emoji Mart data, color palette and the
/// app's dialog/buttons. Image persistence is injected by the host, like the Agent console's upload service.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as image;

import '../../i18n/dify_i18n.dart';
import '../dify_tokens.g.dart';
import 'emoji_catalog.dart';
import 'widgets.dart';

export 'emoji_catalog.dart';

typedef IconFile = ({String name, Uint8List bytes});
typedef UploadedAppIcon = ({String fileId, String url});
typedef UploadAppIcon = Future<UploadedAppIcon> Function(IconFile file);

Future<IconFile?> pickAppIconFile() async {
  final file = await openFile(
    acceptedTypeGroups: [
      const XTypeGroup(
        label: 'Images',
        extensions: ['png', 'jpg', 'jpeg', 'webp', 'gif', 'bmp'],
        uniformTypeIdentifiers: ['public.image'],
      ),
    ],
  );
  if (file == null) return null;
  return (name: file.name, bytes: await file.readAsBytes());
}

Future<Map<String, Object?>?> showAppIconPicker(
  BuildContext context, {
  ({String icon, String? background})? initialEmoji,
  UploadAppIcon? upload,
  Future<IconFile?> Function()? pickFile,
}) => showDifyDialog<Map<String, Object?>>(
  context,
  builder: (context) => DifyAppIconPicker(
    initialEmoji: initialEmoji,
    upload: upload,
    pickFile: pickFile,
    onSelect: (value) => Navigator.pop(context, value),
    onCancel: () => Navigator.pop(context),
  ),
);

class DifyAppIconPicker extends StatefulWidget {
  const DifyAppIconPicker({
    super.key,
    this.initialEmoji,
    this.upload,
    this.enableImageUpload = true,
    this.imageOnly = false,
    this.onDelete,
    this.pickFile,
    required this.onSelect,
    required this.onCancel,
  });
  final ({String icon, String? background})? initialEmoji;
  final UploadAppIcon? upload;
  final bool enableImageUpload;

  /// Avatar uses the same crop/upload implementation, without emoji choices.
  final bool imageOnly;
  final Future<void> Function()? onDelete;
  final Future<IconFile?> Function()? pickFile;
  final ValueChanged<Map<String, Object?>> onSelect;
  final VoidCallback onCancel;
  @override
  State<DifyAppIconPicker> createState() => _DifyAppIconPickerState();
}

class _DifyAppIconPickerState extends State<DifyAppIconPicker> {
  late String _emoji = widget.initialEmoji?.icon ?? '';
  late String _background = widget.initialEmoji?.background ?? iconEmojiBackgrounds.first;
  late bool _styles = _emoji.isNotEmpty;
  final _catalog = EmojiCatalog.load();
  String _query = '';
  late bool _imageTab = widget.imageOnly;
  bool _uploading = false;
  IconFile? _file;
  image.Image? _decoded;
  final _transform = TransformationController();
  static const _cropSize = 264.0;

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  String _t(String key) => DifyI18n.tr('app', 'iconPicker.$key');
  Color _color(String value) => Color(0xFF000000 | int.parse(value.substring(1), radix: 16));

  Future<void> _pick() async {
    try {
      final file = await (widget.pickFile ?? pickAppIconFile)();
      if (file == null || !mounted) return;
      if (file.bytes.length > 3 * 1024 * 1024) {
        throw FormatException(DifyI18n.tr('common', 'imageUploader.uploadFromComputerLimit', {'size': 3}));
      }
      final decoded = image.decodeImage(file.bytes);
      if (decoded == null) throw FormatException(DifyI18n.tr('common', 'imageUploader.uploadFromComputerReadError'));
      if (decoded.width * decoded.height > 16 * 1024 * 1024) {
        throw FormatException(DifyI18n.tr('common', 'imageUploader.uploadFromComputerReadError'));
      }
      final scale = _cropSize / math.min(decoded.width, decoded.height);
      setState(() {
        _file = file;
        _decoded = decoded;
      });
      _transform.value = Matrix4.translationValues(
        -(decoded.width * scale - _cropSize) / 2,
        -(decoded.height * scale - _cropSize) / 2,
        0,
      );
    } on Object catch (e) {
      if (mounted) toast.error(e is FormatException ? e.message : '$e');
    }
  }

  Future<void> _select() async {
    if (_uploading) return;
    if (!_imageTab) {
      if (_emoji.isNotEmpty) widget.onSelect({'type': 'emoji', 'icon': _emoji, 'background': _background});
      return;
    }
    final decoded = _decoded, upload = widget.upload;
    if (decoded == null) return;
    setState(() => _uploading = true);
    try {
      final baseScale = _cropSize / math.min(decoded.width, decoded.height);
      final topLeft = MatrixUtils.transformPoint(Matrix4.inverted(_transform.value), Offset.zero) / baseScale;
      final size = (_cropSize / (_transform.value.getMaxScaleOnAxis() * baseScale))
          .round()
          .clamp(1, math.min(decoded.width, decoded.height))
          .toInt();
      final cropped = image.copyCrop(
        decoded,
        x: topLeft.dx.round().clamp(0, decoded.width - size).toInt(),
        y: topLeft.dy.round().clamp(0, decoded.height - size).toInt(),
        width: size,
        height: size,
      );
      if (upload == null) throw UnsupportedError('No file upload service');
      final value = await upload(
        decoded.numFrames > 1 ? _file! : (name: '${_file!.name}.png', bytes: image.encodePng(cropped)),
      );
      if (mounted) widget.onSelect({'type': 'image', 'fileId': value.fileId, 'url': value.url});
    } on Object {
      if (mounted) toast.error(DifyI18n.tr('common', 'imageUploader.uploadFromComputerUploadError'));
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Widget _emojiButton(IconEmoji emoji, {bool search = false}) => Tooltip(
    message: emoji.name,
    child: Semantics(
      label: emoji.native,
      selected: _emoji == emoji.native,
      child: InkWell(
        key: ValueKey('icon-${search ? 'search' : 'emoji'}-${emoji.id}'),
        borderRadius: BorderRadius.circular(8),
        onTap: () => setState(() {
          _emoji = emoji.native;
          _styles = true;
        }),
        child: Center(child: Text(emoji.native, style: const TextStyle(fontSize: 24, height: 1))),
      ),
    ),
  );

  Widget _grid(List<IconEmoji> emojis, {bool search = false}) => SliverGrid(
    delegate: SliverChildBuilderDelegate(
      (context, i) => _emojiButton(emojis[i], search: search),
      childCount: emojis.length,
    ),
    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: 8,
      mainAxisSpacing: 4,
      crossAxisSpacing: 4,
    ),
  );

  Widget _emojiPicker() => FutureBuilder<EmojiCatalog>(
    future: _catalog,
    initialData: EmojiCatalog.loaded,
    builder: (context, snapshot) {
      final data = snapshot.data;
      if (data == null) {
        return Center(child: snapshot.hasError ? Text('${snapshot.error}') : const CircularProgressIndicator());
      }
      final native = data.emojis[_emoji]?.native ?? _emoji;
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: DifyInput(
              key: const ValueKey('icon-emoji-search'),
              value: _query,
              placeholder: 'Search emojis...',
              onChanged: (query) => setState(() => _query = query),
            ),
          ),
          Divider(height: 1, color: DifyColors.dividerRegular),
          Expanded(
            child: CustomScrollView(
              slivers: [
                if (_query.isNotEmpty) ...[
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                    sliver: SliverToBoxAdapter(
                      child: Text(
                        'Search',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: DifyColors.textPrimary),
                      ),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    sliver: _grid(data.search(_query), search: true),
                  ),
                ],
                for (final category in data.categories) ...[
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                    sliver: SliverToBoxAdapter(
                      child: Text(
                        category.id.toUpperCase(),
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: DifyColors.textPrimary),
                      ),
                    ),
                  ),
                  SliverPadding(padding: const EdgeInsets.symmetric(horizontal: 12), sliver: _grid(category.emojis)),
                ],
              ],
            ),
          ),
          TextButton(
            onPressed: () => setState(() => _styles = !_styles),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [const Text('Choose Style'), Icon(_styles ? Icons.expand_less : Icons.expand_more, size: 16)],
            ),
          ),
          if (_styles)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
              child: GridView.count(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                crossAxisCount: 8,
                mainAxisSpacing: 4,
                crossAxisSpacing: 4,
                children: [
                  for (final color in iconEmojiBackgrounds)
                    Semantics(
                      label: color,
                      selected: _background == color,
                      child: InkWell(
                        key: ValueKey('icon-color-$color'),
                        onTap: () => setState(() => _background = color),
                        borderRadius: BorderRadius.circular(8),
                        child: Center(
                          child: Container(
                            width: 32,
                            height: 32,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: _color(color),
                              borderRadius: BorderRadius.circular(6),
                              border: _background == color
                                  ? Border.all(color: DifyColors.componentsInputBorderHover)
                                  : null,
                            ),
                            child: Text(native, style: const TextStyle(fontSize: 20, height: 1)),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      );
    },
  );

  Widget _imagePicker() {
    final decoded = _decoded;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (_file != null && decoded != null)
          SizedBox(
            width: _cropSize,
            height: _cropSize,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(widget.imageOnly ? _cropSize / 2 : 0),
              child: InteractiveViewer(
                transformationController: _transform,
                constrained: false,
                minScale: 1,
                maxScale: 3,
                child: Image.memory(
                  _file!.bytes,
                  fit: BoxFit.fill,
                  width: decoded.width * _cropSize / math.min(decoded.width, decoded.height),
                  height: decoded.height * _cropSize / math.min(decoded.width, decoded.height),
                ),
              ),
            ),
          ),
        DifyButton(
          key: const ValueKey('app-icon-pick-image'),
          onPressed: _uploading ? null : _pick,
          child: Text(DifyI18n.tr('common', 'imageUploader.uploadFromComputer')),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_uploading,
    child: DifyDialogSurface(
      label: widget.imageOnly ? DifyI18n.tr('common', 'avatar.editAction') : _t('emoji'),
      width: 362,
      height: math.min(462, MediaQuery.sizeOf(context).height - 32),
      padding: EdgeInsets.zero,
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          children: [
            if (widget.enableImageUpload && !widget.imageOnly)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        onPressed: _uploading ? null : () => setState(() => _imageTab = false),
                        child: Text(_t('emoji')),
                      ),
                    ),
                    Expanded(
                      child: TextButton(
                        onPressed: _uploading ? null : () => setState(() => _imageTab = true),
                        child: Text(_t('image')),
                      ),
                    ),
                  ],
                ),
              ),
            Expanded(child: _imageTab ? _imagePicker() : _emojiPicker()),
            Divider(height: 1, color: DifyColors.dividerRegular),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                spacing: 8,
                children: [
                  if (widget.onDelete != null)
                    DifyButton(
                      key: const ValueKey('avatar-delete'),
                      tone: DifyButtonTone.destructive,
                      disabled: _uploading,
                      onPressed: () async {
                        final removed = await showDifyConfirm(
                          context,
                          title: DifyI18n.tr('common', 'avatar.deleteTitle'),
                          description: DifyI18n.tr('common', 'avatar.deleteDescription'),
                          onConfirm: widget.onDelete,
                          lockCancelWhileBusy: true,
                        );
                        if (removed && context.mounted) widget.onCancel();
                      },
                      child: Text(DifyI18n.tr('common', 'operation.delete')),
                    ),
                  Expanded(
                    child: DifyButton(disabled: _uploading, onPressed: widget.onCancel, child: Text(_t('cancel'))),
                  ),
                  Expanded(
                    child: DifyButton(
                      variant: DifyButtonVariant.primary,
                      loading: _uploading,
                      disabled: _imageTab && _decoded == null,
                      onPressed: _select,
                      child: Text(_t('ok')),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
