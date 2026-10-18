/// FileUploadSetting (nodes/_base/components/file-upload-setting.tsx, file-type-item.tsx): the supported file
/// types, the upload method and, for lists, the maximum number of uploads, as the Start node's input field dialog and
/// the human input form use it.
library;

import 'dart:ui' show SemanticsRole;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../cards/card_kit.dart';
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';
import '../../workflow/dify_json.dart';
import '../prompt_editor/prompt_blocks.dart' show fileExts;
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
    final error = validationError;
    // The error describes the checkboxes (a file type error) or only the custom extensions' input.
    final typeError = error?.field == 'allowed_file_types' ? error!.message : null;
    final extensionError = error?.field == 'allowed_file_extensions' ? error!.message : null;
    final fileTypes = ModalField(
      title: ad('variableConfig.file.supportFileTypes'),
      errorMessage: error?.message,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 4,
        children: [
          for (final t in const ['document', 'image', 'audio', 'video'])
            FileTypeItem(type: t, selected: types.contains(t), onToggle: _toggleType, typeError: typeError),
          FileTypeItem(
            type: 'custom',
            selected: types.contains('custom'),
            onToggle: _toggleType,
            customFileTypes: _strings('allowed_file_extensions'),
            onCustomFileTypesChange: (v) => onChange({...payload, 'allowed_file_extensions': v}),
            typeError: typeError,
            customFileTypesError: extensionError,
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
        UploadMethodRadioGroup(
          label: ad('variableConfig.uploadFileTypes'),
          value: selectedMethod,
          options: [
            ('local_file', ad('variableConfig.localUpload')),
            ('remote_url', 'URL'),
            ('all', ad('variableConfig.both')),
          ],
          onChange: (value) => onChange({
            ...payload,
            'allowed_file_upload_methods': value == 'all' ? ['local_file', 'remote_url'] : [value],
          }),
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
                  value: max is num ? (max.isFinite ? max.toInt() : max) : 1,
                  defaultValue: 1,
                  min: 1,
                  max: maxFileUploadLimit,
                  // `handleMaxUploadNumLimitChange`: a number is kept in range; an emptied field stays empty until
                  // the input's blur puts the default back.
                  onChange: (v) => onChange({
                    ...payload,
                    'max_length': v.isFinite ? v.round().clamp(1, maxFileUploadLimit) : v,
                  }),
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

/// The upload methods (`RadioGroup` of `h-8 rounded-md border px-2 system-sm-regular` items, the checked one
/// `border-[1.5px]` in the selected colours with `shadow-xs`): one tab stop (the checked item, else the first); the
/// arrow keys move to the next or previous item and check it, wrapping around.
class UploadMethodRadioGroup extends StatefulWidget {
  const UploadMethodRadioGroup({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.onChange,
  });

  final String label;
  final String? value;
  final List<(String, String)> options;
  final ValueChanged<String> onChange;

  @override
  State<UploadMethodRadioGroup> createState() => _UploadMethodRadioGroupState();
}

class _UploadMethodRadioGroupState extends State<UploadMethodRadioGroup> {
  late List<FocusNode> _nodes = _make();
  final _hovered = <int>{};

  List<FocusNode> _make() => [
    for (final (i, _) in widget.options.indexed)
      FocusNode(debugLabel: 'upload method $i', onKeyEvent: (_, e) => _onKey(i, e)),
  ];

  @override
  void didUpdateWidget(UploadMethodRadioGroup old) {
    super.didUpdateWidget(old);
    if (old.options.length != widget.options.length) {
      for (final n in _nodes) {
        n.dispose();
      }
      _nodes = _make();
    }
  }

  @override
  void dispose() {
    for (final n in _nodes) {
      n.dispose();
    }
    super.dispose();
  }

  int get _tabStop {
    final i = widget.options.indexWhere((o) => o.$1 == widget.value);
    return i < 0 ? 0 : i;
  }

  KeyEventResult _onKey(int i, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    final n = widget.options.length;
    int? next;
    if (k == LogicalKeyboardKey.arrowRight || k == LogicalKeyboardKey.arrowDown) next = (i + 1) % n;
    if (k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.arrowUp) next = (i - 1 + n) % n;
    if (k == LogicalKeyboardKey.space || k == LogicalKeyboardKey.enter) next = i;
    if (next == null) return KeyEventResult.ignored;
    _nodes[next].requestFocus();
    widget.onChange(widget.options[next].$1);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final tabStop = _tabStop;
    return Semantics(
      role: SemanticsRole.radioGroup,
      label: w.label,
      container: true,
      child: Row(
        spacing: 8,
        children: [
          for (final (i, (value, label)) in w.options.indexed)
            Expanded(
              child: ListenableBuilder(
                listenable: _nodes[i],
                builder: (context, _) {
                  final checked = value == w.value;
                  final hovered = _hovered.contains(i) && !checked;
                  final focused = _nodes[i].hasFocus;
                  return Semantics(
                    inMutuallyExclusiveGroup: true,
                    checked: checked,
                    label: label,
                    child: Focus(
                      focusNode: _nodes[i],
                      skipTraversal: i != tabStop,
                      child: MouseRegion(
                        cursor: checked ? SystemMouseCursors.basic : SystemMouseCursors.click,
                        onEnter: (_) => setState(() => _hovered.add(i)),
                        onExit: (_) => setState(() => _hovered.remove(i)),
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () {
                            _nodes[i].requestFocus();
                            if (!checked) w.onChange(value);
                          },
                          child: Container(
                            height: 32,
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: checked
                                  ? DifyColors.componentsOptionCardOptionSelectedBg
                                  : hovered
                                  ? DifyColors.componentsOptionCardOptionBgHover
                                  : DifyColors.componentsOptionCardOptionBg,
                              borderRadius: BorderRadius.circular(DifyRadius.md),
                              border: Border.all(
                                color: checked
                                    ? DifyColors.componentsOptionCardOptionSelectedBorder
                                    : hovered
                                    ? DifyColors.componentsOptionCardOptionBorderHover
                                    : DifyColors.componentsOptionCardOptionBorder,
                                width: checked ? 1.5 : 1,
                              ),
                              boxShadow: [
                                if (checked || hovered) ...DifyShadows.xs,
                                if (focused) const BoxShadow(color: DifyColors.stateAccentSolid, spreadRadius: 2),
                              ],
                            ),
                            child: ExcludeSemantics(
                              child: DifyText(label, DifyType.systemSmRegular, color: DifyColors.textSecondary),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

/// file-type-item.tsx: an option card with the file type's icon, name, extensions and checkbox; the custom type,
/// when selected, edits its extensions in a tag input. [typeError] marks the checkbox invalid and describes it;
/// [customFileTypesError] does the same for the extensions' input.
class FileTypeItem extends StatefulWidget {
  const FileTypeItem({
    super.key,
    required this.type,
    required this.selected,
    required this.onToggle,
    this.customFileTypes = const [],
    this.onCustomFileTypesChange,
    this.typeError,
    this.customFileTypesError,
  });
  final String type;
  final bool selected;
  final ValueChanged<String> onToggle;
  final List<String> customFileTypes;
  final ValueChanged<List<String>>? onCustomFileTypesChange;
  final String? typeError, customFileTypesError;

  @override
  State<FileTypeItem> createState() => _FileTypeItemState();
}

class _FileTypeItemState extends State<FileTypeItem> {
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
          child: DifyCheckbox(
            checked: w.selected,
            label: name,
            invalid: w.typeError != null,
            description: w.typeError,
            onChanged: (_) => w.onToggle(w.type),
          ),
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
                          invalid: w.customFileTypesError != null,
                          description: w.customFileTypesError,
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
