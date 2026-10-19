/// The Studio card's dialogs: explore/create-app-modal (Edit info; also its create mode), app/duplicate-modal, the
/// card's delete AlertDialog (type the app's name) and app/create-from-dsl-modal/dsl-confirm-modal.
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../design/dify_icon.dart';
import '../design/dify_tokens.g.dart';
import '../design/widgets/app_icon_picker.dart';
import '../design/widgets/widgets.dart';
import '../i18n/dify_i18n.dart';

String _a(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('app', key, params);
String _c(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('common', key, params);
String _e(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('explore', key, params);

/// base/app-icon-picker's `AppIconSelection`: an emoji ([icon] the character, [background]) or an uploaded image
/// ([icon] the file id, [url]).
typedef AppIconSelection = ({String type, String icon, String? background, String? url});

AppIconSelection appIconSelectionOf({String? iconType, String? icon, String? background, String? url}) =>
    iconType == 'image'
    ? (type: 'image', icon: icon ?? '', background: null, url: url)
    : (type: 'emoji', icon: icon ?? '', background: background, url: null);

/// Opens Dify's AppIconPicker on [current]; null when it was closed without a choice. Without [upload] (no file
/// storage) only the emoji tab is offered.
Future<AppIconSelection?> pickAppIcon(BuildContext context, AppIconSelection current, {UploadAppIcon? upload}) async {
  final v = await showDifyDialog<Map<String, Object?>>(
    context,
    builder: (context) => DifyAppIconPicker(
      initialEmoji: current.type == 'emoji' ? (icon: current.icon, background: current.background) : null,
      upload: upload,
      enableImageUpload: upload != null,
      onSelect: (value) => Navigator.pop(context, value),
      onCancel: () => Navigator.pop(context),
    ),
  );
  if (v == null) return null;
  if (v['type'] == 'image') {
    return (type: 'image', icon: '${v['fileId'] ?? ''}', background: null, url: v['url'] as String?);
  }
  return (type: 'emoji', icon: '${v['icon'] ?? ''}', background: v['background'] as String?, url: null);
}

/// Mod+Enter (Ctrl+Enter, Cmd+Enter on Apple platforms), Dify's `useHotkey('Mod+Enter', …, {ignoreInputs: false})`.
Map<ShortcutActivator, VoidCallback> modEnter(VoidCallback? run) => run == null
    ? const {}
    : {
        const SingleActivator(LogicalKeyboardKey.enter, control: true): run,
        const SingleActivator(LogicalKeyboardKey.enter, meta: true): run,
      };

/// A primary button's label with the Mod+Enter keycaps.
Widget labelWithModEnter(String label, {bool disabled = false}) => Row(
  mainAxisSize: MainAxisSize.min,
  spacing: 4,
  children: [
    Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis)),
    DifyShortcutKbd(hotkey: 'Mod+Enter', color: DifyKbdColor.white),
  ],
);

/// Takes the focus when the dialog opens (Base UI's initial focus), so its keyboard shortcuts work at once.
class _ModalFocus extends StatelessWidget {
  const _ModalFocus({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Focus(autofocus: true, child: child);
}

/// The modal's field label (`block py-2 text-sm leading-5 font-medium text-text-primary`).
Widget _label(String text) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 8),
  child: Text(
    text,
    style: TextStyle(fontSize: 14, height: 20 / 14, fontWeight: FontWeight.w500, color: DifyColors.textPrimary),
  ),
);

/// The dialogs' title (`text-xl leading-7.5 font-semibold text-text-primary`).
TextStyle get _titleStyle =>
    TextStyle(fontSize: 20, height: 30 / 20, fontWeight: FontWeight.w600, color: DifyColors.textPrimary);

/// What explore/create-app-modal's `onConfirm` receives.
typedef AppInfoPayload = ({
  String name,
  String iconType,
  String icon,
  String? iconBackground,
  String description,
  bool useIconAsAnswerIcon,
  int? maxActiveRequests,
});

/// explore/create-app-modal (`CreateAppModal`): name with its icon, description; in edit mode also "use the icon as
/// the answer icon" (chat modes) and the maximum of active requests. Saving (debounced 300 ms, also Mod+Enter)
/// calls [onConfirm] and closes at once. A click outside does not close it (`disablePointerDismissal`).
class EditAppModal extends StatefulWidget {
  const EditAppModal({
    super.key,
    this.isEditModal = false,
    required this.appName,
    this.appDescription = '',
    this.appIconType,
    required this.appIcon,
    this.appIconBackground,
    this.appIconUrl,
    this.appMode,
    this.appUseIconAsAnswerIcon = false,
    this.maxActiveRequests,
    required this.onConfirm,
    this.confirmDisabled = false,
    required this.onHide,
    this.uploadIcon,
  });

  final bool isEditModal;
  final String appName, appDescription, appIcon;
  final String? appIconType, appIconBackground, appIconUrl, appMode;
  final bool appUseIconAsAnswerIcon;
  final int? maxActiveRequests;
  final Future<void> Function(AppInfoPayload payload) onConfirm;
  final bool confirmDisabled;
  final VoidCallback onHide;
  final UploadAppIcon? uploadIcon;

  @override
  State<EditAppModal> createState() => _EditAppModalState();
}

class _EditAppModalState extends State<EditAppModal> {
  late String _name = widget.appName;
  late String _description = widget.appDescription;
  late AppIconSelection _icon = appIconSelectionOf(
    iconType: widget.appIconType,
    icon: widget.appIcon,
    background: widget.appIconBackground,
    url: widget.appIconUrl,
  );
  late bool _useIconAsAnswerIcon = widget.appUseIconAsAnswerIcon;
  late String _maxActiveRequests = widget.maxActiveRequests?.toString() ?? '';
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  bool get _chatMode => const {'chat', 'advanced-chat', 'agent-chat'}.contains(widget.appMode);
  bool get _canSubmit => _name.trim().isNotEmpty && !widget.confirmDisabled;

  void _submit() {
    if (_name.trim().isEmpty) {
      toast.error(_e('appCustomize.nameRequired'));
      return;
    }
    final parsed = num.tryParse(_maxActiveRequests.trim());
    unawaited(
      widget.onConfirm((
        name: _name,
        iconType: _icon.type,
        icon: _icon.icon,
        iconBackground: _icon.type == 'emoji' ? _icon.background : null,
        description: _description,
        useIconAsAnswerIcon: _useIconAsAnswerIcon,
        maxActiveRequests: _maxActiveRequests.trim().isEmpty || parsed == null ? null : parsed.toInt(),
      )),
    );
    widget.onHide();
  }

  /// `useDebounceFn(submit, {wait: 300})`.
  void _handleSubmit() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), _submit);
  }

  Future<void> _pickIcon() async {
    final v = await pickAppIcon(context, _icon, upload: widget.uploadIcon);
    if (v != null && mounted) setState(() => _icon = v);
  }

  @override
  Widget build(BuildContext context) {
    final submitLabel = widget.isEditModal ? _c('operation.save') : _c('operation.create');
    final title = widget.isEditModal ? _a('editAppTitle') : _e('appCustomize.title', {'name': widget.appName});
    return CallbackShortcuts(
      bindings: {
        ...modEnter(_canSubmit ? _handleSubmit : null),
        const SingleActivator(LogicalKeyboardKey.escape): widget.onHide,
      },
      child: _ModalFocus(
        child: DifyDialogSurface(
          label: title,
          bordered: true,
          scrollable: true,
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(right: 40),
                    child: Text(title, style: _titleStyle),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 36),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _label(_a('newApp.captionName')),
                              Row(
                                spacing: 8,
                                children: [
                                  DifyAppIcon(
                                    key: const ValueKey('app-modal-icon'),
                                    size: DifyAppIconSize.large,
                                    iconType: _icon.type,
                                    icon: _icon.icon,
                                    background: _icon.background,
                                    imageUrl: _icon.url,
                                    semanticLabel: _a('iconPicker.emoji'),
                                    onTap: _pickIcon,
                                  ),
                                  Expanded(
                                    child: DifyInput(
                                      key: const ValueKey('app-modal-name'),
                                      value: _name,
                                      height: 40,
                                      placeholder: _a('newApp.appNamePlaceholder'),
                                      semanticLabel: _a('newApp.captionName'),
                                      onChanged: (v) => setState(() => _name = v),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _label(_a('newApp.captionDescription')),
                              DifyTextarea(
                                key: const ValueKey('app-modal-description'),
                                value: _description,
                                placeholder: _a('newApp.appDescriptionPlaceholder'),
                                semanticLabel: _a('newApp.captionDescription'),
                                onChanged: (v) => setState(() => _description = v),
                              ),
                            ],
                          ),
                        ),
                        if (widget.isEditModal && _chatMode)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Row(
                                  children: [
                                    Expanded(child: _label(_a('answerIcon.title'))),
                                    DifySwitch(
                                      key: const ValueKey('app-modal-answer-icon'),
                                      checked: _useIconAsAnswerIcon,
                                      semanticLabel: _a('answerIcon.title'),
                                      onCheckedChange: (v) => setState(() => _useIconAsAnswerIcon = v),
                                    ),
                                  ],
                                ),
                                Text(
                                  _a('answerIcon.descriptionInExplore'),
                                  style: difyTextStyle(DifyType.bodyXsRegular, DifyColors.textTertiary),
                                ),
                              ],
                            ),
                          ),
                        if (widget.isEditModal)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 8),
                                  child: Text(
                                    _a('maxActiveRequests'),
                                    style: TextStyle(
                                      fontSize: 14,
                                      height: 20 / 14,
                                      fontWeight: FontWeight.w500,
                                      color: DifyColors.textPrimary,
                                    ),
                                  ),
                                ),
                                DifyInput(
                                  key: const ValueKey('app-modal-max-active-requests'),
                                  value: _maxActiveRequests,
                                  height: 40,
                                  keyboardType: TextInputType.number,
                                  placeholder: _a('maxActiveRequestsPlaceholder'),
                                  semanticLabel: _a('maxActiveRequests'),
                                  onChanged: (v) => setState(() => _maxActiveRequests = v),
                                ),
                                Padding(
                                  padding: const EdgeInsets.only(top: 8),
                                  child: Text(
                                    _a('maxActiveRequestsTip'),
                                    style: difyTextStyle(DifyType.bodyXsRegular, DifyColors.textTertiary),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    spacing: 8,
                    children: [
                      SizedBox(
                        width: 96,
                        child: DifyButton(
                          key: const ValueKey('app-modal-cancel'),
                          semanticLabel: _c('operation.cancel'),
                          onPressed: widget.onHide,
                          child: Text(_c('operation.cancel')),
                        ),
                      ),
                      Flexible(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(minWidth: 96),
                          child: DifyButton(
                            key: const ValueKey('app-modal-submit'),
                            variant: DifyButtonVariant.primary,
                            disabled: !_canSubmit,
                            semanticLabel: submitLabel,
                            onPressed: _handleSubmit,
                            child: labelWithModEnter(submitLabel, disabled: !_canSubmit),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              Positioned(
                top: 0,
                right: -8,
                child: DifyIconButton(
                  key: const ValueKey('app-modal-close'),
                  label: _c('operation.close'),
                  size: DifyIconButtonSize.lg,
                  icon: const RemixIcon('close-line', size: 16),
                  onPressed: widget.onHide,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shows [EditAppModal] (a click outside does not close it); completes when it closes.
Future<void> showEditAppModal(BuildContext context, EditAppModal Function(VoidCallback hide) builder) =>
    showDifyDialog<void>(context, dismissible: false, builder: (context) => builder(() => Navigator.pop(context)));

/// What app/duplicate-modal's `onConfirm` receives.
typedef DuplicatePayload = ({String name, String iconType, String icon, String? iconBackground});

/// app/duplicate-modal: the copy's name (the app's by default) and icon. Duplicate (also Enter in the name) calls
/// [onConfirm] and closes at once; an empty name shows `explore.appCustomize.nameRequired`.
class DuplicateAppModal extends StatefulWidget {
  const DuplicateAppModal({
    super.key,
    required this.appName,
    this.iconType,
    required this.icon,
    this.iconBackground,
    this.iconUrl,
    required this.onConfirm,
    required this.onHide,
    this.uploadIcon,
  });

  final String appName, icon;
  final String? iconType, iconBackground, iconUrl;
  final Future<void> Function(DuplicatePayload payload) onConfirm;
  final VoidCallback onHide;
  final UploadAppIcon? uploadIcon;

  @override
  State<DuplicateAppModal> createState() => _DuplicateAppModalState();
}

class _DuplicateAppModalState extends State<DuplicateAppModal> {
  late String _name = widget.appName;
  late AppIconSelection _icon = appIconSelectionOf(
    iconType: widget.iconType,
    icon: widget.icon,
    background: widget.iconBackground,
    url: widget.iconUrl,
  );

  void _submit() {
    if (_name.trim().isEmpty) {
      toast.error(_e('appCustomize.nameRequired'));
      return;
    }
    unawaited(
      widget.onConfirm((
        name: _name,
        iconType: _icon.type,
        icon: _icon.icon,
        iconBackground: _icon.type == 'emoji' ? _icon.background : null,
      )),
    );
    widget.onHide();
  }

  Future<void> _pickIcon() async {
    final v = await pickAppIcon(context, _icon, upload: widget.uploadIcon);
    if (v != null && mounted) setState(() => _icon = v);
  }

  @override
  Widget build(BuildContext context) {
    final title = _a('duplicateTitle');
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): widget.onHide},
      child: _ModalFocus(
        child: DifyDialogSurface(
          label: title,
          bordered: true,
          scrollable: true,
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 12, bottom: 36, right: 40),
                    child: Text(title, style: _titleStyle),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 36),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      spacing: 8,
                      children: [
                        Text(
                          _e('appCustomize.subTitle'),
                          style: difyTextStyle(DifyType.systemMdMedium, DifyColors.textSecondary),
                        ),
                        Row(
                          spacing: 8,
                          children: [
                            DifyAppIcon(
                              key: const ValueKey('duplicate-icon'),
                              size: DifyAppIconSize.large,
                              iconType: _icon.type,
                              icon: _icon.icon,
                              background: _icon.background,
                              imageUrl: _icon.url,
                              semanticLabel: '${_c('operation.edit')} ${_e('appCustomize.subTitle')}',
                              onTap: _pickIcon,
                            ),
                            Expanded(
                              child: DifyInput(
                                key: const ValueKey('duplicate-name'),
                                value: _name,
                                height: 40,
                                placeholder: _c('placeholder.input'),
                                semanticLabel: _e('appCustomize.subTitle'),
                                textInputAction: TextInputAction.done,
                                onSubmitted: (_) => _submit(),
                                onChanged: (v) => setState(() => _name = v),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    spacing: 8,
                    children: [
                      SizedBox(
                        width: 96,
                        child: DifyButton(
                          key: const ValueKey('duplicate-cancel'),
                          semanticLabel: _c('operation.cancel'),
                          onPressed: widget.onHide,
                          child: Text(_c('operation.cancel')),
                        ),
                      ),
                      SizedBox(
                        width: 96,
                        child: DifyButton(
                          key: const ValueKey('duplicate-submit'),
                          variant: DifyButtonVariant.primary,
                          semanticLabel: _a('duplicate'),
                          onPressed: _submit,
                          child: Text(_a('duplicate')),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              Positioned(
                top: -8,
                right: -16,
                child: DifyIconButton(
                  key: const ValueKey('duplicate-close'),
                  label: _c('operation.close'),
                  size: DifyIconButtonSize.lg,
                  icon: const RemixIcon('close-line', size: 16),
                  onPressed: widget.onHide,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The app card's delete AlertDialog: the title, the warning, "To confirm, type `<name>` in the box below" with an
/// input and its Fill button; Confirm stays disabled until the input matches [appName]. [onConfirm] runs while the
/// dialog shows its loading state; it closes on success (true).
class DeleteAppDialog extends StatefulWidget {
  const DeleteAppDialog({super.key, required this.appName, required this.onConfirm, required this.onClose});

  final String appName;
  final Future<bool> Function() onConfirm;
  final VoidCallback onClose;

  @override
  State<DeleteAppDialog> createState() => _DeleteAppDialogState();
}

class _DeleteAppDialogState extends State<DeleteAppDialog> {
  String _input = '';
  bool _deleting = false;

  bool get _mismatch => _input != widget.appName;

  Future<void> _submit() async {
    if (_deleting || _mismatch) return;
    setState(() => _deleting = true);
    final ok = await widget.onConfirm();
    if (!mounted) return;
    setState(() => _deleting = false);
    if (ok) widget.onClose();
  }

  @override
  Widget build(BuildContext context) {
    final label = _a('deleteAppConfirmInputLabel', {'appName': widget.appName});
    // `<appName>{{appName}}</appName>`: the name in system-sm-semibold text-text-primary.
    final parts = label.split(RegExp(r'</?appName>'));
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): () => _deleting ? null : widget.onClose()},
      child: DifyAlertDialog(
        title: _a('deleteAppConfirmTitle'),
        titleMaxLines: null,
        description: _a('deleteAppConfirmContent'),
        extra: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 4,
            children: [
              Text.rich(
                TextSpan(
                  children: [
                    for (final (i, p) in parts.indexed)
                      TextSpan(
                        text: p,
                        style: i == 1 && parts.length == 3
                            ? difyTextStyle(DifyType.systemSmSemibold, DifyColors.textPrimary)
                            : null,
                      ),
                  ],
                ),
                style: difyTextStyle(DifyType.systemSmRegular, DifyColors.textSecondary),
              ),
              DifyInput(
                key: const ValueKey('delete-app-input'),
                value: _input,
                placeholder: _a('deleteAppConfirmInputPlaceholder'),
                semanticLabel: label.replaceAll(RegExp(r'</?appName>'), ''),
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => unawaited(_submit()),
                onChanged: (v) => setState(() => _input = v),
                trailing: Padding(
                  padding: const EdgeInsets.only(right: 7),
                  child: DifyButton(
                    key: const ValueKey('delete-app-fill'),
                    variant: DifyButtonVariant.tertiary,
                    size: DifyButtonSize.small,
                    paddingX: 10,
                    semanticLabel: _c('operation.fill'),
                    onPressed: () => setState(() => _input = widget.appName),
                    child: Text(_c('operation.fill')),
                  ),
                ),
              ),
            ],
          ),
        ),
        cancelKey: const ValueKey('delete-app-cancel'),
        confirmKey: const ValueKey('delete-app-confirm'),
        semanticButtonLabels: true,
        cancelLabel: _c('operation.cancel'),
        confirmLabel: _c('operation.confirm'),
        cancelDisabled: _deleting,
        confirmDisabled: _mismatch,
        confirmLoading: _deleting,
        onCancel: widget.onClose,
        onConfirm: () => unawaited(_submit()),
      ),
    );
  }
}

/// dsl-confirm-modal: the imported file's DSL version differs from the server's; Confirm imports anyway.
class DSLConfirmModal extends StatelessWidget {
  const DSLConfirmModal({
    super.key,
    this.importedVersion = '',
    this.systemVersion = '',
    required this.onCancel,
    required this.onConfirm,
    this.confirmDisabled = false,
    this.confirmLoading = false,
  });

  final String importedVersion, systemVersion;
  final VoidCallback onCancel;
  final VoidCallback onConfirm;
  final bool confirmDisabled, confirmLoading;

  @override
  Widget build(BuildContext context) {
    final body = difyTextStyle(DifyType.systemMdRegular, DifyColors.textSecondary);
    final medium = difyTextStyle(DifyType.systemMdMedium, DifyColors.textSecondary);
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): () => confirmLoading ? null : onCancel()},
      child: DifyAlertDialog(
        title: _a('newApp.appCreateDSLErrorTitle'),
        titleMaxLines: null,
        extra: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_a('newApp.appCreateDSLErrorPart1'), style: body),
            Text(_a('newApp.appCreateDSLErrorPart2'), style: body),
            const SizedBox(height: 20),
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: _a('newApp.appCreateDSLErrorPart3')),
                  TextSpan(text: importedVersion, style: medium),
                ],
              ),
              style: body,
            ),
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: _a('newApp.appCreateDSLErrorPart4')),
                  TextSpan(text: systemVersion, style: medium),
                ],
              ),
              style: body,
            ),
          ],
        ),
        cancelKey: const ValueKey('dsl-confirm-cancel'),
        confirmKey: const ValueKey('dsl-confirm-confirm'),
        semanticButtonLabels: true,
        cancelLabel: _a('newApp.Cancel'),
        confirmLabel: _a('newApp.Confirm'),
        cancelDisabled: confirmLoading,
        confirmDisabled: confirmDisabled,
        confirmLoading: confirmLoading,
        onCancel: onCancel,
        onConfirm: onConfirm,
      ),
    );
  }
}
