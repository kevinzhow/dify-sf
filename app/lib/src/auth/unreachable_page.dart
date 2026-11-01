import 'package:flutter/widgets.dart';

import 'dart:async';

import '../design/dify_tokens.g.dart';
import '../design/widgets/widgets.dart';
import 'auth_api.dart' show TransportException;
import 'widgets/auth_widgets.dart';
import 'server_address_form.dart';

/// dify-sf's own page (Dify's web app comes from its server and never misses it): the server did not answer
/// `GET /v1/setup`. Shows the server's address (editable) and Retry, in the sign-in pages' frame.
class UnreachablePage extends StatefulWidget {
  const UnreachablePage({
    super.key,
    required this.server,
    required this.error,
    required this.onRetry,
  });

  final String server;
  final Object error;
  final FutureOr<void> Function(String) onRetry;

  @override
  State<UnreachablePage> createState() => _UnreachablePageState();
}

class _UnreachablePageState extends State<UnreachablePage> {
  late final String _server = widget.server;

  @override
  Widget build(BuildContext context) {
    final e = widget.error;
    return SignInLayout(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 8,
        children: [
          AuthHeading(
            'Cannot reach the server',
            style: difyTextStyle(DifyType.title2xlSemiBold, DifyColors.textPrimary),
          ),
          DifyTextLine(
            e is TransportException ? e.message : '$e',
            style: difyTextStyle(DifyType.bodyMdRegular, DifyColors.textTertiary),
          ),
          const SizedBox(height: 16),
          ServerAddressForm(
            server: _server,
            onConnect: (server) async => await widget.onRetry(server),
            inputKey: const ValueKey('server-field'),
            buttonKey: const ValueKey('server-retry'),
            buttonLabel: serverText(context, 'retry'),
          ),
        ],
      ),
    );
  }
}
