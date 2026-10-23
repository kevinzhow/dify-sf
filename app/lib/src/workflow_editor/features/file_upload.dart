/// File upload (file-upload/index.tsx, setting-modal.tsx, setting-content.tsx) and the workflow's legacy image
/// upload (image-upload/index.tsx).
library;

import 'package:flutter/material.dart';

import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../panel_fields/file_upload_setting.dart';
import '../prompt_editor/prompt_blocks.dart' show fileExts;
import 'features_services.dart';
import 'features_store.dart';
import 'new_feature_panel.dart';
import 'text_to_speech.dart' show FeaturePopover, FeaturePopoverHeader;

/// FileUpload (chatflows): the switch (which sets `file.enabled` and `file.image = {enabled}`), the supported types
/// and the number limit, and while hovered (or while the settings are open) "Settings".
class FileUpload extends StatelessWidget {
  const FileUpload({super.key, this.disabled = false, this.onChange});
  final bool disabled;
  final OnFeaturesChange? onChange;

  @override
  Widget build(BuildContext context) => _FileFeature(disabled: disabled, onChange: onChange, imageUpload: false);
}

/// ImageUpload (workflows): FileUpload's card as "Image Upload" with a LEGACY badge; its settings have no file types.
class ImageUpload extends StatelessWidget {
  const ImageUpload({super.key, this.disabled = false, this.onChange});
  final bool disabled;
  final OnFeaturesChange? onChange;

  @override
  Widget build(BuildContext context) => _FileFeature(disabled: disabled, onChange: onChange, imageUpload: true);
}

class _FileFeature extends StatefulWidget {
  const _FileFeature({required this.disabled, required this.onChange, required this.imageUpload});
  final bool disabled, imageUpload;
  final OnFeaturesChange? onChange;

  @override
  State<_FileFeature> createState() => _FileFeatureState();
}

class _FileFeatureState extends State<_FileFeature> with FeatureHover {
  bool _modalOpen = false;

  void _toggle(bool enabled) {
    final store = FeaturesScope.of(context);
    store.setFeatures(
      withFeature(store.features.value, FeatureEnum.file, {
        'enabled': enabled,
        'image': {'enabled': enabled},
      }),
    );
    widget.onChange?.call();
  }

  @override
  Widget build(BuildContext context) => FeaturesBuilder(
    builder: (context, features) {
      final file = featureMap(features, FeatureEnum.file);
      final enabled = file['enabled'] == true;
      final types = file['allowed_file_types'];
      final supported = types is List && types.isNotEmpty ? types.join(',') : '-';
      final k = widget.imageUpload ? 'feature.imageUpload' : 'feature.fileUpload';
      return FeatureCard(
        icon: widget.imageUpload
            ? FeatureIcon(color: DifyColors.utilColorsIndigoIndigo600, remix: 'image-2-fill')
            : FeatureIcon(color: DifyColors.utilColorsBlueBlue600, dify: 'vender/features/folder-upload'),
        title: widget.imageUpload
            ? Row(
                children: [
                  Flexible(
                    child: DifyTextLine(
                      ad('$k.title'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: difyTextStyle(DifyType.systemSmSemibold, DifyColors.textSecondary),
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: 4),
                    child: DifyBadge('LEGACY', color: DifyColors.textAccentSecondary),
                  ),
                ],
              )
            : ad('$k.title'),
        value: enabled,
        disabled: widget.disabled,
        onChange: _toggle,
        onMouseEnter: () => setHovering(true),
        onMouseLeave: () => setHovering(false),
        child: !enabled
            ? FeatureDescription(ad('$k.description'))
            : (isHovering || _modalOpen)
            ? FileUploadSettings(
                imageUpload: widget.imageUpload,
                open: _modalOpen && !widget.disabled,
                onOpen: (v) => setState(() {
                  _modalOpen = v;
                  isHovering = v;
                }),
                onChange: widget.onChange,
                child: FeatureCardButton(
                  icon: 'equalizer-2-line',
                  label: tc('operation.settings'),
                  disabled: widget.disabled,
                ),
              )
            : FeatureInfo([(ad('$k.supportedTypes'), supported), (ad('$k.numberLimit'), '${file['number_limits']}')]),
      );
    },
  );
}

/// FileUploadSettings (setting-modal.tsx): the popover 32 px left of [child] with [SettingContent]; saving closes it.
class FileUploadSettings extends StatelessWidget {
  const FileUploadSettings({
    super.key,
    required this.open,
    required this.onOpen,
    required this.child,
    this.onChange,
    this.disabled = false,
    this.imageUpload = false,
  });

  final bool open, disabled, imageUpload;
  final ValueChanged<bool> onOpen;
  final OnFeaturesChange? onChange;
  final Widget child;

  @override
  Widget build(BuildContext context) => FeaturePopover(
    open: open,
    onOpenChange: (v) {
      if (!disabled) onOpen(v);
    },
    scrollable: true,
    trigger: child,
    content: SettingContent(
      imageUpload: imageUpload,
      onClose: () => onOpen(false),
      onChange: ([features]) {
        onChange?.call(features);
        onOpen(false);
      },
    ),
  );
}

/// SettingContent: FileUploadSetting over a copy of the file feature (upload methods, number limit and, unless
/// [imageUpload], file types); Save (off without a file type) writes it to the store, then [onChange].
class SettingContent extends StatefulWidget {
  const SettingContent({super.key, required this.onClose, this.onChange, this.imageUpload = false});
  final bool imageUpload;
  final VoidCallback onClose;
  final OnFeaturesChange? onChange;

  @override
  State<SettingContent> createState() => _SettingContentState();
}

class _SettingContentState extends State<SettingContent> {
  late Json _temp = () {
    final file = featureMap(FeaturesScope.of(context).features.value, FeatureEnum.file);
    Object? or(Object? v, Object fallback) => v ?? fallback;
    final limit = file['number_limits'];
    return <String, Object?>{
      'allowed_file_upload_methods': or(file['allowed_file_upload_methods'], const [
        TransferMethod.localFile,
        TransferMethod.remoteUrl,
      ]),
      'allowed_file_types': or(file['allowed_file_types'], const ['image']),
      'allowed_file_extensions': or(file['allowed_file_extensions'], fileExts['image']!),
      'max_length': limit is num && limit != 0 ? limit : 3,
    };
  }();

  void _save() {
    final store = FeaturesScope.of(context);
    store.setFeatures(
      withFeature(store.features.value, FeatureEnum.file, {
        'allowed_file_upload_methods': _temp['allowed_file_upload_methods'],
        'number_limits': _temp['max_length'],
        'allowed_file_types': _temp['allowed_file_types'],
        'allowed_file_extensions': _temp['allowed_file_extensions'],
      }),
    );
    widget.onChange?.call();
  }

  /// useFileSizeLimit over the system's file upload config.
  ({int img, int doc, int audio, int video, int max}) _limits(Json? c) {
    int mb(Object? v, int fallback) {
      final n = num.tryParse('${v ?? ''}');
      return n == null || n == 0 ? fallback : (n * 1024 * 1024).toInt();
    }

    final max = num.tryParse('${c?['workflow_file_upload_limit'] ?? ''}');
    return (
      img: mb(c?['image_file_size_limit'], 10 << 20),
      doc: mb(c?['file_size_limit'], 15 << 20),
      audio: mb(c?['audio_file_size_limit'], 50 << 20),
      video: mb(c?['video_file_size_limit'], 100 << 20),
      max: max == null || max == 0 ? 10 : max.toInt(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final types = _temp['allowed_file_types'];
    final limits = _limits(FeaturesServicesScope.of(context).fileUploadConfig);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        FeaturePopoverHeader(
          title: widget.imageUpload ? ad('feature.imageUpload.modalTitle') : ad('feature.fileUpload.modalTitle'),
          onClose: widget.onClose,
        ),
        FileUploadSetting(
          isMultiple: true,
          inFeaturePanel: true,
          hideSupportFileType: widget.imageUpload,
          payload: _temp,
          maxFileUploadLimit: limits.max,
          sizeLimits: (img: limits.img, doc: limits.doc, audio: limits.audio, video: limits.video),
          onChange: (p) => setState(() => _temp = p),
        ),
        const SizedBox(height: 16),
        FeatureFooter([
          DifyButton(onPressed: widget.onClose, child: DifyTextLine(tc('operation.cancel'))),
          DifyButton(
            variant: DifyButtonVariant.primary,
            disabled: types is! List || types.isEmpty,
            onPressed: _save,
            child: DifyTextLine(tc('operation.save')),
          ),
        ]),
      ],
    );
  }
}
