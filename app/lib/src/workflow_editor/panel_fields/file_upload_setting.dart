/// FileUploadSetting (nodes/_base/components/file-upload-setting.tsx, file-type-item.tsx): the supported file
/// types, the upload method and, for lists, the maximum number of uploads, as the Start node's input field dialog and
/// the human input form use it.
library;

import 'package:flutter/material.dart';

import '../../cards/card_kit.dart';
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';
import '../../workflow/dify_json.dart';
import '../prompt_editor/prompt_blocks.dart' show fileExts;
import 'field.dart';
import 'form_controls.dart';

/// `formatFileSize` (utils/format.ts).
String formatFileSize(num size) {
  const units = ['', 'K', 'M', 'G', 'T', 'P'];
  var i = 0;
  var s = size.toDouble();
  while (s >= 1024 && i < units.length) {
    s /= 1024;
    i++;
  }
  return i == 0 ? '${s.toStringAsFixed(2)} bytes' : '${s.toStringAsFixed(2)} ${units[i]}B';
}

/// FileUploadSetting: the supported file types, the upload method and, for lists, the maximum number of uploads. In
/// the features panel ([inFeaturePanel]) the file types come last, and not at all with [hideSupportFileType] (the
/// legacy image upload).
class FileUploadSetting extends StatelessWidget {
  const FileUploadSetting({
    super.key,
    required this.payload,
    required this.isMultiple,
    required this.onChange,
    this.maxFileUploadLimit = 10,
    this.validationError,
    this.sizeLimits = const (img: 10 << 20, doc: 15 << 20, audio: 50 << 20, video: 100 << 20),
    this.inFeaturePanel = false,
    this.hideSupportFileType = false,
  });

  final bool inFeaturePanel, hideSupportFileType;

  final Map<String, Object?> payload;
  final bool isMultiple;
  final ValueChanged<Map<String, Object?>> onChange;
  final int maxFileUploadLimit;
  final ({String field, String message})? validationError;

  /// `useFileSizeLimit`'s limits in bytes (the file upload config's, else Dify's fallbacks).
  final ({int img, int doc, int audio, int video}) sizeLimits;

  List<String> _strings(String key) => [for (final v in jsList(payload[key])) jsKey(v)];

  /// handleSupportFileTypeChange: custom excludes the others.
  void _toggleType(String type) {
    var types = _strings('allowed_file_types');
    if (type == 'custom') {
      types = types.contains('custom') ? types.where((v) => v != type).toList() : ['custom'];
    } else {
      types = types.where((v) => v != 'custom').toList();
      types = types.contains(type) ? types.where((v) => v != type).toList() : [...types, type];
    }
    onChange({...payload, 'allowed_file_types': types});
  }

  @override
  Widget build(BuildContext context) {
    String ad(String key, [Map<String, Object?> p = const {}]) => DifyI18n.tr('app-debug', key, p);
    final types = _strings('allowed_file_types');
    final methods = _strings('allowed_file_upload_methods');
    final selectedMethod = methods.contains('local_file')
        ? (methods.contains('remote_url') ? 'all' : 'local_file')
        : (methods.contains('remote_url') ? 'remote_url' : null);
    final max = payload['max_length'];
    final fileTypes = ModalField(
      title: ad('variableConfig.file.supportFileTypes'),
      errorMessage: validationError?.message,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 4,
        children: [
          for (final t in const ['document', 'image', 'audio', 'video'])
            _FileTypeItem(type: t, selected: types.contains(t), onToggle: _toggleType),
          _FileTypeItem(
            type: 'custom',
            selected: types.contains('custom'),
            onToggle: _toggleType,
            customFileTypes: _strings('allowed_file_extensions'),
            onCustomFileTypesChange: (v) => onChange({...payload, 'allowed_file_extensions': v}),
          ),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!inFeaturePanel) fileTypes,
        const SizedBox(height: 16),
        SizedBox(
          height: 32,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              ad('variableConfig.uploadFileTypes'),
              style: difyTextStyle(DifyType.systemSmSemibold, DifyColors.textSecondary),
            ),
          ),
        ),
        Row(
          spacing: 8,
          children: [
            for (final (value, label) in [
              ('local_file', ad('variableConfig.localUpload')),
              ('remote_url', 'URL'),
              ('all', ad('variableConfig.both')),
            ])
              Expanded(
                child: OptionCard(
                  title: label,
                  selected: selectedMethod == value,
                  onSelect: () => onChange({
                    ...payload,
                    'allowed_file_upload_methods': value == 'all' ? ['local_file', 'remote_url'] : [value],
                  }),
                ),
              ),
          ],
        ),
        if (isMultiple) ...[
          const SizedBox(height: 16),
          ModalField(
            title: ad('variableConfig.maxNumberOfUploads'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    ad('variableConfig.maxNumberTip', {
                      'imgLimit': formatFileSize(sizeLimits.img),
                      'docLimit': formatFileSize(sizeLimits.doc),
                      'audioLimit': formatFileSize(sizeLimits.audio),
                      'videoLimit': formatFileSize(sizeLimits.video),
                    }),
                    style: difyTextStyle(DifyType.bodyXsRegular, DifyColors.textTertiary),
                  ),
                ),
                InputNumberWithSlider(
                  label: ad('variableConfig.maxNumberOfUploads'),
                  value: max is num ? max.toInt() : 1,
                  defaultValue: 1,
                  min: 1,
                  max: maxFileUploadLimit,
                  onChange: (v) =>
                      onChange({...payload, 'max_length': (v.isFinite ? v.round() : 1).clamp(1, maxFileUploadLimit)}),
                ),
              ],
            ),
          ),
        ],
        if (inFeaturePanel && !hideSupportFileType) ...[const SizedBox(height: 16), fileTypes],
      ],
    );
  }
}

/// file-type-item.tsx: an option card with the file type's icon, name, extensions and checkbox; the custom type,
/// when selected, edits its extensions in a tag input.
class _FileTypeItem extends StatefulWidget {
  const _FileTypeItem({
    required this.type,
    required this.selected,
    required this.onToggle,
    this.customFileTypes = const [],
    this.onCustomFileTypesChange,
  });
  final String type;
  final bool selected;
  final ValueChanged<String> onToggle;
  final List<String> customFileTypes;
  final ValueChanged<List<String>>? onCustomFileTypesChange;

  @override
  State<_FileTypeItem> createState() => _FileTypeItemState();
}

class _FileTypeItemState extends State<_FileTypeItem> {
  bool _hovered = false;

  static const _icons = {
    'image': ('file-image-fill', Color(0xFF00B2EA)),
    'document': ('file-text-fill', Color(0xFF6F8BB5)),
    'audio': ('file-music-fill', Color(0xFFFF3093)),
    'video': ('file-video-fill', Color(0xFF844FDA)),
    'custom': ('file-3-fill', Color(0xFFBCC0D1)),
  };

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final name = DifyI18n.tr('app-debug', 'variableConfig.file.${w.type}.name');
    final (icon, color) = _icons[w.type]!;
    final customSelected = w.type == 'custom' && w.selected;
    final head = Row(
      children: [
        RemixIcon(icon, size: 20, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DifyText(name, DifyType.systemSmMedium, color: DifyColors.textPrimary),
              if (!customSelected)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: DifyText(
                    w.type == 'custom'
                        ? DifyI18n.tr('app-debug', 'variableConfig.file.custom.description')
                        : fileExts[w.type]!.join(', '),
                    DifyType.system2xsRegularUppercase,
                    color: DifyColors.textTertiary,
                    maxLines: null,
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        ExcludeFocus(
          child: DifyCheckbox(checked: w.selected, label: name, onChanged: (_) => w.onToggle(w.type)),
        ),
      ],
    );
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => w.onToggle(w.type),
        child: Container(
          padding: customSelected ? null : const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: w.selected
                ? DifyColors.componentsOptionCardOptionSelectedBg
                : _hovered
                ? DifyColors.componentsOptionCardOptionBgHover
                : DifyColors.componentsOptionCardOptionBg,
            borderRadius: BorderRadius.circular(DifyRadius.lg),
            border: Border.all(
              color: w.selected
                  ? DifyColors.componentsOptionCardOptionSelectedBorder
                  : _hovered
                  ? DifyColors.componentsOptionCardOptionBorderHover
                  : DifyColors.componentsOptionCardOptionBorder,
              width: w.selected ? 1.5 : 1,
            ),
          ),
          child: !customSelected
              ? head
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                      decoration: const BoxDecoration(
                        border: Border(bottom: BorderSide(color: DifyColors.dividerSubtle)),
                      ),
                      child: head,
                    ),
                    GestureDetector(
                      onTap: () {}, // e.stopPropagation()
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: TagInput(
                          items: w.customFileTypes,
                          label: DifyI18n.tr('app-debug', 'variableConfig.file.custom.name'),
                          placeholder: DifyI18n.tr('app-debug', 'variableConfig.file.custom.createPlaceholder'),
                          onChange: (v) => w.onCustomFileTypesChange?.call(v),
                        ),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
