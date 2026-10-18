import 'package:flutter/widgets.dart';

import '../design/dify_tokens.g.dart';
import '../design/widgets/widgets.dart';
import '../workflow_editor/panel_fields/controls.dart' show DifyInput;
import 'auth_api.dart' show TransportException;
import 'widgets/auth_widgets.dart';

/// dify-sf's own page (Dify's web app comes from its server and never misses it): the server did not answer
/// `GET /v1/setup`. Shows the server's address (editable) and Retry, in the sign-in pages' frame.
class UnreachablePage extends StatefulWidget {
  const UnreachablePage({super.key, required this.server, required this.error, required this.onRetry});

  final String server;
  final Object error;
  final ValueChanged<String> onRetry;

  @override
  State<UnreachablePage> createState() => _UnreachablePageState();
}

class _UnreachablePageState extends State<UnreachablePage> {
  late String _server = widget.server;

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
          Text(
            e is TransportException ? e.message : '$e',
            style: difyTextStyle(DifyType.bodyMdRegular, DifyColors.textTertiary),
          ),
          const SizedBox(height: 16),
          Text('Server', style: difyTextStyle(DifyType.systemSmMedium, DifyColors.textSecondary)),
          DifyInput(
            key: const ValueKey('server-field'),
            value: _server,
            semanticLabel: 'Server',
            keyboardType: TextInputType.url,
            onChanged: (v) => _server = v,
            onSubmitted: (_) => widget.onRetry(_server.trim()),
          ),
          const SizedBox(height: 8),
          DifyButton(
            key: const ValueKey('server-retry'),
            variant: DifyButtonVariant.primary,
            onPressed: () => widget.onRetry(_server.trim()),
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}
