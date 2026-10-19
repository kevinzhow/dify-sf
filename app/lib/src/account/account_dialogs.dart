/// The account page's dialogs (account-page/index.tsx): Edit Name and Reset password.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../auth/auth_controller.dart';
import '../auth/validation.dart';
import '../design/dify_tokens.g.dart';
import '../design/widgets/widgets.dart';
import '../settings/members/member_menu.dart' show requestErrorMessage;
import '../settings/settings_kit.dart';
import '../workflow_editor/panel_fields/controls.dart' show DifyInput;

/// Shows Edit Name for the signed-in account of [auth].
Future<void> showEditNameDialog(BuildContext context, AuthController auth) =>
    showSettingsDialog<void>(context, (context) => EditNameDialog(auth: auth));

/// Shows Reset password for the signed-in account of [auth].
Future<void> showPasswordDialog(BuildContext context, AuthController auth) =>
    showSettingsDialog<void>(context, (context) => PasswordDialog(auth: auth));

TextStyle get _label => difyTextStyle(DifyType.systemSmSemibold, DifyColors.textSecondary);

Widget _title(String text) => Padding(
  padding: const EdgeInsets.only(bottom: 24),
  child: Text(text, style: difyTextStyle(DifyType.title2xlSemiBold, DifyColors.textPrimary)),
);

/// `w-105 p-6`: "Edit Name", the Name input (the current name), Cancel and Save (`primary`, disabled while saving or
/// when the name is empty). Saving (`PUT /v1/account/name`) toasts "Modified successfully" and closes; a refusal toasts
/// the server's message and stays open.
class EditNameDialog extends StatefulWidget {
  const EditNameDialog({super.key, required this.auth});

  final AuthController auth;

  @override
  State<EditNameDialog> createState() => _EditNameDialogState();
}

class _EditNameDialogState extends State<EditNameDialog> {
  late String _name = widget.auth.account?.name ?? '';
  bool _editing = false;

  Future<void> _save() async {
    setState(() => _editing = true);
    try {
      await widget.auth.session.updateName(_name);
      if (!mounted) return;
      toast.success(stc(context, 'actionMsg.modifiedSuccessfully'));
      Navigator.of(context).pop();
    } on Object catch (e) {
      toast.error(requestErrorMessage(e));
      if (mounted) setState(() => _editing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = stc(context, 'account.editName'), label = stc(context, 'account.name');
    return SettingsDialogContent(
      label: title,
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _title(title),
          Text(label, style: _label),
          const SizedBox(height: 8),
          DifyInput(
            key: const ValueKey('edit-name-input'),
            semanticLabel: label,
            value: _name,
            onChanged: (v) => setState(() => _name = v),
            onSubmitted: (_) {
              if (!_editing && _name.isNotEmpty) unawaited(_save());
            },
          ),
          const SizedBox(height: 40),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            spacing: 8,
            children: [
              Flexible(
                child: DifyButton(
                  semanticLabel: stc(context, 'operation.cancel'),
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(stc(context, 'operation.cancel')),
                ),
              ),
              Flexible(
                child: DifyButton(
                  key: const ValueKey('edit-name-save'),
                  semanticLabel: stc(context, 'operation.save'),
                  variant: DifyButtonVariant.primary,
                  disabled: _editing || _name.isEmpty,
                  onPressed: () => unawaited(_save()),
                  child: Text(stc(context, 'operation.save')),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// `w-105 p-6`: "Reset password" with the current password, the new one and its confirmation (each an InputGroup with
/// the show / hide toggle, `mt-8` apart), Cancel and Reset. Dify's checks run first ("Password is required", its
/// password rule, "Two passwords are different."); then `PUT /v1/account/password` toasts "Modified successfully" or the
/// server's message, and the dialog closes either way (as Dify's).
class PasswordDialog extends StatefulWidget {
  const PasswordDialog({super.key, required this.auth});

  final AuthController auth;

  @override
  State<PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<PasswordDialog> {
  String _current = '', _password = '', _confirm = '';
  bool _showCurrent = false, _showPassword = false, _showConfirm = false, _editing = false;

  String _t(String ns, String key) => st(context, ns, key);

  bool _valid() {
    if (_password.trim().isEmpty) {
      toast.error(_t('login', 'error.passwordEmpty'));
      return false;
    }
    if (!validPassword.hasMatch(_password)) {
      toast.error(_t('login', 'error.passwordInvalid'));
      return false;
    }
    if (_password != _confirm) {
      toast.error(_t('common', 'account.notEqual'));
      return false;
    }
    return true;
  }

  Future<void> _save() async {
    if (!_valid()) return;
    setState(() => _editing = true);
    try {
      await widget.auth.session.updatePassword(
        password: _current,
        newPassword: _password,
        repeatNewPassword: _confirm,
      );
      if (mounted) toast.success(stc(context, 'actionMsg.modifiedSuccessfully'));
    } on Object catch (e) {
      toast.error(requestErrorMessage(e));
    }
    if (mounted) Navigator.of(context).pop();
  }

  Widget _field({
    required Key key,
    required String label,
    required String value,
    required bool shown,
    required ValueChanged<String> onChanged,
    required VoidCallback onToggle,
    required List<String> autofill,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(label, style: _label),
      const SizedBox(height: 8),
      DifyInput(
        key: key,
        semanticLabel: label,
        value: value,
        obscureText: !shown,
        autofillHints: autofill,
        onChanged: onChanged,
        trailing: DifyIconButton(
          label: _t('login', shown ? 'hidePassword' : 'showPassword'),
          size: DifyIconButtonSize.lg,
          icon: Text(shown ? '👀' : '😝'),
          onPressed: onToggle,
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final title = stc(context, 'account.resetPassword');
    return SettingsDialogContent(
      label: title,
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _title(title),
          _field(
            key: const ValueKey('password-current'),
            label: stc(context, 'account.currentPassword'),
            value: _current,
            shown: _showCurrent,
            onChanged: (v) => setState(() => _current = v),
            onToggle: () => setState(() => _showCurrent = !_showCurrent),
            autofill: const [AutofillHints.password],
          ),
          const SizedBox(height: 32),
          _field(
            key: const ValueKey('password-new'),
            label: stc(context, 'account.newPassword'),
            value: _password,
            shown: _showPassword,
            onChanged: (v) => setState(() => _password = v),
            onToggle: () => setState(() => _showPassword = !_showPassword),
            autofill: const [AutofillHints.newPassword],
          ),
          const SizedBox(height: 32),
          _field(
            key: const ValueKey('password-confirm'),
            label: stc(context, 'account.confirmPassword'),
            value: _confirm,
            shown: _showConfirm,
            onChanged: (v) => setState(() => _confirm = v),
            onToggle: () => setState(() => _showConfirm = !_showConfirm),
            autofill: const [AutofillHints.newPassword],
          ),
          const SizedBox(height: 40),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            spacing: 8,
            children: [
              Flexible(
                child: DifyButton(
                  semanticLabel: stc(context, 'operation.cancel'),
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(stc(context, 'operation.cancel')),
                ),
              ),
              Flexible(
                child: DifyButton(
                  key: const ValueKey('password-save'),
                  semanticLabel: stc(context, 'operation.reset'),
                  variant: DifyButtonVariant.primary,
                  disabled: _editing,
                  onPressed: () => unawaited(_save()),
                  child: Text(stc(context, 'operation.reset')),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
