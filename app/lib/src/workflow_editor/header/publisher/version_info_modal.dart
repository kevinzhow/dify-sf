import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../../../design/dify_icon.dart';
import '../../../design/dify_tokens.g.dart';
import '../../../design/widgets/widgets.dart';
import '../../../i18n/dify_i18n.dart';
import 'summary_section.dart';

/// dify-ui's toast types.
typedef PublisherToastType = DifyToastType;

/// Shows a toast (dify-ui's `toast.success` / `toast.error`).
typedef PublisherToast = void Function(PublisherToastType type, String message);

/// What the version info modal saves (`{ title, releaseNotes, id }`).
typedef VersionInfoUpdate = ({String? id, String title, String releaseNotes});

const _titleMaxLength = 15;
const _releaseNotesMaxLength = 100;

String _w(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('workflow', key, params);

/// version-info-modal.tsx as a dialog route: names the published version (title up to 15 characters, release notes
/// up to 100; longer ones are refused with an error toast). Save hands the values to [onPublish] and closes;
/// Escape, a tap on the backdrop, the close button and Cancel just close. [onClose] runs once the dialog is closed,
/// however it closed.
Future<void> showVersionInfoModal(
  BuildContext context, {
  PublishedWorkflowInfo? versionInfo,
  required ValueChanged<VersionInfoUpdate> onPublish,
  VoidCallback? onClose,
  PublisherToast? onToast,
}) async {
  await showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    // modalBackdropClassName: `bg-background-overlay`, modalPopupAnimationClassName: scale 0.95 and fade, 150 ms.
    barrierColor: DifyColors.backgroundOverlay,
    transitionDuration: difyTransitionDuration,
    transitionBuilder: (context, animation, _, child) {
      final a = CurvedAnimation(parent: animation, curve: difyTransitionCurve);
      return FadeTransition(
        opacity: a,
        child: ScaleTransition(scale: Tween(begin: 0.95, end: 1.0).animate(a), child: child),
      );
    },
    pageBuilder: (context, _, _) => VersionInfoModal(versionInfo: versionInfo, onPublish: onPublish, onToast: onToast),
  );
  onClose?.call();
}

/// The modal's content (DialogContent `w-full max-w-120 overflow-hidden border-none p-0`: `rounded-2xl
/// bg-components-panel-bg shadow-xl`, centred, at most the viewport less 2 rem wide).
class VersionInfoModal extends StatefulWidget {
  const VersionInfoModal({super.key, this.versionInfo, required this.onPublish, this.onToast});

  final PublishedWorkflowInfo? versionInfo;
  final ValueChanged<VersionInfoUpdate> onPublish;
  final PublisherToast? onToast;

  @override
  State<VersionInfoModal> createState() => _VersionInfoModalState();
}

class _VersionInfoModalState extends State<VersionInfoModal> {
  late final _title = TextEditingController(text: widget.versionInfo?.markedName ?? '');
  late final _notes = TextEditingController(text: widget.versionInfo?.markedComment ?? '');
  bool _titleError = false;
  bool _notesError = false;

  @override
  void dispose() {
    _title.dispose();
    _notes.dispose();
    super.dispose();
  }

  void _close() => Navigator.of(context).pop();

  void _save() {
    final title = _title.text, notes = _notes.text;
    if (title.length > _titleMaxLength) {
      setState(() => _titleError = true);
      widget.onToast?.call(
        PublisherToastType.error,
        _w('versionHistory.editField.titleLengthLimit', {'limit': _titleMaxLength}),
      );
      return;
    }
    if (_titleError) setState(() => _titleError = false);
    if (notes.length > _releaseNotesMaxLength) {
      setState(() => _notesError = true);
      widget.onToast?.call(
        PublisherToastType.error,
        _w('versionHistory.editField.releaseNotesLengthLimit', {'limit': _releaseNotesMaxLength}),
      );
      return;
    }
    if (_notesError) setState(() => _notesError = false);
    widget.onPublish((title: title, releaseNotes: notes, id: widget.versionInfo?.id));
    _close();
  }

  @override
  Widget build(BuildContext context) {
    final named = widget.versionInfo?.markedName.isNotEmpty ?? false;
    final heading = named ? _w('versionHistory.editVersionInfo') : _w('versionHistory.nameThisVersion');
    final optional = _w('panel.optional');
    final label = difyTextStyle(DifyType.systemSmSemibold, DifyColors.textSecondary);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 480, maxHeight: MediaQuery.sizeOf(context).height * 0.8),
          child: Material(
            type: MaterialType.transparency,
            child: Semantics(
              container: true,
              role: SemanticsRole.dialog,
              explicitChildNodes: true,
              label: heading,
              child: Container(
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: DifyColors.componentsPanelBg,
                  borderRadius: BorderRadius.circular(DifyRadius.xxl),
                  boxShadow: DifyShadows.xl,
                ),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Stack(
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(24, 24, 56, 16),
                            child: Text(
                              heading.isEmpty ? heading : heading[0].toUpperCase() + heading.substring(1),
                              style: difyTextStyle(DifyType.title2xlSemiBold, DifyColors.textPrimary),
                            ),
                          ),
                          Positioned(
                            top: 20,
                            right: 20,
                            child: DifyIconButton(
                              label: DifyI18n.tr('common', 'operation.close'),
                              size: DifyIconButtonSize.lg,
                              icon: RemixIcon('close-line', size: 18, color: DifyColors.textTertiary),
                              onPressed: _close,
                            ),
                          ),
                        ],
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          spacing: 16,
                          children: [
                            _Field(
                              label: Text(_w('versionHistory.editField.title'), style: label),
                              child: DifyTextControl(
                                controller: _title,
                                invalid: _titleError,
                                placeholder: '${_w('versionHistory.nameThisVersion')}$optional',
                              ),
                            ),
                            _Field(
                              label: Text(_w('versionHistory.editField.releaseNotes'), style: label),
                              child: DifyTextControl(
                                controller: _notes,
                                invalid: _notesError,
                                multiline: true,
                                placeholder: '${_w('versionHistory.releaseNotesPlaceholder')}$optional',
                              ),
                            ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
                        child: Wrap(
                          alignment: WrapAlignment.end,
                          spacing: 12,
                          runSpacing: 12,
                          children: [
                            DifyButton(onPressed: _close, child: Text(DifyI18n.tr('common', 'operation.cancel'))),
                            DifyButton(
                              variant: DifyButtonVariant.primary,
                              onPressed: _save,
                              child: Text(DifyI18n.tr('common', 'operation.save')),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Field `grid gap-y-1` with its FieldLabel (`flex h-6 items-center`).
class _Field extends StatelessWidget {
  const _Field({required this.label, required this.child});
  final Widget label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    spacing: 4,
    children: [
      SizedBox(
        height: 24,
        child: Align(alignment: AlignmentDirectional.centerStart, child: label),
      ),
      child,
    ],
  );
}

/// dify-ui's Input (`rounded-lg border border-transparent bg-components-input-bg-normal px-3 py-1.75
/// system-sm-regular`) and Textarea (medium: `min-h-20 rounded-lg px-3 py-2`): hover, focus (`shadow-xs`, active
/// border and background) and invalid (`data-invalid`, destructive border and background) states.
class DifyTextControl extends StatefulWidget {
  const DifyTextControl({
    super.key,
    required this.controller,
    this.placeholder,
    this.invalid = false,
    this.multiline = false,
  });

  final TextEditingController controller;
  final String? placeholder;
  final bool invalid;
  final bool multiline;

  @override
  State<DifyTextControl> createState() => _DifyTextControlState();
}

class _DifyTextControlState extends State<DifyTextControl> {
  final _focus = FocusNode();
  bool _hovered = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final focused = _focus.hasFocus;
    final (bg, border) = widget.invalid
        ? (DifyColors.componentsInputBgDestructive, DifyColors.componentsInputBorderDestructive)
        : focused
        ? (DifyColors.componentsInputBgActive, DifyColors.componentsInputBorderActive)
        : _hovered
        ? (DifyColors.componentsInputBgHover, DifyColors.componentsInputBorderHover)
        : (DifyColors.componentsInputBgNormal, const Color(0x00000000));
    final style = difyTextStyle(DifyType.systemSmRegular, DifyColors.componentsInputTextFilled);
    final field = TextField(
      controller: widget.controller,
      focusNode: _focus,
      style: style,
      cursorColor: const Color(0xFF155EEF), // caret-primary-600
      cursorWidth: 1,
      maxLines: widget.multiline ? null : 1,
      expands: widget.multiline,
      textAlignVertical: TextAlignVertical.top,
      keyboardType: widget.multiline ? TextInputType.multiline : TextInputType.text,
      decoration: InputDecoration.collapsed(
        hintText: widget.placeholder,
        hintStyle: style.copyWith(color: DifyColors.componentsInputTextPlaceholder),
      ),
    );
    return MouseRegion(
      cursor: SystemMouseCursors.text,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: difyTransitionDuration,
        curve: difyTransitionCurve,
        height: widget.multiline ? 80 : null,
        padding: widget.multiline
            ? const EdgeInsets.symmetric(horizontal: 12, vertical: 8)
            : const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: bg,
          border: Border.all(color: border),
          borderRadius: BorderRadius.circular(DifyRadius.lg),
          boxShadow: focused ? DifyShadows.xs : null,
        ),
        child: field,
      ),
    );
  }
}
