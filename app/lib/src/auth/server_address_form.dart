import 'package:flutter/services.dart' show TextInputAction;
import 'package:flutter/widgets.dart';

import '../design/dify_tokens.g.dart';
import '../design/widgets/widgets.dart';
import '../i18n/app_locale.dart';
import '../i18n/dify_i18n.dart';
import '../server_address.dart';
import '../server_connection.dart';
import 'widgets/auth_widgets.dart';

String serverText(BuildContext context, String key) {
  AppLocaleScope.of(context);
  return DifyI18n.tr('server-connection', key);
}

/// The native connection picker uses the same Dify input/button/dialog components as account settings.
class ServerAddressForm extends StatefulWidget {
  const ServerAddressForm({
    super.key,
    required this.server,
    required this.onConnect,
    this.onConnected,
    this.inputKey = const ValueKey('server-address-input'),
    this.buttonKey = const ValueKey('server-address-connect'),
    this.buttonLabel,
  });
  final String server;
  final Future<void> Function(String) onConnect;
  final VoidCallback? onConnected;
  final Key inputKey, buttonKey;
  final String? buttonLabel;

  @override
  State<ServerAddressForm> createState() => _ServerAddressFormState();
}

class _ServerAddressFormState extends State<ServerAddressForm> {
  late String _value = widget.server;
  String? _error;
  bool _busy = false;

  Future<void> _connect() async {
    if (_busy) return;
    String address;
    try {
      address = normalizeServerAddress(_value);
    } on ServerAddressException catch (e) {
      setState(() => _error = serverText(context, e.problem.name));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onConnect(address);
      if (mounted) widget.onConnected?.call();
    } on Object {
      if (mounted) setState(() => _error = serverText(context, 'saveFailed'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    spacing: 12,
    children: [
      DifyTextLine(
        serverText(context, 'address'),
        style: difyTextStyle(DifyType.systemSmMedium, DifyColors.textSecondary),
      ),
      DifyInput(
        key: widget.inputKey,
        value: _value,
        semanticLabel: serverText(context, 'address'),
        placeholder: 'https://dify.example.com',
        keyboardType: TextInputType.url,
        // The keyboard's Go connects.
        textInputAction: TextInputAction.go,
        disabled: _busy,
        invalid: _error != null,
        onChanged: (v) => _value = v,
        onSubmitted: (_) => _connect(),
      ),
      DifyTextLine(
        serverText(context, 'originHint'),
        style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textTertiary),
      ),
      if (_error != null)
        Semantics(
          liveRegion: true,
          child: DifyTextLine(
            _error!,
            key: const ValueKey('server-address-error'),
            style: difyTextStyle(DifyType.systemSmRegular, DifyColors.textDestructive),
          ),
        ),
      DifyPrimaryAction(
        child: DifyButton(
          key: widget.buttonKey,
          variant: DifyButtonVariant.primary,
          onPressed: _busy ? null : _connect,
          child: _busy ? const DifyLoading() : DifyTextLine(widget.buttonLabel ?? serverText(context, 'connect')),
        ),
      ),
    ],
  );
}

class ServerAddressPage extends StatelessWidget {
  const ServerAddressPage({super.key, required this.connection});
  final ServerConnectionController connection;

  @override
  Widget build(BuildContext context) => SignInLayout(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      spacing: 24,
      children: [
        AuthHeading(
          serverText(context, 'title'),
          style: difyTextStyle(DifyType.title2xlSemiBold, DifyColors.textPrimary),
        ),
        ServerAddressForm(
          server: connection.server,
          onConnect: connection.select,
        ),
      ],
    ),
  );
}

Future<void> showServerAddressDialog(BuildContext context, ServerConnectionController connection) =>
    showDifyDialog<void>(
      context,
      builder: (context) => DifyDialogSurface(
        label: serverText(context, 'switch'),
        padding: const EdgeInsets.all(24),
        scrollable: true,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 16,
          children: [
            DifyTextLine(
              serverText(context, 'switch'),
              style: difyTextStyle(DifyType.title2xlSemiBold, DifyColors.textPrimary),
            ),
            DifyTextLine(serverText(context, 'switchHint')),
            ServerAddressForm(
              server: connection.server,
              onConnect: connection.select,
              onConnected: () {
                // AppRoot already dismisses every route when it replaces the connection. The old dialog can remain
                // mounted during its exit animation; popping it again would pop the new root page as well.
                if (ModalRoute.of(context)?.isCurrent ?? false) Navigator.of(context).pop();
              },
            ),
          ],
        ),
      ),
    );

class NativeServerButton extends StatelessWidget {
  const NativeServerButton({super.key, required this.connection});
  final ServerConnectionController connection;

  @override
  Widget build(BuildContext context) => DifyButton(
    key: const ValueKey('server-change'),
    onPressed: connection.busy ? null : () => showServerAddressDialog(context, connection),
    child: DifyTextLine(
      '${serverText(context, 'server')}: ${connection.server}',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    ),
  );
}
